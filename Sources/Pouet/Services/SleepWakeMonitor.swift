// SleepWakeMonitor.swift — Reusable sleep/wake observer for system + display sleep
// Consolidates NSWorkspace.willSleep/didWake + screensDidSleep/screensDidWake

import AppKit

/// Observes system sleep/wake and display sleep/wake, calling provided closures.
/// Call `start(onSleep:onWake:)` to begin, `stop()` to remove all observers.
class SleepWakeMonitor {
    private var observers: [Any] = []

    func start(onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        stop()
        let nc = NSWorkspace.shared.notificationCenter
        let sleepNames: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
        ]
        let wakeNames: [NSNotification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ]
        for name in sleepNames {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in onSleep() })
        }
        for name in wakeNames {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in onWake() })
        }
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for obs in observers { nc.removeObserver(obs) }
        observers.removeAll()
    }

    deinit { stop() }
}
