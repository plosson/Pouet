import SwiftUI
import AppKit

// MARK: - Theme (neo-brutalist, inspired by gifhurlant.axel.siteio.me)

private enum Theme {
    // Palette
    static let bg         = Color(red: 1.0, green: 0.99, blue: 0.96)    // warm cream #FFFDF5
    static let cardBg     = Color.white
    static let border     = Color(red: 0.12, green: 0.16, blue: 0.23)   // dark slate #1E293B
    static let accent     = Color(red: 0.00, green: 0.78, blue: 0.65)   // teal mint
    static let purple     = Color(red: 0.38, green: 0.36, blue: 0.90)   // indigo
    static let coral      = Color(red: 1.0, green: 0.45, blue: 0.42)    // warm red/coral
    static let dimText    = Color(red: 0.40, green: 0.45, blue: 0.53)   // slate-500
    static let bodyText   = Color(red: 0.12, green: 0.16, blue: 0.23)   // slate-800
    static let shadow     = Color(red: 0.89, green: 0.91, blue: 0.94)   // slate-200 for hard shadow

    // Audio constants
    static let dbFloor    = -60.0
    static let dbRange    = 60.0
    static let silenceThreshold = 0.0001

    // Hard shadow offset (neo-brutalist signature)
    static let shadowX: CGFloat = 4
    static let shadowY: CGFloat = 4

    // Border width
    static let borderW: CGFloat = 2.5
    static let cornerR: CGFloat = 20
}

// MARK: - Main View

struct ContentView: View {
    @ObservedObject var app: AppService
    @ObservedObject var video: VideoService

    @State private var toast: String?
    @State private var selectedTab = 0
    @State private var showUninstallConfirm = false
    @State private var soundFilterText = ""
    @State private var recPulse = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                tabBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                ScrollView {
                    Group {
                        switch selectedTab {
                        case 0: controlCenterTab
                        case 1: libraryTab
                        case 2: settingsTab
                        default: controlCenterTab
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }

                if selectedTab == 0 {
                    levelsFooter
                }

                versionBar
            }

            if let msg = toast {
                toastView(msg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 56)
            }
        }
        .preferredColorScheme(.light)
        .alert("Uninstall Driver", isPresented: $showUninstallConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { performUninstall() }
        } message: {
            Text("This will remove the Pouet audio driver and restart Core Audio. The app will remain installed.")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("Pouet")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(Theme.bodyText)
                    .tracking(-0.5)
                Text("STUDIO")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.5)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.accent)
                    .cornerRadius(20)
            }

            Spacer()

            devicePill(
                icon: "mic.fill",
                label: app.selectedDevice.isEmpty ? "Select mic" : app.selectedDevice,
                active: app.proxyRunning,
                color: Theme.purple
            ) {
                ForEach(app.devices) { dev in
                    Button("\(dev.name) (\(dev.inputChannels) ch)") { app.selectMicDevice(dev.name) }
                }
            }

            devicePill(
                icon: "speaker.wave.2.fill",
                label: app.selectedOutputDevice.isEmpty ? "Select output" : app.selectedOutputDevice,
                active: app.speakerProxyRunning,
                color: Theme.accent
            ) {
                ForEach(app.outputDevices) { dev in
                    Button(dev.name) { app.selectOutputDevice(dev.name) }
                }
            }
        }
    }

    private func devicePill<Items: View>(
        icon: String, label: String, active: Bool, color: Color,
        @ViewBuilder items: () -> Items
    ) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(active ? Theme.accent : Theme.coral)
                    .frame(width: 8, height: 8)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(color)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.bodyText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Theme.dimText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.cardBg)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Theme.border, lineWidth: 2)
            )
            .shadow(color: Theme.shadow, radius: 0, x: 2, y: 2)
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 8) {
            tabButton("Control Center", icon: "square.grid.2x2", index: 0)
            tabButton("Library", icon: "tray.full.fill", index: 1)
            tabButton("Settings", icon: "gearshape.fill", index: 2)
            Spacer()
        }
    }

    private func tabButton(_ title: String, icon: String, index: Int) -> some View {
        let selected = selectedTab == index
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { selectedTab = index }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(selected ? .white : Theme.bodyText)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? Theme.border : Theme.cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Theme.border, lineWidth: selected ? 0 : 2)
            )
            .shadow(color: selected ? .clear : Theme.shadow, radius: 0, x: 2, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Control Center Tab

    private var controlCenterTab: some View {
        VStack(spacing: 16) {
            // Audio card
            card {
                VStack(alignment: .leading, spacing: 14) {
                    // Inject header
                    HStack(spacing: 10) {
                        sectionTitle("Audio", icon: "waveform")
                        Spacer()

                        if app.injectingURL != nil {
                            pillButton("Stop", icon: "stop.fill", color: Theme.coral) {
                                app.stopInjection()
                                showToast("Stopped")
                            }
                        }

                        circleButton(icon: "folder.fill") {
                            if !app.soundsDir.isEmpty {
                                NSWorkspace.shared.open(URL(fileURLWithPath: app.soundsDir))
                            }
                        }
                    }

                    // Inject sub-section
                    if app.sounds.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "music.note")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(Theme.dimText.opacity(0.4))
                                Text("No sounds yet")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(Theme.bodyText)
                                Text("Drop audio files in your sounds folder")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.dimText)
                            }
                            .padding(.vertical, 16)
                            Spacer()
                        }
                    } else {
                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)
                        ], spacing: 12) {
                            ForEach(app.sounds, id: \.self) { name in
                                soundCard(name: name)
                            }
                        }
                    }

                    separator

                    // Snapshot sub-section
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
                                .font(.system(size: 14, weight: .bold))
                            Text("Save Audio Snapshot (\(Int(app.dashcamBufferSeconds))s)")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundColor(app.speakerProxyRunning ? .white : Theme.dimText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(app.speakerProxyRunning ? Theme.accent : Color.black.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(app.speakerProxyRunning ? Theme.border : Color.clear, lineWidth: Theme.borderW)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!app.speakerProxyRunning)
                }
            }

            // Video card
            card {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Video", icon: "video.fill")

                    // Window dropdown
                    HStack(spacing: 10) {
                        Text("Window")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Theme.bodyText)

                        Menu {
                            Button("Refresh Windows") {
                                Task { await video.refreshWindows() }
                            }
                            Divider()
                            Button("None") {
                                video.selectedWindowID = nil
                                Task { await video.stopCapture() }
                            }
                            ForEach(video.availableWindows) { window in
                                Button {
                                    video.selectedWindowID = window.id
                                    Task { try? await video.startCapture() }
                                } label: {
                                    Text("\(window.appName) — \(window.title)")
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(selectedWindowTitle)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(video.selectedWindowID != nil ? Theme.bodyText : Theme.dimText)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Theme.dimText)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(Theme.bg)
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Theme.border.opacity(0.3), lineWidth: 1.5)
                            )
                        }
                    }

                    // Status line + audio toggle
                    HStack(spacing: 10) {
                        if video.isCapturing {
                            Circle()
                                .fill(Theme.coral)
                                .frame(width: 8, height: 8)
                                .opacity(recPulse ? 1.0 : 0.3)
                                .onAppear {
                                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                        recPulse = true
                                    }
                                }
                                .onDisappear { recPulse = false }
                            Text("REC")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundColor(Theme.coral)
                            Text(selectedWindowTitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.dimText)
                                .lineLimit(1)
                        } else {
                            Text("No window selected")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.dimText)
                        }

                        Spacer()

                        Toggle(isOn: Binding(
                            get: { video.captureAudio },
                            set: { app.setVideoCaptureAudio($0) }
                        )) {
                            HStack(spacing: 4) {
                                Image(systemName: "speaker.wave.2")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Audio")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundColor(Theme.bodyText)
                        }
                        .toggleStyle(.checkbox)
                    }

                    // Save video snapshot button
                    Button {
                        Task {
                            let result = await video.saveSnapshot()
                            if let url = result.url {
                                showToast("Saved: \(url.lastPathComponent)")
                            } else {
                                showToast("Save failed: \(result.error ?? "unknown")")
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text("Save Video Snapshot (\(Int(video.bufferDurationSeconds))s)")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundColor(video.isCapturing ? .white : Theme.dimText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(video.isCapturing ? Theme.purple : Color.black.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(video.isCapturing ? Theme.border : Color.clear, lineWidth: Theme.borderW)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!video.isCapturing)
                }
            }
        }
        .onAppear {
            Task { await video.refreshWindows() }
        }
    }

    private var selectedWindowTitle: String {
        guard let id = video.selectedWindowID,
              let window = video.availableWindows.first(where: { $0.id == id }) else {
            return "Select window..."
        }
        return "\(window.appName) — \(window.title)"
    }

    private func soundCard(name: String) -> some View {
        let url = URL(fileURLWithPath: (app.soundsDir as NSString).appendingPathComponent(name))
        let isInjecting = app.injectingURL == url
        let isPreviewing = app.previewingURL == url
        let isActive = isInjecting || isPreviewing
        let ext = (name as NSString).pathExtension.uppercased()
        let displayName = (name as NSString).deletingPathExtension

        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isActive ? Theme.accent.opacity(0.15) : Theme.purple.opacity(0.1))
                    .frame(width: 40, height: 40)
                Image(systemName: isActive ? "waveform" : "music.note")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(isActive ? Theme.accent : Theme.purple)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.bodyText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(ext)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundColor(Theme.dimText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.bg)
                        .cornerRadius(4)
                    if let dur = app.soundDurations[name] {
                        Text(formatDuration(dur))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.dimText)
                    }
                }
            }

            Spacer()

            playbackButton(active: isPreviewing, icon: "headphones", size: 32, help: "Play for me only") {
                if isPreviewing { app.stopPreview() }
                else { app.preview(url: url) }
            }

            playbackButton(active: isInjecting, icon: "mic.fill", size: 32, help: "Play for everyone") {
                if isInjecting { app.stopInjection() }
                else {
                    app.inject(url: url)
                    showToast("Injecting: \(displayName)")
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isActive ? Theme.accent : Theme.border, lineWidth: Theme.borderW)
        )
        .shadow(color: isActive ? Theme.accent.opacity(0.15) : Color.black.opacity(0.06),
                radius: 4, x: 0, y: 2)
    }

    // MARK: - Library Tab

    private var filteredSounds: [String] {
        let query = soundFilterText.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty { return app.sounds }
        return app.sounds.filter { $0.lowercased().contains(query) }
    }

    private var libraryTab: some View {
        VStack(spacing: 16) {
            // Sounds card
            card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        sectionTitle("Sounds", icon: "music.note.list")
                        Spacer()
                        pillButton("Refresh", icon: "arrow.clockwise", color: Theme.accent) {
                            app.refreshSounds()
                            showToast("Sounds refreshed")
                        }
                        circleButton(icon: "folder.fill") {
                            if !app.soundsDir.isEmpty {
                                NSWorkspace.shared.open(URL(fileURLWithPath: app.soundsDir))
                            }
                        }
                    }

                    if !app.sounds.isEmpty {
                        // Filter
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Theme.dimText)
                            TextField("Filter sounds...", text: $soundFilterText)
                                .font(.system(size: 12, weight: .medium))
                                .textFieldStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Theme.bg)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border.opacity(0.3), lineWidth: 1.5))
                    }

                    if app.sounds.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 10) {
                                Image(systemName: "music.note")
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundColor(Theme.dimText.opacity(0.4))
                                Text("No sounds yet")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(Theme.bodyText)
                                Text("Drop audio files in your sounds folder")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.dimText)
                            }
                            .padding(.vertical, 20)
                            Spacer()
                        }
                    } else {
                        VStack(spacing: 8) {
                            ForEach(filteredSounds, id: \.self) { name in
                                soundRow(name: name)
                            }
                        }
                    }
                }
            }

            // Recordings card
            card {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Recordings", icon: "record.circle")

                    if app.allRecordings.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "record.circle")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(Theme.dimText.opacity(0.4))
                                Text("No recordings yet")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(Theme.bodyText)
                                Text("Use Control Center to save audio or video snapshots")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.dimText)
                            }
                            .padding(.vertical, 16)
                            Spacer()
                        }
                    } else {
                        VStack(spacing: 8) {
                            ForEach(app.allRecordings) { item in
                                recordingRow(item: item)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            app.refreshAllSnapshots()
        }
    }

    private func soundRow(name: String) -> some View {
        let url = URL(fileURLWithPath: (app.soundsDir as NSString).appendingPathComponent(name))
        let isInjecting = app.injectingURL == url
        let isPreviewing = app.previewingURL == url
        let isActive = isInjecting || isPreviewing
        let ext = (name as NSString).pathExtension.uppercased()
        let displayName = (name as NSString).deletingPathExtension

        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? Theme.accent.opacity(0.15) : Theme.purple.opacity(0.1))
                    .frame(width: 34, height: 34)
                Image(systemName: isActive ? "waveform" : "music.note")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isActive ? Theme.accent : Theme.purple)
            }

            Text(displayName)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.bodyText)
                .lineLimit(1)

            Text(ext)
                .font(.system(size: 9, weight: .heavy))
                .foregroundColor(Theme.dimText)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Theme.bg)
                .cornerRadius(4)

            if let dur = app.soundDurations[name] {
                Text(formatDuration(dur))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.dimText)
            }

            Spacer()

            playbackButton(active: isPreviewing, icon: "headphones", size: 28, help: "Play for me only") {
                if isPreviewing { app.stopPreview() }
                else { app.preview(url: url) }
            }

            playbackButton(active: isInjecting, icon: "mic.fill", size: 28, help: "Play for everyone") {
                if isInjecting { app.stopInjection() }
                else { app.inject(url: url) }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isActive ? Theme.accent : Theme.border.opacity(0.3), lineWidth: isActive ? Theme.borderW : 1.5)
        )
    }

    private func recordingRow(item: RecordingItem) -> some View {
        let url = item.url
        let isPreviewing = app.previewingURL == url
        let isInjecting = app.injectingURL == url
        let isActive = isPreviewing || isInjecting
        let displayName = (url.lastPathComponent as NSString).deletingPathExtension
        let isAudio = item.kind == .audio

        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? Theme.accent.opacity(0.15) : Theme.purple.opacity(0.1))
                    .frame(width: 34, height: 34)
                Image(systemName: isAudio ? (isActive ? "waveform" : "mic.fill") : "film")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isActive ? Theme.accent : Theme.purple)
            }

            Text(displayName)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.bodyText)
                .lineLimit(1)

            Spacer()

            circleButton(icon: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }

            if isAudio {
                playbackButton(active: isPreviewing, icon: "headphones", size: 28, help: "Play for me only") {
                    if isPreviewing { app.stopPreview() }
                    else { app.preview(url: url) }
                }

                playbackButton(active: isInjecting, icon: "mic.fill", size: 28, help: "Play for everyone") {
                    if isInjecting { app.stopInjection() }
                    else { app.inject(url: url) }
                }
            } else {
                circleButton(icon: "play.fill") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isActive ? Theme.accent : Theme.border.opacity(0.3), lineWidth: isActive ? Theme.borderW : 1.5)
        )
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
        VStack(spacing: 14) {
            // Base folder
            card {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Base Folder", icon: "folder.fill")
                    HStack(spacing: 8) {
                        Text(app.baseDir)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.bodyText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.bg)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border.opacity(0.3), lineWidth: 1.5))

                        pillButton("Browse", icon: nil, color: Theme.accent) {
                            pickBaseFolder()
                        }

                        circleButton(icon: "arrow.up.forward.square") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: app.baseDir))
                        }
                    }
                    Text("Sounds in /Sounds, audio in /Recordings/Audio, video in /Recordings/Video")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.dimText)
                }
            }

            // Two columns
            HStack(alignment: .top, spacing: 14) {
                // Left: Audio & Video Controls
                card {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("Audio Controls", icon: "speaker.wave.2.fill")

                        // Inject Volume
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Inject Volume")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Theme.bodyText)
                            HStack(spacing: 10) {
                                Image(systemName: app.volume < 0.01 ? "speaker.slash.fill" : "speaker.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(Theme.dimText)
                                    .frame(width: 18)
                                Slider(value: $app.volume, in: 0...1, step: 0.01) { editing in
                                    if !editing { app.setVolume(app.volume) }
                                }
                                .tint(Theme.accent)
                                Text("\(Int(app.volume * 100))%")
                                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                                    .foregroundColor(Theme.bodyText)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }

                        separator

                        // Audio Capture Buffer
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Audio Buffer")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Theme.bodyText)
                            HStack(spacing: 10) {
                                Text("\(Int(app.dashcamBufferSeconds))s")
                                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                                    .foregroundColor(Theme.bodyText)
                                    .frame(width: 30, alignment: .trailing)
                                Slider(value: $app.dashcamBufferSeconds, in: 1...30, step: 1) { editing in
                                    if !editing { app.setDashcamBufferSeconds(app.dashcamBufferSeconds) }
                                }
                                .tint(Theme.accent)
                            }
                            Text("Rolling buffer for audio snapshots")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Theme.dimText)
                        }

                        separator

                        // Video Capture Buffer
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Video Buffer")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Theme.bodyText)
                            HStack(spacing: 10) {
                                Text("\(Int(video.bufferDurationSeconds))s")
                                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                                    .foregroundColor(Theme.bodyText)
                                    .frame(width: 30, alignment: .trailing)
                                Slider(value: Binding(
                                    get: { video.bufferDurationSeconds },
                                    set: { app.setVideoBufferSeconds($0) }
                                ), in: 1...10, step: 1)
                                .tint(Theme.accent)
                            }
                            Text("Rolling buffer for video snapshots")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Theme.dimText)
                        }

                        separator

                        // Ring Buffers
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ring Buffers")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Theme.bodyText)
                            meterRow(label: "Mic -> Apps", percent: app.mainRingPercent, color: Theme.purple)
                            meterRow(label: "Inject Buffer", percent: app.injectRingPercent, color: Theme.accent)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // Right: Health & Driver
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Health Check", icon: "checkmark.shield.fill")
                        healthRow("Driver installed", ok: app.driverInstalled)
                        healthRow("Pouet visible", ok: app.virtualMicVisible)
                        healthRow("Mic shared memory", ok: app.shmAvailable)
                        healthRow("Speaker shared memory", ok: app.speakerShmAvailable)
                        healthRow("Microphone permission", ok: app.hasMicPermission)
                        healthRow("Screen recording", ok: app.hasScreenRecordingPermission)
                        healthRow("Input devices found", ok: !app.devices.isEmpty)
                        healthRow("Output devices found", ok: !app.outputDevices.isEmpty)
                        healthRow("Mic proxy active", ok: app.proxyRunning)
                        healthRow("Speaker proxy active", ok: app.speakerProxyRunning)
                        healthRow("Video capture active", ok: video.isCapturing)

                        separator

                        sectionTitle("Audio Driver", icon: "cpu")
                        HStack(spacing: 10) {
                            Circle()
                                .fill(app.driverInstalled ? Theme.accent : Theme.coral)
                                .frame(width: 10, height: 10)
                                .overlay(
                                    Circle().stroke(Theme.border, lineWidth: 1.5)
                                )
                            Text(app.driverInstalled ? "Driver installed" : "Driver not found")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(Theme.bodyText)
                            Spacer()
                            if app.driverInstalled {
                                pillButton("Uninstall", icon: "trash", color: Theme.coral) {
                                    showUninstallConfirm = true
                                }
                            } else {
                                pillButton("Install", icon: "arrow.down.circle", color: Theme.accent) {
                                    performInstall()
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Levels Footer

    private var levelsFooter: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border.opacity(0.1)).frame(height: 1)
            HStack(spacing: 16) {
                levelMeter(label: "Mic Input", level: app.micPeakLevel, color: Theme.purple)
                levelMeter(label: "Inject Audio", level: app.injectPeakLevel, color: Theme.accent)
                levelMeter(label: "Speaker Output", level: app.speakerPeakLevel, color: Theme.purple)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Theme.cardBg)
        }
    }

    // MARK: - Version Bar

    private var versionBar: some View {
        HStack {
            Text("Pouet")
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(Theme.bodyText)
            Text("\u{b7}")
                .foregroundColor(Theme.dimText)
            Text("Virtual microphone proxy with audio & video capture")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.dimText)
            Spacer()
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.dimText)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.cardBg)
    }

    // MARK: - Reusable Components

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading) { content() }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBg)
            .cornerRadius(Theme.cornerR)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerR)
                    .stroke(Theme.border, lineWidth: Theme.borderW)
            )
            .shadow(color: Theme.shadow, radius: 0, x: Theme.shadowX, y: Theme.shadowY)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.purple)
            Text(title)
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(Theme.bodyText)
                .tracking(-0.3)
        }
    }

    private func pillButton(_ label: String, icon: String?, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .bold))
                }
                Text(label)
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(color.opacity(0.12))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(color.opacity(0.3), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func circleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.dimText)
                .frame(width: 30, height: 30)
                .background(Theme.bg)
                .cornerRadius(15)
                .overlay(
                    RoundedRectangle(cornerRadius: 15)
                        .stroke(Theme.border.opacity(0.2), lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func playbackButton(active: Bool, icon: String, size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        let iconSize = size > 30 ? CGFloat(12) : CGFloat(10)
        return ZStack {
            Circle()
                .fill(active ? Theme.accent : Theme.border)
                .frame(width: size, height: size)
            Image(systemName: active ? "stop.fill" : icon)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundColor(.white)
        }
        .onTapGesture(perform: action)
        .help(help)
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.border.opacity(0.1))
            .frame(height: 1.5)
    }

    private func healthRow(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(ok ? Theme.accent.opacity(0.15) : Theme.coral.opacity(0.15))
                    .frame(width: 22, height: 22)
                Image(systemName: ok ? "checkmark" : "xmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(ok ? Theme.accent : Theme.coral)
            }
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.bodyText)
            Spacer()
        }
    }

    private func levelMeter(label: String, level: Float, color: Color) -> some View {
        let dbValue = level > Float(Theme.silenceThreshold) ? Double(20 * log10(level)) : Theme.dbFloor
        let normalized = CGFloat(max(0, min(1, (dbValue - Theme.dbFloor) / Theme.dbRange)))
        let dbText = level > Float(Theme.silenceThreshold) ? String(format: "%.0f dB", dbValue) : "-inf"

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.dimText)
                Spacer()
                Text(dbText)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.bodyText)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.border.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(normalized > 0.85 ? Theme.coral : color)
                        .frame(width: geo.size.width * normalized)
                        .animation(.easeOut(duration: 0.08), value: normalized)
                }
            }
            .frame(height: 8)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.border.opacity(0.15), lineWidth: 1)
            )
        }
    }

    private func meterRow(label: String, percent: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.dimText)
                Spacer()
                Text("\(percent)%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.bodyText)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.border.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(percent) / 100)
                        .animation(.easeOut(duration: 0.3), value: percent)
                }
            }
            .frame(height: 6)
            .cornerRadius(3)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Theme.border.opacity(0.15), lineWidth: 1)
            )
        }
    }

    private func toastView(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(Theme.accent)
                .font(.system(size: 14, weight: .bold))
            Text(msg)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.bodyText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.cardBg)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.border, lineWidth: 2)
        )
        .shadow(color: Theme.shadow, radius: 0, x: 3, y: 3)
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    // MARK: - Actions

    private func showToast(_ msg: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeIn(duration: 0.3)) { toast = nil }
        }
    }

    private func pickBaseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select the base folder for Pouet data"
        if panel.runModal() == .OK, let url = panel.url {
            app.setBaseDir(url.path)
            showToast("Base folder updated")
        }
    }

    private func performInstall() {
        guard let driverSource = Bundle.main.url(forResource: "Pouet", withExtension: "driver") else {
            showToast("Driver bundle not found in app resources")
            return
        }
        let src = driverSource.path
        let dst = "/Library/Audio/Plug-Ins/HAL"
        let script = """
        do shell script "mkdir -p \(dst); \
        rm -rf \(dst)/Pouet.driver; \
        cp -R \\\"\(src)\\\" \(dst)/; \
        chown -R root:wheel \(dst)/Pouet.driver; \
        killall -9 coreaudiod 2>/dev/null || true" with administrator privileges
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                DispatchQueue.main.async {
                    if error == nil {
                        showToast("Driver installed — restarting Core Audio")
                    } else {
                        showToast("Install cancelled or failed")
                    }
                }
            }
        }
    }

    private func performUninstall() {
        app.shutdown()

        let script = """
        do shell script "rm -rf /Library/Audio/Plug-Ins/HAL/Pouet.driver; \
        killall -9 coreaudiod 2>/dev/null || true" with administrator privileges
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                DispatchQueue.main.async {
                    if error == nil {
                        showToast("Driver uninstalled — Core Audio restarted")
                        app.loadDevices()
                    } else {
                        showToast("Uninstall cancelled or failed")
                    }
                }
            }
        }
    }
}
