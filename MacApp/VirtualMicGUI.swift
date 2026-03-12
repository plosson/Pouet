import SwiftUI

@main
struct VirtualMicGUI: App {
    @StateObject private var server = ServerManager()

    var body: some Scene {
        WindowGroup {
            ContentView(server: server)
                .frame(minWidth: 480, minHeight: 500)
        }
        .windowResizability(.contentSize)
    }
}
