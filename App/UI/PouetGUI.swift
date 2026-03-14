import SwiftUI
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var appService: AppService?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true  // Cmd+W closes the window → quits the app → triggers shutdown
    }

    func applicationWillTerminate(_ notification: Notification) {
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
                .frame(idealWidth: 520, idealHeight: 680)
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
}
