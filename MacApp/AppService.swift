// AppService.swift — High-level service layer for the UI
// Owns: config persistence, sound file management, app state (@Published)
// Uses AudioService for all low-level audio operations

import Foundation
import AVFoundation
import Combine

// MARK: - Config

struct AppConfig: Codable {
    var selectedDevice: String?
    var soundsDir: String
    var injectVolume: Float?
    var selectedOutputDevice: String?
    var dashcamBufferSeconds: Double?

    static let defaultPath = NSHomeDirectory() + "/.virtualmicapp.json"
    static let defaultSoundsDir = NSHomeDirectory() + "/VirtualMicSounds"

    static func load() -> AppConfig {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: defaultPath)),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return config
        }
        return AppConfig(selectedDevice: nil, soundsDir: defaultSoundsDir)
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
    @Published var soundsDir: String = ""
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
    @Published var lastSnapshotURL: URL?

    private var config: AppConfig
    private var pollTimer: Timer?

    // MARK: - Init

    init() {
        self.audio = AudioService()
        self.config = AppConfig.load()
        self.soundsDir = config.soundsDir
        self.volume = config.injectVolume ?? 1.0
        self.dashcamBufferSeconds = config.dashcamBufferSeconds ?? 5.0

        // Ensure sounds directory exists
        try? FileManager.default.createDirectory(
            atPath: config.soundsDir, withIntermediateDirectories: true)

        start()
    }

    // MARK: - Lifecycle

    func start() {
        isRunning = true
        loadDevices()
        loadOutputDevices()
        refreshSounds()

        // Auto-start proxy if device was previously saved
        if let savedDevice = config.selectedDevice,
           let device = audio.findDevice(matching: savedDevice) {
            selectedDevice = device.name
            do {
                try audio.startProxy(deviceID: device.id, deviceName: device.name, volume: volume)
                proxyRunning = true
                proxyDeviceName = device.name
            } catch {
                print("[AppService] Auto-start proxy failed: \(error)")
            }
        }

        // Auto-start speaker proxy if output device was previously saved
        if let savedOutput = config.selectedOutputDevice,
           let device = audio.findOutputDevice(matching: savedOutput) {
            selectedOutputDevice = device.name
            do {
                try audio.startSpeakerProxy(deviceID: device.id, deviceName: device.name, bufferDuration: dashcamBufferSeconds)
                speakerProxyRunning = true
                speakerProxyDeviceName = device.name
            } catch {
                print("[AppService] Auto-start speaker proxy failed: \(error)")
            }
        }

        startPolling()
    }

    func shutdown() {
        stopPolling()
        audio.stopProxy()
        audio.stopSpeakerProxy()
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

    // MARK: - Proxy Control

    func startProxy(deviceName: String) throws {
        guard let device = audio.findDevice(matching: deviceName) else {
            throw NSError(domain: "AppService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Device not found: \(deviceName)"])
        }
        try audio.startProxy(deviceID: device.id, deviceName: device.name, volume: volume)
        proxyRunning = true
        proxyDeviceName = device.name
        selectedDevice = device.name
        config.selectedDevice = device.name
        config.save()
    }

    func stopProxy() {
        audio.stopProxy()
        proxyRunning = false
        proxyDeviceName = nil
        // Refresh devices (may have changed while proxy held the device)
        loadDevices()
    }

    // MARK: - Speaker Proxy (Dashcam)

    func startSpeakerProxy(deviceName: String) throws {
        guard let device = audio.findOutputDevice(matching: deviceName) else {
            throw NSError(domain: "AppService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Output device not found: \(deviceName)"])
        }
        do {
            try audio.startSpeakerProxy(deviceID: device.id, deviceName: device.name, bufferDuration: dashcamBufferSeconds)
            speakerProxyRunning = true
            speakerProxyDeviceName = device.name
            selectedOutputDevice = device.name
            config.selectedOutputDevice = device.name
            config.save()
        } catch {
            speakerProxyRunning = false
            speakerProxyDeviceName = nil
            throw error
        }
    }

    func stopSpeakerProxy() {
        audio.stopSpeakerProxy()
        speakerProxyRunning = false
        speakerProxyDeviceName = nil
        loadOutputDevices()
    }

    func setDashcamBufferSeconds(_ seconds: Double) {
        dashcamBufferSeconds = max(1, min(30, seconds))
        config.dashcamBufferSeconds = dashcamBufferSeconds
        config.save()

        // Restart proxy with new buffer duration if running
        if speakerProxyRunning, let deviceName = speakerProxyDeviceName {
            audio.stopSpeakerProxy()
            do {
                try audio.startSpeakerProxy(deviceID: audio.findOutputDevice(matching: deviceName)!.id,
                                            deviceName: deviceName, bufferDuration: dashcamBufferSeconds)
            } catch {
                speakerProxyRunning = false
                speakerProxyDeviceName = nil
                print("[AppService] Failed to restart speaker proxy: \(error)")
            }
        }
    }

    func saveDashcamSnapshot() -> URL? {
        let snapshotDir = (NSHomeDirectory() as NSString).appendingPathComponent("VirtualMicDashcam")
        try? FileManager.default.createDirectory(atPath: snapshotDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "dashcam_\(formatter.string(from: Date())).m4a"
        let url = URL(fileURLWithPath: (snapshotDir as NSString).appendingPathComponent(filename))

        do {
            try audio.saveDashcamSnapshot(to: url)
            lastSnapshotURL = url
            return url
        } catch {
            print("[AppService] Dashcam snapshot failed: \(error)")
            return nil
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
    }

    func playSound(name: String) {
        let path = (config.soundsDir as NSString).appendingPathComponent(name)
        let url = URL(fileURLWithPath: path)
        currentlyPlaying = name
        audio.injectAudioAsync(url: url) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.currentlyPlaying = nil
                    print("[AppService] Play error: \(error)")
                }
            }
        }
    }

    func stopPlayback() {
        audio.stopInjection()
        currentlyPlaying = nil
    }

    // MARK: - Settings

    func setSoundsDir(_ path: String) {
        soundsDir = path
        config.soundsDir = path
        config.save()
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        refreshSounds()
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.mainRingPercent = self.audio.mainRingFillPercent
            self.injectRingPercent = self.audio.injectRingFillPercent
            self.injectAvailableSamples = self.audio.injectRingAvailableSamples
            self.micPeakLevel = self.audio.micPeakLevel
            self.injectPeakLevel = self.audio.injectPeakLevel
            self.speakerPeakLevel = self.audio.speakerPeakLevel

            // Clear playing state when inject buffer drains
            if self.currentlyPlaying != nil && self.injectAvailableSamples == 0 {
                self.currentlyPlaying = nil
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
