// AudioService.swift — Audio engine using AVAudioEngine loopback
// Captures real mic, mixes in soundboard audio, outputs to PouetMicrophone loopback device

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

// MARK: - Constants

let SAMPLE_RATE: Double = 48000.0
let NUM_CHANNELS: UInt32 = 2

// MARK: - Audio Device Info

struct AudioDeviceInfo: Identifiable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannels: Int
}

// MARK: - AudioService

class AudioService {
    private var engine: AVAudioEngine?
    private var playerNodes: [AVAudioPlayerNode] = []
    private(set) var proxyDeviceName: String?

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

    // MARK: - Proxy (AVAudioEngine)

    var isProxyRunning: Bool { engine?.isRunning ?? false }

    /// True when any player nodes are actively playing
    var isInjecting: Bool {
        playerNodes.contains(where: { $0.isPlaying })
    }

    func startProxy(deviceID: AudioDeviceID, deviceName: String, inputChannels: Int, volume: Float = 1.0) throws {
        stopProxy()

        let eng = AVAudioEngine()

        // Set input device (real mic)
        let inputNode = eng.inputNode
        if let inputAU = inputNode.audioUnit {
            var devID = deviceID
            let status = AudioUnitSetProperty(
                inputAU,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                throw NSError(domain: "AudioService", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "Failed to set input device: \(status)"])
            }
        }

        // Set output device (PouetMicrophone loopback)
        guard let loopbackID = findDeviceByUID("PouetMicrophone") else {
            throw NSError(domain: "AudioService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "PouetMicrophone loopback device not found"])
        }
        let outputNode = eng.outputNode
        if let outputAU = outputNode.audioUnit {
            var devID = loopbackID
            let status = AudioUnitSetProperty(
                outputAU,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                throw NSError(domain: "AudioService", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "Failed to set output device: \(status)"])
            }
        }

        // Install tap on input node for peak metering
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            var peak: Float = 0.0
            for ch in 0..<Int(buffer.format.channelCount) {
                for i in 0..<frameLength {
                    let abs = Swift.abs(channelData[ch][i])
                    if abs > peak { peak = abs }
                }
            }
            self.micPeakLevel = peak
        }

        // Connect input → mixer → output (AVAudioEngine does this automatically)
        // Just need to prepare and start
        eng.prepare()
        try eng.start()

        engine = eng
        proxyDeviceName = deviceName
        injectVolume = volume
        Log.info("Proxy started: \(deviceName) → PouetMicrophone")
    }

    func stopProxy() {
        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            for node in playerNodes {
                node.stop()
                eng.detach(node)
            }
            playerNodes.removeAll()
            eng.stop()
            engine = nil
        }
        proxyDeviceName = nil
        micPeakLevel = 0.0
        injectPeakLevel = 0.0
    }

    // MARK: - Audio Injection

    func injectAudio(url: URL) throws {
        guard let eng = engine, eng.isRunning else { return }

        let file = try AVAudioFile(forReading: url)
        let player = AVAudioPlayerNode()
        player.volume = injectVolume

        eng.attach(player)
        eng.connect(player, to: eng.mainMixerNode, format: file.processingFormat)

        // Install tap on player for inject peak metering
        let playerFormat = player.outputFormat(forBus: 0)
        if playerFormat.sampleRate > 0 && playerFormat.channelCount > 0 {
            // Track this player for peak level updates via a mixer tap instead
        }

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
        DispatchQueue.global().async {
            do {
                try self.injectAudio(url: url)
                completion?(nil)
            } catch {
                completion?(error)
            }
        }
    }

    func stopInjection() {
        guard let eng = engine else { return }
        for node in playerNodes {
            node.stop()
            eng.detach(node)
        }
        playerNodes.removeAll()
        injectPeakLevel = 0.0
        removeInjectMeteringTap()
    }

    // MARK: - Inject Metering

    private var injectTapInstalled = false

    private func updateInjectMeteringTap() {
        guard let eng = engine, !injectTapInstalled else { return }
        let mixer = eng.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, !self.playerNodes.isEmpty else {
                self?.injectPeakLevel = 0.0
                return
            }
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            var peak: Float = 0.0
            for ch in 0..<Int(buffer.format.channelCount) {
                for i in 0..<frameLength {
                    let abs = Swift.abs(channelData[ch][i])
                    if abs > peak { peak = abs }
                }
            }
            self.injectPeakLevel = peak
        }
        injectTapInstalled = true
    }

    private func removeInjectMeteringTap() {
        guard injectTapInstalled, let eng = engine else { return }
        eng.mainMixerNode.removeTap(onBus: 0)
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
        listDevicesInternal(scope: kAudioDevicePropertyScopeInput, excludeUIDs: ["PouetMicrophone"])
    }

    private func findDeviceIn(_ devices: [AudioDeviceInfo], matching query: String) -> AudioDeviceInfo? {
        let q = query.lowercased()
        return devices.first(where: { $0.name.lowercased() == q })
            ?? devices.first(where: { $0.name.lowercased().contains(q) })
    }

    func findDevice(matching query: String) -> AudioDeviceInfo? {
        findDeviceIn(listDevices(), matching: query)
    }

    func listOutputDevices() -> [AudioDeviceInfo] {
        listDevicesInternal(scope: kAudioDevicePropertyScopeOutput, excludeUIDs: ["PouetMicrophone"])
    }

    func defaultDevice(input: Bool) -> AudioDeviceInfo? {
        guard let deviceID = getSystemDefaultDevice(input: input) else { return nil }
        let uid = getAudioDeviceStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? ""
        if uid.contains("PouetMicrophone") { return nil }
        let name = getAudioDeviceStringProperty(deviceID, selector: kAudioObjectPropertyName) ?? ""
        return AudioDeviceInfo(id: deviceID, name: name, uid: uid, inputChannels: 0)
    }

    func findOutputDevice(matching query: String) -> AudioDeviceInfo? {
        findDeviceIn(listOutputDevices(), matching: query)
    }

    // MARK: - System Default Device Switching

    func deviceUID(for deviceID: AudioDeviceID) -> String? {
        getAudioDeviceStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    func findDeviceByExactUID(_ uid: String) -> AudioDeviceID? {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &ids) == noErr else { return nil }
        for devID in ids {
            if let devUID = getAudioDeviceStringProperty(devID, selector: kAudioDevicePropertyDeviceUID),
               devUID == uid {
                return devID
            }
        }
        return nil
    }

    func findDeviceByUID(_ uidFragment: String) -> AudioDeviceID? {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize) == noErr else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &ids) == noErr else { return nil }
        for devID in ids {
            if let uid = getAudioDeviceStringProperty(devID, selector: kAudioDevicePropertyDeviceUID),
               uid.contains(uidFragment) {
                return devID
            }
        }
        return nil
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

    /// Returns current system default, but nil if it's a virtual device (crash recovery safety)
    func getNonVirtualDefaultDevice(input: Bool) -> AudioDeviceID? {
        guard let deviceID = getSystemDefaultDevice(input: input) else { return nil }
        let uid = getAudioDeviceStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? ""
        if uid.contains("PouetMicrophone") { return nil }
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

    /// Check if PouetMicrophone appears as an audio device in the system
    var virtualMicVisible: Bool {
        findDeviceByUID("PouetMicrophone") != nil
    }

    // MARK: - Audio Decoding

    static func decodeAudioFile(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SAMPLE_RATE,
            channels: NUM_CHANNELS,
            interleaved: true
        )!

        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw NSError(domain: "AudioConvert", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create converter"])
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "AudioConvert", code: -2)
        }
        try file.read(into: srcBuffer)

        let ratio = SAMPLE_RATE / srcFormat.sampleRate
        let dstFrameCount = AVAudioFrameCount(Double(frameCount) * ratio) + 512
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: dstFrameCount) else {
            throw NSError(domain: "AudioConvert", code: -3)
        }

        var error: NSError?
        var srcConsumed = false
        _ = converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            if srcConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            srcConsumed = true
            outStatus.pointee = .haveData
            return srcBuffer
        }
        if let e = error { throw e }

        let frameLength = Int(dstBuffer.frameLength)
        let numSamples  = frameLength * Int(NUM_CHANNELS)
        var result = [Float](repeating: 0, count: numSamples)

        if let ptr = dstBuffer.floatChannelData {
            if targetFormat.isInterleaved {
                memcpy(&result, ptr[0], numSamples * MemoryLayout<Float>.size)
            } else {
                let L = ptr[0]; let R = ptr[1]
                for i in 0..<frameLength {
                    result[i * 2]     = L[i]
                    result[i * 2 + 1] = R[i]
                }
            }
        }
        return result
    }
}

// MARK: - CoreAudio Property Helpers

private func getAudioDeviceStringProperty(_ devID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(devID, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<CFString>.alignment)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, buf) == noErr else { return nil }
    let cfStr = Unmanaged<CFString>.fromOpaque(buf.load(as: UnsafeRawPointer.self)).takeUnretainedValue()
    return cfStr as String
}
