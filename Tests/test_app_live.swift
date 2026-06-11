// test_app_live.swift — Launch the REAL app and verify the contract a video
// call client (Meet/Zoom) actually sees. This is the automated version of
// "call someone and ask if they hear you":
//
//   1. Launch Pouet.app (the real bundle, real config, real TCC permissions)
//   2. The system default input/output must switch to PouetMicrophone/PouetSpeaker
//      — this is what Meet reads. (A takeover that silently fails = silent call.)
//   3. Speak through the machine: `say` plays to the default output
//      (PouetSpeaker → speaker proxy → real speakers → room → real mic →
//      mic proxy → PouetMicrophone). Capturing the DEFAULT INPUT — exactly
//      like Meet — must show the speech well above ambient noise.
//   4. Quit the app: the defaults must be restored to real devices.
//
// Requirements: driver installed, app built/installed, mic permission for both
// the app and this test's terminal, speakers audible (acoustic loop).
//
// Run: make test-live            (uses build/Pouet.app)
//      APP=/Applications/Pouet.app make test-live

import Foundation
import AVFoundation
import CoreAudio
import AppKit

// MARK: - CoreAudio helpers

private func defaultDeviceID(input: Bool) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var deviceID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
          deviceID != 0 else { return nil }
    return deviceID
}

private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uid) == noErr, let uid else { return nil }
    return uid.takeRetainedValue() as String
}

private func defaultDeviceUID(input: Bool) -> String {
    defaultDeviceID(input: input).flatMap(deviceUID) ?? "<none>"
}

/// Captures channel 0 of a device via a raw HAL IOProc (what a call app does).
private final class InputCapture {
    private let deviceID: AudioDeviceID
    private var procID: AudioDeviceIOProcID?
    private var samples: [Float] = []
    private let lock = NSLock()

    init(deviceID: AudioDeviceID) throws {
        self.deviceID = deviceID
        var pid: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "live.capture.\(deviceID)")
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
                self.samples.append(data[i])
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

    func rms() -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for v in samples { sum += Double(v) * Double(v) }
        return Float(sqrt(sum / Double(samples.count)))
    }

    func stop() {
        if let pid = procID {
            AudioDeviceStop(deviceID, pid)
            AudioDeviceDestroyIOProcID(deviceID, pid)
            procID = nil
        }
    }
}

// MARK: - Harness

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

private func waitFor(timeout: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return condition()
}

@discardableResult
private func shell(_ command: String) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", command]
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

// MARK: - Main

@main
struct AppLiveTests {
    static func main() {
        print("=== Live App Tests (launches the real Pouet.app) ===")

        let appPath = ProcessInfo.processInfo.environment["APP"] ?? "build/Pouet.app"
        guard FileManager.default.fileExists(atPath: appPath) else {
            print("ABORT: \(appPath) not found — build the app first (make)")
            exit(2)
        }
        guard FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/Pouet.driver") else {
            print("ABORT: driver not installed (make install)")
            exit(2)
        }

        let originalInput = defaultDeviceUID(input: true)
        let originalOutput = defaultDeviceUID(input: false)
        print("  defaults before launch: in=\(originalInput) out=\(originalOutput)")

        // Fresh start: no stale instance
        shell("killall Pouet 2>/dev/null")
        settle(1.0)

        run("test_app_launches") {
            try assert(shell("open \"\(appPath)\"") == 0, "open failed")
            try assert(waitFor(timeout: 10, {
                NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.pouet.gui" }
            }), "app did not launch")
        }

        // What Meet sees: the system default devices must become Pouet's.
        // This assertion alone catches "takeover silently skipped".
        run("test_system_defaults_switch_to_pouet") {
            let switched = waitFor(timeout: 15, {
                defaultDeviceUID(input: true).contains("PouetMicrophone") &&
                defaultDeviceUID(input: false).contains("PouetSpeaker")
            })
            try assert(switched,
                       "defaults did not switch (in=\(defaultDeviceUID(input: true)) out=\(defaultDeviceUID(input: false)))")
        }

        // The acoustic loop — the machine talks to itself like a Meet call:
        // say → default output (PouetSpeaker) → speaker proxy → real speakers
        // → room → real mic → mic proxy → PouetMicrophone (default input).
        run("test_speech_reaches_default_input_acoustically") {
            guard let inputID = defaultDeviceID(input: true) else {
                throw TestError("no default input device")
            }
            let capture = try InputCapture(deviceID: inputID)
            defer { capture.stop() }
            settle(0.5)

            capture.reset()
            settle(1.5)
            let ambient = capture.rms()

            capture.reset()
            shell("say 'pouet pouet, testing the audio path, one two three'")
            let speech = capture.rms()

            print(String(format: "(ambient=%.4f speech=%.4f) ", ambient, speech), terminator: "")
            try assert(speech > 0.01 && speech > ambient * 3,
                       "speech not heard on default input (ambient \(ambient), speech \(speech)) — " +
                       "check app mic permission and speaker volume")
        }

        // Quitting must hand the real devices back.
        run("test_defaults_restored_on_quit") {
            shell("osascript -e 'tell application \"Pouet\" to quit'")
            let restored = waitFor(timeout: 10, {
                !defaultDeviceUID(input: true).contains("Pouet") &&
                !defaultDeviceUID(input: false).contains("Pouet")
            })
            try assert(restored,
                       "defaults still on Pouet after quit (in=\(defaultDeviceUID(input: true)) out=\(defaultDeviceUID(input: false)))")
        }

        print("\n\(testsPassed)/\(testsRun) live app tests passed")
        exit(testsPassed == testsRun ? 0 : 1)
    }
}
