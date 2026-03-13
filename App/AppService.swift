// AppService.swift — High-level service layer for the UI
// Owns: config persistence, sound file management, app state (@Published)
// Uses AudioService for all low-level audio operations

import Foundation
import AVFoundation
import Combine

// MARK: - Config

struct AppConfig: Codable {
    var selectedDevice: String?
    var baseDir: String
    var injectVolume: Float?
    var selectedOutputDevice: String?
    var dashcamBufferSeconds: Double?

    static let defaultPath = NSHomeDirectory() + "/.virtualmicapp.json"
    static let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
    static let defaultBaseDir = (documentsDir as NSString).appendingPathComponent("VirtualMic")

    var soundsDir: String { (baseDir as NSString).appendingPathComponent("Sounds") }
    var snapshotsDir: String { (baseDir as NSString).appendingPathComponent("Recordings") }

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
    @Published var mainRingPercent = 0
    @Published var injectRingPercent = 0
    @Published var injectAvailableSamples = 0
    @Published var currentlyPlaying: String?
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
    @Published var playingSnapshot: URL?

    var soundsDir: String { (baseDir as NSString).appendingPathComponent("Sounds") }
    var snapshotsDir: String { (baseDir as NSString).appendingPathComponent("Recordings") }

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

        // Ensure directories exist
        try? FileManager.default.createDirectory(
            atPath: soundsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            atPath: snapshotsDir, withIntermediateDirectories: true)

        start()
    }

    // MARK: - Lifecycle

    func start() {
        Log.info("AppService starting")
        isRunning = true
        loadDevices()
        loadOutputDevices()
        refreshSounds()
        refreshSnapshots()

        // Save original system defaults BEFORE any changes (skip if already virtual)
        originalInputDeviceID = audio.getNonVirtualDefaultDevice(input: true)
        originalOutputDeviceID = audio.getNonVirtualDefaultDevice(input: false)

        // Auto-start proxies: saved device or system default
        let micName = config.selectedDevice
            ?? audio.defaultDevice(input: true)?.name
        if let name = micName { selectMicDevice(name) }

        let outputName = config.selectedOutputDevice
            ?? audio.defaultDevice(input: false)?.name
        if let name = outputName { selectOutputDevice(name) }

        config.save()

        // Switch system defaults to virtual devices
        if let vmID = audio.findDeviceByUID("VirtualMic") {
            if audio.setSystemDefaultDevice(input: true, deviceID: vmID) {
                Log.info("System default input -> VirtualMic")
            }
        }
        if let vsID = audio.findDeviceByUID("VirtualSpeaker") {
            if audio.setSystemDefaultDevice(input: false, deviceID: vsID) {
                Log.info("System default output -> VirtualSpeaker")
            }
        }

        startPolling()
    }

    func shutdown() {
        stopPolling()
        audio.stopProxy()
        audio.stopSpeakerProxy()

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

        // Restart proxy with new buffer duration if running
        if let deviceName = speakerProxyDeviceName {
            selectOutputDevice(deviceName)
        }
    }

    func saveDashcamSnapshot() -> (url: URL?, error: String?) {
        Log.info("Saving dashcam snapshot (speakerProxy=\(audio.isSpeakerProxyRunning))")
        guard audio.isSpeakerProxyRunning else {
            Log.warn("Snapshot aborted: speaker proxy not running")
            return (nil, "Speaker proxy not running")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "dashcam_\(formatter.string(from: Date())).m4a"
        let url = URL(fileURLWithPath: (snapshotsDir as NSString).appendingPathComponent(filename))

        do {
            try audio.saveDashcamSnapshot(to: url)
            refreshSnapshots()
            return (url, nil)
        } catch {
            Log.error("Dashcam snapshot failed: \(error)")
            return (nil, error.localizedDescription)
        }
    }

    func refreshSnapshots() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: snapshotsDir) else {
            recentSnapshots = []
            return
        }
        let urls = files
            .filter { $0.hasSuffix(".m4a") }
            .map { URL(fileURLWithPath: (self.snapshotsDir as NSString).appendingPathComponent($0)) }
            .sorted { u1, u2 in
                let d1 = (try? fm.attributesOfItem(atPath: u1.path)[.creationDate] as? Date) ?? .distantPast
                let d2 = (try? fm.attributesOfItem(atPath: u2.path)[.creationDate] as? Date) ?? .distantPast
                return d1 > d2
            }
        recentSnapshots = Array(urls.prefix(5))
    }

    private var snapshotPlayer: AVAudioPlayer?

    func playSnapshot(url: URL) {
        stopSnapshotPlayback()
        do {
            snapshotPlayer = try AVAudioPlayer(contentsOf: url)
            snapshotPlayer?.delegate = self
            snapshotPlayer?.play()
            playingSnapshot = url
        } catch {
            Log.error("Snapshot playback failed: \(error)")
            playingSnapshot = nil
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.playingSnapshot = nil
        }
    }

    func stopSnapshotPlayback() {
        snapshotPlayer?.stop()
        snapshotPlayer = nil
        playingSnapshot = nil
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

    func playSound(name: String) {
        let path = (config.soundsDir as NSString).appendingPathComponent(name)
        let url = URL(fileURLWithPath: path)
        currentlyPlaying = name
        audio.injectAudioAsync(url: url) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.currentlyPlaying = nil
                    Log.error("Play error: \(error)")
                }
            }
        }
    }

    func stopPlayback() {
        audio.stopInjection()
        currentlyPlaying = nil
    }

    // MARK: - Settings

    func setBaseDir(_ path: String) {
        baseDir = path
        config.baseDir = path
        config.save()
        try? FileManager.default.createDirectory(atPath: soundsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: snapshotsDir, withIntermediateDirectories: true)
        refreshSounds()
        refreshSnapshots()
    }

    var driverInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/VirtualMic.driver")
    }

    // MARK: - Polling

    // Health checks (read on demand, not polled)
    var hasMicPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    var virtualMicVisible: Bool { audio.virtualMicVisible }
    var speakerShmAvailable: Bool { audio.speakerRing != nil }
    var shmAvailable: Bool { audio.mainRing != nil && audio.injectRing != nil }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let newMainRing = self.audio.mainRingFillPercent
            let newInjectRing = self.audio.injectRingFillPercent
            let newInjectSamples = self.audio.injectRingAvailableSamples
            let newMicPeak = self.audio.micPeakLevel
            let newInjectPeak = self.audio.injectPeakLevel
            let newSpeakerPeak = self.audio.speakerPeakLevel

            if newMainRing != self.mainRingPercent { self.mainRingPercent = newMainRing }
            if newInjectRing != self.injectRingPercent { self.injectRingPercent = newInjectRing }
            if newInjectSamples != self.injectAvailableSamples { self.injectAvailableSamples = newInjectSamples }
            if abs(newMicPeak - self.micPeakLevel) > 0.005 { self.micPeakLevel = newMicPeak }
            if abs(newInjectPeak - self.injectPeakLevel) > 0.005 { self.injectPeakLevel = newInjectPeak }
            if abs(newSpeakerPeak - self.speakerPeakLevel) > 0.005 { self.speakerPeakLevel = newSpeakerPeak }

            if self.currentlyPlaying != nil && self.injectAvailableSamples == 0 {
                self.currentlyPlaying = nil
            }

            // Stop speaker output after idle period
            if let proxy = self.audio.proxy, proxy.idleCallbackCount > 50 {
                proxy.stopOutputIfIdle()
                proxy.idleCallbackCount = 0
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
