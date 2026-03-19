import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Theme (neo-brutalist, inspired by gifhurlant.axel.siteio.me)

private enum Theme {
    // Palette
    static let bg         = Color(red: 1.0, green: 0.99, blue: 0.96)    // warm cream #FFFDF5
    static let cardBg     = Color.white
    static let border     = Color(red: 0.12, green: 0.16, blue: 0.23)   // dark slate #1E293B
    static let accent     = Color(red: 0.00, green: 0.78, blue: 0.65)   // teal mint
    static let purple     = Color(red: 0.38, green: 0.36, blue: 0.90)   // indigo
    static let violet     = Color(red: 0.55, green: 0.36, blue: 0.96)   // #8B5CF6 vivid violet
    static let pink       = Color(red: 0.96, green: 0.45, blue: 0.71)   // #F472B6 hot pink
    static let amber      = Color(red: 0.98, green: 0.75, blue: 0.14)   // #FBBF24 amber
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

// MARK: - App Card Model

private struct AppCard: Identifiable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let previewImage: String?   // resource name (without extension) — png or gif
    let previewExt: String      // "png" or "gif"
    let previewColor: Color
    let accentColor: Color
    let enabled: Bool
}

private let appCards: [AppCard] = [
    AppCard(
        id: "studio",
        name: "Studio",
        description: "Virtual mic with audio injection via loopback driver.",
        icon: "waveform.circle.fill",
        previewImage: nil,
        previewExt: "png",
        previewColor: Color(red: 0.83, green: 0.95, blue: 0.93),  // mint pastel
        accentColor: Theme.accent,
        enabled: true
    ),
    AppCard(
        id: "bubblesnap",
        name: "BubbleSnap",
        description: "Add speech bubbles to screenshots. Roast your friends in style.",
        icon: "bubble.left.and.bubble.right.fill",
        previewImage: "preview-bubblesnap",
        previewExt: "png",
        previewColor: Color(red: 0.99, green: 0.89, blue: 0.93),  // pink pastel #fce4ec
        accentColor: Theme.pink,
        enabled: false
    ),
    AppCard(
        id: "facegif",
        name: "FaceGIF",
        description: "Swap any face onto any GIF. Chaotic. Beautiful. Unhinged.",
        icon: "face.smiling.fill",
        previewImage: "preview-facegif",
        previewExt: "gif",
        previewColor: Color(red: 0.93, green: 0.91, blue: 0.99),  // violet pastel #ede9fe
        accentColor: Theme.violet,
        enabled: false
    ),
    AppCard(
        id: "headcut",
        name: "HeadCut",
        description: "Isolate heads from photos as transparent PNGs. No Photoshop needed.",
        icon: "scissors",
        previewImage: "head3",
        previewExt: "png",
        previewColor: Color(red: 1.0, green: 0.95, blue: 0.85),   // amber pastel #fef3c7
        accentColor: Theme.amber,
        enabled: false
    ),
]

// MARK: - Floating Heads Physics

private class FloatingHead {
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var rot: CGFloat = 0
    var rotV: CGFloat
    var size: CGFloat
    var imageName: String
    var bobPhase: CGFloat
    var squashPhase: CGFloat

    init(x: CGFloat, y: CGFloat, size: CGFloat, imageName: String) {
        self.x = x
        self.y = y
        self.size = size
        self.imageName = imageName
        let speed = CGFloat.random(in: 0.12...0.32)
        let angle = CGFloat.random(in: 0...(2 * .pi))
        self.vx = cos(angle) * speed
        self.vy = sin(angle) * speed
        self.rotV = CGFloat.random(in: -0.15...0.15)
        self.bobPhase = CGFloat.random(in: 0...(2 * .pi))
        self.squashPhase = CGFloat.random(in: 0...(2 * .pi))
        self.rot = CGFloat.random(in: -10...10)
    }
}

private class FloatingHeadsState: ObservableObject {
    @Published var tick: UInt64 = 0
    var heads: [FloatingHead] = []
    var mouseX: CGFloat = -1000
    var mouseY: CGFloat = -1000
    private var timer: Timer?
    private var lastTime: CFAbsoluteTime = 0

    private let maxSpeed: CGFloat = 1.0
    private let fleeRadius: CGFloat = 150
    private let fleeForce: CGFloat = 0.35

    func setup(width: CGFloat, height: CGFloat) {
        guard heads.isEmpty else { return }
        let positions: [(CGFloat, CGFloat, CGFloat, String)] = [
            (0.08, 0.15, 90, "head1"),
            (0.85, 0.25, 110, "head2"),
            (0.12, 0.70, 80, "head3"),
            (0.82, 0.60, 100, "head4"),
        ]
        for (fx, fy, sz, name) in positions {
            heads.append(FloatingHead(x: fx * width, y: fy * height, size: sz, imageName: name))
        }
        lastTime = CFAbsoluteTimeGetCurrent()
        startTimer()
    }

    func startTimer() {
        timer?.invalidate()
        lastTime = CFAbsoluteTimeGetCurrent()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.step()
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = min(CGFloat((now - lastTime) * 1000), 50) // milliseconds, capped at 50ms
        lastTime = now

        for h in heads {
            // Cursor flee
            let hcx = h.x + h.size / 2
            let hcy = h.y + h.size / 2
            let dx = hcx - mouseX
            let dy = hcy - mouseY
            let dist = sqrt(dx * dx + dy * dy)
            if dist < fleeRadius && dist > 0 {
                let strength = fleeForce * (1 - dist / fleeRadius)
                h.vx += (dx / dist) * strength * dt * 0.06
                h.vy += (dy / dist) * strength * dt * 0.06
                h.rotV += CGFloat.random(in: -0.05...0.05)
            }

            // Speed cap
            let speed = sqrt(h.vx * h.vx + h.vy * h.vy)
            if speed > maxSpeed {
                h.vx = h.vx / speed * maxSpeed
                h.vy = h.vy / speed * maxSpeed
            }

            // Drag
            h.vx *= 0.9995
            h.vy *= 0.9995
            h.rotV *= 0.998

            // Move (dt in ms, matching web)
            h.x += h.vx * dt
            h.y += h.vy * dt
            h.rot += h.rotV * dt * 0.05
            h.squashPhase += 0.002 * dt
            h.bobPhase += 0.0015 * dt

            // Minimum drift
            let curSpeed = sqrt(h.vx * h.vx + h.vy * h.vy)
            if curSpeed < 0.2 {
                let a = CGFloat.random(in: 0...(2 * .pi))
                h.vx += cos(a) * 0.05
                h.vy += sin(a) * 0.05
            }
        }

        // Head-to-head collisions
        for i in 0..<heads.count {
            for j in (i + 1)..<heads.count {
                let a = heads[i], b = heads[j]
                let dx = (b.x + b.size / 2) - (a.x + a.size / 2)
                let dy = (b.y + b.size / 2) - (a.y + a.size / 2)
                let dist = sqrt(dx * dx + dy * dy)
                let minDist = (a.size + b.size) / 2 * 0.75
                if dist < minDist && dist > 0 {
                    let nx = dx / dist, ny = dy / dist
                    let relV = (a.vx - b.vx) * nx + (a.vy - b.vy) * ny
                    if relV > 0 {
                        a.vx -= relV * nx * 0.8
                        a.vy -= relV * ny * 0.8
                        b.vx += relV * nx * 0.8
                        b.vy += relV * ny * 0.8
                    }
                    let overlap = (minDist - dist) / 2
                    a.x -= nx * overlap
                    a.y -= ny * overlap
                    b.x += nx * overlap
                    b.y += ny * overlap
                    a.rotV = CGFloat.random(in: -0.6...0.6)
                    b.rotV = CGFloat.random(in: -0.6...0.6)
                }
            }
        }

        tick &+= 1
    }

    func bounceWalls(width: CGFloat, height: CGFloat) {
        for h in heads {
            if h.x < 0 { h.x = 0; h.vx = abs(h.vx) * 0.8; h.rotV = CGFloat.random(in: -0.4...0.4) }
            if h.x + h.size > width { h.x = width - h.size; h.vx = -abs(h.vx) * 0.8; h.rotV = CGFloat.random(in: -0.4...0.4) }
            if h.y < 0 { h.y = 0; h.vy = abs(h.vy) * 0.8; h.rotV = CGFloat.random(in: -0.4...0.4) }
            if h.y + h.size > height { h.y = height - h.size; h.vy = -abs(h.vy) * 0.8; h.rotV = CGFloat.random(in: -0.4...0.4) }
        }
    }
}

private struct FloatingHeadsView: View {
    @ObservedObject var state: FloatingHeadsState
    @State private var viewOrigin: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            let _ = state.bounceWalls(width: geo.size.width, height: geo.size.height)
            ZStack {
                ForEach(0..<state.heads.count, id: \.self) { i in
                    let h = state.heads[i]
                    let bobY = sin(h.bobPhase) * 5
                    let squash = 1 + sin(h.squashPhase) * 0.035
                    let stretch = 1 - sin(h.squashPhase) * 0.035
                    headImage(h.imageName, size: h.size)
                        .rotationEffect(.degrees(h.rot))
                        .scaleEffect(x: stretch, y: squash)
                        .position(x: h.x + h.size / 2, y: h.y + h.size / 2 + bobY)
                }
            }
            .onAppear {
                state.setup(width: geo.size.width, height: geo.size.height)
            }
            .background(
                GeometryReader { inner in
                    Color.clear.onAppear {
                        viewOrigin = inner.frame(in: .global).origin
                    }.onChange(of: inner.frame(in: .global).origin) { newOrigin in
                        viewOrigin = newOrigin
                    }
                }
            )
        }
        .allowsHitTesting(false)
        .onAppear { state.startTimer(); startMouseTracking() }
        .onDisappear { state.stopTimer() }
    }

    private func startMouseTracking() {
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            if let window = NSApp.mainWindow {
                let windowPoint = event.locationInWindow
                let flipped = NSPoint(x: windowPoint.x - viewOrigin.x, y: window.frame.height - windowPoint.y - viewOrigin.y)
                state.mouseX = flipped.x
                state.mouseY = flipped.y
            }
            return event
        }
    }

    private func headImage(_ name: String, size: CGFloat) -> some View {
        Group {
            if let resourcePath = Bundle.main.path(forResource: name, ofType: "png"),
               let nsImage = NSImage(contentsOfFile: resourcePath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                Circle()
                    .fill(Theme.purple.opacity(0.3))
                    .frame(width: size, height: size)
            }
        }
    }
}

// MARK: - Main View

struct ContentView: View {
    @ObservedObject var app: AppService

    @State private var toast: String?
    @State private var currentApp: String? = nil
    @State private var selectedTab = 0
    @State private var showUninstallConfirm = false
    @State private var soundFilterText = ""
    @State private var cardHover: String? = nil
    @State private var soundsDropHighlight = false
    @StateObject private var floatingHeads = FloatingHeadsState()

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.bg.ignoresSafeArea()

            if currentApp == nil {
                homeScreen
            } else {
                studioView
            }

            if let msg = toast {
                toastView(msg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 56)
            }
        }
        .preferredColorScheme(.light)
        .onReceive(NotificationCenter.default.publisher(for: .hotkeyToast)) { notification in
            if let msg = notification.object as? String {
                showToast(msg)
            }
        }
        .alert("Uninstall Driver", isPresented: $showUninstallConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { performUninstall() }
        } message: {
            Text("This will remove the Pouet audio driver and restart Core Audio. The app will remain installed.")
        }
    }

    // MARK: - Home Screen

    private var homeScreen: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 32)

            // Badge
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
                Text("CREATIVE SUITE")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.5)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Theme.border)
            .cornerRadius(20)

            Spacer().frame(height: 16)

            // Title
            (Text("Stupid little ")
                .font(.system(size: 28, weight: .heavy))
                .foregroundColor(Theme.bodyText)
            + Text("tools")
                .font(.system(size: 28, weight: .heavy))
                .foregroundColor(Theme.violet)
            + Text(" for stupid little things")
                .font(.system(size: 28, weight: .heavy))
                .foregroundColor(Theme.bodyText)
            )
            .multilineTextAlignment(.center)
            .tracking(-0.5)
            .padding(.horizontal, 40)

            Spacer().frame(height: 8)

            // Subtitle
            Text("A collection of fun desktop tools. No signups. Just vibes.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.dimText)

            Spacer().frame(height: 16)

            squiggleDivider

            Spacer().frame(height: 28)

            // App cards — 4 in a row
            HStack(alignment: .top, spacing: 16) {
                ForEach(appCards) { appCard in
                    homeAppCard(appCard)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 32)

            Spacer().frame(height: 24)

            // Footer
            Text("More stupid tools coming soon.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.dimText)

            Spacer()

            versionBar
        }
        .background(FloatingHeadsView(state: floatingHeads))
    }

    private func homeAppCard(_ appCard: AppCard) -> some View {
        let isHovered = cardHover == appCard.id
        return Button {
            if appCard.enabled {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    currentApp = appCard.id
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Preview area
                ZStack {
                    appCard.previewColor

                    if let imgName = appCard.previewImage,
                       let path = Bundle.main.path(forResource: imgName, ofType: appCard.previewExt),
                       let nsImage = NSImage(contentsOfFile: path) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: appCard.icon)
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(appCard.accentColor.opacity(0.5))
                    }
                }
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(height: Theme.borderW)
                }

                // Content
                VStack(alignment: .leading, spacing: 6) {
                    Text(appCard.name)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(Theme.bodyText)
                        .tracking(-0.3)

                    Text(appCard.description)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.dimText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    // Bottom row
                    HStack {
                        if appCard.enabled {
                            Text("OPEN")
                                .font(.system(size: 9, weight: .heavy))
                                .tracking(1)
                                .foregroundColor(Theme.bodyText)
                        } else {
                            Text("COMING SOON")
                                .font(.system(size: 7, weight: .heavy))
                                .tracking(0.8)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.border)
                                .cornerRadius(8)
                        }

                        Spacer()

                        // Arrow circle
                        ZStack {
                            Circle()
                                .fill(isHovered && appCard.enabled ? appCard.accentColor : Color(red: 0.94, green: 0.96, blue: 0.97))
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle()
                                        .stroke(Theme.shadow, lineWidth: 1.5)
                                )
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(isHovered && appCard.enabled ? .white : Theme.dimText)
                        }
                    }
                }
                .padding(10)
            }
            .background(Theme.cardBg)
            .cornerRadius(Theme.cornerR)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerR)
                    .stroke(Theme.border, lineWidth: Theme.borderW)
            )
            .shadow(
                color: isHovered && appCard.enabled ? Theme.pink : Theme.shadow,
                radius: 0,
                x: isHovered && appCard.enabled ? 6 : Theme.shadowX,
                y: isHovered && appCard.enabled ? 6 : Theme.shadowY
            )
            .opacity(appCard.enabled ? 1.0 : 0.7)
            .scaleEffect(isHovered && appCard.enabled ? 1.02 : 1.0)
            .offset(x: isHovered && appCard.enabled ? -2 : 0, y: isHovered && appCard.enabled ? -2 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(!appCard.enabled)
        .onHover { hovering in
            cardHover = hovering ? appCard.id : nil
        }
    }

    private var squiggleDivider: some View {
        // Pink squiggle matching PouetWeb
        Path { path in
            let w: CGFloat = 80
            let h: CGFloat = 10
            let segments = 4
            let segW = w / CGFloat(segments)
            path.move(to: CGPoint(x: 0, y: h / 2))
            for i in 0..<segments {
                let x = CGFloat(i) * segW
                let up = i % 2 == 0
                path.addQuadCurve(
                    to: CGPoint(x: x + segW, y: h / 2),
                    control: CGPoint(x: x + segW / 2, y: up ? 0 : h)
                )
            }
        }
        .stroke(Theme.pink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        .frame(width: 80, height: 10)
    }

    // MARK: - Studio View (existing app)

    private var studioView: some View {
        VStack(spacing: 0) {
            studioHeaderBar
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
                .padding(.top, 4)
                .padding(.bottom, 20)
            }

            if selectedTab == 0 {
                levelsFooter
            }

            versionBar
        }
    }

    // MARK: - Studio Header (with back button)

    private var studioHeaderBar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    currentApp = nil
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    Text("Home")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(Theme.purple)
            }
            .buttonStyle(.plain)

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

        }
    }

    // MARK: - Header

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

                }
            }

        }
    }

    private func soundCard(name: String) -> some View {
        let url = URL(fileURLWithPath: (app.soundsDir as NSString).appendingPathComponent(name))
        let isInjecting = app.injectingURL == url
        let ext = (name as NSString).pathExtension.uppercased()
        let displayName = (name as NSString).deletingPathExtension

        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isInjecting ? Theme.accent.opacity(0.15) : Theme.purple.opacity(0.1))
                    .frame(width: 40, height: 40)
                Image(systemName: isInjecting ? "waveform" : "music.note")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(isInjecting ? Theme.accent : Theme.purple)
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

            playbackButton(active: isInjecting, icon: "mic.fill", size: 32, help: "Inject into virtual mic") {
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
                .stroke(isInjecting ? Theme.accent : Theme.border, lineWidth: Theme.borderW)
        )
        .shadow(color: isInjecting ? Theme.accent.opacity(0.15) : Color.black.opacity(0.06),
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
            // Sounds card (drop target for audio files)
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
                                Image(systemName: soundsDropHighlight ? "arrow.down.circle.fill" : "music.note")
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundColor(soundsDropHighlight ? Theme.accent : Theme.dimText.opacity(0.4))
                                Text(soundsDropHighlight ? "Drop to add" : "No sounds yet")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(Theme.bodyText)
                                Text("Drag & drop audio files here")
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

                    if soundsDropHighlight && !app.sounds.isEmpty {
                        HStack {
                            Spacer()
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 12, weight: .bold))
                                Text("Drop audio files to add")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(Theme.accent)
                            .padding(.vertical, 4)
                            Spacer()
                        }
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerR)
                    .stroke(soundsDropHighlight ? Theme.accent : Color.clear, lineWidth: 3)
            )
            .onDrop(of: [.fileURL], isTargeted: $soundsDropHighlight) { providers in
                handleSoundsDrop(providers)
            }

        }
    }

    private func soundRow(name: String) -> some View {
        let url = URL(fileURLWithPath: (app.soundsDir as NSString).appendingPathComponent(name))
        let isInjecting = app.injectingURL == url
        let ext = (name as NSString).pathExtension.uppercased()
        let displayName = (name as NSString).deletingPathExtension

        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isInjecting ? Theme.accent.opacity(0.15) : Theme.purple.opacity(0.1))
                    .frame(width: 34, height: 34)
                Image(systemName: isInjecting ? "waveform" : "music.note")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isInjecting ? Theme.accent : Theme.purple)
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

            playbackButton(active: isInjecting, icon: "mic.fill", size: 28, help: "Inject into virtual mic") {
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
                .stroke(isInjecting ? Theme.accent : Theme.border.opacity(0.3), lineWidth: isInjecting ? Theme.borderW : 1.5)
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
                    Text("Sound files stored in /Sounds")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.dimText)
                }
            }

            // Two columns
            HStack(alignment: .top, spacing: 14) {
                // Left: Audio Controls
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
                    }
                }
                .frame(maxWidth: .infinity)

                // Right: Health & Driver
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Health Check", icon: "checkmark.shield.fill")
                        healthRow("Driver installed", ok: app.driverInstalled)
                        healthRow("Pouet visible", ok: app.virtualMicVisible)
                        healthRow("Microphone permission", ok: app.hasMicPermission)
                        healthRow("Input devices found", ok: !app.devices.isEmpty)
                        healthRow("Mic proxy active", ok: app.proxyRunning)

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
            Text("Virtual microphone with audio injection")
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

    private func handleSoundsDrop(_ providers: [NSItemProvider]) -> Bool {
        let audioExts: Set<String> = ["mp3", "m4a", "wav", "aiff", "flac", "aac", "opus"]
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let ext = url.pathExtension.lowercased()
                guard audioExts.contains(ext) else {
                    DispatchQueue.main.async { self.showToast("Skipped: \(url.lastPathComponent) (not audio)") }
                    return
                }
                let dest = URL(fileURLWithPath: (self.app.soundsDir as NSString).appendingPathComponent(url.lastPathComponent))
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: url, to: dest)
                    DispatchQueue.main.async {
                        self.app.refreshSounds()
                        self.showToast("Added: \(url.lastPathComponent)")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.showToast("Failed: \(error.localizedDescription)")
                    }
                }
            }
            handled = true
        }
        return handled
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
