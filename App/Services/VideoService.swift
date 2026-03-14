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
    @Published var captureAudio = true
    @Published var bufferDurationSeconds: Double = 5.0
    @Published var recentVideoSnapshots: [URL] = []

    var snapshotsDir: String = ""

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
            .filter { $0.hasPrefix("video_") && $0.hasSuffix(".mp4") }
            .map { URL(fileURLWithPath: (self.snapshotsDir as NSString).appendingPathComponent($0)) }
            .sorted { u1, u2 in
                let d1 = (try? fm.attributesOfItem(atPath: u1.path)[.creationDate] as? Date) ?? .distantPast
                let d2 = (try? fm.attributesOfItem(atPath: u2.path)[.creationDate] as? Date) ?? .distantPast
                return d1 > d2
            }
        recentVideoSnapshots = Array(urls.prefix(5))
    }
}
