import Foundation
import Combine

class ServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var serverOutput = ""

    private var process: Process?
    private var outputPipe: Pipe?

    var cliPath: String {
        let paths = [
            "/usr/local/bin/VirtualMicCli",
            Bundle.main.bundlePath + "/Contents/Resources/VirtualMicCli"
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/local/bin/VirtualMicCli"
    }

    func start(port: UInt16 = 9999) {
        guard !isRunning else { return }

        // Kill any existing VirtualMicCli process to free the port
        killExisting()
        Thread.sleep(forTimeInterval: 0.5)

        let path = cliPath
        print("[GUI] Starting server at: \(path)")
        print("[GUI] File exists: \(FileManager.default.fileExists(atPath: path))")
        print("[GUI] Is executable: \(FileManager.default.isExecutableFile(atPath: path))")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["start", "--port", "\(port)"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        outputPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.serverOutput += str
                if let s = self?.serverOutput, s.count > 2000 {
                    self?.serverOutput = String(s.suffix(2000))
                }
            }
        }

        proc.terminationHandler = { [weak self] p in
            print("[GUI] Server process exited with status \(p.terminationStatus)")
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.process = nil
            }
        }

        do {
            try proc.run()
            process = proc
            isRunning = true
            print("[GUI] Server process started, pid=\(proc.processIdentifier)")
        } catch {
            print("[GUI] Failed to start: \(error)")
            serverOutput += "Failed to start: \(error.localizedDescription)\n"
        }
    }

    func stop() {
        if let proc = process, proc.isRunning {
            proc.interrupt()
        } else {
            // Server was started externally — kill by name
            killExisting()
        }
        process = nil
        isRunning = false
    }

    func checkIfRunning(port: UInt16 = 9999) {
        let url = URL(string: "http://localhost:\(port)/api/status")!
        URLSession.shared.dataTask(with: url) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else { return }
            DispatchQueue.main.async {
                self.isRunning = true
            }
        }.resume()
    }

    private func killExisting() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["VirtualMicCli"]
        try? kill.run()
        kill.waitUntilExit()
    }

    deinit {
        stop()
    }
}
