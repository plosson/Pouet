// test_mux.swift — Unit tests for video+audio muxing (no app or hardware needed)
// Compiles against VideoMuxing.swift and exercises the AVMutableComposition pipeline.
//
// Build: swiftc -O -o build/test_mux Tests/test_mux.swift Sources/Pouet/Services/VideoMuxing.swift
// Run:   ./build/test_mux

import Foundation
import AVFoundation

// MARK: - Test Helpers

private let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PouetMuxTest-\(UUID().uuidString)")

private func setup() {
    try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
}

private func cleanup() {
    try? FileManager.default.removeItem(at: tempDir)
}

/// Generate a synthetic video file (solid color frames) using AVAssetWriter.
private func generateVideoFile(url: URL, durationSeconds: Double, fps: Int = 30, width: Int = 320, height: Int = 240) throws {
    let writer = try AVAssetWriter(url: url, fileType: .mp4)
    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ]
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: videoInput,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
    videoInput.expectsMediaDataInRealTime = false
    writer.add(videoInput)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let totalFrames = Int(durationSeconds * Double(fps))
    for i in 0..<totalFrames {
        while !videoInput.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.001)
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let pb = pixelBuffer else { continue }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!
        memset(base, 128, CVPixelBufferGetDataSize(pb))  // grey
        CVPixelBufferUnlockBaseAddress(pb, [])

        let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
        adaptor.append(pb, withPresentationTime: pts)
    }

    videoInput.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()

    guard writer.status == .completed else {
        throw NSError(domain: "test", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Video generation failed: \(writer.error?.localizedDescription ?? "unknown")"])
    }
}

/// Generate a synthetic audio file (sine wave) as M4A.
private func generateAudioFile(url: URL, durationSeconds: Double, sampleRate: Double = 48000, channels: UInt32 = 2) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
    let frameCount = Int(sampleRate * durationSeconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
        throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
    }
    buffer.frameLength = AVAudioFrameCount(frameCount)

    // Fill with 440Hz sine wave
    let freq: Float = 440.0
    for ch in 0..<Int(channels) {
        let channelData = buffer.floatChannelData![ch]
        for i in 0..<frameCount {
            channelData[i] = sinf(2.0 * .pi * freq * Float(i) / Float(sampleRate))
        }
    }

    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128000,
        ],
        commonFormat: .pcmFormatFloat32,
        interleaved: false)
    try file.write(from: buffer)
}

/// Load track info from a file.
private func loadTrackInfo(url: URL) async throws -> (hasVideo: Bool, hasAudio: Bool, duration: Double) {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.load(.tracks)
    let duration = try await asset.load(.duration)
    let hasVideo = tracks.contains(where: { $0.mediaType == .video })
    let hasAudio = tracks.contains(where: { $0.mediaType == .audio })
    return (hasVideo, hasAudio, CMTimeGetSeconds(duration))
}

// MARK: - Tests

private var testsRun = 0
private var testsPassed = 0

private func run(_ name: String, _ body: () async throws -> Void) async {
    testsRun += 1
    print("  \(name)".padding(toLength: 55, withPad: " ", startingAt: 0), terminator: "")
    do {
        try await body()
        print("OK")
        testsPassed += 1
    } catch {
        print("FAIL: \(error.localizedDescription)")
    }
}

private func assert(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

// MARK: - Main

@main
struct MuxTests {
    static func main() async {
        setup()

        print("=== Video Muxing Tests (no hardware needed) ===")

        // Test 1: Mux video-only (no audio)
        await run("test_mux_video_only") {
            let videoURL = tempDir.appendingPathComponent("video1.mp4")
            let outputURL = tempDir.appendingPathComponent("output1.mp4")
            try generateVideoFile(url: videoURL, durationSeconds: 1.0)
            try await muxVideoSegments([videoURL], outputURL: outputURL)
            let info = try await loadTrackInfo(url: outputURL)
            try assert(info.hasVideo, "output should have video track")
            try assert(!info.hasAudio, "output should not have audio track")
            try assert(info.duration > 0.8, "duration too short: \(info.duration)")
        }

        // Test 2: Mux video + audio
        await run("test_mux_video_with_audio") {
            let videoURL = tempDir.appendingPathComponent("video2.mp4")
            let audioURL = tempDir.appendingPathComponent("audio2.m4a")
            let outputURL = tempDir.appendingPathComponent("output2.mp4")
            try generateVideoFile(url: videoURL, durationSeconds: 2.0)
            try generateAudioFile(url: audioURL, durationSeconds: 2.0)
            try await muxVideoSegments([videoURL], audioURL: audioURL, outputURL: outputURL)
            let info = try await loadTrackInfo(url: outputURL)
            try assert(info.hasVideo, "output should have video track")
            try assert(info.hasAudio, "output should have audio track")
            try assert(info.duration > 1.8, "duration too short: \(info.duration)")
        }

        // Test 3: Multiple segments concatenated + audio
        await run("test_mux_multiple_segments_with_audio") {
            let seg1 = tempDir.appendingPathComponent("seg3a.mp4")
            let seg2 = tempDir.appendingPathComponent("seg3b.mp4")
            let audioURL = tempDir.appendingPathComponent("audio3.m4a")
            let outputURL = tempDir.appendingPathComponent("output3.mp4")
            try generateVideoFile(url: seg1, durationSeconds: 1.0)
            try generateVideoFile(url: seg2, durationSeconds: 1.0)
            try generateAudioFile(url: audioURL, durationSeconds: 2.0)
            try await muxVideoSegments([seg1, seg2], audioURL: audioURL, outputURL: outputURL)
            let info = try await loadTrackInfo(url: outputURL)
            try assert(info.hasVideo, "output should have video track")
            try assert(info.hasAudio, "output should have audio track")
            try assert(info.duration > 1.8, "concatenated duration too short: \(info.duration)")
        }

        // Test 4: Audio shorter than video — should trim to audio duration
        await run("test_mux_audio_shorter_than_video") {
            let videoURL = tempDir.appendingPathComponent("video4.mp4")
            let audioURL = tempDir.appendingPathComponent("audio4.m4a")
            let outputURL = tempDir.appendingPathComponent("output4.mp4")
            try generateVideoFile(url: videoURL, durationSeconds: 3.0)
            try generateAudioFile(url: audioURL, durationSeconds: 1.0)
            try await muxVideoSegments([videoURL], audioURL: audioURL, outputURL: outputURL)
            let info = try await loadTrackInfo(url: outputURL)
            try assert(info.hasVideo, "output should have video track")
            try assert(info.hasAudio, "output should have audio track")
            // Audio track should be ~1s, video track ~3s, overall duration = video duration
            try assert(info.duration > 2.5, "video duration should be preserved: \(info.duration)")
        }

        // Test 5: Empty segments list should fail
        await run("test_mux_no_segments_fails") {
            let outputURL = tempDir.appendingPathComponent("output5.mp4")
            var threw = false
            do {
                try await muxVideoSegments([], outputURL: outputURL)
            } catch {
                threw = true
            }
            try assert(threw, "should throw for empty segments")
        }

        print("\n\(testsPassed)/\(testsRun) mux tests passed")
        cleanup()
        exit(testsPassed == testsRun ? 0 : 1)
    }
}
