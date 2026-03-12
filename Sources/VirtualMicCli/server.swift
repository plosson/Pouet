// server.swift — HTTP server for VirtualMic web UI (using Swifter)
import Foundation
import Swifter

// ---------------------------------------------------------------------------
// MARK: - Configuration persistence
// ---------------------------------------------------------------------------

struct AppConfig: Codable {
    var selectedDevice: String?
    var port: UInt16
    var soundsDir: String
    var injectVolume: Float?

    static let defaultPath = NSHomeDirectory() + "/.virtualmicapp.json"
    static let defaultSoundsDir = NSHomeDirectory() + "/VirtualMicSounds"

    static func load() -> AppConfig {
        let path = defaultPath
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return config
        }
        return AppConfig(selectedDevice: nil, port: 9999, soundsDir: defaultSoundsDir)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: URL(fileURLWithPath: AppConfig.defaultPath))
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - HTTP Server
// ---------------------------------------------------------------------------

class VirtualMicServer {
    let port: UInt16
    var config: AppConfig
    let injectRing: SharedRingBuffer
    let mainRing: SharedRingBuffer
    var proxy: MicProxy?
    var proxyDeviceName: String?

    private let server = HttpServer()
    private var cachedDevices: [[String: Any]] = []
    private var deviceCacheLoading = false

    init(port: UInt16, config: AppConfig, mainRing: SharedRingBuffer, injectRing: SharedRingBuffer) {
        self.port = port
        self.config = config
        self.mainRing = mainRing
        self.injectRing = injectRing
    }

    func refreshDeviceCache() {
        print("[server] Refreshing device cache...")
        fflush(stdout)
        cachedDevices = listInputDevices().map { dev in
            ["id": dev.id, "name": dev.name, "uid": dev.uid, "channels": dev.inputChannels] as [String: Any]
        }
        print("[server] Cached \(cachedDevices.count) devices")
        fflush(stdout)
    }

    func start() throws {
        // Ensure sounds directory exists
        try FileManager.default.createDirectory(atPath: config.soundsDir,
                                                 withIntermediateDirectories: true)

        setupRoutes()

        try server.start(port, forceIPv4: true)
        print("Web UI: http://localhost:\(port)")
        fflush(stdout)

        // Cache device list in background
        DispatchQueue.global().async { [weak self] in
            self?.refreshDeviceCache()
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: - Routes
    // ---------------------------------------------------------------------------

    private func setupRoutes() {
        // CORS middleware for all responses
        server.middleware.append { request in
            return nil  // continue processing
        }

        server["/" ] = { [weak self] _ in self?.serveIndex() ?? .notFound }
        server["/index.html"] = { [weak self] _ in self?.serveIndex() ?? .notFound }

        server["/api/devices"] = { [weak self] _ in
            guard let self = self else { return .notFound }
            return self.handleGetDevices()
        }

        server["/api/sounds"] = { [weak self] _ in
            guard let self = self else { return .notFound }
            return self.handleGetSounds()
        }

        server["/api/status"] = { [weak self] _ in
            guard let self = self else { return .notFound }
            return self.handleGetStatus()
        }

        server["/api/config"] = { [weak self] request in
            guard let self = self else { return .notFound }
            if request.method == "POST" {
                return self.handlePostConfig(request)
            }
            return self.handleGetConfig()
        }

        server["/api/proxy/start"] = { [weak self] request in
            guard let self = self else { return .notFound }
            print("[server] POST /api/proxy/start")
            fflush(stdout)
            return self.handleProxyStart(request)
        }

        server["/api/proxy/stop"] = { [weak self] _ in
            guard let self = self else { return .notFound }
            print("[server] POST /api/proxy/stop")
            fflush(stdout)
            return self.handleProxyStop()
        }

        server["/api/play"] = { [weak self] request in
            guard let self = self else { return .notFound }
            print("[server] POST /api/play")
            fflush(stdout)
            return self.handlePlay(request)
        }

        server["/api/volume"] = { [weak self] request in
            guard let self = self else { return .notFound }
            print("[server] POST /api/volume")
            fflush(stdout)
            return self.handleSetVolume(request)
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: - Helpers
    // ---------------------------------------------------------------------------

    private func jsonResponse(_ obj: Any, status: Int = 200) -> HttpResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else {
            return .internalServerError
        }
        let headers = ["Content-Type": "application/json", "Access-Control-Allow-Origin": "*"]
        return .raw(status, status == 200 ? "OK" : "Error", headers) { writer in
            try writer.write(data)
        }
    }

    private func parseJSON(_ request: HttpRequest) -> [String: Any]? {
        let data = Data(request.body)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func serveIndex() -> HttpResponse {
        let headers = ["Content-Type": "text/html; charset=utf-8", "Access-Control-Allow-Origin": "*"]
        return .raw(200, "OK", headers) { writer in
            try writer.write(Data(indexHTML.utf8))
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: - API Handlers
    // ---------------------------------------------------------------------------

    private func handleGetDevices() -> HttpResponse {
        if cachedDevices.isEmpty && !deviceCacheLoading {
            deviceCacheLoading = true
            DispatchQueue.global().async { [weak self] in
                self?.refreshDeviceCache()
                self?.deviceCacheLoading = false
            }
        }
        return jsonResponse(["devices": cachedDevices])
    }

    private func handleGetSounds() -> HttpResponse {
        let fm = FileManager.default
        let dir = config.soundsDir
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else {
            return jsonResponse(["sounds": [], "dir": dir])
        }
        let audioExts = Set(["mp3", "m4a", "wav", "aiff", "flac", "aac", "opus"])
        let sounds = files.filter { f in
            let ext = (f as NSString).pathExtension.lowercased()
            return audioExts.contains(ext)
        }.sorted()
        return jsonResponse(["sounds": sounds, "dir": dir])
    }

    private func handleGetStatus() -> HttpResponse {
        let status: [String: Any] = [
            "proxy": [
                "running": proxy != nil,
                "device": proxyDeviceName as Any? ?? NSNull(),
                "injectVolume": (proxy?.injectVolume ?? config.injectVolume ?? 1.0) as Float
            ],
            "mainRing": [
                "fillPercent": mainRing.fillPercent,
                "availableSamples": mainRing.availableSamples
            ],
            "injectRing": [
                "fillPercent": injectRing.fillPercent,
                "availableSamples": injectRing.availableSamples
            ]
        ]
        return jsonResponse(status)
    }

    private func handleGetConfig() -> HttpResponse {
        let cfg: [String: Any] = [
            "selectedDevice": config.selectedDevice ?? NSNull(),
            "port": config.port,
            "soundsDir": config.soundsDir
        ]
        return jsonResponse(cfg)
    }

    private func handlePostConfig(_ request: HttpRequest) -> HttpResponse {
        guard let obj = parseJSON(request) else {
            return jsonResponse(["error": "Invalid JSON"], status: 400)
        }
        if let dev = obj["selectedDevice"] as? String { config.selectedDevice = dev }
        if let dir = obj["soundsDir"] as? String { config.soundsDir = dir }
        config.save()
        return jsonResponse(["ok": true])
    }

    private func handleProxyStart(_ request: HttpRequest) -> HttpResponse {
        print("[proxy] Start requested")
        fflush(stdout)

        if proxy != nil {
            print("[proxy] Already running")
            fflush(stdout)
            return jsonResponse(["error": "Proxy already running"], status: 400)
        }

        guard let obj = parseJSON(request),
              let deviceQuery = obj["device"] as? String, !deviceQuery.isEmpty else {
            print("[proxy] Missing device field")
            fflush(stdout)
            return jsonResponse(["error": "Missing 'device' field"], status: 400)
        }

        print("[proxy] Looking for device: '\(deviceQuery)' in \(cachedDevices.count) cached devices")
        fflush(stdout)

        let lowerQuery = deviceQuery.lowercased()
        guard let cached = cachedDevices.first(where: { ($0["name"] as? String)?.lowercased() == lowerQuery })
                        ?? cachedDevices.first(where: { ($0["name"] as? String)?.lowercased().contains(lowerQuery) == true }),
              let devID = cached["id"] as? UInt32,
              let devName = cached["name"] as? String else {
            print("[proxy] Device not found in cache")
            fflush(stdout)
            return jsonResponse(["error": "No input device matching '\(deviceQuery)'"], status: 400)
        }

        let device = (id: devID, name: devName)
        print("[proxy] Found device: \(device.name) (id=\(device.id))")
        fflush(stdout)

        let newProxy = MicProxy(deviceID: device.id, mainRing: mainRing, injectRing: injectRing)
        do {
            newProxy.injectVolume = config.injectVolume ?? 1.0
            try newProxy.start()
            proxy = newProxy
            proxyDeviceName = device.name
            config.selectedDevice = device.name
            config.save()
            print("[proxy] Started successfully: \(device.name)")
            fflush(stdout)
            return jsonResponse(["ok": true, "device": device.name])
        } catch {
            print("[proxy] Start failed: \(error)")
            fflush(stdout)
            return jsonResponse(["error": error.localizedDescription], status: 500)
        }
    }

    private func handleProxyStop() -> HttpResponse {
        print("[proxy] Stop requested")
        fflush(stdout)
        guard let p = proxy else {
            return jsonResponse(["error": "Proxy not running"], status: 400)
        }
        p.stop()
        proxy = nil
        proxyDeviceName = nil
        mainRing.clear()
        injectRing.clear()
        print("[proxy] Stopped, refreshing device cache...")
        fflush(stdout)
        refreshDeviceCache()
        print("[proxy] Device cache refreshed")
        fflush(stdout)
        return jsonResponse(["ok": true])
    }

    private func handlePlay(_ request: HttpRequest) -> HttpResponse {
        // Try query parameter first, then JSON body
        var filename = request.queryParams.first(where: { $0.0 == "file" })?.1 ?? ""
        if filename.isEmpty, let obj = parseJSON(request) {
            filename = obj["file"] as? String ?? ""
        }

        guard !filename.isEmpty else {
            return jsonResponse(["error": "Missing 'file' parameter"], status: 400)
        }

        let path = (config.soundsDir as NSString).appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: path) else {
            return jsonResponse(["error": "File not found: \(filename)"], status: 404)
        }

        let ring = injectRing
        let url = URL(fileURLWithPath: path)
        DispatchQueue.global().async {
            do {
                let samples = try decodeAudioFile(url: url)
                ring.writeArray(samples)
                print("Injected: \(filename) (\(samples.count / Int(NUM_CHANNELS)) frames)")
            } catch {
                print("Inject error: \(error.localizedDescription)")
            }
        }

        return jsonResponse(["ok": true, "file": filename])
    }

    private func handleSetVolume(_ request: HttpRequest) -> HttpResponse {
        guard let obj = parseJSON(request),
              let vol = obj["volume"] as? Double else {
            return jsonResponse(["error": "Missing 'volume' (0.0-1.0)"], status: 400)
        }
        let clamped = Float(max(0.0, min(1.0, vol)))
        proxy?.injectVolume = clamped
        config.injectVolume = clamped
        config.save()
        print("[server] Volume set to \(clamped)")
        fflush(stdout)
        return jsonResponse(["ok": true, "volume": clamped])
    }
}

// ---------------------------------------------------------------------------
// MARK: - HTML UI
// ---------------------------------------------------------------------------

let indexHTML = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>VirtualMic</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
         background: #1a1a2e; color: #e0e0e0; min-height: 100vh; }
  .container { max-width: 720px; margin: 0 auto; padding: 24px; }
  h1 { font-size: 28px; font-weight: 700; margin-bottom: 8px; color: #fff; }
  .subtitle { color: #888; margin-bottom: 32px; font-size: 14px; }
  .card { background: #16213e; border-radius: 12px; padding: 20px; margin-bottom: 20px;
          border: 1px solid #1a1a40; }
  .card h2 { font-size: 16px; font-weight: 600; margin-bottom: 16px; color: #a0a0c0; text-transform: uppercase; letter-spacing: 1px; font-size: 12px; }
  .status-dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 8px; }
  .status-dot.on { background: #4ade80; box-shadow: 0 0 8px #4ade8066; }
  .status-dot.off { background: #666; }
  select { width: 100%; padding: 10px 12px; border-radius: 8px; border: 1px solid #333;
           background: #0f0f23; color: #e0e0e0; font-size: 14px; margin-bottom: 12px;
           appearance: none; cursor: pointer; }
  select:focus { outline: none; border-color: #5b6abf; }
  button { padding: 10px 20px; border-radius: 8px; border: none; cursor: pointer;
           font-size: 14px; font-weight: 500; transition: all 0.15s; }
  .btn-primary { background: #5b6abf; color: #fff; }
  .btn-primary:hover { background: #6b7bd0; }
  .btn-primary:disabled { background: #333; color: #666; cursor: not-allowed; }
  .btn-danger { background: #dc2626; color: #fff; }
  .btn-danger:hover { background: #ef4444; }
  .btn-row { display: flex; gap: 8px; }
  .sound-list { list-style: none; }
  .sound-item { display: flex; align-items: center; padding: 10px 12px; border-radius: 8px;
                cursor: pointer; transition: background 0.15s; margin-bottom: 4px; }
  .sound-item:hover { background: #1a1a40; }
  .sound-item.playing { background: #1e3a5f; }
  .sound-icon { width: 36px; height: 36px; border-radius: 8px; background: #5b6abf22;
                display: flex; align-items: center; justify-content: center; margin-right: 12px;
                flex-shrink: 0; font-size: 16px; }
  .sound-item.playing .sound-icon { background: #5b6abf44; }
  .sound-name { font-size: 14px; flex: 1; }
  .sound-ext { font-size: 11px; color: #666; margin-left: 8px; text-transform: uppercase; }
  .meter { height: 6px; background: #0f0f23; border-radius: 3px; overflow: hidden; margin-top: 8px; }
  .meter-fill { height: 100%; background: linear-gradient(90deg, #5b6abf, #4ade80); border-radius: 3px;
                transition: width 0.3s; }
  .meter-label { display: flex; justify-content: space-between; font-size: 11px; color: #666; margin-top: 4px; }
  .empty-state { text-align: center; padding: 32px; color: #666; }
  .empty-state p { margin-bottom: 8px; }
  .empty-state code { background: #0f0f23; padding: 4px 8px; border-radius: 4px; font-size: 13px; color: #a0a0c0; }
  .settings-row { display: flex; align-items: center; gap: 8px; margin-bottom: 12px; }
  .settings-row label { font-size: 13px; color: #888; min-width: 80px; }
  .settings-row input { flex: 1; padding: 8px 12px; border-radius: 8px; border: 1px solid #333;
                         background: #0f0f23; color: #e0e0e0; font-size: 13px; }
  .settings-row input:focus { outline: none; border-color: #5b6abf; }
  .toast { position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%);
           background: #333; color: #fff; padding: 10px 20px; border-radius: 8px;
           font-size: 13px; opacity: 0; transition: opacity 0.3s; pointer-events: none; z-index: 100; }
  .toast.show { opacity: 1; }
</style>
</head>
<body>
<div class="container">
  <h1>VirtualMic</h1>
  <p class="subtitle">Virtual microphone proxy with audio injection</p>

  <!-- Proxy Control -->
  <div class="card">
    <h2>Microphone Proxy</h2>
    <div id="proxy-status" style="margin-bottom: 12px; font-size: 14px;">
      <span class="status-dot off" id="status-dot"></span>
      <span id="status-text">Stopped</span>
    </div>
    <select id="device-select"><option value="">Loading devices…</option></select>
    <div class="btn-row">
      <button class="btn-primary" id="btn-start" onclick="startProxy()">Start Proxy</button>
      <button class="btn-danger" id="btn-stop" onclick="stopProxy()" style="display:none">Stop Proxy</button>
    </div>
  </div>

  <!-- Ring Buffer Status -->
  <div class="card">
    <h2>Buffer Status</h2>
    <div style="font-size: 13px; color: #888; margin-bottom: 4px;">Main (mic → apps)</div>
    <div class="meter"><div class="meter-fill" id="main-meter" style="width:0%"></div></div>
    <div class="meter-label"><span id="main-pct">0%</span><span id="main-samples">0 samples</span></div>
    <div style="font-size: 13px; color: #888; margin-bottom: 4px; margin-top: 12px;">Inject</div>
    <div class="meter"><div class="meter-fill" id="inject-meter" style="width:0%"></div></div>
    <div class="meter-label"><span id="inject-pct">0%</span><span id="inject-samples">0 samples</span></div>
  </div>

  <!-- Volume -->
  <div class="card">
    <h2>Inject Volume</h2>
    <div style="display: flex; align-items: center; gap: 12px;">
      <span style="font-size: 13px; color: #888;">0%</span>
      <input type="range" id="volume-slider" min="0" max="100" value="100"
             style="flex: 1; accent-color: #5b6abf;"
             oninput="updateVolumeLabel(this.value)" onchange="setVolume(this.value)">
      <span id="volume-label" style="font-size: 13px; color: #ccc; min-width: 36px;">100%</span>
    </div>
  </div>

  <!-- Sounds -->
  <div class="card">
    <h2>Sound Board</h2>
    <ul class="sound-list" id="sound-list">
      <li class="empty-state" id="sounds-empty">
        <p>No sounds found</p>
        <p>Drop MP3 files in <code id="sounds-dir">~/VirtualMicSounds</code></p>
      </li>
    </ul>
  </div>

  <!-- Settings -->
  <div class="card">
    <h2>Settings</h2>
    <div class="settings-row">
      <label>Sounds dir</label>
      <input type="text" id="cfg-sounds-dir" placeholder="~/VirtualMicSounds">
    </div>
    <button class="btn-primary" onclick="saveConfig()" style="margin-top: 4px;">Save</button>
  </div>
</div>
<div class="toast" id="toast"></div>

<script>
const API = '';
let pollTimer = null;
let currentPlaying = null;

function toast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.classList.add('show');
  setTimeout(() => t.classList.remove('show'), 2000);
}

async function api(method, path, body) {
  const opts = { method };
  if (body) {
    opts.headers = { 'Content-Type': 'application/json' };
    opts.body = JSON.stringify(body);
  }
  const r = await fetch(API + path, opts);
  return r.json();
}

async function loadDevices() {
  const data = await api('GET', '/api/devices');
  const sel = document.getElementById('device-select');
  sel.innerHTML = '<option value="">— Select microphone —</option>';
  (data.devices || []).forEach(d => {
    const opt = document.createElement('option');
    opt.value = d.name;
    opt.textContent = `${d.name} (${d.channels} ch)`;
    sel.appendChild(opt);
  });
  // Restore saved selection
  const cfg = await api('GET', '/api/config');
  if (cfg.selectedDevice) sel.value = cfg.selectedDevice;
  document.getElementById('cfg-sounds-dir').value = cfg.soundsDir || '';
}

async function loadSounds() {
  const data = await api('GET', '/api/sounds');
  const list = document.getElementById('sound-list');
  const empty = document.getElementById('sounds-empty');
  const dir = data.dir || '~/VirtualMicSounds';
  document.getElementById('sounds-dir').textContent = dir;

  if (!data.sounds || data.sounds.length === 0) {
    empty.style.display = '';
    return;
  }
  empty.style.display = 'none';

  // Remove old items (keep empty state)
  list.querySelectorAll('.sound-item').forEach(el => el.remove());

  data.sounds.forEach(name => {
    const ext = name.split('.').pop();
    const li = document.createElement('li');
    li.className = 'sound-item';
    li.dataset.file = name;
    li.innerHTML = `<div class="sound-icon">&#9835;</div><span class="sound-name">${name.replace(/\\.[^.]+$/, '')}</span><span class="sound-ext">${ext}</span>`;
    li.onclick = () => playSound(name, li);
    list.appendChild(li);
  });
}

async function playSound(name, el) {
  document.querySelectorAll('.sound-item.playing').forEach(e => e.classList.remove('playing'));
  el.classList.add('playing');
  currentPlaying = name;
  const data = await api('POST', '/api/play?file=' + encodeURIComponent(name));
  if (data.ok) {
    toast('Playing: ' + name);
  } else {
    toast('Error: ' + (data.error || 'unknown'));
  }
  // Remove playing state after a delay
  setTimeout(() => { if (currentPlaying === name) el.classList.remove('playing'); }, 3000);
}

async function startProxy() {
  const device = document.getElementById('device-select').value;
  if (!device) { toast('Select a microphone first'); return; }
  const data = await api('POST', '/api/proxy/start', { device });
  if (data.ok) {
    toast('Proxy started: ' + data.device);
    updateProxyUI(true, data.device);
  } else {
    toast('Error: ' + (data.error || 'unknown'));
  }
}

async function stopProxy() {
  const data = await api('POST', '/api/proxy/stop');
  if (data.ok) {
    toast('Proxy stopped');
    updateProxyUI(false, null);
  }
}

function updateProxyUI(running, device) {
  const dot = document.getElementById('status-dot');
  const text = document.getElementById('status-text');
  const btnStart = document.getElementById('btn-start');
  const btnStop = document.getElementById('btn-stop');
  const sel = document.getElementById('device-select');
  dot.className = 'status-dot ' + (running ? 'on' : 'off');
  text.textContent = running ? 'Proxying: ' + device : 'Stopped';
  btnStart.style.display = running ? 'none' : '';
  btnStop.style.display = running ? '' : 'none';
  sel.disabled = running;
}

async function pollStatus() {
  try {
    const data = await api('GET', '/api/status');
    const p = data.proxy || {};
    updateProxyUI(p.running, p.device);
    const mr = data.mainRing || {};
    const ir = data.injectRing || {};
    document.getElementById('main-meter').style.width = (mr.fillPercent || 0) + '%';
    document.getElementById('main-pct').textContent = (mr.fillPercent || 0) + '%';
    document.getElementById('main-samples').textContent = (mr.availableSamples || 0).toLocaleString() + ' samples';
    document.getElementById('inject-meter').style.width = (ir.fillPercent || 0) + '%';
    document.getElementById('inject-pct').textContent = (ir.fillPercent || 0) + '%';
    document.getElementById('inject-samples').textContent = (ir.availableSamples || 0).toLocaleString() + ' samples';
    // Sync volume slider (only if user is not actively dragging)
    if (document.activeElement?.id !== 'volume-slider') {
      const vol = Math.round((p.injectVolume ?? 1.0) * 100);
      document.getElementById('volume-slider').value = vol;
      document.getElementById('volume-label').textContent = vol + '%';
    }
  } catch (e) {}
}

function updateVolumeLabel(val) {
  document.getElementById('volume-label').textContent = val + '%';
}

async function setVolume(val) {
  const v = parseInt(val) / 100;
  await api('POST', '/api/volume', { volume: v });
}

async function saveConfig() {
  const dir = document.getElementById('cfg-sounds-dir').value;
  await api('POST', '/api/config', { soundsDir: dir });
  toast('Config saved');
  loadSounds();
}

// Init
loadDevices();
loadSounds();
pollStatus();
pollTimer = setInterval(pollStatus, 1000);
</script>
</body>
</html>
"""
