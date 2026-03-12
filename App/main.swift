// VirtualMicApp/main.swift
// Companion app for VirtualMic Audio Server Plugin.
//
// Usage:
//   VirtualMicApp list                    # list available input devices
//   VirtualMicApp start <device-name>     # start proxying a real mic (foreground)
//   VirtualMicApp inject <audiofile>      # inject audio into running proxy
//   VirtualMicApp stop                    # clear ring buffers
//   VirtualMicApp status                  # show ring buffer fill level

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

// ---------------------------------------------------------------------------
// MARK: - Shared memory constants
// ---------------------------------------------------------------------------

let SHM_NAME         = "/VirtualMicAudio"   // main ring buffer (driver reads)
let SHM_INJECT_NAME  = "/VirtualMicInject"  // inject ring buffer (inject cmd writes)
let SHM_DATA_SIZE    = 4096 * 256           // bytes for float samples
let SAMPLE_RATE      = 48000.0
let NUM_CHANNELS: UInt32 = 2

// ---------------------------------------------------------------------------
// MARK: - Shared memory header (must match SharedMemory.h / driver)
// ---------------------------------------------------------------------------

struct SHMHeader {
    var writePos: UInt64
    var readPos:  UInt64
    var capacity: UInt32
    var pad:      UInt32
    // data[] follows in memory
}

// ---------------------------------------------------------------------------
// MARK: - Ring buffer wrapper
// ---------------------------------------------------------------------------

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

    func writeArray(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { buf in
            write(buf.baseAddress!, count: buf.count)
        }
    }

    /// Read available samples (non-blocking). Returns number of samples read.
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

// ---------------------------------------------------------------------------
// MARK: - List audio input devices
// ---------------------------------------------------------------------------

struct AudioDeviceInfo {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannels: Int
}

func listInputDevices() -> [AudioDeviceInfo] {
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
        // Check input channels
        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var bufSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(devID, &inputAddr, 0, nil, &bufSize) == noErr,
              bufSize > 0 else { continue }

        let bufListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(bufSize) / MemoryLayout<AudioBufferList>.size + 1)
        defer { bufListPtr.deallocate() }
        guard AudioObjectGetPropertyData(devID, &inputAddr, 0, nil, &bufSize, bufListPtr) == noErr else { continue }

        let bufList = UnsafeMutableAudioBufferListPointer(bufListPtr)
        var totalChannels = 0
        for buf in bufList { totalChannels += Int(buf.mNumberChannels) }
        if totalChannels == 0 { continue }

        // Get name
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(devID, &nameAddr, 0, nil, &nameSize, &nameRef)
        let name = nameRef as String

        // Get UID
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(devID, &uidAddr, 0, nil, &uidSize, &uidRef)
        let uid = uidRef as String

        // Skip our own virtual mic
        if uid.contains("VirtualMic") { continue }

        result.append(AudioDeviceInfo(id: devID, name: name, uid: uid, inputChannels: totalChannels))
    }
    return result
}

func findDevice(matching query: String) -> AudioDeviceInfo? {
    let devices = listInputDevices()
    // Try exact name match first, then substring
    if let exact = devices.first(where: { $0.name.lowercased() == query.lowercased() }) {
        return exact
    }
    return devices.first(where: { $0.name.lowercased().contains(query.lowercased()) })
}

// ---------------------------------------------------------------------------
// MARK: - Audio decoder
// ---------------------------------------------------------------------------

func decodeAudioFile(url: URL) throws -> [Float] {
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
            let L = ptr[0]
            let R = ptr[1]
            for i in 0..<frameLength {
                result[i * 2]     = L[i]
                result[i * 2 + 1] = R[i]
            }
        }
    }
    return result
}

// ---------------------------------------------------------------------------
// MARK: - Mic capture + proxy (the "start" command)
// ---------------------------------------------------------------------------

class MicProxy {
    let deviceID: AudioDeviceID
    let mainRing: SharedRingBuffer
    let injectRing: SharedRingBuffer

    var audioUnit: AudioComponentInstance?
    private var outputUnit: AudioComponentInstance?  // for playing inject audio to speakers

    // Buffers for mixing
    private let mixBufSize = 2048 // stereo samples per callback
    private var injectBuf: [Float]

    init(deviceID: AudioDeviceID, mainRing: SharedRingBuffer, injectRing: SharedRingBuffer) {
        self.deviceID = deviceID
        self.mainRing = mainRing
        self.injectRing = injectRing
        self.injectBuf = [Float](repeating: 0, count: mixBufSize)
    }

    func start() throws {
        // --- Input unit (capture from real mic) ---
        var inputDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
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

        // Enable input
        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input, 1, &enableIO,
                                      UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw NSError(domain: "EnableInput", code: Int(status)) }

        // Disable output on the input unit
        var disableIO: UInt32 = 0
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, 0, &disableIO,
                                      UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw NSError(domain: "DisableOutput", code: Int(status)) }

        // Set the input device
        var devID = deviceID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &devID,
                                      UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw NSError(domain: "SetDevice", code: Int(status)) }

        // Set format: 48kHz stereo float32
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: SAMPLE_RATE,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * Int(NUM_CHANNELS)),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * Int(NUM_CHANNELS)),
            mChannelsPerFrame: NUM_CHANNELS,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, 1, &streamFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw NSError(domain: "SetFormat", code: Int(status)) }

        // Set input callback
        var callbackStruct = AURenderCallbackStruct(
            inputProc: inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Global, 0, &callbackStruct,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw NSError(domain: "SetCallback", code: Int(status)) }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { throw NSError(domain: "InitUnit", code: Int(status)) }

        // --- Output unit (play inject audio to speakers) ---
        var outputDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        if let outComp = AudioComponentFindNext(nil, &outputDesc) {
            var outUnit: AudioComponentInstance?
            if AudioComponentInstanceNew(outComp, &outUnit) == noErr, let ou = outUnit {
                outputUnit = ou

                // Set stream format to match our inject audio (48kHz stereo float32 interleaved)
                var outFormat = AudioStreamBasicDescription(
                    mSampleRate: SAMPLE_RATE,
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
                    mBytesPerPacket: UInt32(MemoryLayout<Float>.size * Int(NUM_CHANNELS)),
                    mFramesPerPacket: 1,
                    mBytesPerFrame: UInt32(MemoryLayout<Float>.size * Int(NUM_CHANNELS)),
                    mChannelsPerFrame: NUM_CHANNELS,
                    mBitsPerChannel: 32,
                    mReserved: 0
                )
                var s = AudioUnitSetProperty(ou, kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Input, 0, &outFormat,
                                     UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
                if s != noErr { print("Warning: output format set failed: \(s)") }

                var renderCallback = AURenderCallbackStruct(
                    inputProc: outputRenderCallback,
                    inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
                )
                s = AudioUnitSetProperty(ou, kAudioUnitProperty_SetRenderCallback,
                                     kAudioUnitScope_Input, 0, &renderCallback,
                                     UInt32(MemoryLayout<AURenderCallbackStruct>.size))
                if s != noErr { print("Warning: output render callback failed: \(s)") }

                s = AudioUnitInitialize(ou)
                if s != noErr { print("Warning: output init failed: \(s)") }

                s = AudioOutputUnitStart(ou)
                if s != noErr { print("Warning: output start failed: \(s)") }
            }
        }

        // Start capturing
        status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw NSError(domain: "StartUnit", code: Int(status)) }
    }

    func stop() {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
        }
        if let unit = outputUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
        }
    }

    // Buffer for inject audio to play to speakers
    // We use a separate ring buffer to decouple inject reading for mix vs playback
    private let speakerBufCapacity = 48000 * 2 * 2  // 2 seconds stereo
    private lazy var speakerRing: [Float] = [Float](repeating: 0, count: speakerBufCapacity)
    private var speakerWritePos: UInt64 = 0
    private var speakerReadPos: UInt64 = 0

    private var speakerEnqueueTotal: UInt64 = 0

    fileprivate func enqueueSpeakerSamples(_ samples: UnsafePointer<Float>, count: Int) {
        let cap = speakerBufCapacity
        for i in 0..<count {
            let idx = Int(speakerWritePos % UInt64(cap))
            speakerRing[idx] = samples[i]
            speakerWritePos += 1
        }
        speakerEnqueueTotal += UInt64(count)
        if speakerEnqueueTotal % 48000 < UInt64(count) {
            print("Speaker enqueue: \(speakerEnqueueTotal) samples total, avail=\(Int(speakerWritePos - speakerReadPos))")
            fflush(stdout)
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
        // Fill remainder with silence
        if toRead < count {
            for i in toRead..<count {
                buffer[i] = 0
            }
        }
        return toRead
    }
}

// ---------------------------------------------------------------------------
// MARK: - Audio callbacks (C function pointers)
// ---------------------------------------------------------------------------

private func inputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let proxy = Unmanaged<MicProxy>.fromOpaque(inRefCon).takeUnretainedValue()

    // Allocate buffer for captured audio
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

    // Render (capture) from the real mic
    let status = AudioUnitRender(proxy.audioUnit!, ioActionFlags, inTimeStamp,
                                 inBusNumber, inNumberFrames, &bufferList)
    if status != noErr { return status }

    // Read inject samples (non-blocking)
    let injectBuffer = UnsafeMutablePointer<Float>.allocate(capacity: numSamples)
    defer { injectBuffer.deallocate() }
    let injectCount = proxy.injectRing.read(into: injectBuffer, maxSamples: numSamples)

    // Mix: add inject audio on top of mic audio
    if injectCount > 0 {
        for i in 0..<injectCount {
            captureBuffer[i] = captureBuffer[i] + injectBuffer[i]
            // Clamp to prevent clipping
            if captureBuffer[i] > 1.0 { captureBuffer[i] = 1.0 }
            if captureBuffer[i] < -1.0 { captureBuffer[i] = -1.0 }
        }
        // Enqueue inject audio for speaker playback
        proxy.enqueueSpeakerSamples(injectBuffer, count: injectCount)
    }

    // Write mixed audio to main ring buffer (driver reads this)
    proxy.mainRing.write(captureBuffer, count: numSamples)

    return noErr
}

private func outputRenderCallback(
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
    for buf in abl {
        if let data = buf.mData?.assumingMemoryBound(to: Float.self) {
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            _ = proxy.dequeueSpeakerSamples(into: data, count: count)
        }
    }
    return noErr
}

// ---------------------------------------------------------------------------
// MARK: - CLI
// ---------------------------------------------------------------------------

func printUsage() {
    print("""
    VirtualMicApp — proxy a real mic through the VirtualMic driver

    Usage:
      VirtualMicApp start [--port 9999]    Start web UI + server (Ctrl-C to stop)
      VirtualMicApp list                   List available input devices
      VirtualMicApp inject <audiofile>     Inject audio into running proxy
      VirtualMicApp stop                   Clear ring buffers
      VirtualMicApp status                 Show buffer fill level

    Open http://localhost:9999 to configure the mic proxy and play sounds.
    """)
}

func main() throws {
    let args = CommandLine.arguments
    guard args.count >= 2 else { printUsage(); exit(1) }
    let cmd = args[1]

    switch cmd {

    case "list":
        let devices = listInputDevices()
        if devices.isEmpty {
            print("No input devices found.")
        } else {
            print("Available input devices:")
            for dev in devices {
                print("  [\(dev.id)] \(dev.name) (\(dev.inputChannels) ch) — \(dev.uid)")
            }
        }

    case "start":
        // Parse --port flag
        var port: UInt16 = 0
        var i = 2
        while i < args.count {
            if args[i] == "--port", i + 1 < args.count, let p = UInt16(args[i + 1]) {
                port = p
                i += 2
            } else {
                i += 1
            }
        }

        var config = AppConfig.load()
        if port > 0 { config.port = port }

        let mainRing   = try SharedRingBuffer(name: SHM_NAME)
        let injectRing = try SharedRingBuffer(name: SHM_INJECT_NAME)

        let server = HTTPServer(port: config.port, config: config, mainRing: mainRing, injectRing: injectRing)
        try server.start()

        // Auto-start proxy if a device was previously saved
        if let savedDevice = config.selectedDevice, let device = findDevice(matching: savedDevice) {
            let proxy = MicProxy(deviceID: device.id, mainRing: mainRing, injectRing: injectRing)
            try proxy.start()
            server.proxy = proxy
            server.proxyDeviceName = device.name
            print("Auto-started proxy: \(device.name)")
        }

        signal(SIGINT) { _ in
            print("\nStopping.")
            exit(0)
        }
        print("Press Ctrl-C to stop.")
        dispatchMain()

    case "inject":
        guard args.count >= 3 else { print("Missing file argument."); exit(1) }
        let path = args[2]
        let url  = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            print("File not found: \(path)"); exit(1)
        }

        let injectRing = try SharedRingBuffer(name: SHM_INJECT_NAME)

        print("Decoding \(url.lastPathComponent) …")
        let samples = try decodeAudioFile(url: url)
        let durationS = Double(samples.count / Int(NUM_CHANNELS)) / SAMPLE_RATE
        print(String(format: "Decoded %.2f s of stereo 48kHz audio. Injecting …", durationS))

        injectRing.writeArray(samples)
        print("Done. Audio queued for injection.")

    case "stop":
        let mainRing   = try SharedRingBuffer(name: SHM_NAME)
        let injectRing = try SharedRingBuffer(name: SHM_INJECT_NAME)
        mainRing.clear()
        injectRing.clear()
        print("Ring buffers cleared.")

    case "status":
        let mainRing   = try SharedRingBuffer(name: SHM_NAME)
        let injectRing = try SharedRingBuffer(name: SHM_INJECT_NAME)
        print("Main ring buffer:   \(mainRing.fillPercent)% full (\(mainRing.availableSamples) samples)")
        print("Inject ring buffer: \(injectRing.fillPercent)% full (\(injectRing.availableSamples) samples)")

    default:
        printUsage()
        exit(1)
    }
}

do {
    try main()
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
