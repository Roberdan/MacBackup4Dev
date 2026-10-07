import Foundation
import os.log

/// Simple file + os_log logger for debugging and telemetry.
/// Log file: ~/.local/share/macbackup4dev/app.log
/// Rotated at 1 MB.
enum Log {
    private static let osLog = OSLog(subsystem: "com.roberdan.rusty-mac-backup", category: "app")
    private static let maxLogSize: UInt64 = 1_048_576 // 1 MB

    /// Overridable so tests never write fake entries into the user's real log.
    static var logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/macbackup4dev")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()

    static func info(_ message: String) {
        write("INFO", message)
        os_log(.info, log: osLog, "%{public}@", message)
    }

    static func warn(_ message: String) {
        write("WARN", message)
        os_log(.default, log: osLog, "WARN: %{public}@", message)
    }

    static func error(_ message: String) {
        write("ERROR", message)
        os_log(.error, log: osLog, "ERROR: %{public}@", message)
    }

    private static func write(_ level: String, _ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(level): \(message)\n"

        rotateIfNeeded()

        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else { return }
        let oldURL = logURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: logURL, to: oldURL)
    }
}
