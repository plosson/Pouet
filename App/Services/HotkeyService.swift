// HotkeyService.swift — Global hotkey registration using CGEvent tap
// Cmd+J = audio snapshot, Cmd+J J (double tap) = video snapshot

import Foundation
import CoreGraphics
import Combine

class HotkeyService {
    fileprivate var eventTap: CFMachPort?
    fileprivate var runLoopSource: CFRunLoopSource?
    private var lastTapTime: Date?
    private let doubleTapInterval: TimeInterval = 0.35

    // Callbacks
    var onAudioSnapshot: (() -> Void)?
    var onVideoSnapshot: (() -> Void)?

    // Configurable key (default: J = keycode 38)
    var keyCode: CGKeyCode = 38
    var modifierFlags: CGEventFlags = .maskCommand

    private var pendingAudioTimer: DispatchWorkItem?

    init() {}

    func start() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // Use a raw pointer to self for the callback
        let unmanagedSelf = Unmanaged.passUnretained(self)
        let userInfo = unmanagedSelf.toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: userInfo
        ) else {
            Log.error("Failed to create CGEvent tap — check Accessibility permissions")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("Global hotkey registered (Cmd+J)")
    }

    func stop() {
        pendingAudioTimer?.cancel()
        pendingAudioTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        Log.info("Global hotkey unregistered")
    }

    fileprivate func handleKeyDown(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        // Check if it's our hotkey
        guard keyCode == self.keyCode,
              flags.contains(modifierFlags),
              !flags.contains(.maskControl),
              !flags.contains(.maskAlternate),
              !flags.contains(.maskShift) else {
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

        return true // Consume the event
    }

    deinit {
        stop()
    }
}

// C callback — bridges to HotkeyService instance
private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .keyDown {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if service.handleKeyDown(keyCode: keyCode, flags: flags) {
            return nil // Consume the event
        }
    }

    // If the tap is disabled by the system (timeout), re-enable it
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = service.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    return Unmanaged.passUnretained(event)
}
