import SwiftUI
import AppKit
import AVFoundation

// MARK: - Floating HUD (visible above all apps)

class FloatingHUD {
    static let shared = FloatingHUD()
    private var panel: NSPanel?
    private var hideTimer: DispatchWorkItem?

    func show(_ message: String) {
        DispatchQueue.main.async { [self] in
            hideTimer?.cancel()

            let panel = self.panel ?? createPanel()
            self.panel = panel

            // Build content
            let label = NSTextField(labelWithString: message)
            label.font = NSFont.systemFont(ofSize: 14, weight: .bold)
            label.textColor = .white
            label.alignment = .center

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            icon.contentTintColor = NSColor(red: 0.0, green: 0.78, blue: 0.65, alpha: 1.0)
            icon.frame = NSRect(x: 0, y: 0, width: 20, height: 20)

            let stack = NSStackView(views: [icon, label])
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)

            panel.contentView = stack

            // Position at top center of main screen
            let fitting = stack.fittingSize
            if let screen = NSScreen.main {
                let w = fitting.width + 40
                let h = fitting.height + 24
                let x = screen.frame.midX - w / 2
                let y = screen.frame.maxY - h - 80
                panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
            }

            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1.0
            }

            let timer = DispatchWorkItem { [weak self] in
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.3
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    panel.orderOut(nil)
                })
                self?.hideTimer = nil
            }
            hideTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: timer)
        }
    }

    private func createPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 50),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = NSColor(white: 0.12, alpha: 0.92)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 14
        panel.contentView?.layer?.masksToBounds = true
        return panel
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var appService: AppService?
    private var hudObserver: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true  // Cmd+W closes the window → quits the app → triggers shutdown
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hudObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyToast, object: nil, queue: .main
        ) { note in
            if let msg = note.object as? String {
                FloatingHUD.shared.show(msg)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = hudObserver { NotificationCenter.default.removeObserver(obs) }
        appService?.shutdown()
    }
}

@main
struct PouetGUI: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppService()

    init() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(app: app, video: app.video)
                .frame(minWidth: 520, minHeight: 600)
                .frame(idealWidth: 820, idealHeight: 700)
                .onAppear { delegate.appService = app }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Uninstall Pouet...") {
                    NotificationCenter.default.post(name: .requestUninstall, object: nil)
                }
            }
        }
    }
}

extension Notification.Name {
    static let requestUninstall = Notification.Name("requestUninstall")
    static let hotkeyToast = Notification.Name("hotkeyToast")
}
