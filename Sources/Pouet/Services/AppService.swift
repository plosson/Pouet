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
    var hotkeyKeyCode: UInt16?
    var savedInputDefaultUID: String?   // original system default before we switched to PouetMicrophone

    static let defaultPath = NSHomeDirectory() + "/.pouetapp.json"
    static let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
    static let defaultBaseDir = (documentsDir as NSString).appendingPathComponent("Pouet")

    var soundsDir: String { (baseDir as NSString).appendingPathComponent("Sounds") }

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

class AppService: ObservableObject {
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
    @Published var injectingURL: URL?
    @Published var micPeakLevel: Float = 0.0
    @Published var injectPeakLevel: Float = 0.0

    var soundsDir: String { (baseDir as NSString).appendingPathComponent("Sounds") }

    private static let pollIntervalSeconds = 0.05    // 50ms — smooth meters without excessive CPU
    private static let peakChangeThreshold: Float = 0.005  // 0.5% of full scale, avoids UI thrashing

    private var config: AppConfig
    private var pollTimer: Timer?
    private var originalInputDeviceID: AudioDeviceID?

    // MARK: - Init

    init() {
        self.audio = AudioService()
        self.config = AppConfig.load()
        self.baseDir = config.baseDir
        self.volume = config.injectVolume ?? 1.0

        // Ensure directories exist
        try? FileManager.default.createDirectory(
            atPath: soundsDir, withIntermediateDirectories: true)

        start()
    }

    // MARK: - Lifecycle

    func start() {
        Log.info("AppService starting")
        isRunning = true
        loadDevices()
        refreshSounds()

        // Restore defaults from a previous crash (config has UIDs that weren't cleared)
        if let savedUID = config.savedInputDefaultUID,
           let deviceID = audio.findDeviceByExactUID(savedUID) {
            if audio.setSystemDefaultDevice(input: true, deviceID: deviceID) {
                Log.info("Crash recovery: restored system default input from saved UID")
            }
            config.savedInputDefaultUID = nil
        }
        config.save()

        // Save original system default BEFORE any changes (skip if already virtual)
        originalInputDeviceID = audio.getNonVirtualDefaultDevice(input: true)

        // Persist UID so we can restore on crash recovery
        if let id = originalInputDeviceID {
            config.savedInputDefaultUID = audio.deviceUID(for: id)
        }
        config.save()

        // Auto-start proxy: saved device or system default
        let micName = config.selectedDevice
            ?? audio.defaultDevice(input: true)?.name
        if let name = micName { selectMicDevice(name) }

        config.save()

        // Switch system default input to PouetMicrophone
        if let vmID = audio.findDeviceByUID("PouetMicrophone") {
            if audio.setSystemDefaultDevice(input: true, deviceID: vmID) {
                Log.info("System default input -> PouetMicrophone")
            }
        }

        startPolling()
    }

    func shutdown() {
        stopPolling()
        audio.stopProxy()

        // Restore original system default input
        if let origIn = originalInputDeviceID {
            if audio.setSystemDefaultDevice(input: true, deviceID: origIn) {
                Log.info("Restored system default input")
            }
        }

        // Clear saved UID — clean shutdown means no crash recovery needed
        config.savedInputDefaultUID = nil
        config.save()

        isRunning = false
        proxyRunning = false
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
        refreshSounds()
    }

    var driverInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/Pouet.driver")
    }

    // MARK: - Health Checks

    var hasMicPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    var virtualMicVisible: Bool { audio.virtualMicVisible }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let newMicPeak = self.audio.micPeakLevel
            let newInjectPeak = self.audio.injectPeakLevel

            if abs(newMicPeak - self.micPeakLevel) > Self.peakChangeThreshold { self.micPeakLevel = newMicPeak }
            if abs(newInjectPeak - self.injectPeakLevel) > Self.peakChangeThreshold { self.injectPeakLevel = newInjectPeak }

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
