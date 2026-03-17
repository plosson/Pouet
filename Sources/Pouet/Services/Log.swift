// Log.swift — Rotating file logger for Pouet
// Logs to ~/Library/Logs/Pouet/ with automatic rotation.

import Foundation

enum Log {
    private static let maxFileSize: UInt64 = 1_000_000  // 1 MB per file
    private static let maxFiles = 5
    private static let logDir: String = {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Pouet")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let logFile: String = (logDir as NSString).appendingPathComponent("pouet.log")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let queue = DispatchQueue(label: "com.pouet.log", qos: .utility)

    static func info(_ message: String, file: String = #file, line: Int = #line) {
        write("INFO", message, file: file, line: line)
    }

    static func warn(_ message: String, file: String = #file, line: Int = #line) {
        write("WARN", message, file: file, line: line)
    }

    static func error(_ message: String, file: String = #file, line: Int = #line) {
        write("ERROR", message, file: file, line: line)
    }

    private static func write(_ level: String, _ message: String, file: String, line: Int) {
        let timestamp = dateFormatter.string(from: Date())
        let source = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        let entry = "[\(timestamp)] [\(level)] [\(source):\(line)] \(message)\n"

        // Also print to stderr for console/Xcode
        fputs(entry, stderr)

        queue.async {
            rotateIfNeeded()
            if let data = entry.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFile) {
                    if let handle = FileHandle(forWritingAtPath: logFile) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    FileManager.default.createFile(atPath: logFile, contents: data)
                }
            }
        }
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFile),
              let size = attrs[.size] as? UInt64,
              size >= maxFileSize else { return }

        let fm = FileManager.default
        // Remove oldest
        let oldest = logFile + ".\(maxFiles)"
        try? fm.removeItem(atPath: oldest)
        // Shift existing files
        for i in stride(from: maxFiles - 1, through: 1, by: -1) {
            let src = logFile + ".\(i)"
            let dst = logFile + ".\(i + 1)"
            try? fm.moveItem(atPath: src, toPath: dst)
        }
        // Rotate current
        try? fm.moveItem(atPath: logFile, toPath: logFile + ".1")
    }

    /// Path to log directory for UI display
    static var logDirectory: String { logDir }
}
