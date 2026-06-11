// test_e2e_audio.swift — End-to-end audio path tests against the INSTALLED driver.
//
// Proves that sound actually flows through the full stack (HAL driver IO +
// AVAudioEngine wiring + AudioService), using the virtual devices themselves as
// stand-ins for real hardware so no human ears or physical devices are needed:
//
//   Mic proxy path:   test sine → PouetSpeaker ─(proxy: fake mic)→ PouetMicrophone → captured & analyzed
//   Injection path:   880 Hz file ─(inject submixer)→ PouetMicrophone → captured & analyzed
//   Speaker proxy:    test sine → PouetSpeaker ─(monitor)→ PouetMicrophone (fake speakers)
//                     and → dashcam rolling buffer → M4A snapshot → analyzed
//
// Requirements: driver installed (make install) + microphone permission for the
// terminal running the tests.
//
// Build: see `make test-e2e`

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

// MARK: - Tone generation & capture
//
// Both use raw HAL IOProcs, NOT AVAudioEngine: multiple AVAudioEngine input
// nodes in one process are unreliable (the second one delivers silence), and
// this harness must not interfere with the AudioService engines under test.

private func deviceStreamFormat(_ deviceID: AudioDeviceID, input: Bool) throws -> AudioStreamBasicDescription {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamFormat,
        mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &asbd)
    guard status == noErr, asbd.mSampleRate > 0 else {
        throw TestError("no \(input ? "input" : "output") stream format (status \(status))")
    }
    return asbd
}

/// Plays a continuous sine tone to a specific output device via a HAL IOProc.
private final class SinePlayer {
    private let deviceID: AudioDeviceID
    private var procID: AudioDeviceIOProcID?

    init(deviceID: AudioDeviceID, frequency: Double, amplitude: Float = 0.8) throws {
        self.deviceID = deviceID
        let sampleRate = try deviceStreamFormat(deviceID, input: false).mSampleRate

        var phase = 0.0
        let increment = 2.0 * Double.pi * frequency / sampleRate
        var pid: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "e2e.sine.\(deviceID)")
        let status = AudioDeviceCreateIOProcIDWithBlock(&pid, deviceID, queue) { _, _, _, outData, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(outData)
            for buffer in buffers {
                guard let base = buffer.mData else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
                let out = base.assumingMemoryBound(to: Float.self)
                for f in 0..<frames {
                    let value = Float(sin(phase)) * amplitude
                    phase += increment
                    if phase > 2.0 * .pi { phase -= 2.0 * .pi }
                    for c in 0..<channels { out[f * channels + c] = value }
                }
            }
        }
        guard status == noErr, let pid else { throw TestError("create sine IOProc failed: \(status)") }
        procID = pid
        let startStatus = AudioDeviceStart(deviceID, pid)
        guard startStatus == noErr else { throw TestError("start sine IO failed: \(startStatus)") }
    }

    func stop() {
        if let pid = procID {
            AudioDeviceStop(deviceID, pid)
            AudioDeviceDestroyIOProcID(deviceID, pid)
            procID = nil
        }
    }
}

/// Captures samples (channel 0) from a specific input device via a HAL IOProc.
private final class InputCapture {
    private let deviceID: AudioDeviceID
    private var procID: AudioDeviceIOProcID?
    private var samples: [Float] = []
    private let lock = NSLock()
    let sampleRate: Double

    init(deviceID: AudioDeviceID) throws {
        self.deviceID = deviceID
        sampleRate = try deviceStreamFormat(deviceID, input: true).mSampleRate

        var pid: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "e2e.capture.\(deviceID)")
        let status = AudioDeviceCreateIOProcIDWithBlock(&pid, deviceID, queue) { [weak self] _, inData, _, _, _ in
            guard let self else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard buffers.count > 0, let base = buffers[0].mData else { return }
            let channels = max(1, Int(buffers[0].mNumberChannels))
            let count = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let data = base.assumingMemoryBound(to: Float.self)
            self.lock.lock()
            var i = 0
            while i < count {
                self.samples.append(data[i])  // channel 0 only
                i += channels
            }
            self.lock.unlock()
        }
        guard status == noErr, let pid else { throw TestError("create capture IOProc failed: \(status)") }
        procID = pid
        let startStatus = AudioDeviceStart(deviceID, pid)
        guard startStatus == noErr else { throw TestError("start capture IO failed: \(startStatus)") }
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func stop() {
        if let pid = procID {
            AudioDeviceStop(deviceID, pid)
            AudioDeviceDestroyIOProcID(deviceID, pid)
            procID = nil
        }
    }
}

// MARK: - Signal analysis

private struct ToneAnalysis {
    var rms: Float = 0
    var frequency: Double = 0
    var amplitude: Double = 0      // fitted tone amplitude
    var snrDB: Double = 0          // fitted tone power vs residual power
    var longestGapMs: Double = 0   // longest near-silent run inside the tone
}

/// RMS of the active (non-silent) region — used by the silence test.
private func activeRMS(_ samples: [Float]) -> Float {
    let threshold: Float = 0.02
    guard let first = samples.firstIndex(where: { abs($0) > threshold }),
          let last = samples.lastIndex(where: { abs($0) > threshold }),
          last > first + 256 else {
        return 0
    }
    var sum = 0.0
    for i in first...last { sum += Double(samples[i]) * Double(samples[i]) }
    return Float(sqrt(sum / Double(last - first + 1)))
}

/// Fidelity analysis: least-squares fit of the expected sine per 100 ms chunk
/// (sin/cos quadrature), then measure everything the fit does NOT explain.
/// Clipping, harmonic distortion, glitches, and resampling artifacts all land
/// in the residual and crater the SNR; dropouts show up in the gap scan.
private func analyzeTone(_ samples: [Float], sampleRate: Double, expectedFrequency: Double) -> ToneAnalysis {
    var result = ToneAnalysis()

    // Trim leading/trailing silence, then drop 10% margins to avoid start/stop
    // transients (engine spin-up, ring prefill)
    let threshold: Float = 0.02
    guard let first = samples.firstIndex(where: { abs($0) > threshold }),
          let last = samples.lastIndex(where: { abs($0) > threshold }),
          last > first + 4096 else {
        return result
    }
    let margin = (last - first) / 10
    let core = Array(samples[(first + margin)...(last - margin)])

    // RMS + zero-crossing frequency
    var sum = 0.0
    var crossings = 0
    for i in 0..<core.count {
        sum += Double(core[i]) * Double(core[i])
        if i > 0 && (core[i - 1] < 0) != (core[i] < 0) { crossings += 1 }
    }
    result.rms = Float(sqrt(sum / Double(core.count)))
    result.frequency = Double(crossings) / 2.0 * sampleRate / Double(core.count)

    // Dropout scan: a continuous tone never sits near zero for more than a
    // fraction of a cycle; a multi-millisecond quiet run is a glitch
    var gap = 0
    var longestGap = 0
    for value in core {
        if abs(value) < 0.005 {
            gap += 1
            longestGap = max(longestGap, gap)
        } else {
            gap = 0
        }
    }
    result.longestGapMs = Double(longestGap) / sampleRate * 1000.0

    // Per-chunk quadrature fit. 100 ms chunks hold an integer number of cycles
    // for 440/880 Hz, keeping sin/cos orthogonal, and tolerate slow phase drift.
    let chunk = Int(sampleRate * 0.1)
    let omega = 2.0 * Double.pi * expectedFrequency / sampleRate
    var tonePower = 0.0
    var residualPower = 0.0
    var amplitudeSum = 0.0
    var chunkCount = 0
    var index = 0
    while index + chunk <= core.count {
        var sinSum = 0.0
        var cosSum = 0.0
        for i in 0..<chunk {
            let v = Double(core[index + i])
            sinSum += v * sin(omega * Double(i))
            cosSum += v * cos(omega * Double(i))
        }
        let a = 2.0 * sinSum / Double(chunk)
        let b = 2.0 * cosSum / Double(chunk)
        amplitudeSum += sqrt(a * a + b * b)
        for i in 0..<chunk {
            let fit = a * sin(omega * Double(i)) + b * cos(omega * Double(i))
            let residual = Double(core[index + i]) - fit
            tonePower += fit * fit
            residualPower += residual * residual
        }
        chunkCount += 1
        index += chunk
    }
    if chunkCount > 0 {
        result.amplitude = amplitudeSum / Double(chunkCount)
        result.snrDB = 10.0 * log10(tonePower / max(residualPower, 1e-12))
    }
    return result
}

/// The full fidelity gate: present, right pitch, right level, clean, gapless.
private func assertTone(_ samples: [Float], sampleRate: Double,
                        expectedFrequency: Double, label: String,
                        amplitudeRange: ClosedRange<Double> = 0.4...1.2) throws {
    let tone = analyzeTone(samples, sampleRate: sampleRate, expectedFrequency: expectedFrequency)
    try assert(tone.rms > 0.05,
               "\(label): expected signal, got RMS \(tone.rms)")
    try assert(abs(tone.frequency - expectedFrequency) < expectedFrequency * 0.05,
               "\(label): expected ~\(Int(expectedFrequency)) Hz, measured \(Int(tone.frequency)) Hz")
    try assert(amplitudeRange.contains(tone.amplitude),
               "\(label): amplitude \(tone.amplitude) outside \(amplitudeRange) (gain wrong)")
    try assert(tone.snrDB > 25,
               "\(label): distorted — tone SNR only \(Int(tone.snrDB)) dB (clipping/glitches)")
    try assert(tone.longestGapMs < 5,
               "\(label): dropout — \(Int(tone.longestGapMs)) ms silent gap inside the tone")
    print(String(format: "(%.0fHz amp=%.2f snr=%.0fdB) ", tone.frequency, tone.amplitude, tone.snrDB),
          terminator: "")
}

/// Generate a sine WAV file for the injection test.
private func generateSineFile(url: URL, frequency: Double, durationSeconds: Double,
                              sampleRate: Double = 48000) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
        throw TestError("failed to create buffer")
    }
    buffer.frameLength = frameCount
    for ch in 0..<2 {
        let data = buffer.floatChannelData![ch]
        for i in 0..<Int(frameCount) {
            data[i] = sinf(2.0 * .pi * Float(frequency) * Float(i) / Float(sampleRate)) * 0.8
        }
    }
    try file.write(from: buffer)
}

/// Read an audio file back as channel-0 samples.
private func readAudioFile(url: URL) throws -> (samples: [Float], sampleRate: Double) {
    let file = try AVAudioFile(forReading: url)
    let frameCount = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
        throw TestError("failed to create read buffer")
    }
    try file.read(into: buffer)
    guard let data = buffer.floatChannelData else { throw TestError("no channel data") }
    return (Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))),
            file.processingFormat.sampleRate)
}

// MARK: - Test harness

private struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private var testsRun = 0
private var testsPassed = 0

private func run(_ name: String, _ body: () throws -> Void) {
    testsRun += 1
    print("  \(name)".padding(toLength: 55, withPad: " ", startingAt: 0), terminator: "")
    do {
        try body()
        print("OK")
        testsPassed += 1
    } catch {
        print("FAIL: \(error)")
    }
}

private func assert(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestError(message) }
}

private func settle(_ seconds: Double) {
    Thread.sleep(forTimeInterval: seconds)
}

private func ensureMicPermission() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)
        return granted
    default:
        return false
    }
}

// MARK: - Main

@main
struct E2EAudioTests {
    static func main() {
        print("=== End-to-End Audio Tests (installed driver + mic permission required) ===")

        let audio = AudioService()

        guard audio.virtualMicVisible, audio.virtualSpeakerVisible else {
            print("ABORT: PouetMicrophone/PouetSpeaker not visible — install the driver first (make install)")
            exit(2)
        }
        guard ensureMicPermission() else {
            print("ABORT: microphone permission denied — grant it to this terminal in System Settings > Privacy")
            exit(2)
        }
        guard let pouetSpeakerID = audio.findDeviceByUID("PouetSpeaker"),
              let pouetMicID = audio.findDeviceByUID("PouetMicrophone") else {
            print("ABORT: could not resolve virtual device IDs")
            exit(2)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PouetE2E-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // ------------------------------------------------------------------
        // Mic proxy: PouetSpeaker stands in for the real mic. A tone written
        // to PouetSpeaker must come out of PouetMicrophone — this is the path
        // Zoom reads, and exactly the wiring that was silently broken before.
        // ------------------------------------------------------------------
        run("test_mic_proxy_passes_audio_end_to_end") {
            try audio.startProxy(deviceID: pouetSpeakerID, deviceName: "FakeMic(PouetSpeaker)",
                                 inputChannels: 2, volume: 1.0)
            defer { audio.stopProxy() }

            let player = try SinePlayer(deviceID: pouetSpeakerID, frequency: 440)
            defer { player.stop() }
            settle(0.5)

            let capture = try InputCapture(deviceID: pouetMicID)
            defer { capture.stop() }
            settle(0.3)
            capture.reset()
            settle(1.5)

            try assertTone(capture.snapshot(), sampleRate: capture.sampleRate,
                           expectedFrequency: 440, label: "mic proxy output")
        }

        // ------------------------------------------------------------------
        // Injection: with the proxy running but the "mic" silent, an injected
        // 880 Hz file must come out of PouetMicrophone via the inject submixer.
        // ------------------------------------------------------------------
        run("test_injection_reaches_virtual_mic") {
            try audio.startProxy(deviceID: pouetSpeakerID, deviceName: "FakeMic(PouetSpeaker)",
                                 inputChannels: 2, volume: 1.0)
            defer {
                audio.stopInjection()
                audio.stopProxy()
            }
            settle(0.5)

            let soundURL = tempDir.appendingPathComponent("inject-880.wav")
            try generateSineFile(url: soundURL, frequency: 880, durationSeconds: 2.5)

            let capture = try InputCapture(deviceID: pouetMicID)
            defer { capture.stop() }
            settle(0.3)

            try audio.injectAudio(url: soundURL)
            settle(0.3)
            capture.reset()
            settle(1.5)

            try assertTone(capture.snapshot(), sampleRate: capture.sampleRate,
                           expectedFrequency: 880, label: "injected sound")
        }

        // ------------------------------------------------------------------
        // Speaker proxy, monitoring path: PouetMicrophone stands in for the
        // real speakers. A tone written to PouetSpeaker must be forwarded to
        // the "speakers" — the local-monitoring wiring that was also broken.
        // ------------------------------------------------------------------
        run("test_speaker_proxy_monitoring_path") {
            try audio.startSpeakerProxy(deviceID: pouetMicID, deviceName: "FakeSpeakers(PouetMicrophone)",
                                        bufferDuration: 3.0)
            defer { audio.stopSpeakerProxy() }

            let player = try SinePlayer(deviceID: pouetSpeakerID, frequency: 440)
            defer { player.stop() }
            settle(0.5)

            let capture = try InputCapture(deviceID: pouetMicID)
            defer { capture.stop() }
            settle(0.3)
            capture.reset()
            settle(1.5)

            try assertTone(capture.snapshot(), sampleRate: capture.sampleRate,
                           expectedFrequency: 440, label: "monitoring output")
        }

        // ------------------------------------------------------------------
        // Speaker proxy, dashcam path: the same tone must land in the rolling
        // buffer and survive the M4A export with the right frequency.
        // ------------------------------------------------------------------
        run("test_dashcam_snapshot_records_speaker_audio") {
            try audio.startSpeakerProxy(deviceID: pouetMicID, deviceName: "FakeSpeakers(PouetMicrophone)",
                                        bufferDuration: 3.0)
            defer { audio.stopSpeakerProxy() }

            let player = try SinePlayer(deviceID: pouetSpeakerID, frequency: 440)
            settle(2.0)
            player.stop()

            let snapshotURL = tempDir.appendingPathComponent("dashcam.m4a")
            try audio.saveDashcamSnapshot(to: snapshotURL)

            let recording = try readAudioFile(url: snapshotURL)
            try assertTone(recording.samples, sampleRate: recording.sampleRate,
                           expectedFrequency: 440, label: "dashcam recording")
        }

        // ------------------------------------------------------------------
        // Both proxies at once — the app's real-world configuration. Two
        // capture clients on PouetSpeaker and two playback engines writing
        // PouetMicrophone must all coexist in one process.
        // ------------------------------------------------------------------
        run("test_both_proxies_run_concurrently") {
            try audio.startProxy(deviceID: pouetSpeakerID, deviceName: "FakeMic(PouetSpeaker)",
                                 inputChannels: 2, volume: 1.0)
            try audio.startSpeakerProxy(deviceID: pouetMicID, deviceName: "FakeSpeakers(PouetMicrophone)",
                                        bufferDuration: 3.0)
            defer {
                audio.stopProxy()
                audio.stopSpeakerProxy()
            }

            let player = try SinePlayer(deviceID: pouetSpeakerID, frequency: 440)
            defer { player.stop() }
            settle(0.5)

            let capture = try InputCapture(deviceID: pouetMicID)
            defer { capture.stop() }
            settle(0.3)
            capture.reset()
            settle(1.5)

            // Both proxies forward the tone to PouetMicrophone (HAL sums them,
            // so the amplitude is roughly doubled)
            try assertTone(capture.snapshot(), sampleRate: capture.sampleRate,
                           expectedFrequency: 440, label: "concurrent proxies",
                           amplitudeRange: 0.4...2.0)
            try assert(audio.isProxyRunning, "mic proxy should still be running")
            try assert(audio.isSpeakerProxyRunning, "speaker proxy should still be running")
        }

        // ------------------------------------------------------------------
        // Isolation: once everything is stopped and the ring buffers go
        // stale, PouetMicrophone must read back silence — no residual tone.
        // ------------------------------------------------------------------
        run("test_silence_after_proxies_stop") {
            settle(0.5)
            let capture = try InputCapture(deviceID: pouetMicID)
            defer { capture.stop() }
            settle(0.3)
            capture.reset()
            settle(1.0)

            let rms = activeRMS(capture.snapshot())
            try assert(rms < 0.01, "expected silence, got RMS \(rms)")
        }

        print("\n\(testsPassed)/\(testsRun) end-to-end audio tests passed")
        exit(testsPassed == testsRun ? 0 : 1)
    }
}
