import SwiftUI
import AVFoundation

@main
struct VirtualMicGUI: App {
    @StateObject private var app = AppService()

    init() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(app: app)
                .frame(minWidth: 520, minHeight: 560)
                .frame(idealWidth: 520, idealHeight: 620)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Uninstall VirtualMic...") {
                    NotificationCenter.default.post(name: .requestUninstall, object: nil)
                }
            }
        }
    }
}

extension Notification.Name {
    static let requestUninstall = Notification.Name("requestUninstall")
}
