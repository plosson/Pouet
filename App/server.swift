// server.swift — Embedded HTTP server for VirtualMic web UI
import Foundation
import Darwin.POSIX

// ---------------------------------------------------------------------------
// MARK: - Configuration persistence
// ---------------------------------------------------------------------------

struct AppConfig: Codable {
    var selectedDevice: String?
    var port: UInt16
    var soundsDir: String

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

class HTTPServer {
    let port: UInt16
    var config: AppConfig
    let injectRing: SharedRingBuffer
    let mainRing: SharedRingBuffer
    var proxy: MicProxy?
    var proxyDeviceName: String?

    private var listenSocket: Int32 = -1
    private let queue = DispatchQueue(label: "httpserver", attributes: .concurrent)
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

        listenSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard listenSocket >= 0 else { throw NSError(domain: "HTTP", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"]) }

        var yes: Int32 = 1
        setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { throw NSError(domain: "HTTP", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind() failed on port \(port): errno \(errno)"]) }

        guard listen(listenSocket, 128) == 0 else { throw NSError(domain: "HTTP", code: 3, userInfo: [NSLocalizedDescriptionKey: "listen() failed"]) }

        print("Web UI: http://localhost:\(port)")
        fflush(stdout)

        // Cache device list in background (coreaudiod may still be restarting)
        DispatchQueue.global().async { [weak self] in
            self?.refreshDeviceCache()
        }

        // Accept loop on background thread
        let sock = listenSocket
        queue.async { [weak self] in
            while true {
                var clientAddr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(sock, $0, &addrLen) }
                }
                guard clientFd >= 0 else { continue }
                DispatchQueue.global().async { self?.handleConnection(clientFd) }
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { Darwin.close(fd) }

        // Read request (up to 64KB)
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &buf, buf.count)
        guard n > 0 else { return }

        let requestStr = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
        let lines = requestStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }

        let method = String(parts[0])
        let rawPath = String(parts[1])
        let (path, queryParams) = parseURL(rawPath)

        // Extract body for POST
        var body: String? = nil
        if method == "POST" {
            if let bodyStart = requestStr.range(of: "\r\n\r\n") {
                body = String(requestStr[bodyStart.upperBound...])
            }
        }

        if path != "/api/status" {  // don't spam status polls
            print("[server] \(method) \(path)")
            fflush(stdout)
        }
        let response = routeRequest(method: method, path: path, query: queryParams, body: body)
        sendResponse(fd: fd, response: response)
    }

    private func parseURL(_ raw: String) -> (String, [String: String]) {
        let parts = raw.split(separator: "?", maxSplits: 1)
        let path = String(parts[0])
        var params: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                    let val = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    params[key] = val
                }
            }
        }
        return (path, params)
    }

    // ---------------------------------------------------------------------------
    // MARK: - Routing
    // ---------------------------------------------------------------------------

    struct HTTPResponse {
        let status: Int
        let contentType: String
        let body: Data

        static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            return HTTPResponse(status: status, contentType: "application/json", body: data)
        }

        static func text(_ str: String, status: Int = 200) -> HTTPResponse {
            return HTTPResponse(status: status, contentType: "text/plain", body: str.data(using: .utf8) ?? Data())
        }

        static func html(_ str: String, status: Int = 200) -> HTTPResponse {
            return HTTPResponse(status: status, contentType: "text/html; charset=utf-8", body: str.data(using: .utf8) ?? Data())
        }
    }

    private func routeRequest(method: String, path: String, query: [String: String], body: String?) -> HTTPResponse {
        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .html(indexHTML)

        case ("GET", "/api/devices"):
            return handleGetDevices()

        case ("GET", "/api/sounds"):
            return handleGetSounds()

        case ("GET", "/api/status"):
            return handleGetStatus()

        case ("GET", "/api/config"):
            return handleGetConfig()

        case ("POST", "/api/config"):
            return handlePostConfig(body: body)

        case ("POST", "/api/proxy/start"):
            return handleProxyStart(body: body)

        case ("POST", "/api/proxy/stop"):
            return handleProxyStop()

        case ("POST", "/api/play"):
            let file = query["file"] ?? ""
            return handlePlay(file: file, body: body)

        default:
            return .json(["error": "Not found"], status: 404)
        }
    }

    private func sendResponse(fd: Int32, response: HTTPResponse) {
        let statusText: String
        switch response.status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        let header = "HTTP/1.1 \(response.status) \(statusText)\r\n" +
                     "Content-Type: \(response.contentType)\r\n" +
                     "Content-Length: \(response.body.count)\r\n" +
                     "Access-Control-Allow-Origin: *\r\n" +
                     "Connection: close\r\n\r\n"

        var data = header.data(using: .utf8)!
        data.append(response.body)
        data.withUnsafeBytes { ptr in
            _ = Darwin.write(fd, ptr.baseAddress!, data.count)
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: - API Handlers
    // ---------------------------------------------------------------------------

    private func handleGetDevices() -> HTTPResponse {
        if cachedDevices.isEmpty && !deviceCacheLoading {
            deviceCacheLoading = true
            DispatchQueue.global().async { [weak self] in
                self?.refreshDeviceCache()
                self?.deviceCacheLoading = false
            }
        }
        return .json(["devices": cachedDevices])
    }

    private func handleGetSounds() -> HTTPResponse {
        let fm = FileManager.default
        let dir = config.soundsDir
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else {
            return .json(["sounds": [], "dir": dir])
        }
        let audioExts = Set(["mp3", "m4a", "wav", "aiff", "flac", "aac", "opus"])
        let sounds = files.filter { f in
            let ext = (f as NSString).pathExtension.lowercased()
            return audioExts.contains(ext)
        }.sorted()
        return .json(["sounds": sounds, "dir": dir])
    }

    private func handleGetStatus() -> HTTPResponse {
        let status: [String: Any] = [
            "proxy": [
                "running": proxy != nil,
                "device": proxyDeviceName as Any? ?? NSNull()
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
        return .json(status)
    }

    private func handleGetConfig() -> HTTPResponse {
        let cfg: [String: Any] = [
            "selectedDevice": config.selectedDevice ?? NSNull(),
            "port": config.port,
            "soundsDir": config.soundsDir
        ]
        return .json(cfg)
    }

    private func handlePostConfig(body: String?) -> HTTPResponse {
        guard let body = body,
              let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .json(["error": "Invalid JSON"], status: 400)
        }

        if let dev = obj["selectedDevice"] as? String { config.selectedDevice = dev }
        if let dir = obj["soundsDir"] as? String { config.soundsDir = dir }
        config.save()
        return .json(["ok": true])
    }

    private func handleProxyStart(body: String?) -> HTTPResponse {
        print("[proxy] Start requested")
        fflush(stdout)

        if proxy != nil {
            print("[proxy] Already running")
            fflush(stdout)
            return .json(["error": "Proxy already running"], status: 400)
        }

        var deviceQuery: String?
        if let body = body, let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            deviceQuery = obj["device"] as? String
        }

        guard let query = deviceQuery, !query.isEmpty else {
            print("[proxy] Missing device field")
            fflush(stdout)
            return .json(["error": "Missing 'device' field"], status: 400)
        }

        print("[proxy] Looking for device: '\(query)' in \(cachedDevices.count) cached devices")
        fflush(stdout)

        // Use cached devices to find the device ID (avoid CoreAudio calls on GCD thread)
        let lowerQuery = query.lowercased()
        guard let cached = cachedDevices.first(where: { ($0["name"] as? String)?.lowercased() == lowerQuery })
                        ?? cachedDevices.first(where: { ($0["name"] as? String)?.lowercased().contains(lowerQuery) == true }),
              let devID = cached["id"] as? UInt32,
              let devName = cached["name"] as? String else {
            print("[proxy] Device not found in cache")
            fflush(stdout)
            return .json(["error": "No input device matching '\(query)'"], status: 400)
        }

        let device = (id: devID, name: devName)
        print("[proxy] Found device: \(device.name) (id=\(device.id))")
        fflush(stdout)

        let newProxy = MicProxy(deviceID: device.id, mainRing: mainRing, injectRing: injectRing)
        do {
            try newProxy.start()
            proxy = newProxy
            proxyDeviceName = device.name
            config.selectedDevice = device.name
            config.save()
            print("[proxy] Started successfully: \(device.name)")
            fflush(stdout)
            return .json(["ok": true, "device": device.name])
        } catch {
            print("[proxy] Start failed: \(error)")
            fflush(stdout)
            return .json(["error": error.localizedDescription], status: 500)
        }
    }

    private func handleProxyStop() -> HTTPResponse {
        print("[proxy] Stop requested")
        fflush(stdout)
        guard let p = proxy else {
            return .json(["error": "Proxy not running"], status: 400)
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
        return .json(["ok": true])
    }

    private func handlePlay(file: String, body: String?) -> HTTPResponse {
        var filename = file
        if filename.isEmpty, let body = body, let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            filename = obj["file"] as? String ?? ""
        }

        guard !filename.isEmpty else {
            return .json(["error": "Missing 'file' parameter"], status: 400)
        }

        let path = (config.soundsDir as NSString).appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: path) else {
            return .json(["error": "File not found: \(filename)"], status: 404)
        }

        // Decode and inject on background queue to not block the response
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

        return .json(["ok": true, "file": filename])
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
  } catch (e) {}
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
