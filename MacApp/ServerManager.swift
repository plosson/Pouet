import Foundation
import Combine

class ServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var serverOutput = ""

    private var process: Process?
    private var outputPipe: Pipe?

    var cliPath: String {
        // Check common locations
        let paths = [
            "/usr/local/bin/VirtualMicApp",
            Bundle.main.bundlePath + "/Contents/Resources/VirtualMicApp"
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/local/bin/VirtualMicApp"
    }

    func start(port: UInt16 = 9999) {
        guard !isRunning else { return }

        // Kill any existing VirtualMicApp process to free the port
        let killProc = Process()
        killProc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killProc.arguments = ["VirtualMicApp"]
        try? killProc.run()
        killProc.waitUntilExit()
        // Give it a moment to release the port
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

        // Read output asynchronously
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.serverOutput += str
                // Keep last 2000 chars
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
        guard let proc = process, proc.isRunning else {
            isRunning = false
            return
        }
        proc.interrupt()  // SIGINT, same as Ctrl-C
        process = nil
        isRunning = false
    }

    deinit {
        stop()
    }
}
