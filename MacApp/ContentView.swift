import SwiftUI
import AppKit

// MARK: - Theme

private enum Theme {
    static let bg         = Color(red: 0.06, green: 0.06, blue: 0.14)
    static let cardBg     = Color(red: 0.08, green: 0.10, blue: 0.20)
    static let cardBorder = Color(white: 0.2, opacity: 0.3)
    static let accent     = Color(red: 0.29, green: 0.87, blue: 0.50)
    static let purple     = Color(red: 0.36, green: 0.42, blue: 0.75)
    static let dimText    = Color(white: 0.45)
    static let bodyText   = Color(white: 0.85)
}

// MARK: - Main View

struct ContentView: View {
    @ObservedObject var app: AppService

    @State private var toast: String?
    @State private var selectedTab = 0
    @State private var showUninstallConfirm = false
    @State private var showLog = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                Divider().background(Theme.cardBorder)

                tabBar
                ScrollView {
                    Group {
                        switch selectedTab {
                        case 0: dashboardTab
                        case 1: soundBoardTab
                        case 2: settingsTab
                        default: dashboardTab
                        }
                    }
                    .padding(20)
                }

                // Toast
                if let msg = toast {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Theme.accent)
                            .font(.caption)
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(Theme.bodyText)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Theme.cardBg)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder, lineWidth: 1))
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("Uninstall VirtualMic", isPresented: $showUninstallConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { performUninstall() }
        } message: {
            Text("This will remove the VirtualMic audio driver, the CLI tool, and restart Core Audio. The app itself will be moved to Trash.")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                if app.proxyRunning {
                    Circle()
                        .fill(Theme.accent.opacity(0.3))
                        .frame(width: 20, height: 20)
                        .scaleEffect(1.4)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: app.proxyRunning)
                }
                Circle()
                    .fill(app.proxyRunning ? Theme.accent : Color.orange)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.proxyRunning ? "Proxying" : "Ready")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.bodyText)
                if let dev = app.proxyDeviceName, app.proxyRunning {
                    Text(dev)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.dimText)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Dashboard", icon: "mic.fill", index: 0)
            tabButton("Sounds", icon: "music.note.list", index: 1)
            tabButton("Settings", icon: "gearshape.fill", index: 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func tabButton(_ title: String, icon: String, index: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = index }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(selectedTab == index ? Theme.accent : Theme.dimText)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedTab == index ? Theme.accent.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Dashboard Tab

    private var dashboardTab: some View {
        VStack(spacing: 16) {
            // Proxy control
            card {
                VStack(alignment: .leading, spacing: 14) {
                    cardTitle("Microphone Proxy", icon: "mic.fill")

                    HStack(spacing: 10) {
                        Menu {
                            Button("-- Select microphone --") { app.selectedDevice = "" }
                            Divider()
                            ForEach(app.devices) { dev in
                                Button("\(dev.name) (\(dev.inputChannels) ch)") {
                                    app.selectedDevice = dev.name
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "waveform")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.purple)
                                Text(app.selectedDevice.isEmpty ? "Select microphone" : app.selectedDevice)
                                    .font(.system(size: 12))
                                    .foregroundColor(app.selectedDevice.isEmpty ? Theme.dimText : Theme.bodyText)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                                    .foregroundColor(Theme.dimText)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder, lineWidth: 1))
                        }
                        .disabled(app.proxyRunning)

                        if app.proxyRunning {
                            Button {
                                app.stopProxy()
                                showToast("Proxy stopped")
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white)
                                    .frame(width: 34, height: 34)
                                    .background(Color.red.opacity(0.8))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                do {
                                    try app.startProxy(deviceName: app.selectedDevice)
                                    showToast("Proxy started")
                                } catch {
                                    showToast("Error: \(error.localizedDescription)")
                                }
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(app.selectedDevice.isEmpty ? Theme.dimText : Theme.bg)
                                    .frame(width: 34, height: 34)
                                    .background(app.selectedDevice.isEmpty ? Color.white.opacity(0.05) : Theme.accent)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .disabled(app.selectedDevice.isEmpty)
                        }
                    }
                }
            }

            // Volume
            card {
                VStack(alignment: .leading, spacing: 10) {
                    cardTitle("Inject Volume", icon: "speaker.wave.2.fill")
                    HStack(spacing: 10) {
                        Image(systemName: app.volume < 0.01 ? "speaker.slash.fill" : "speaker.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.dimText)
                            .frame(width: 16)
                        Slider(value: $app.volume, in: 0...1, step: 0.01) { editing in
                            if !editing { app.setVolume(app.volume) }
                        }
                        .tint(Theme.accent)
                        Text("\(Int(app.volume * 100))%")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.bodyText)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            // Meters
            card {
                VStack(alignment: .leading, spacing: 12) {
                    cardTitle("Audio Pipeline", icon: "waveform.path")
                    meterRow(label: "Mic -> Apps", percent: app.mainRingPercent, color: Theme.purple)
                    meterRow(label: "Inject Buffer", percent: app.injectRingPercent, color: Theme.accent)
                }
            }
        }
    }

    // MARK: - Sound Board Tab

    private var soundBoardTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    app.refreshSounds()
                    showToast("Sounds refreshed")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                if app.currentlyPlaying != nil {
                    Button {
                        app.stopPlayback()
                        showToast("Stopped")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                            Text("Stop")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.12))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    if !app.soundsDir.isEmpty {
                        NSWorkspace.shared.open(URL(fileURLWithPath: app.soundsDir))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                        Text("Open Folder")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.dimText)
                }
                .buttonStyle(.plain)
            }

            if app.sounds.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(Theme.cardBg)
                            .frame(width: 64, height: 64)
                        Image(systemName: "music.note")
                            .font(.system(size: 26, weight: .light))
                            .foregroundColor(Theme.dimText)
                    }
                    Text("No sounds yet")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.bodyText)
                    Text("Drop audio files in your sounds folder")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.dimText)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ], spacing: 10) {
                    ForEach(app.sounds, id: \.self) { name in
                        soundCard(name: name)
                    }
                }
            }
        }
    }

    private func soundCard(name: String) -> some View {
        let isPlaying = app.currentlyPlaying == name
        let ext = (name as NSString).pathExtension.uppercased()
        let displayName = (name as NSString).deletingPathExtension

        return Button {
            if isPlaying {
                app.stopPlayback()
            } else {
                app.playSound(name: name)
                showToast("Playing: \(displayName)")
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isPlaying ? Theme.accent.opacity(0.2) : Theme.purple.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: isPlaying ? "waveform" : "music.note")
                        .font(.system(size: 14))
                        .foregroundColor(isPlaying ? Theme.accent : Theme.purple)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.bodyText)
                        .lineLimit(1)
                    Text(ext)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.dimText)
                }

                Spacer()

                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(isPlaying ? Theme.accent : Theme.purple.opacity(0.6))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isPlaying ? Theme.accent.opacity(0.06) : Theme.cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isPlaying ? Theme.accent.opacity(0.3) : Theme.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
        VStack(spacing: 16) {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    cardTitle("Sounds Folder", icon: "folder.fill")
                    HStack(spacing: 8) {
                        Text(app.soundsDir.isEmpty ? "~/VirtualMicSounds" : app.soundsDir)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.bodyText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder, lineWidth: 1))

                        Button { pickSoundsFolder() } label: {
                            Text("Browse")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.accent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.accent.opacity(0.12))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        Button {
                            if !app.soundsDir.isEmpty {
                                NSWorkspace.shared.open(URL(fileURLWithPath: app.soundsDir))
                            }
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.dimText)
                                .frame(width: 34, height: 34)
                                .background(Color.white.opacity(0.04))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .help("Open in Finder")
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 12) {
                    cardTitle("Audio Driver", icon: "cpu")
                    HStack(spacing: 8) {
                        Circle()
                            .fill(app.driverInstalled ? Theme.accent : Color.red)
                            .frame(width: 8, height: 8)
                        Text(app.driverInstalled ? "VirtualMic driver installed" : "Driver not found")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.bodyText)
                        Spacer()
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 12) {
                    cardTitle("Uninstall", icon: "trash")
                    Text("Remove the VirtualMic audio driver, CLI, and restart Core Audio.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.dimText)
                    Button { showUninstallConfirm = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("Uninstall VirtualMic")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            card {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VirtualMic")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.bodyText)
                        Text("Virtual microphone proxy with audio injection")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.dimText)
                    }
                    Spacer()
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.dimText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(6)
                }
            }
        }
    }

    // MARK: - Card Components

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBg)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardBorder, lineWidth: 1))
    }

    private func cardTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(Theme.purple)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.dimText)
                .tracking(1)
        }
    }

    private func meterRow(label: String, percent: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.dimText)
                Spacer()
                Text("\(percent)%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.bodyText)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.05))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [color.opacity(0.7), color],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: geo.size.width * CGFloat(percent) / 100)
                        .animation(.easeOut(duration: 0.3), value: percent)
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: - Actions

    private func showToast(_ msg: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeIn(duration: 0.3)) { toast = nil }
        }
    }

    private func pickSoundsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select the folder containing your sound files"
        if panel.runModal() == .OK, let url = panel.url {
            app.setSoundsDir(url.path)
            showToast("Sounds folder updated")
        }
    }

    private func performUninstall() {
        app.shutdown()
        let script = """
        do shell script "rm -rf /Library/Audio/Plug-Ins/HAL/VirtualMic.driver; \
        rm -f /usr/local/bin/VirtualMicCli; \
        killall -9 coreaudiod 2>/dev/null || true" with administrator privileges
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if error == nil {
                let appURL = Bundle.main.bundleURL
                NSWorkspace.shared.recycle([appURL]) { _, _ in
                    DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
                }
            }
        }
    }
}
