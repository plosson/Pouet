// AppService.swift — High-level service layer for the UI
// Owns: config persistence, sound file management, app state (@Published)
// Uses AudioService for all low-level audio operations

import Foundation
import AVFoundation
import Combine

// MARK: - Recording Item (unified audio + video)

enum RecordingKind { case audio, video }

struct RecordingItem: Identifiable {
    let id: String
    let url: URL
    let kind: RecordingKind
    let date: Date
}

// MARK: - Config

struct AppConfig: Codable {
    var selectedDevice: String?
    var baseDir: String
    var injectVolume: Float?
    var selectedOutputDevice: String?
    var dashcamBufferSeconds: Double?
    var hotkeyKeyCode: UInt16?
    var savedInputDefaultUID: String?   // original system default before we switched to Pouet
    var savedOutputDefaultUID: String?  // original system default before we switched to PouetSpeaker

    static let defaultPath = NSHomeDirectory() + "/.pouetapp.json"
    static let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
    static let defaultBaseDir = (documentsDir as NSString).appendingPathComponent("Pouet")

    var soundsDir: String { (baseDir as NSString).appendingPathComponent("Sounds") }
    var audioSnapshotsDir: String { (baseDir as NSString).appendingPathComponent("Recordings/Audio") }
    var videoSnapshotsDir: String { (baseDir as NSString).appendingPathComponent("Recordings/Video") }

    static func load() -> AppConfig {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: defaultPath)),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return config
        }
        return AppConfig(selectedDevice: nil, baseDir: defaultBaseDir)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: URL(fileURLWithPath: AppConfig.defaultPath))
        }
    }
}

// MARK: - AppService

class AppService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    let audio: AudioService
    let video = VideoService()
    let hotkey = HotkeyService()

    // MARK: - Published State

    @Published var isRunning = false
    @Published var proxyRunning = false
    @Published var proxyDeviceName: String?
    @Published var devices: [AudioDeviceInfo] = []
    @Published var sounds: [String] = []
    @Published var soundDurations: [String: TimeInterval] = [:]
    @Published var baseDir: String = ""
    @Published var selectedDevice: String = ""
    @Published var volume: Float = 1.0
    @Published var injectingURL: URL?
    @Published var micPeakLevel: Float = 0.0
    @Published var injectPeakLevel: Float = 0.0

    // Dashcam state
    @Published var speakerProxyRunning = false
    @Published var speakerProxyDeviceName: String?
    @Published var selectedOutputDevice: String = ""
    @Published var outputDevices: [AudioDeviceInfo] = []
    @Published var dashcamBufferSeconds: Double = 5.0
    @Published var speakerPeakLevel: Float = 0.0
    @Published var recentSnapshots: [URL] = []
    @Published var previewingURL: URL?

    var soundsDir: String { (baseDir as NSString).appendingPathComponent("Sounds") }
    var audioSnapshotsDir: String { (baseDir as NSString).appendingPathComponent("Recordings/Audio") }
    var videoSnapshotsDir: String { (baseDir as NSString).appendingPathComponent("Recordings/Video") }

    private static let pollIntervalSeconds = 0.05    // 50ms — smooth meters without excessive CPU
    private static let peakChangeThreshold: Float = 0.005  // 0.5% of full scale, avoids UI thrashing
    private static let maxRecentSnapshots = 10

    private var config: AppConfig
    private var pollTimer: Timer?
    private var originalInputDeviceID: AudioDeviceID?
    private var originalOutputDeviceID: AudioDeviceID?

    // MARK: - Init

    override init() {
        self.audio = AudioService()
        self.config = AppConfig.load()
        self.baseDir = config.baseDir
        self.volume = config.injectVolume ?? 1.0
        self.dashcamBufferSeconds = config.dashcamBufferSeconds ?? 5.0
        super.init()

        // Video buffer matches dashcam duration (audio comes from AudioService)
        video.bufferDurationSeconds = dashcamBufferSeconds
        video.snapshotsDir = videoSnapshotsDir

        // Hotkey config
        if let kc = config.hotkeyKeyCode {
            hotkey.keyCode = kc
        }

        // Ensure directories exist
        try? FileManager.default.createDirectory(
            atPath: soundsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            atPath: audioSnapshotsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            atPath: videoSnapshotsDir, withIntermediateDirectories: true)

        // Defer heavy audio setup so SwiftUI can render first
        DispatchQueue.main.async { [self] in
            start()
        }
    }

    // MARK: - Lifecycle

    func start() {
        Log.info("AppService starting")
        isRunning = true
        loadDevices()
        loadOutputDevices()
        refreshSounds()
        refreshSnapshots()

        // Restore defaults from a previous crash (config has UIDs that weren't cleared)
        if let savedUID = config.savedInputDefaultUID,
           let deviceID = audio.findDeviceByExactUID(savedUID) {
            if audio.setSystemDefaultDevice(input: true, deviceID: deviceID) {
                Log.info("Crash recovery: restored system default input from saved UID")
            }
            config.savedInputDefaultUID = nil
        }
        if let savedUID = config.savedOutputDefaultUID,
           let deviceID = audio.findDeviceByExactUID(savedUID) {
            if audio.setSystemDefaultDevice(input: false, deviceID: deviceID) {
                Log.info("Crash recovery: restored system default output from saved UID")
            }
            config.savedOutputDefaultUID = nil
        }
        config.save()

        // Save original system defaults BEFORE any changes (skip if already virtual)
        originalInputDeviceID = audio.getNonVirtualDefaultDevice(input: true)
        originalOutputDeviceID = audio.getNonVirtualDefaultDevice(input: false)

        // Persist UIDs so we can restore on crash recovery
        if let id = originalInputDeviceID {
            config.savedInputDefaultUID = audio.deviceUID(for: id)
        }
        if let id = originalOutputDeviceID {
            config.savedOutputDefaultUID = audio.deviceUID(for: id)
        }
        config.save()

        // Auto-start proxies: saved device or system default
        let micName = config.selectedDevice
            ?? audio.defaultDevice(input: true)?.name
        if let name = micName { selectMicDevice(name) }

        let outputName = config.selectedOutputDevice
            ?? audio.defaultDevice(input: false)?.name
        if let name = outputName { selectOutputDevice(name) }

        config.save()

        // Switch system defaults to virtual devices
        if let vmID = audio.findDeviceByUID("PouetMicrophone") {
            if audio.setSystemDefaultDevice(input: true, deviceID: vmID) {
                Log.info("System default input -> PouetMicrophone")
            }
        }
        if let vsID = audio.findDeviceByUID("PouetSpeaker") {
            if audio.setSystemDefaultDevice(input: false, deviceID: vsID) {
                Log.info("System default output -> PouetSpeaker")
            }
        }

        startPolling()
        startHotkeys()
    }

    func shutdown() {
        hotkey.stop()
        stopPolling()
        audio.stopProxy()
        audio.stopSpeakerProxy()
        Task { await video.stopCapture() }

        // Restore original system defaults
        if let origIn = originalInputDeviceID {
            if audio.setSystemDefaultDevice(input: true, deviceID: origIn) {
                Log.info("Restored system default input")
            }
        }
        if let origOut = originalOutputDeviceID {
            if audio.setSystemDefaultDevice(input: false, deviceID: origOut) {
                Log.info("Restored system default output")
            }
        }

        // Clear saved UIDs — clean shutdown means no crash recovery needed
        config.savedInputDefaultUID = nil
        config.savedOutputDefaultUID = nil
        config.save()

        isRunning = false
        proxyRunning = false
        speakerProxyRunning = false
    }

    // MARK: - Devices

    func loadDevices() {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let devs = self.audio.listDevices()
            DispatchQueue.main.async {
                self.devices = devs
            }
        }
    }

    func loadOutputDevices() {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let devs = self.audio.listOutputDevices()
            DispatchQueue.main.async {
                self.outputDevices = devs
            }
        }
    }

    // MARK: - Device Selection (auto-starts proxy)

    func selectMicDevice(_ name: String) {
        guard let device = audio.findDevice(matching: name) else {
            Log.error("Mic device not found: \(name)")
            return
        }
        do {
            try audio.startProxy(deviceID: device.id, deviceName: device.name, inputChannels: device.inputChannels, volume: volume)
            proxyRunning = true
            proxyDeviceName = device.name
            selectedDevice = device.name
            config.selectedDevice = device.name
            config.save()
        } catch {
            Log.error("Mic proxy failed: \(error)")
            proxyRunning = false
            proxyDeviceName = nil
        }
    }

    func selectOutputDevice(_ name: String) {
        guard let device = audio.findOutputDevice(matching: name) else {
            Log.error("Output device not found: \(name)")
            return
        }
        do {
            try audio.startSpeakerProxy(deviceID: device.id, deviceName: device.name, bufferDuration: dashcamBufferSeconds)
            speakerProxyRunning = true
            speakerProxyDeviceName = device.name
            selectedOutputDevice = device.name
            config.selectedOutputDevice = device.name
            config.save()
            Log.info("Speaker proxy started: \(device.name) (buffer: \(dashcamBufferSeconds)s)")
        } catch {
            Log.error("Speaker proxy start failed: \(error)")
            speakerProxyRunning = false
            speakerProxyDeviceName = nil
        }
    }

    func setDashcamBufferSeconds(_ seconds: Double) {
        dashcamBufferSeconds = max(1, min(30, seconds))
        config.dashcamBufferSeconds = dashcamBufferSeconds
        config.save()

        // Sync video rolling buffer to same duration
        video.bufferDurationSeconds = dashcamBufferSeconds

        // Restart proxy with new buffer duration if running
        if let deviceName = speakerProxyDeviceName {
            selectOutputDevice(deviceName)
        }
    }


    // MARK: - Hotkey Config

    func setHotkeyKey(_ keyCode: UInt16) {
        hotkey.stop()
        hotkey.keyCode = keyCode
        config.hotkeyKeyCode = keyCode
        config.save()
        hotkey.start()
    }

    func saveDashcamSnapshot() -> (url: URL?, error: String?) {
        Log.info("Saving dashcam snapshot (speakerProxy=\(audio.isSpeakerProxyRunning))")
        guard audio.isSpeakerProxyRunning else {
            Log.warn("Snapshot aborted: speaker proxy not running")
            return (nil, "Speaker proxy not running")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "pouet-audio-\(formatter.string(from: Date())).m4a"
        let url = URL(fileURLWithPath: (audioSnapshotsDir as NSString).appendingPathComponent(filename))

        do {
            try audio.saveDashcamSnapshot(to: url)
            refreshSnapshots()
            return (url, nil)
        } catch {
            Log.error("Dashcam snapshot failed: \(error)")
            return (nil, error.localizedDescription)
        }
    }

    /// Save video snapshot with muxed dashcam audio
    func saveVideoSnapshot() async -> (url: URL?, error: String?) {
        // Save dashcam audio to a temp file for muxing
        var audioURL: URL? = nil
        if audio.isSpeakerProxyRunning {
            let tempAudio = FileManager.default.temporaryDirectory
                .appendingPathComponent("pouet-dashcam-\(UUID().uuidString).m4a")
            do {
                try audio.saveDashcamSnapshot(to: tempAudio)
                audioURL = tempAudio
            } catch {
                Log.warn("No dashcam audio for video snapshot: \(error.localizedDescription)")
            }
        }

        let result = await video.saveSnapshot(audioURL: audioURL)

        // Clean up temp audio file
        if let tempURL = audioURL {
            try? FileManager.default.removeItem(at: tempURL)
        }

        if result.url != nil {
            await MainActor.run { refreshAllSnapshots() }
        }
        return result
    }

    func refreshSnapshots() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: audioSnapshotsDir) else {
            recentSnapshots = []
            return
        }
        let urls = files
            .filter { $0.hasSuffix(".m4a") }
            .map { URL(fileURLWithPath: (self.audioSnapshotsDir as NSString).appendingPathComponent($0)) }
            .sorted { u1, u2 in
                let d1 = (try? fm.attributesOfItem(atPath: u1.path)[.creationDate] as? Date) ?? .distantPast
                let d2 = (try? fm.attributesOfItem(atPath: u2.path)[.creationDate] as? Date) ?? .distantPast
                return d1 > d2
            }
        recentSnapshots = Array(urls.prefix(Self.maxRecentSnapshots))
    }

    // MARK: - All Recordings (merged audio + video)

    var allRecordings: [RecordingItem] {
        let fm = FileManager.default
        let audioItems = recentSnapshots.map { url -> RecordingItem in
            let date = (try? fm.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? .distantPast
            return RecordingItem(id: url.absoluteString, url: url, kind: .audio, date: date)
        }
        let videoItems = video.recentVideoSnapshots.map { url -> RecordingItem in
            let date = (try? fm.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? .distantPast
            return RecordingItem(id: url.absoluteString, url: url, kind: .video, date: date)
        }
        return (audioItems + videoItems)
            .sorted { $0.date > $1.date }
            .prefix(10)
            .map { $0 }
    }

    func refreshAllSnapshots() {
        refreshSnapshots()
        video.refreshVideoSnapshots()
    }

    // MARK: - Preview (local playback via speakers)

    private var previewPlayer: AVAudioPlayer?

    func preview(url: URL) {
        stopPreview()
        do {
            previewPlayer = try AVAudioPlayer(contentsOf: url)
            previewPlayer?.delegate = self
            previewPlayer?.play()
            previewingURL = url
        } catch {
            Log.error("Preview playback failed: \(error)")
            previewingURL = nil
        }
    }

    func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        previewingURL = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.previewingURL = nil
        }
    }

    // MARK: - Volume

    func setVolume(_ vol: Float) {
        let clamped = max(0.0, min(1.0, vol))
        volume = clamped
        audio.injectVolume = clamped
        config.injectVolume = clamped
        config.save()
    }

    // MARK: - Sounds

    func refreshSounds() {
        let dir = config.soundsDir
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else {
            sounds = []
            return
        }
        let audioExts: Set<String> = ["mp3", "m4a", "wav", "aiff", "flac", "aac", "opus"]
        sounds = files.filter { f in
            audioExts.contains((f as NSString).pathExtension.lowercased())
        }.sorted()

        var durations: [String: TimeInterval] = [:]
        for name in sounds {
            let path = (dir as NSString).appendingPathComponent(name)
            let url = URL(fileURLWithPath: path)
            if let file = try? AVAudioFile(forReading: url) {
                let frames = Double(file.length)
                let sampleRate = file.processingFormat.sampleRate
                if sampleRate > 0 {
                    durations[name] = frames / sampleRate
                }
            }
        }
        soundDurations = durations
    }

    // MARK: - Inject (virtual mic)

    func inject(url: URL) {
        injectingURL = url
        audio.injectAudioAsync(url: url) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.injectingURL = nil
                    Log.error("Inject error: \(error)")
                }
            }
        }
    }

    func stopInjection() {
        audio.stopInjection()
        injectingURL = nil
    }

    // MARK: - Settings

    func setBaseDir(_ path: String) {
        baseDir = path
        config.baseDir = path
        config.save()
        try? FileManager.default.createDirectory(atPath: soundsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: audioSnapshotsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: videoSnapshotsDir, withIntermediateDirectories: true)
        video.snapshotsDir = videoSnapshotsDir
        refreshSounds()
        refreshSnapshots()
        video.refreshVideoSnapshots()
    }

    var driverInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/Pouet.driver")
    }

    // MARK: - Polling

    // Health checks (read on demand, not polled)
    var hasMicPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    var virtualMicVisible: Bool { audio.virtualMicVisible }
    var virtualSpeakerVisible: Bool { audio.virtualSpeakerVisible }
    var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    private func startHotkeys() {
        hotkey.onAudioSnapshot = { [weak self] in
            guard let self = self else { return }
            let result = self.saveDashcamSnapshot()
            if let url = result.url {
                Log.info("Hotkey: audio snapshot saved — \(url.lastPathComponent)")
                NotificationCenter.default.post(name: .hotkeyToast, object: "Audio saved: \(url.lastPathComponent)")
            } else {
                NotificationCenter.default.post(name: .hotkeyToast, object: result.error ?? "Audio snapshot failed")
            }
        }
        hotkey.onVideoSnapshot = { [weak self] in
            guard let self = self else { return }
            Task {
                let result = await self.saveVideoSnapshot()
                await MainActor.run {
                    if let url = result.url {
                        Log.info("Hotkey: video snapshot saved — \(url.lastPathComponent)")
                        NotificationCenter.default.post(name: .hotkeyToast, object: "Video saved: \(url.lastPathComponent)")
                    } else {
                        NotificationCenter.default.post(name: .hotkeyToast, object: result.error ?? "Video snapshot failed")
                    }
                }
            }
        }
        hotkey.start()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let newMicPeak = self.audio.micPeakLevel
            let newInjectPeak = self.audio.injectPeakLevel
            let newSpeakerPeak = self.audio.speakerPeakLevel

            if abs(newMicPeak - self.micPeakLevel) > Self.peakChangeThreshold { self.micPeakLevel = newMicPeak }
            if abs(newInjectPeak - self.injectPeakLevel) > Self.peakChangeThreshold { self.injectPeakLevel = newInjectPeak }
            if abs(newSpeakerPeak - self.speakerPeakLevel) > Self.peakChangeThreshold { self.speakerPeakLevel = newSpeakerPeak }

            // Sync proxy state from AudioService
            let running = self.audio.isProxyRunning
            if self.proxyRunning != running { self.proxyRunning = running }
            let name = self.audio.proxyDeviceName
            if self.proxyDeviceName != name { self.proxyDeviceName = name }

            if self.injectingURL != nil && !self.audio.isInjecting {
                self.injectingURL = nil
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    deinit {
        shutdown()
    }
}
