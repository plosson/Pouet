// AudioService.swift — Low-level audio engine
// Owns: shared memory ring buffers, mic proxy, audio decoding, device listing

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

// MARK: - Constants

let SHM_NAME         = "/VirtualMicAudio"
let SHM_INJECT_NAME  = "/VirtualMicInject"
let SHM_DATA_SIZE    = 4096 * 256
let SAMPLE_RATE      = 48000.0
let NUM_CHANNELS: UInt32 = 2

// MARK: - Shared Memory Header

struct SHMHeader {
    var writePos: UInt64
    var readPos:  UInt64
    var capacity: UInt32
    var pad:      UInt32
}

// MARK: - Ring Buffer

class SharedRingBuffer {
    let name: String
    private let fd:  Int32
    private let ptr: UnsafeMutableRawPointer
    private let totalSize: Int
    var header: UnsafeMutablePointer<SHMHeader>
    var data:   UnsafeMutablePointer<Float>

    init(name: String, recreate: Bool = false) throws {
        self.name = name
        let total = MemoryLayout<SHMHeader>.size + SHM_DATA_SIZE
        self.totalSize = total

        var f: Int32
        if recreate {
            f = shm_recreate(name)
            guard f >= 0 else { throw NSError(domain: "SHM", code: Int(errno)) }
            ftruncate(f, off_t(total))
        } else {
            f = shm_open_rw(name)
            if f < 0 {
                f = shm_open_create(name)
                guard f >= 0 else { throw NSError(domain: "SHM", code: Int(errno)) }
                ftruncate(f, off_t(total))
            }
        }
        fd = f
        let p = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard p != MAP_FAILED else { throw NSError(domain: "SHM mmap", code: Int(errno)) }
        ptr    = p!
        header = ptr.assumingMemoryBound(to: SHMHeader.self)
        data   = (ptr + MemoryLayout<SHMHeader>.size).assumingMemoryBound(to: Float.self)

        let cap = UInt32(SHM_DATA_SIZE / MemoryLayout<Float>.size)
        if header.pointee.capacity == 0 {
            header.pointee.capacity = cap
            header.pointee.writePos = 0
            header.pointee.readPos  = 0
        }
    }

    deinit { munmap(ptr, totalSize); close(fd) }

    var capacity: Int { Int(header.pointee.capacity) }

    func write(_ samples: UnsafePointer<Float>, count: Int) {
        let cap = capacity
        var written = 0
        while written < count {
            let wp = header.pointee.writePos
            let rp = header.pointee.readPos
            let avail = cap - Int(wp - rp)
            if avail <= 0 { usleep(500); continue }
            let chunk = min(avail, count - written)
            for i in 0..<chunk {
                let idx = Int((wp + UInt64(i)) % UInt64(cap))
                data[idx] = samples[written + i]
            }
            header.pointee.writePos = wp + UInt64(chunk)
            written += chunk
        }
    }

    func tryWrite(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        let cap = capacity
        let wp = header.pointee.writePos
        let rp = header.pointee.readPos
        let avail = cap - Int(wp - rp)
        if avail <= 0 { return 0 }
        let ch = Int(NUM_CHANNELS)
        let chunk = (min(avail, count) / ch) * ch
        if chunk <= 0 { return 0 }
        for i in 0..<chunk {
            let idx = Int((wp + UInt64(i)) % UInt64(cap))
            data[idx] = samples[i]
        }
        header.pointee.writePos = wp + UInt64(chunk)
        return chunk
    }

    func writeArray(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { buf in
            write(buf.baseAddress!, count: buf.count)
        }
    }

    func read(into buffer: UnsafeMutablePointer<Float>, maxSamples: Int) -> Int {
        let cap = capacity
        let wp = header.pointee.writePos
        let rp = header.pointee.readPos
        let avail = Int(wp - rp)
        if avail <= 0 { return 0 }
        let toRead = min(avail, maxSamples)
        for i in 0..<toRead {
            let idx = Int((rp + UInt64(i)) % UInt64(cap))
            buffer[i] = data[idx]
        }
        header.pointee.readPos = rp + UInt64(toRead)
        return toRead
    }

    func clear() {
        header.pointee.readPos = header.pointee.writePos
    }

    var fillPercent: Int {
        let cap = capacity
        let used = Int(header.pointee.writePos - header.pointee.readPos)
        return cap > 0 ? min(100, used * 100 / cap) : 0
    }

    var availableSamples: Int {
        return Int(header.pointee.writePos - header.pointee.readPos)
    }
}

// MARK: - Audio Device Info

struct AudioDeviceInfo: Identifiable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannels: Int
}

// MARK: - Mic Proxy

class MicProxy {
    let deviceID: AudioDeviceID
    let mainRing: SharedRingBuffer
    let injectRing: SharedRingBuffer
    var injectVolume: Float = 1.0

    /// Peak levels updated from the audio callback (read from main thread for UI)
    var micPeakLevel: Float = 0.0
    var injectPeakLevel: Float = 0.0

    var audioUnit: AudioComponentInstance?
    private var outputUnit: AudioComponentInstance?
    private var outputRunning = false

    private let mixBufSize = 2048
    private var injectBuf: [Float]

    private let speakerBufCapacity = 48000 * 2 * 2
    private let speakerRing: UnsafeMutablePointer<Float>
    private var speakerWritePos: UInt64 = 0
    private var speakerReadPos: UInt64 = 0

    init(deviceID: AudioDeviceID, mainRing: SharedRingBuffer, injectRing: SharedRingBuffer) {
        self.deviceID = deviceID
        self.mainRing = mainRing
        self.injectRing = injectRing
        self.injectBuf = [Float](repeating: 0, count: mixBufSize)
        self.speakerRing = UnsafeMutablePointer<Float>.allocate(capacity: speakerBufCapacity)
        self.speakerRing.initialize(repeating: 0, count: speakerBufCapacity)
    }

    func start() throws {
        var inputDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &inputDesc) else {
            throw NSError(domain: "AudioUnit", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No HALOutput component found"])
        }
        var au: AudioComponentInstance?
        var status = AudioComponentInstanceNew(comp, &au)
        guard status == noErr, let unit = au else {
            throw NSError(domain: "AudioUnit", code: Int(status))
        }
        audioUnit = unit

        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input, 1, &enableIO,
                                      UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw NSError(domain: "EnableInput", code: Int(status)) }

        var disableIO: UInt32 = 0
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, 0, &disableIO,
                                      UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw NSError(domain: "DisableOutput", code: Int(status)) }

        var devID = deviceID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &devID,
                                      UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw NSError(domain: "SetDevice", code: Int(status)) }

        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: SAMPLE_RATE,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * Int(NUM_CHANNELS)),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * Int(NUM_CHANNELS)),
            mChannelsPerFrame: NUM_CHANNELS,
            mBitsPerChannel: 32, mReserved: 0
        )
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, 1, &streamFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw NSError(domain: "SetFormat", code: Int(status)) }

        var callbackStruct = AURenderCallbackStruct(
            inputProc: micInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Global, 0, &callbackStruct,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw NSError(domain: "SetCallback", code: Int(status)) }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { throw NSError(domain: "InitUnit", code: Int(status)) }

        // Output unit (speakers) — initialized but NOT started, on-demand
        var outputDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        if let outComp = AudioComponentFindNext(nil, &outputDesc) {
            var outUnit: AudioComponentInstance?
            if AudioComponentInstanceNew(outComp, &outUnit) == noErr, let ou = outUnit {
                outputUnit = ou
                var outFormat = streamFormat
                AudioUnitSetProperty(ou, kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Input, 0, &outFormat,
                                     UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
                var renderCallback = AURenderCallbackStruct(
                    inputProc: speakerOutputCallback,
                    inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
                )
                AudioUnitSetProperty(ou, kAudioUnitProperty_SetRenderCallback,
                                     kAudioUnitScope_Input, 0, &renderCallback,
                                     UInt32(MemoryLayout<AURenderCallbackStruct>.size))
                AudioUnitInitialize(ou)
            }
        }

        status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw NSError(domain: "StartUnit", code: Int(status)) }
    }

    func stop() {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
        if let unit = outputUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
            outputUnit = nil
        }
        speakerRing.deallocate()
    }

    fileprivate func ensureOutputRunning() {
        guard !outputRunning, let ou = outputUnit else { return }
        AudioOutputUnitStart(ou)
        outputRunning = true
    }

    fileprivate func stopOutputIfIdle() {
        guard outputRunning, let ou = outputUnit else { return }
        AudioOutputUnitStop(ou)
        outputRunning = false
    }

    fileprivate func enqueueSpeakerSamples(_ samples: UnsafePointer<Float>, count: Int) {
        let cap = speakerBufCapacity
        for i in 0..<count {
            let idx = Int(speakerWritePos % UInt64(cap))
            speakerRing[idx] = samples[i]
            speakerWritePos += 1
        }
    }

    fileprivate func dequeueSpeakerSamples(into buffer: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let avail = Int(speakerWritePos - speakerReadPos)
        let toRead = min(avail, count)
        let cap = speakerBufCapacity
        for i in 0..<toRead {
            let idx = Int(speakerReadPos % UInt64(cap))
            buffer[i] = speakerRing[idx]
            speakerReadPos += 1
        }
        if toRead < count {
            for i in toRead..<count { buffer[i] = 0 }
        }
        return toRead
    }
}

// MARK: - Audio Callbacks

private func micInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let proxy = Unmanaged<MicProxy>.fromOpaque(inRefCon).takeUnretainedValue()
    let numSamples = Int(inNumberFrames) * Int(NUM_CHANNELS)
    let captureBuffer = UnsafeMutablePointer<Float>.allocate(capacity: numSamples)
    defer { captureBuffer.deallocate() }

    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: NUM_CHANNELS,
            mDataByteSize: UInt32(numSamples * MemoryLayout<Float>.size),
            mData: captureBuffer
        )
    )

    let status = AudioUnitRender(proxy.audioUnit!, ioActionFlags, inTimeStamp,
                                 inBusNumber, inNumberFrames, &bufferList)
    if status != noErr { return status }

    // Mono mic fix
    let frames = Int(inNumberFrames)
    for f in 0..<frames { captureBuffer[f * 2 + 1] = captureBuffer[f * 2] }

    // Compute mic peak level
    var micPeak: Float = 0.0
    for i in 0..<numSamples {
        let v = abs(captureBuffer[i])
        if v > micPeak { micPeak = v }
    }
    proxy.micPeakLevel = micPeak

    // Read + mix inject audio
    let injectBuffer = UnsafeMutablePointer<Float>.allocate(capacity: numSamples)
    defer { injectBuffer.deallocate() }
    let injectCount = proxy.injectRing.read(into: injectBuffer, maxSamples: numSamples)

    if injectCount > 0 {
        let vol = proxy.injectVolume
        var injPeak: Float = 0.0
        for i in 0..<injectCount {
            injectBuffer[i] *= vol
            let v = abs(injectBuffer[i])
            if v > injPeak { injPeak = v }
            captureBuffer[i] = min(1.0, max(-1.0, captureBuffer[i] + injectBuffer[i]))
        }
        proxy.injectPeakLevel = injPeak
        proxy.enqueueSpeakerSamples(injectBuffer, count: injectCount)
        proxy.ensureOutputRunning()
    } else {
        proxy.injectPeakLevel = 0.0
    }

    _ = proxy.mainRing.tryWrite(captureBuffer, count: numSamples)
    return noErr
}

private func speakerOutputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let proxy = Unmanaged<MicProxy>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let bufList = ioData else { return noErr }

    let abl = UnsafeMutableAudioBufferListPointer(bufList)
    var hadData = false
    for buf in abl {
        if let data = buf.mData?.assumingMemoryBound(to: Float.self) {
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            if proxy.dequeueSpeakerSamples(into: data, count: count) > 0 { hadData = true }
        }
    }
    if !hadData {
        DispatchQueue.global().async { proxy.stopOutputIfIdle() }
    }
    return noErr
}

// MARK: - AudioService

class AudioService {
    private(set) var mainRing: SharedRingBuffer?
    private(set) var injectRing: SharedRingBuffer?
    private(set) var proxy: MicProxy?
    private(set) var proxyDeviceName: String?

    init() {
        do {
            mainRing = try SharedRingBuffer(name: SHM_NAME)
            injectRing = try SharedRingBuffer(name: SHM_INJECT_NAME)
            mainRing?.clear()
            injectRing?.clear()
        } catch {
            print("[AudioService] Failed to init ring buffers: \(error)")
        }
    }

    // MARK: - Devices

    func listDevices() -> [AudioDeviceInfo] {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize)
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return [] }

        var result: [AudioDeviceInfo] = []
        for devID in deviceIDs {
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(devID, &inputAddr, 0, nil, &bufSize) == noErr,
                  bufSize > 0 else { continue }

            let bufListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(
                capacity: Int(bufSize) / MemoryLayout<AudioBufferList>.size + 1)
            defer { bufListPtr.deallocate() }
            guard AudioObjectGetPropertyData(devID, &inputAddr, 0, nil, &bufSize, bufListPtr) == noErr else { continue }

            let bufList = UnsafeMutableAudioBufferListPointer(bufListPtr)
            var totalChannels = 0
            for buf in bufList { totalChannels += Int(buf.mNumberChannels) }
            if totalChannels == 0 { continue }

            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(devID, &nameAddr, 0, nil, &nameSize, &nameRef)

            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(devID, &uidAddr, 0, nil, &uidSize, &uidRef)

            let uid = uidRef as String
            if uid.contains("VirtualMic") { continue }

            result.append(AudioDeviceInfo(id: devID, name: nameRef as String, uid: uid, inputChannels: totalChannels))
        }
        return result
    }

    func findDevice(matching query: String) -> AudioDeviceInfo? {
        let devices = listDevices()
        if let exact = devices.first(where: { $0.name.lowercased() == query.lowercased() }) {
            return exact
        }
        return devices.first(where: { $0.name.lowercased().contains(query.lowercased()) })
    }

    // MARK: - Proxy

    var isProxyRunning: Bool { proxy != nil }

    func startProxy(deviceID: AudioDeviceID, deviceName: String, volume: Float = 1.0) throws {
        guard let mainRing = mainRing, let injectRing = injectRing else {
            throw NSError(domain: "AudioService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Ring buffers not initialized"])
        }
        stopProxy()
        let p = MicProxy(deviceID: deviceID, mainRing: mainRing, injectRing: injectRing)
        p.injectVolume = volume
        try p.start()
        proxy = p
        proxyDeviceName = deviceName
    }

    func stopProxy() {
        proxy?.stop()
        proxy = nil
        proxyDeviceName = nil
        mainRing?.clear()
        injectRing?.clear()
    }

    var injectVolume: Float {
        get { proxy?.injectVolume ?? 1.0 }
        set { proxy?.injectVolume = newValue }
    }

    // MARK: - Audio Injection

    func injectAudio(url: URL) throws {
        guard let ring = injectRing else { return }
        let samples = try Self.decodeAudioFile(url: url)
        ring.writeArray(samples)
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
        injectRing?.clear()
    }

    // MARK: - Buffer Status

    var mainRingFillPercent: Int { mainRing?.fillPercent ?? 0 }
    var injectRingFillPercent: Int { injectRing?.fillPercent ?? 0 }
    var injectRingAvailableSamples: Int { injectRing?.availableSamples ?? 0 }

    var micPeakLevel: Float { proxy?.micPeakLevel ?? 0.0 }
    var injectPeakLevel: Float { proxy?.injectPeakLevel ?? 0.0 }

    /// Check if VirtualMic appears as an audio device in the system
    var virtualMicVisible: Bool {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize) == noErr else { return false }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &ids) == noErr else { return false }
        for devID in ids {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            if AudioObjectGetPropertyData(devID, &uidAddr, 0, nil, &uidSize, &uidRef) == noErr {
                if (uidRef as String).contains("VirtualMic") { return true }
            }
        }
        return false
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
