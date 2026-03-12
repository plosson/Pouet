import SwiftUI

struct ContentView: View {
    @ObservedObject var server: ServerManager
    @StateObject private var api = APIClient()

    @State private var devices: [APIClient.Device] = []
    @State private var selectedDevice = ""
    @State private var proxyRunning = false
    @State private var proxyDevice: String?
    @State private var sounds: [String] = []
    @State private var volume: Float = 1.0
    @State private var mainRingPercent = 0
    @State private var injectRingPercent = 0
    @State private var statusMessage = ""
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Server control bar
            serverBar
            Divider()

            if server.isRunning {
                ScrollView {
                    VStack(spacing: 16) {
                        proxyCard
                        metersCard
                        volumeCard
                        soundsCard
                    }
                    .padding()
                }
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "mic.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Server not running")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Start the server to control VirtualMic")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Server log
            if !server.serverOutput.isEmpty {
                Divider()
                ScrollView {
                    Text(server.serverOutput)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(maxHeight: 80)
            }

            // Status bar
            if !statusMessage.isEmpty {
                Divider()
                HStack {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Server bar

    private var serverBar: some View {
        HStack {
            Circle()
                .fill(server.isRunning ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(server.isRunning ? "Server running" : "Server stopped")
                .font(.headline)
            Spacer()
            if server.isRunning {
                Button("Stop Server") {
                    stopEverything()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Start Server") {
                    server.start()
                    // Wait a moment for server to start, then begin polling
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        startPolling()
                        loadData()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    // MARK: - Proxy card

    private var proxyCard: some View {
        GroupBox("Microphone Proxy") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle()
                        .fill(proxyRunning ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(proxyRunning ? "Proxying: \(proxyDevice ?? "?")" : "Stopped")
                        .font(.subheadline)
                }

                HStack {
                    Picker("Device", selection: $selectedDevice) {
                        Text("— Select microphone —").tag("")
                        ForEach(devices) { dev in
                            Text("\(dev.name) (\(dev.channels) ch)").tag(dev.name)
                        }
                    }
                    .disabled(proxyRunning)

                    if proxyRunning {
                        Button("Stop") {
                            Task { await doStopProxy() }
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    } else {
                        Button("Start") {
                            Task { await doStartProxy() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedDevice.isEmpty)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Meters card

    private var metersCard: some View {
        GroupBox("Ring Buffers") {
            VStack(alignment: .leading, spacing: 8) {
                meterRow(label: "Main", percent: mainRingPercent)
                meterRow(label: "Inject", percent: injectRingPercent)
            }
            .padding(.vertical, 4)
        }
    }

    private func meterRow(label: String, percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(percent)%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            ProgressView(value: Double(percent), total: 100)
                .tint(percent > 80 ? .red : .blue)
        }
    }

    // MARK: - Volume card

    private var volumeCard: some View {
        GroupBox("Inject Volume") {
            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.secondary)
                Slider(value: $volume, in: 0...1, step: 0.01) { editing in
                    if !editing {
                        Task {
                            try? await api.setVolume(volume)
                        }
                    }
                }
                Text("\(Int(volume * 100))%")
                    .font(.body.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Sounds card

    private var soundsCard: some View {
        GroupBox("Sound Board") {
            if sounds.isEmpty {
                VStack(spacing: 4) {
                    Text("No sounds found")
                        .foregroundColor(.secondary)
                    Text("Drop audio files in ~/VirtualMicSounds/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 4) {
                    ForEach(sounds, id: \.self) { name in
                        HStack {
                            Image(systemName: "music.note")
                                .foregroundColor(.blue)
                            Text(name)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                Task { await doPlay(file: name) }
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Actions

    private func loadData() {
        Task {
            do {
                devices = try await api.getDevices()
                sounds = try await api.getSounds()
                let config = try await api.getConfig()
                if let dev = config.selectedDevice {
                    selectedDevice = dev
                }
            } catch {
                statusMessage = "Failed to load: \(error.localizedDescription)"
            }
        }
    }

    private func doStartProxy() async {
        guard !selectedDevice.isEmpty else { return }
        do {
            try await api.startProxy(device: selectedDevice)
            statusMessage = "Proxy started"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func doStopProxy() async {
        do {
            try await api.stopProxy()
            statusMessage = "Proxy stopped"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func doPlay(file: String) async {
        do {
            try await api.play(file: file)
            statusMessage = "Playing: \(file)"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task {
                do {
                    let status = try await api.getStatus()
                    await MainActor.run {
                        proxyRunning = status.proxy.running
                        proxyDevice = status.proxy.device
                        volume = status.proxy.injectVolume ?? volume
                        mainRingPercent = status.mainRing.fillPercent
                        injectRingPercent = status.injectRing.fillPercent
                    }
                } catch {
                    // Server might not be ready yet
                }
            }
        }
    }

    private func stopEverything() {
        pollTimer?.invalidate()
        pollTimer = nil
        server.stop()
        proxyRunning = false
        devices = []
        sounds = []
        statusMessage = ""
    }
}
