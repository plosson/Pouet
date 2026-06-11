// AudioService.swift — Audio proxies built on AVAudioEngine + the loopback driver
//
// On macOS a single AVAudioEngine cannot run input and output on two DIFFERENT
// devices: the input side silently never starts (zero buffers, no error). Each
// proxy therefore uses TWO engines bridged by a ring buffer:
//
//   capture engine (input device, tap) → ring buffer → playback engine
//                                        (source node → mixer → output device)
//
//   Mic proxy:     real mic → ring → [+ inject submixer] → PouetMicrophone
//   Speaker proxy: PouetSpeaker → ring → real speakers
//                  (capture tap also feeds the dashcam rolling buffer)

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import os

// MARK: - Audio Device Info

struct AudioDeviceInfo: Identifiable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannels: Int
}

// MARK: - AudioService

private func peakLevel(from buffer: AVAudioPCMBuffer) -> Float {
    guard let channelData = buffer.floatChannelData else { return 0.0 }
    let frameLength = Int(buffer.frameLength)
    var peak: Float = 0.0
    for ch in 0..<Int(buffer.format.channelCount) {
        for i in 0..<frameLength {
            let abs = Swift.abs(channelData[ch][i])
            if abs > peak { peak = abs }
        }
    }
    return peak
}

private func peakLevel(of samples: UnsafeBufferPointer<Float>) -> Float {
    var peak: Float = 0.0
    for value in samples {
        let abs = Swift.abs(value)
        if abs > peak { peak = abs }
    }
    return peak
}

/// Single-producer single-consumer interleaved float ring buffer bridging the
/// capture and playback engines. Underruns produce silence; overruns drop the
/// oldest samples (absorbs clock drift between the two devices).
private final class AudioRingBuffer {
    private struct State {
        var storage: [Float]
        var readIndex = 0
        var writeIndex = 0
    }
    private let capacity: Int  // in samples
    private let channels: Int
    private let state: OSAllocatedUnfairLock<State>

    init(frameCapacity: Int, channels: Int) {
        self.capacity = frameCapacity * channels
        self.channels = channels
        self.state = OSAllocatedUnfairLock(
            initialState: State(storage: [Float](repeating: 0, count: frameCapacity * channels)))
    }

    func writeInterleaved(_ samples: UnsafeBufferPointer<Float>, channels bufferChannels: Int) {
        guard bufferChannels > 0 else { return }
        let frames = samples.count / bufferChannels
        state.withLockUnchecked { s in
            for f in 0..<frames {
                for ch in 0..<channels {
                    s.storage[s.writeIndex % capacity] = samples[f * bufferChannels + min(ch, bufferChannels - 1)]
                    s.writeIndex += 1
                }
            }
            if s.writeIndex - s.readIndex > capacity {
                // overrun: skip the oldest samples, staying frame-aligned
                let lag = s.writeIndex - s.readIndex - capacity
                s.readIndex += ((lag + channels - 1) / channels) * channels
            }
        }
    }

    /// Fill a deinterleaved AudioBufferList (one buffer per channel), padding
    /// with silence when not enough samples are buffered yet.
    func read(into bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        state.withLockUnchecked { s in
            for f in 0..<frameCount {
                let frameAvailable = (s.writeIndex - s.readIndex) >= channels
                for (ch, buffer) in buffers.enumerated() {
                    let out = UnsafeMutableBufferPointer<Float>(buffer)
                    guard f < out.count else { continue }
                    out[f] = frameAvailable ? s.storage[(s.readIndex + min(ch, channels - 1)) % capacity] : 0
                }
                if frameAvailable { s.readIndex += channels }
            }
        }
    }
}

/// One audio proxy: a raw HAL IOProc reading the input device, an AVAudioEngine
/// writing the output device, bridged by an AudioRingBuffer.
///
/// Capture deliberately does NOT use AVAudioEngine.inputNode: multiple engines
/// with input nodes in one process are unreliable (the second one silently
/// delivers zeros), and this app needs two simultaneous captures (real mic +
/// PouetSpeaker). Raw HAL clients have no such limit.
private final class ProxyEngine {
    let playbackEngine = AVAudioEngine()
    let captureFormat: AVAudioFormat

    /// Called on the capture IO thread with each interleaved Float32 buffer
    var onCaptureSamples: ((UnsafeBufferPointer<Float>, Int) -> Void)?

    /// Called on the main thread when the capture device disappears
    var onCaptureFailure: (() -> Void)?

    private let captureDeviceID: AudioDeviceID
    private var captureProcID: AudioDeviceIOProcID?
    private var captureStarted = false
    private let captureQueue: DispatchQueue
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private let ring: AudioRingBuffer
    private var sourceNode: AVAudioSourceNode!

    init(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        captureDeviceID = inputDeviceID
        captureQueue = DispatchQueue(label: "com.pouet.proxy.capture.\(inputDeviceID)")

        var outDev = outputDeviceID
        guard let outputAU = playbackEngine.outputNode.audioUnit,
              AudioUnitSetProperty(outputAU, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &outDev,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw NSError(domain: "AudioService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to set output device"])
        }

        // HAL clients always see Float32 in the device's virtual stream format
        var formatAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioObjectGetPropertyData(inputDeviceID, &formatAddr, 0, nil, &size, &asbd)
        guard formatStatus == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                         channels: asbd.mChannelsPerFrame) else {
            throw NSError(domain: "AudioService", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Input device has no valid format (\(formatStatus))"])
        }
        captureFormat = format

        // ~340 ms of slack at 48 kHz absorbs clock drift between the devices
        let ringBuffer = AudioRingBuffer(frameCapacity: 16384, channels: Int(format.channelCount))
        ring = ringBuffer

        guard let sourceFormat = AVAudioFormat(
            standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount) else {
            throw NSError(domain: "AudioService", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to build source format"])
        }
        sourceNode = AVAudioSourceNode(format: sourceFormat) { _, _, frameCount, bufferList -> OSStatus in
            ringBuffer.read(into: bufferList, frameCount: Int(frameCount))
            return noErr
        }
        playbackEngine.attach(sourceNode)
        playbackEngine.connect(sourceNode, to: playbackEngine.mainMixerNode, format: sourceFormat)

        // Raw HAL capture client: interleaved Float32 frames → ring + hook
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, inputDeviceID, captureQueue) {
            [weak self] _, inData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard buffers.count > 0, let base = buffers[0].mData else { return }
            let sampleCount = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let bufferChannels = max(1, Int(buffers[0].mNumberChannels))
            let samples = UnsafeBufferPointer(start: base.assumingMemoryBound(to: Float.self),
                                              count: sampleCount)
            ringBuffer.writeInterleaved(samples, channels: bufferChannels)
            self?.onCaptureSamples?(samples, bufferChannels)
        }
        guard procStatus == noErr, let procID else {
            throw NSError(domain: "AudioService", code: Int(procStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create capture IO proc: \(procStatus)"])
        }
        captureProcID = procID

        // Detect the capture device disappearing (e.g. USB mic unplugged)
        var aliveAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.captureStarted else { return }
                var alive: UInt32 = 1
                var aliveSize = UInt32(MemoryLayout<UInt32>.size)
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsAlive,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                let status = AudioObjectGetPropertyData(self.captureDeviceID, &addr, 0, nil, &aliveSize, &alive)
                if status != noErr || alive == 0 {
                    self.captureStarted = false
                    self.onCaptureFailure?()
                }
            }
        }
        AudioObjectAddPropertyListenerBlock(inputDeviceID, &aliveAddr, .main, listener)
        aliveListener = listener
    }

    var isRunning: Bool { captureStarted && playbackEngine.isRunning }

    func start() throws {
        playbackEngine.prepare()
        try playbackEngine.start()
        try startCapture()
    }

    private func startCapture() throws {
        guard !captureStarted, let procID = captureProcID else { return }
        let status = AudioDeviceStart(captureDeviceID, procID)
        guard status == noErr else {
            throw NSError(domain: "AudioService", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to start capture IO: \(status)"])
        }
        captureStarted = true
    }

    func pause() {
        if captureStarted, let procID = captureProcID {
            AudioDeviceStop(captureDeviceID, procID)
            captureStarted = false
        }
        playbackEngine.pause()
    }

    func resume() throws {
        if !playbackEngine.isRunning { try playbackEngine.start() }
        try startCapture()
    }

    func stop() {
        if let listener = aliveListener {
            var aliveAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(captureDeviceID, &aliveAddr, .main, listener)
            aliveListener = nil
        }
        if let procID = captureProcID {
            if captureStarted { AudioDeviceStop(captureDeviceID, procID) }
            AudioDeviceDestroyIOProcID(captureDeviceID, procID)
            captureProcID = nil
            captureStarted = false
        }
        playbackEngine.stop()
    }
}

class AudioService {
    private var micProxy: ProxyEngine?
    private var playerNodes: [AVAudioPlayerNode] = []
    private var injectMixer: AVAudioMixerNode?
    private var micConfigObservers: [NSObjectProtocol] = []
    private var speakerConfigObservers: [NSObjectProtocol] = []
    private(set) var proxyDeviceName: String?

    /// Called on the main thread when an engine stops and cannot be restarted
    /// (e.g. the underlying device was unplugged or its format changed fatally)
    var onEngineFailure: ((String) -> Void)?

    /// Peak levels updated from input tap
    private(set) var micPeakLevel: Float = 0.0
    private(set) var injectPeakLevel: Float = 0.0

    /// Volume for injected audio (0.0–1.0)
    var injectVolume: Float = 1.0 {
        didSet {
            for node in playerNodes {
                node.volume = injectVolume
            }
        }
    }

    init() {
        Log.info("AudioService init")
    }

    // MARK: - Mic Proxy (real mic → ring → inject mix → PouetMicrophone)

    var isProxyRunning: Bool { micProxy?.isRunning ?? false }

    /// True when any player nodes are actively playing
    var isInjecting: Bool {
        playerNodes.contains(where: { $0.isPlaying })
    }

    func startProxy(deviceID: AudioDeviceID, deviceName: String, inputChannels: Int, volume: Float = 1.0) throws {
        stopProxy()

        guard let loopbackID = findDeviceByUID("PouetMicrophone") else {
            throw NSError(domain: "AudioService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "PouetMicrophone loopback device not found"])
        }

        let proxy = try ProxyEngine(inputDeviceID: deviceID, outputDeviceID: loopbackID)
        proxy.onCaptureSamples = { [weak self] samples, _ in
            let peak = peakLevel(of: samples)
            DispatchQueue.main.async { self?.micPeakLevel = peak }
        }
        proxy.onCaptureFailure = { [weak self] in
            self?.onEngineFailure?("Mic capture device disappeared")
        }

        // Injected sounds go through a dedicated submixer on the playback
        // engine so the inject meter measures them in isolation from the mic.
        let injectMix = AVAudioMixerNode()
        proxy.playbackEngine.attach(injectMix)
        proxy.playbackEngine.connect(injectMix, to: proxy.playbackEngine.mainMixerNode, format: nil)
        injectMixer = injectMix

        try proxy.start()

        micProxy = proxy
        proxyDeviceName = deviceName
        injectVolume = volume
        micConfigObservers = observeConfigurationChanges(of: proxy, name: "Mic proxy")
        Log.info("Proxy started: \(deviceName) → PouetMicrophone")
    }

    func stopProxy() {
        for observer in micConfigObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        micConfigObservers = []
        if let proxy = micProxy {
            removeInjectMeteringTap()
            for node in playerNodes {
                node.stop()
                proxy.playbackEngine.detach(node)
            }
            playerNodes.removeAll()
            proxy.stop()
            micProxy = nil
        }
        injectMixer = nil
        injectTapInstalled = false
        proxyDeviceName = nil
        micPeakLevel = 0.0
        injectPeakLevel = 0.0
    }

    /// Restart a proxy's playback engine when its device changes configuration
    /// (sample rate change, device unplugged). If restart fails, report upstream
    /// so routing can be rolled back. The capture side is covered separately by
    /// the proxy's device-alive listener.
    private func observeConfigurationChanges(of proxy: ProxyEngine, name: String) -> [NSObjectProtocol] {
        let engine = proxy.playbackEngine
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self, weak proxy, weak engine] _ in
            guard let self, let proxy, let engine else { return }
            guard proxy === self.micProxy || proxy === self.speakerProxy else { return }
            guard !engine.isRunning else { return }
            do {
                try engine.start()
                Log.info("\(name) engine restarted after configuration change")
            } catch {
                Log.error("\(name) engine failed to restart: \(error)")
                self.onEngineFailure?("\(name) engine stopped and could not be restarted")
            }
        }
        return [observer]
    }

    // MARK: - Audio Injection

    func injectAudio(url: URL) throws {
        guard let proxy = micProxy, proxy.isRunning, let injectMix = injectMixer else { return }
        let eng = proxy.playbackEngine

        let file = try AVAudioFile(forReading: url)
        let player = AVAudioPlayerNode()
        player.volume = injectVolume

        eng.attach(player)
        eng.connect(player, to: injectMix, format: file.processingFormat)

        player.scheduleFile(file, at: nil) { [weak self, weak player, weak eng] in
            DispatchQueue.main.async {
                guard let self = self, let player = player, let eng = eng else { return }
                player.stop()
                eng.detach(player)
                self.playerNodes.removeAll(where: { $0 === player })
                if self.playerNodes.isEmpty {
                    self.injectPeakLevel = 0.0
                }
            }
        }

        playerNodes.append(player)
        player.play()

        // Install a tap on the main mixer to track inject peak level
        updateInjectMeteringTap()
    }

    func injectAudioAsync(url: URL, completion: ((Error?) -> Void)? = nil) {
        DispatchQueue.main.async {
            do {
                try self.injectAudio(url: url)
                completion?(nil)
            } catch {
                completion?(error)
            }
        }
    }

    func stopInjection() {
        guard let proxy = micProxy else { return }
        for node in playerNodes {
            node.stop()
            proxy.playbackEngine.detach(node)
        }
        playerNodes.removeAll()
        injectPeakLevel = 0.0
        removeInjectMeteringTap()
    }

    // MARK: - Inject Metering

    private var injectTapInstalled = false

    private func updateInjectMeteringTap() {
        guard let mixer = injectMixer else { return }
        // Always remove existing tap before installing new one
        if injectTapInstalled {
            mixer.removeTap(onBus: 0)
            injectTapInstalled = false
        }
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let peak = peakLevel(from: buffer)
            DispatchQueue.main.async { self?.injectPeakLevel = peak }
        }
        injectTapInstalled = true
    }

    private func removeInjectMeteringTap() {
        guard injectTapInstalled, let mixer = injectMixer else { return }
        mixer.removeTap(onBus: 0)
        injectTapInstalled = false
    }

    // MARK: - Devices

    private func listDevicesInternal(scope: AudioObjectPropertyScope, excludeUIDs: [String]) -> [AudioDeviceInfo] {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [AudioDeviceInfo] = []
        for devID in deviceIDs {
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(devID, &streamAddr, 0, nil, &bufSize) == noErr,
                  bufSize > 0 else { continue }

            let bufListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(
                capacity: Int(bufSize) / MemoryLayout<AudioBufferList>.size + 1)
            defer { bufListPtr.deallocate() }
            guard AudioObjectGetPropertyData(devID, &streamAddr, 0, nil, &bufSize, bufListPtr) == noErr else { continue }

            let bufList = UnsafeMutableAudioBufferListPointer(bufListPtr)
            var totalChannels = 0
            for buf in bufList { totalChannels += Int(buf.mNumberChannels) }
            if totalChannels == 0 { continue }

            let name = getAudioDeviceStringProperty(devID, selector: kAudioObjectPropertyName) ?? ""
            let uid = getAudioDeviceStringProperty(devID, selector: kAudioDevicePropertyDeviceUID) ?? ""
            if excludeUIDs.contains(where: { uid.contains($0) }) { continue }

            result.append(AudioDeviceInfo(id: devID, name: name, uid: uid, inputChannels: totalChannels))
        }
        return result
    }

    func listDevices() -> [AudioDeviceInfo] {
        listDevicesInternal(scope: kAudioDevicePropertyScopeInput, excludeUIDs: ["PouetMicrophone", "PouetSpeaker"])
    }

    func listOutputDevices() -> [AudioDeviceInfo] {
        listDevicesInternal(scope: kAudioDevicePropertyScopeOutput, excludeUIDs: ["PouetMicrophone", "PouetSpeaker"])
    }

    private func findDeviceIn(_ devices: [AudioDeviceInfo], matching query: String) -> AudioDeviceInfo? {
        let q = query.lowercased()
        return devices.first(where: { $0.name.lowercased() == q })
            ?? devices.first(where: { $0.name.lowercased().contains(q) })
    }

    func findDevice(matching query: String) -> AudioDeviceInfo? {
        findDeviceIn(listDevices(), matching: query)
    }

    func findOutputDevice(matching query: String) -> AudioDeviceInfo? {
        findDeviceIn(listOutputDevices(), matching: query)
    }

    func defaultDevice(input: Bool) -> AudioDeviceInfo? {
        guard let deviceID = getSystemDefaultDevice(input: input) else { return nil }
        let uid = getAudioDeviceStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? ""
        if uid.contains("PouetMicrophone") || uid.contains("PouetSpeaker") { return nil }
        let name = getAudioDeviceStringProperty(deviceID, selector: kAudioObjectPropertyName) ?? ""
        return AudioDeviceInfo(id: deviceID, name: name, uid: uid, inputChannels: 0)
    }

    // MARK: - System Default Device Switching

    func deviceUID(for deviceID: AudioDeviceID) -> String? {
        getAudioDeviceStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private func allDeviceIDs() -> [AudioDeviceID] {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &ids) == noErr else { return [] }
        return ids
    }

    func allDeviceUIDs() -> [String] {
        allDeviceIDs().compactMap { deviceUID(for: $0) }
    }

    func findDeviceByExactUID(_ uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { devID in
            getAudioDeviceStringProperty(devID, selector: kAudioDevicePropertyDeviceUID) == uid
        }
    }

    func findDeviceByUID(_ uidFragment: String) -> AudioDeviceID? {
        allDeviceIDs().first { devID in
            getAudioDeviceStringProperty(devID, selector: kAudioDevicePropertyDeviceUID)?.contains(uidFragment) == true
        }
    }

    func getSystemDefaultDevice(input: Bool) -> AudioDeviceID? {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        return deviceID
    }

    func defaultDeviceUID(input: Bool) -> String? {
        guard let deviceID = getSystemDefaultDevice(input: input) else { return nil }
        return getAudioDeviceStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Returns current system default, but nil if it's a virtual device (crash recovery safety)
    func getNonVirtualDefaultDevice(input: Bool) -> AudioDeviceID? {
        guard let deviceID = getSystemDefaultDevice(input: input) else { return nil }
        let uid = getAudioDeviceStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? ""
        if uid.contains("PouetMicrophone") || uid.contains("PouetSpeaker") { return nil }
        return deviceID
    }

    func setSystemDefaultDevice(input: Bool, deviceID: AudioDeviceID) -> Bool {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &devID)
        if status != noErr {
            Log.error("Failed to set system default \(input ? "input" : "output") device: \(status)")
        }
        return status == noErr
    }

    var virtualMicVisible: Bool {
        findDeviceByUID("PouetMicrophone") != nil
    }

    var virtualSpeakerVisible: Bool {
        findDeviceByUID("PouetSpeaker") != nil
    }

    // MARK: - Speaker Proxy (PouetSpeaker → ring → real speakers + rolling buffer)

    private var speakerProxy: ProxyEngine?
    private(set) var speakerProxyDeviceName: String?
    var isSpeakerProxyRunning: Bool { speakerProxy?.isRunning ?? false }
    private(set) var speakerPeakLevel: Float = 0.0

    /// Rolling buffer for dashcam snapshots
    private var dashcamBuffer: [Float] = []
    private var dashcamBufferCapacity: Int = 0
    private var dashcamWriteIndex: Int = 0
    private var dashcamSampleRate: Double = 48000
    private var dashcamChannelCount: UInt32 = 2
    private let dashcamLock = DispatchQueue(label: "com.pouet.dashcam.lock")

    func startSpeakerProxy(deviceID: AudioDeviceID, deviceName: String, bufferDuration: Double) throws {
        stopSpeakerProxy()

        guard let speakerLoopbackID = findDeviceByUID("PouetSpeaker") else {
            throw NSError(domain: "AudioService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "PouetSpeaker loopback device not found"])
        }

        // PouetSpeaker input → ring → real speakers (monitoring path)
        let proxy = try ProxyEngine(inputDeviceID: speakerLoopbackID, outputDeviceID: deviceID)

        // Set up rolling buffer
        let inputFormat = proxy.captureFormat
        dashcamSampleRate = inputFormat.sampleRate
        dashcamChannelCount = inputFormat.channelCount
        dashcamBufferCapacity = Int(dashcamSampleRate * Double(dashcamChannelCount) * bufferDuration)
        dashcamBuffer = [Float](repeating: 0, count: dashcamBufferCapacity)
        dashcamWriteIndex = 0

        // The capture hook also feeds the dashcam buffer + peak metering.
        // Samples arrive interleaved, exactly the dashcam buffer's layout.
        proxy.onCaptureSamples = { [weak self] samples, _ in
            guard let self = self else { return }
            let peak = peakLevel(of: samples)
            DispatchQueue.main.async { self.speakerPeakLevel = peak }

            self.dashcamLock.sync {
                for value in samples {
                    self.dashcamBuffer[self.dashcamWriteIndex % self.dashcamBufferCapacity] = value
                    self.dashcamWriteIndex += 1
                }
            }
        }
        proxy.onCaptureFailure = { [weak self] in
            self?.onEngineFailure?("Speaker capture device disappeared")
        }

        try proxy.start()

        speakerProxy = proxy
        speakerProxyDeviceName = deviceName
        speakerConfigObservers = observeConfigurationChanges(of: proxy, name: "Speaker proxy")
        Log.info("Speaker proxy started: PouetSpeaker → \(deviceName)")
    }

    func stopSpeakerProxy() {
        for observer in speakerConfigObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        speakerConfigObservers = []
        speakerProxy?.stop()
        speakerProxy = nil
        speakerProxyDeviceName = nil
        speakerPeakLevel = 0.0
        dashcamBuffer = []
        dashcamWriteIndex = 0
    }

    func saveDashcamSnapshot(to url: URL) throws {
        guard speakerProxy?.isRunning == true else {
            throw NSError(domain: "AudioService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Speaker proxy not running"])
        }

        // Snapshot the write index and buffer under the lock
        let (totalWritten, bufferSnapshot): (Int, [Float]) = dashcamLock.sync {
            (dashcamWriteIndex, dashcamBuffer)
        }

        let sampleCount = min(totalWritten, dashcamBufferCapacity)
        guard sampleCount > 0 else {
            throw NSError(domain: "AudioService", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "No audio captured yet"])
        }

        let channels = dashcamChannelCount
        let frameCount = sampleCount / Int(channels)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: dashcamSampleRate,
            channels: channels,
            interleaved: false
        )!
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw NSError(domain: "AudioService", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy from rolling buffer snapshot (interleaved) to PCM buffer (non-interleaved)
        let startIndex = (totalWritten >= dashcamBufferCapacity)
            ? (totalWritten % dashcamBufferCapacity)
            : 0

        guard let floatChannelData = pcmBuffer.floatChannelData else {
            throw NSError(domain: "AudioService", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to access buffer channel data"])
        }

        for frame in 0..<frameCount {
            for ch in 0..<Int(channels) {
                let srcIdx = (startIndex + frame * Int(channels) + ch) % dashcamBufferCapacity
                floatChannelData[ch][frame] = bufferSnapshot[srcIdx]
            }
        }

        // Write as M4A (AAC)
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: dashcamSampleRate,
            channels: channels,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: dashcamSampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 128000
            ],
            commonFormat: outputFormat.commonFormat,
            interleaved: false
        )
        try file.write(from: pcmBuffer)
        Log.info("Dashcam snapshot saved: \(url.lastPathComponent) (\(frameCount) frames)")
    }

    // MARK: - Sleep/Wake

    /// Pause audio engines for system sleep — prevents stale state on wake
    func pauseForSleep() {
        micProxy?.pause()
        speakerProxy?.pause()
        Log.info("Audio engines paused for sleep")
    }

    /// Resume audio engines after system wake
    @discardableResult
    func resumeAfterWake() -> Bool {
        do {
            try micProxy?.resume()
            try speakerProxy?.resume()
            Log.info("Audio engines resumed after wake")
            return true
        } catch {
            Log.error("Failed to resume audio engines: \(error)")
            return false
        }
    }
}

extension AudioService: RoutingAudioBackend {
    func setSystemDefaultDevice(input: Bool, uid: String) -> Bool {
        guard let deviceID = findDeviceByExactUID(uid) else { return false }
        return setSystemDefaultDevice(input: input, deviceID: deviceID)
    }

    func virtualDeviceUID(input: Bool) -> String? {
        let fragment = input ? "PouetMicrophone" : "PouetSpeaker"
        return allDeviceUIDs().first(where: { $0.contains(fragment) })
    }
}

// MARK: - CoreAudio Property Helpers

private func getAudioDeviceStringProperty(_ devID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, &value) == noErr,
          let value else { return nil }
    return value.takeRetainedValue() as String
}
