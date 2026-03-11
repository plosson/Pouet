// test_flow.swift — Automated test for VirtualMic data flow
// Tests: start proxy → inject audio → verify driver output is non-silent

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

// Reuse the shm bridge from shm_bridge.h

let SHM_NAME         = "/VirtualMicAudio"
let SHM_INJECT_NAME  = "/VirtualMicInject"
let SHM_DATA_SIZE    = 4096 * 256
let SAMPLE_RATE      = 48000.0
let NUM_CHANNELS: UInt32 = 2

struct SHMHeader {
    var writePos: UInt64
    var readPos:  UInt64
    var capacity: UInt32
    var pad:      UInt32
}

class TestRingBuffer {
    let name: String
    private let fd: Int32
    private let ptr: UnsafeMutableRawPointer
    private let totalSize: Int
    var header: UnsafeMutablePointer<SHMHeader>
    var data: UnsafeMutablePointer<Float>

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
        ptr = p!
        header = ptr.assumingMemoryBound(to: SHMHeader.self)
        data = (ptr + MemoryLayout<SHMHeader>.size).assumingMemoryBound(to: Float.self)

        let cap = UInt32(SHM_DATA_SIZE / MemoryLayout<Float>.size)
        if header.pointee.capacity == 0 {
            header.pointee.capacity = cap
            header.pointee.writePos = 0
            header.pointee.readPos  = 0
        }
    }

    deinit { munmap(ptr, totalSize); close(fd) }
    var capacity: Int { Int(header.pointee.capacity) }
    var availableSamples: Int { Int(header.pointee.writePos - header.pointee.readPos) }
    var fillPercent: Int {
        let cap = capacity
        let used = availableSamples
        return cap > 0 ? min(100, used * 100 / cap) : 0
    }
}

// ---------------------------------------------------------------------------
// Find VirtualMic device ID
// ---------------------------------------------------------------------------
func findVirtualMicDeviceID() -> AudioDeviceID? {
    var propAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                          &propAddr, 0, nil, &dataSize) == noErr else { return nil }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                      &propAddr, 0, nil, &dataSize, &ids) == noErr else { return nil }
    for id in ids {
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        if AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uid) == noErr {
            if (uid as String).contains("VirtualMic") { return id }
        }
    }
    return nil
}

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------
func runTests() {
    var passed = 0
    var failed = 0

    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("  PASS: \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            passed += 1
        } else {
            print("  FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            failed += 1
        }
    }

    print("=== VirtualMic Test Suite ===\n")

    // Test 1: Driver loaded
    print("[1] Driver registration")
    let vmID = findVirtualMicDeviceID()
    check("VirtualMic device exists", vmID != nil, vmID.map { "deviceID=\($0)" } ?? "not found")

    if let devID = vmID {
        // Check it has input channels
        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var bufSize: UInt32 = 0
        let hasInputConfig = AudioObjectGetPropertyDataSize(devID, &inputAddr, 0, nil, &bufSize) == noErr
        check("Device has input stream config", hasInputConfig && bufSize > 0, "size=\(bufSize)")

        // Check name
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        if AudioObjectGetPropertyData(devID, &nameAddr, 0, nil, &nameSize, &nameRef) == noErr {
            check("Device name is 'VirtualMic'", (nameRef as String) == "VirtualMic", "name='\(nameRef)'")
        }

        // Check sample rate
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(devID, &rateAddr, 0, nil, &rateSize, &rate) == noErr {
            check("Sample rate is 48000", rate == 48000.0, "rate=\(rate)")
        }
    }

    // Test 2: Shared memory
    print("\n[2] Shared memory")
    do {
        let mainRing = try TestRingBuffer(name: SHM_NAME)
        check("Main ring buffer opens", true, "capacity=\(mainRing.capacity)")
        check("Main ring buffer capacity correct", mainRing.capacity == SHM_DATA_SIZE / MemoryLayout<Float>.size)

        let injectRing = try TestRingBuffer(name: SHM_INJECT_NAME)
        check("Inject ring buffer opens", true, "capacity=\(injectRing.capacity)")

        // Write test pattern to main ring
        let testSamples = 1024
        for i in 0..<testSamples {
            let idx = i % mainRing.capacity
            mainRing.data[idx] = sin(Float(i) * 0.1)
        }
        mainRing.header.pointee.writePos = UInt64(testSamples)
        mainRing.header.pointee.readPos = 0
        check("Write test pattern to main ring", mainRing.availableSamples == testSamples,
              "available=\(mainRing.availableSamples)")

        // Verify data integrity
        let sample0 = mainRing.data[0]
        let sample1 = mainRing.data[1]
        check("Data integrity", abs(sample0 - sin(0)) < 0.001 && abs(sample1 - sin(0.1)) < 0.001,
              "s[0]=\(sample0), s[1]=\(sample1)")

    } catch {
        check("Shared memory", false, error.localizedDescription)
    }

    // Test 3: Driver reads from ring buffer
    // We need to open VirtualMic as an input device to trigger StartIO/DoIOOperation
    print("\n[3] Driver I/O (reading from ring buffer)")
    if let devID = vmID {
        do {
            let ring = try TestRingBuffer(name: SHM_NAME)

            // Open a HAL input audio unit pointed at VirtualMic to trigger IO
            var inputDesc = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0
            )
            guard let comp = AudioComponentFindNext(nil, &inputDesc) else {
                check("Find HALOutput component", false); return
            }
            var au: AudioComponentInstance?
            guard AudioComponentInstanceNew(comp, &au) == noErr, let unit = au else {
                check("Create HALOutput instance", false); return
            }

            // Enable input, disable output
            var one: UInt32 = 1
            var zero: UInt32 = 0
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size))
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Output, 0, &zero, UInt32(MemoryLayout<UInt32>.size))

            // Point at VirtualMic
            var dev = devID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))

            // Set format
            var fmt = AudioStreamBasicDescription(
                mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
            )
            AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output, 1, &fmt,
                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

            guard AudioUnitInitialize(unit) == noErr else {
                check("Initialize HAL unit", false); return
            }
            guard AudioOutputUnitStart(unit) == noErr else {
                check("Start HAL unit", false); return
            }
            check("Opened VirtualMic for recording", true)

            // Give the driver a moment to start IO
            usleep(100_000)

            // Reset ring buffer with a known pattern (440Hz sine)
            ring.header.pointee.readPos = 0
            ring.header.pointee.writePos = 0
            let framesToWrite = 48000 * 2  // 0.5 second of stereo samples
            for i in 0..<framesToWrite {
                let frame = i / 2
                let val = sin(Float(frame) * 2.0 * Float.pi * 440.0 / 48000.0) * 0.5
                ring.data[i % ring.capacity] = val
            }
            ring.header.pointee.writePos = UInt64(framesToWrite)
            check("Loaded 440Hz tone into ring buffer", true,
                  "\(framesToWrite) samples, \(ring.fillPercent)% full")

            // Snapshot readPos before and after a short wait
            let readPosBefore = ring.header.pointee.readPos
            let writePosBefore = ring.header.pointee.writePos
            print("    [debug] before wait: readPos=\(readPosBefore) writePos=\(writePosBefore) cap=\(ring.header.pointee.capacity)")
            usleep(500_000) // 500ms
            let readPosAfter = ring.header.pointee.readPos
            let writePosAfter = ring.header.pointee.writePos
            let consumed = readPosAfter - readPosBefore
            print("    [debug] after wait:  readPos=\(readPosAfter) writePos=\(writePosAfter)")

            check("Driver is consuming samples", consumed > 0,
                  "consumed \(consumed) samples in 500ms (expect ~48000)")

            if consumed > 0 {
                let expectedRate = Double(consumed) / 0.5 / 2.0 // frames/sec (stereo)
                check("Consumption rate ~48kHz", expectedRate > 30000 && expectedRate < 60000,
                      "rate=\(Int(expectedRate)) frames/s")
            }

            // Cleanup
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
        } catch {
            check("Ring buffer for IO test", false, error.localizedDescription)
        }
    }

    // Summary
    print("\n=== Results: \(passed) passed, \(failed) failed ===")
    exit(failed > 0 ? 1 : 0)
}

runTests()
