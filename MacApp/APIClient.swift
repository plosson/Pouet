import Foundation

class APIClient: ObservableObject {
    let baseURL: String

    init(port: UInt16 = 9999) {
        self.baseURL = "http://localhost:\(port)"
    }

    // MARK: - Models

    struct Device: Identifiable, Codable {
        let id: UInt32
        let name: String
        let uid: String
        let channels: Int
    }

    struct Status: Codable {
        struct Proxy: Codable {
            let running: Bool
            let device: String?
            let injectVolume: Float?
        }
        struct Ring: Codable {
            let fillPercent: Int
            let availableSamples: Int
        }
        let proxy: Proxy
        let mainRing: Ring
        let injectRing: Ring
    }

    struct Config: Codable {
        let selectedDevice: String?
        let port: Int?
        let soundsDir: String?
    }

    // MARK: - API calls

    func getDevices() async throws -> [Device] {
        let data = try await get("/api/devices")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let devArray = obj?["devices"] as? [[String: Any]] else { return [] }
        return devArray.compactMap { d in
            guard let id = d["id"] as? UInt32,
                  let name = d["name"] as? String,
                  let uid = d["uid"] as? String,
                  let ch = d["channels"] as? Int else { return nil }
            return Device(id: id, name: name, uid: uid, channels: ch)
        }
    }

    func getStatus() async throws -> Status {
        let data = try await get("/api/status")
        return try JSONDecoder().decode(Status.self, from: data)
    }

    func getSounds() async throws -> [String] {
        let data = try await get("/api/sounds")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["sounds"] as? [String] ?? []
    }

    func getConfig() async throws -> Config {
        let data = try await get("/api/config")
        return try JSONDecoder().decode(Config.self, from: data)
    }

    func startProxy(device: String) async throws {
        _ = try await post("/api/proxy/start", body: ["device": device])
    }

    func stopProxy() async throws {
        _ = try await post("/api/proxy/stop", body: [:])
    }

    func play(file: String) async throws {
        _ = try await post("/api/play", body: ["file": file])
    }

    func setVolume(_ volume: Float) async throws {
        _ = try await post("/api/volume", body: ["volume": volume])
    }

    // MARK: - HTTP helpers

    private func get(_ path: String) async throws -> Data {
        let url = URL(string: baseURL + path)!
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
