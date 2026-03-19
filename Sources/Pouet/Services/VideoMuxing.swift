// VideoMuxing.swift — Pure muxing functions for combining video segments + audio
// Extracted for testability. Used by VideoService.saveSnapshot.

import Foundation
import AVFoundation

/// Concatenate video segment files and optionally mux in an external audio file.
/// Returns the output URL on success, or throws on failure.
func muxVideoSegments(
    _ segmentURLs: [URL],
    audioURL: URL? = nil,
    outputURL: URL
) async throws {
    guard !segmentURLs.isEmpty else {
        throw MuxError.noSegments
    }

    let composition = AVMutableComposition()
    let compositionVideoTrack = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    var insertTime = CMTime.zero

    for segmentURL in segmentURLs {
        let asset = AVURLAsset(url: segmentURL)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)

        if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
            try compositionVideoTrack?.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: videoTrack, at: insertTime)
        }
        insertTime = CMTimeAdd(insertTime, duration)
    }

    let videoDuration = insertTime
    guard CMTimeGetSeconds(videoDuration) > 0 else {
        throw MuxError.noVideoData
    }

    // Mux in audio if provided
    if let audioURL = audioURL {
        let audioAsset = AVURLAsset(url: audioURL)
        let audioDuration = try await audioAsset.load(.duration)
        let audioTracks = try await audioAsset.load(.tracks)
        if let audioTrack = audioTracks.first(where: { $0.mediaType == .audio }) {
            let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            let muxDuration = CMTimeMinimum(videoDuration, audioDuration)
            try compositionAudioTrack?.insertTimeRange(
                CMTimeRange(start: .zero, duration: muxDuration),
                of: audioTrack, at: .zero)
        }
    }

    // Export to MP4
    guard let exportSession = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
        throw MuxError.exportSessionFailed
    }
    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mp4

    await exportSession.export()

    switch exportSession.status {
    case .completed:
        return
    case .failed:
        throw MuxError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown error")
    default:
        throw MuxError.exportFailed("Export cancelled")
    }
}

enum MuxError: LocalizedError {
    case noSegments
    case noVideoData
    case exportSessionFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSegments: return "No video segments provided"
        case .noVideoData: return "No valid video data in segments"
        case .exportSessionFailed: return "Failed to create export session"
        case .exportFailed(let reason): return "Export failed: \(reason)"
        }
    }
}
