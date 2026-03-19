// VideoService.swift — ScreenCaptureKit-based window capture with rolling buffer
// Completely independent from CoreAudio pipeline (AudioService)

import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit

// MARK: - Data Model

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let appName: String
    let bundleID: String
    let appIcon: NSImage?
    let scWindow: SCWindow

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - VideoService

class VideoService: ObservableObject {
    @Published var availableWindows: [WindowInfo] = []
    @Published var selectedWindowID: CGWindowID?
    @Published var isCapturing = false
    @Published var bufferDurationSeconds: Double = 5.0
    @Published var recentVideoSnapshots: [URL] = []

    var snapshotsDir: String = ""

    // Capture internals
    private var stream: SCStream?
    private var streamOutput: VideoStreamOutput?
    private let videoQueue = DispatchQueue(label: "com.pouet.video.capture", qos: .userInteractive)

    // Segment-based rolling buffer: writes 1-second MP4 chunks, keeps last N seconds
    private let segmentDuration: Double = 1.0
    private var segments: [URL] = []
    private var segmentWriter: AVAssetWriter?
    private var segmentVideoInput: AVAssetWriterInput?
    private var segmentStartTime: CMTime?
    private var firstSampleTime: CMTime?
    private var captureWidth: Int = 1920
    private var captureHeight: Int = 1080
    private let writerQueue = DispatchQueue(label: "com.pouet.video.writer")

    private var tempDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PouetVideo")
    }

    // MARK: - Window Listing

    func refreshWindows() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let runningApps = NSWorkspace.shared.runningApplications
            let appsByPID: [pid_t: NSRunningApplication] = Dictionary(
                runningApps.map { ($0.processIdentifier, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            let windows: [WindowInfo] = content.windows.compactMap { scWindow in
                let title = scWindow.title ?? ""
                guard let app = scWindow.owningApplication else { return nil }
                let bundleID = app.bundleIdentifier
                // Skip system UI windows
                if bundleID == "com.apple.dock" || bundleID == "com.apple.WindowManager" ||
                   bundleID == "com.apple.controlcenter" || bundleID == "com.apple.notificationcenterui" {
                    return nil
                }
                // Skip tiny windows (likely invisible)
                if scWindow.frame.width < 100 || scWindow.frame.height < 100 { return nil }

                let nsApp = appsByPID[app.processID]
                let appName = nsApp?.localizedName ?? app.applicationName
                let icon = nsApp?.icon

                return WindowInfo(
                    id: scWindow.windowID,
                    title: title.isEmpty ? appName : title,
                    appName: appName,
                    bundleID: bundleID,
                    appIcon: icon,
                    scWindow: scWindow
                )
            }

            await MainActor.run {
                self.availableWindows = windows.sorted { $0.appName < $1.appName }
            }
        } catch {
            Log.error("Failed to list windows: \(error)")
            await MainActor.run {
                self.availableWindows = []
            }
        }
    }

    func refreshVideoSnapshots() {
        let fm = FileManager.default
        guard !snapshotsDir.isEmpty,
              let files = try? fm.contentsOfDirectory(atPath: snapshotsDir) else {
            recentVideoSnapshots = []
            return
        }
        let urls = files
            .filter { $0.hasPrefix("pouet-video-") && $0.hasSuffix(".mp4") }
            .map { URL(fileURLWithPath: (self.snapshotsDir as NSString).appendingPathComponent($0)) }
            .sorted { u1, u2 in
                let d1 = (try? fm.attributesOfItem(atPath: u1.path)[.creationDate] as? Date) ?? .distantPast
                let d2 = (try? fm.attributesOfItem(atPath: u2.path)[.creationDate] as? Date) ?? .distantPast
                return d1 > d2
            }
        recentVideoSnapshots = Array(urls.prefix(5))
    }

    // MARK: - Capture

    func startCapture() async throws {
        guard let windowID = selectedWindowID,
              let windowInfo = availableWindows.first(where: { $0.id == windowID }) else {
            throw VideoError.noWindowSelected
        }

        // Clean up any previous capture
        await stopCapture()

        // Prepare temp directory
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let scWindow = windowInfo.scWindow
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)

        let config = SCStreamConfiguration()
        // Cap resolution to avoid huge frames; scale down if window is very large
        let maxDim: CGFloat = 1920
        let scale = min(1.0, maxDim / max(scWindow.frame.width, scWindow.frame.height))
        config.width = Int(scWindow.frame.width * scale * 2)   // Retina
        config.height = Int(scWindow.frame.height * scale * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30fps
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false

        streamOutput = VideoStreamOutput(service: self)
        let newStream = SCStream(filter: filter, configuration: config, delegate: streamOutput)
        try newStream.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: videoQueue)

        captureWidth = config.width
        captureHeight = config.height
        stream = newStream
        firstSampleTime = nil
        try await newStream.startCapture()

        await MainActor.run {
            self.isCapturing = true
        }
        Log.info("Video capture started: \(windowInfo.title) (\(config.width)x\(config.height))")
    }

    func stopCapture() async {
        if let stream = stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil

        writerQueue.sync {
            finalizeCurrentSegment()
            cleanupSegments()
        }

        await MainActor.run {
            self.isCapturing = false
        }
    }

    // MARK: - Segment Management (called on writerQueue)

    fileprivate func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, ofType type: SCStreamOutputType) {
        writerQueue.async { [weak self] in
            guard let self = self else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isValid && !pts.isIndefinite else { return }

            // Track first sample time for relative timestamps
            if self.firstSampleTime == nil {
                self.firstSampleTime = pts
            }

            // Start a new segment if needed
            if self.segmentWriter == nil {
                self.startNewSegment(at: pts)
            }

            // Check if current segment exceeded duration
            if let startTime = self.segmentStartTime {
                let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, startTime))
                if elapsed >= self.segmentDuration {
                    self.finalizeCurrentSegment()
                    self.trimOldSegments()
                    self.startNewSegment(at: pts)
                }
            }

            // Write video frame to current segment
            guard let writer = self.segmentWriter, writer.status == .writing else { return }
            if let input = self.segmentVideoInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }

    // MARK: - Save Snapshot

    /// Save a video snapshot, muxing in external audio from the dashcam buffer.
    func saveSnapshot(audioURL: URL? = nil) async -> (url: URL?, error: String?) {
        let segmentsCopy: [URL] = writerQueue.sync {
            finalizeCurrentSegment()
            return Array(segments)
        }

        guard !segmentsCopy.isEmpty else {
            return (nil, "No video data captured")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "pouet-video-\(formatter.string(from: Date())).mp4"
        let outputURL = URL(fileURLWithPath: (snapshotsDir as NSString).appendingPathComponent(filename))

        do {
            try await muxVideoSegments(segmentsCopy, audioURL: audioURL, outputURL: outputURL)
            Log.info("Video snapshot saved: \(outputURL.lastPathComponent)")
            await MainActor.run { refreshVideoSnapshots() }
            return (outputURL, nil)
        } catch {
            Log.error("Video export failed: \(error.localizedDescription)")
            return (nil, error.localizedDescription)
        }
    }

    // MARK: - Segment Management (called on writerQueue)

    private func startNewSegment(at time: CMTime) {
        let filename = "segment_\(segments.count)_\(ProcessInfo.processInfo.globallyUniqueString).mp4"
        let url = tempDir.appendingPathComponent(filename)

        guard let writer = try? AVAssetWriter(url: url, fileType: .mp4) else {
            Log.error("Failed to create AVAssetWriter for segment")
            return
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: captureWidth,
            AVVideoHeightKey: captureHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)
        segmentVideoInput = videoInput

        writer.startWriting()
        writer.startSession(atSourceTime: time)
        segmentWriter = writer
        segmentStartTime = time
    }

    private func finalizeCurrentSegment() {
        guard let writer = segmentWriter else { return }
        segmentVideoInput?.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        if writer.status == .completed {
            segments.append(writer.outputURL)
        } else if let error = writer.error {
            Log.error("Segment finalization error: \(error)")
            try? FileManager.default.removeItem(at: writer.outputURL)
        }

        segmentWriter = nil
        segmentVideoInput = nil
        segmentStartTime = nil
    }

    private func trimOldSegments() {
        let maxSegments = Int(bufferDurationSeconds / segmentDuration)
        while segments.count > maxSegments {
            let old = segments.removeFirst()
            try? FileManager.default.removeItem(at: old)
        }
    }

    private func cleanupSegments() {
        for url in segments {
            try? FileManager.default.removeItem(at: url)
        }
        segments.removeAll()
        try? FileManager.default.removeItem(at: tempDir)
    }
}

// MARK: - Stream Output Delegate

private class VideoStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var service: VideoService?

    init(service: VideoService) {
        self.service = service
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        service?.handleSampleBuffer(sampleBuffer, ofType: type)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("SCStream stopped with error: \(error)")
        Task { @MainActor in
            service?.isCapturing = false
        }
    }
}

// MARK: - Errors

enum VideoError: LocalizedError {
    case noWindowSelected
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noWindowSelected: return "No window selected"
        case .exportFailed(let reason): return "Export failed: \(reason)"
        }
    }
}
