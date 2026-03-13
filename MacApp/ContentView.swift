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
                        case 0: soundsTab
                        case 1: settingsTab
                        default: soundsTab
                        }
                    }
                    .padding(20)
                }

                // Signal levels footer
                if selectedTab == 0 {
                    Divider().background(Theme.cardBorder)
                    HStack(spacing: 16) {
                        levelMeter(label: "Mic Input", level: app.micPeakLevel, color: Theme.purple)
                        levelMeter(label: "Inject Audio", level: app.injectPeakLevel, color: Theme.accent)
                        levelMeter(label: "Speaker Output", level: app.speakerPeakLevel, color: Theme.purple)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Theme.bg)
                }

                // Version bar
                Divider().background(Theme.cardBorder)
                HStack {
                    Text("VirtualMic")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.bodyText)
                    Text("·")
                        .foregroundColor(Theme.dimText)
                    Text("Virtual microphone proxy with audio injection")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.dimText)
                    Spacer()
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.dimText)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Theme.bg)

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
        .alert("Uninstall Driver", isPresented: $showUninstallConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { performUninstall() }
        } message: {
            Text("This will remove the VirtualMic audio driver and restart Core Audio. The app will remain installed.")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            // Left: Mic proxy
            headerProxyButton(
                running: app.proxyRunning,
                disabled: app.selectedDevice.isEmpty,
                onStart: {
                    do { try app.startProxy(deviceName: app.selectedDevice); showToast("Mic proxy started") }
                    catch { showToast("Error: \(error.localizedDescription)") }
                },
                onStop: { app.stopProxy(); showToast("Mic proxy stopped") }
            )

            Menu {
                Button("-- Select microphone --") { app.selectedDevice = "" }
                Divider()
                ForEach(app.devices) { dev in
                    Button("\(dev.name) (\(dev.inputChannels) ch)") { app.selectedDevice = dev.name }
                }
            } label: {
                headerDropdownLabel(
                    icon: "mic.fill", placeholder: "Select microphone",
                    value: app.selectedDevice, color: Theme.purple
                )
            }
            .disabled(app.proxyRunning)

            Spacer()

            // Right: Speaker proxy
            Menu {
                Button("-- Select output --") { app.selectedOutputDevice = "" }
                Divider()
                ForEach(app.outputDevices) { dev in
                    Button(dev.name) { app.selectedOutputDevice = dev.name }
                }
            } label: {
                headerDropdownLabel(
                    icon: "speaker.fill", placeholder: "Select output",
                    value: app.selectedOutputDevice, color: Theme.accent
                )
            }
            .disabled(app.speakerProxyRunning)

            headerProxyButton(
                running: app.speakerProxyRunning,
                disabled: app.selectedOutputDevice.isEmpty,
                onStart: {
                    do { try app.startSpeakerProxy(deviceName: app.selectedOutputDevice); showToast("Speaker proxy started") }
                    catch { showToast("Error: \(error.localizedDescription)") }
                },
                onStop: { app.stopSpeakerProxy(); showToast("Speaker proxy stopped") }
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func headerProxyButton(running: Bool, disabled: Bool, onStart: @escaping () -> Void, onStop: @escaping () -> Void) -> some View {
        Group {
            if running {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onStart) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundColor(disabled ? Theme.dimText : Theme.bg)
                        .frame(width: 28, height: 28)
                        .background(disabled ? Color.white.opacity(0.05) : Theme.accent)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(disabled)
            }
        }
    }

    private func headerDropdownLabel(icon: String, placeholder: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
            Text(value.isEmpty ? placeholder : value)
                .font(.system(size: 11))
                .foregroundColor(value.isEmpty ? Theme.dimText : Theme.bodyText)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8))
                .foregroundColor(Theme.dimText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardBorder, lineWidth: 1))
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Sounds", icon: "music.note.list", index: 0)
            tabButton("Settings", icon: "gearshape.fill", index: 1)
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

    // MARK: - Sounds Tab

    private var soundsTab: some View {
        VStack(spacing: 16) {
            // INJECT section
            card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        cardTitle("Inject", icon: "music.note.list")

                        Spacer()

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
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "music.note")
                                    .font(.system(size: 20, weight: .light))
                                    .foregroundColor(Theme.dimText)
                                Text("No sounds yet — drop audio files in your sounds folder")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.dimText)
                            }
                            .padding(.vertical, 12)
                            Spacer()
                        }
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

            // CAPTURE section
            card {
                VStack(alignment: .leading, spacing: 12) {
                    cardTitle("Capture", icon: "record.circle")

                    Button {
                        let result = app.saveDashcamSnapshot()
                        if let url = result.url {
                            showToast("Saved: \(url.lastPathComponent)")
                        } else {
                            showToast("Snapshot failed: \(result.error ?? "unknown error")")
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 13))
                            Text("Save Snapshot (\(Int(app.dashcamBufferSeconds))s)")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(app.speakerProxyRunning ? Theme.bg : Theme.dimText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(app.speakerProxyRunning ? Theme.accent : Color.white.opacity(0.05))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(!app.speakerProxyRunning)

                    if !app.recentSnapshots.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(app.recentSnapshots, id: \.absoluteString) { url in
                                snapshotRow(url: url)
                            }
                        }
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

    private func snapshotRow(url: URL) -> some View {
        let isPlaying = app.playingSnapshot == url
        let displayName = (url.lastPathComponent as NSString).deletingPathExtension

        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isPlaying ? Theme.accent.opacity(0.2) : Theme.purple.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: isPlaying ? "waveform" : "record.circle")
                    .font(.system(size: 13))
                    .foregroundColor(isPlaying ? Theme.accent : Theme.purple)
            }

            Text(displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.bodyText)
                .lineLimit(1)

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.dimText)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")

            Button {
                if isPlaying {
                    app.stopSnapshotPlayback()
                } else {
                    app.playSnapshot(url: url)
                }
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(isPlaying ? Theme.accent : Theme.purple.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isPlaying ? Theme.accent.opacity(0.06) : Color.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPlaying ? Theme.accent.opacity(0.3) : Theme.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
        VStack(spacing: 12) {
            // Base folder
            card {
                VStack(alignment: .leading, spacing: 10) {
                    cardTitle("Base Folder", icon: "folder.fill")
                    HStack(spacing: 6) {
                        Text(app.baseDir)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.bodyText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.cardBorder, lineWidth: 1))

                        Button(action: pickBaseFolder) {
                            Text("Browse")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Theme.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Theme.accent.opacity(0.12))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: app.baseDir)) } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.dimText)
                                .frame(width: 26, height: 26)
                                .background(Color.white.opacity(0.04))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .help("Open in Finder")
                    }
                    Text("Sounds stored in /Sounds, recordings in /Recordings")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.dimText)
                }
            }

            // Two columns: Controls (left) | Status (right)
            HStack(alignment: .top, spacing: 12) {
                // Left: Audio Controls
                card {
                    VStack(alignment: .leading, spacing: 14) {
                        cardTitle("Audio Controls", icon: "speaker.wave.2.fill")

                        // Inject Volume
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Inject Volume")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.bodyText)
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

                        Divider().background(Theme.cardBorder)

                        // Capture Buffer
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Capture Buffer")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.bodyText)
                            HStack(spacing: 10) {
                                Text("\(Int(app.dashcamBufferSeconds))s")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(Theme.bodyText)
                                    .frame(width: 30, alignment: .trailing)
                                Slider(value: $app.dashcamBufferSeconds, in: 1...30, step: 1) { editing in
                                    if !editing { app.setDashcamBufferSeconds(app.dashcamBufferSeconds) }
                                }
                                .tint(Theme.accent)
                            }
                            Text("Rolling buffer duration for capture snapshots.")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.dimText)
                        }

                        Divider().background(Theme.cardBorder)

                        // Ring Buffers
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ring Buffers")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.bodyText)
                            meterRow(label: "Mic → Apps", percent: app.mainRingPercent, color: Theme.purple)
                            meterRow(label: "Inject Buffer", percent: app.injectRingPercent, color: Theme.accent)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // Right: Health & Driver
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        cardTitle("Health Check", icon: "checkmark.shield.fill")
                        healthRow("Driver installed", ok: app.driverInstalled)
                        healthRow("VirtualMic visible", ok: app.virtualMicVisible)
                        healthRow("Mic shared memory", ok: app.shmAvailable)
                        healthRow("Speaker shared memory", ok: app.speakerShmAvailable)
                        healthRow("Microphone permission", ok: app.hasMicPermission)
                        healthRow("Input devices found", ok: !app.devices.isEmpty)
                        healthRow("Output devices found", ok: !app.outputDevices.isEmpty)
                        healthRow("Mic proxy active", ok: app.proxyRunning)
                        healthRow("Speaker proxy active", ok: app.speakerProxyRunning)

                        Divider().background(Theme.cardBorder)

                        // Audio Driver
                        HStack(spacing: 8) {
                            Image(systemName: "cpu")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.purple)
                            Text("AUDIO DRIVER")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Theme.dimText)
                                .tracking(1)
                        }
                        HStack(spacing: 8) {
                            Circle()
                                .fill(app.driverInstalled ? Theme.accent : Color.red)
                                .frame(width: 8, height: 8)
                            Text(app.driverInstalled ? "Driver installed" : "Driver not found")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.bodyText)
                            Spacer()
                            if app.driverInstalled {
                                Button { showUninstallConfirm = true } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "trash")
                                        Text("Uninstall")
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(6)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.3), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            } else {
                                Button { performInstall() } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.down.circle")
                                        Text("Install")
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Theme.accent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Theme.accent.opacity(0.12))
                                    .cornerRadius(6)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
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

    private func healthRow(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(ok ? Theme.accent : Color.red.opacity(0.8))
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.bodyText)
            Spacer()
        }
    }

    private func levelMeter(label: String, level: Float, color: Color) -> some View {
        let dbValue = level > 0.0001 ? 20 * log10(level) : -60.0
        let normalized = CGFloat(max(0, min(1, (dbValue + 60) / 60)))  // -60dB..0dB → 0..1
        let dbText = level > 0.0001 ? String(format: "%.0f dB", dbValue) : "-inf"

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.dimText)
                Spacer()
                Text(dbText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.bodyText)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.05))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [color.opacity(0.7), normalized > 0.85 ? .red : color],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: geo.size.width * normalized)
                        .animation(.easeOut(duration: 0.08), value: normalized)
                }
            }
            .frame(height: 6)
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

    private func pickBaseFolder() {
        pickFolder(message: "Select the base folder for VirtualMic data") {
            app.setBaseDir($0)
            showToast("Base folder updated")
        }
    }

    private func pickFolder(message: String, onPick: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url.path)
        }
    }

    private func performInstall() {
        guard let driverSource = Bundle.main.url(forResource: "VirtualMic", withExtension: "driver") else {
            showToast("Driver bundle not found in app resources")
            return
        }
        let src = driverSource.path
        let dst = "/Library/Audio/Plug-Ins/HAL"
        let script = """
        do shell script "mkdir -p \(dst); \
        rm -rf \(dst)/VirtualMic.driver; \
        cp -R \\\"\(src)\\\" \(dst)/; \
        chown -R root:wheel \(dst)/VirtualMic.driver; \
        killall -9 coreaudiod 2>/dev/null || true" with administrator privileges
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if error == nil {
                showToast("Driver installed — restarting Core Audio")
            } else {
                showToast("Install cancelled or failed")
            }
        }
    }

    private func performUninstall() {
        // Stop proxy first so the app doesn't crash when the driver disappears
        app.stopProxy()

        let script = """
        do shell script "rm -rf /Library/Audio/Plug-Ins/HAL/VirtualMic.driver; \
        killall -9 coreaudiod 2>/dev/null || true" with administrator privileges
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if error == nil {
                showToast("Driver uninstalled — Core Audio restarted")
                // Refresh device list since VirtualMic is now gone
                app.loadDevices()
            } else {
                showToast("Uninstall cancelled or failed")
            }
        }
    }
}
