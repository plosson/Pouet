// HotkeyService.swift — Global hotkey registration using NSEvent monitors
// Cmd+J = audio snapshot, Cmd+J J (double tap) = video snapshot
// Uses NSEvent global/local monitors — no Accessibility permission required.

import Foundation
import AppKit

class HotkeyService {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastTapTime: Date?
    private let doubleTapInterval: TimeInterval = 0.35
    private var pendingAudioTimer: DispatchWorkItem?

    // Callbacks
    var onAudioSnapshot: (() -> Void)?
    var onVideoSnapshot: (() -> Void)?

    // Configurable key (default: J = keycode 38)
    var keyCode: UInt16 = 38 {
        didSet { keyDisplayName = Self.displayName(for: keyCode) }
    }

    // Human-readable key name for UI display
    private(set) var keyDisplayName: String = "J"

    // Map keycodes to display names
    static func displayName(for keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G",
            6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
            13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1",
            19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=",
            25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 31: "O",
            32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
            45: "N", 46: "M",
        ]
        return map[keyCode] ?? "?\(keyCode)"
    }

    /// Available single-letter keys suitable for Cmd+key hotkeys
    /// (excludes letters commonly used by system: A, C, V, X, Z, Q, W, S, N, O, P, H, M, F)
    static let availableKeys: [(name: String, keyCode: UInt16)] = [
        ("B", 11), ("D", 2), ("E", 14), ("G", 5), ("I", 34),
        ("J", 38), ("K", 40), ("L", 37), ("R", 15), ("T", 17),
        ("U", 32), ("Y", 16),
    ]

    init() {}

    func start() {
        // Global monitor: fires when another app is active (cannot consume events)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleEvent(event)
        }

        // Local monitor: fires when Pouet is active (can consume events)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleEvent(event) == true {
                return nil // consume
            }
            return event
        }

        Log.info("Global hotkey registered (Cmd+\(keyDisplayName))")
    }

    func stop() {
        pendingAudioTimer?.cancel()
        pendingAudioTimer = nil
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        Log.info("Global hotkey unregistered")
    }

    @discardableResult
    private func handleEvent(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode,
              event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.shift) else {
            return false
        }

        let now = Date()

        if let lastTap = lastTapTime, now.timeIntervalSince(lastTap) < doubleTapInterval {
            // Double tap — video snapshot
            pendingAudioTimer?.cancel()
            pendingAudioTimer = nil
            lastTapTime = nil
            DispatchQueue.main.async { [weak self] in
                self?.onVideoSnapshot?()
            }
        } else {
            // First tap — wait for possible second tap
            lastTapTime = now
            pendingAudioTimer?.cancel()
            let timer = DispatchWorkItem { [weak self] in
                self?.lastTapTime = nil
                DispatchQueue.main.async {
                    self?.onAudioSnapshot?()
                }
            }
            pendingAudioTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapInterval, execute: timer)
        }

        return true
    }

    deinit {
        stop()
    }
}
