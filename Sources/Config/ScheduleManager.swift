import Foundation

struct ScheduleStatus {
    let installed: Bool
    let intervalMinutes: Int?
    let dailyHour: Int?
}

enum ScheduleManager {
    static let label = AppIdentity.launchAgentLabel
    static var binaryPath: String {
        // Use actual bundle path if available, fall back to /Applications
        if let bundlePath = Bundle.main.executablePath {
            return bundlePath
        }
        return "/Applications/MacBackup4Dev.app/Contents/MacOS/MacBackup4Dev"
    }

    static var plistPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var logPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/macbackup4dev/backup.log")
    }

    private static var errorLogPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/macbackup4dev/backup-error.log")
    }

    static func generatePlist(intervalSeconds: Int) -> String {
        generatePlistBody("""
            <key>StartInterval</key>
            <integer>\(intervalSeconds)</integer>
        """)
    }

    static func generatePlistDaily(hour: Int) -> String {
        generatePlistBody("""
            <key>StartCalendarInterval</key>
            <dict>
                <key>Hour</key>
                <integer>\(hour)</integer>
                <key>Minute</key>
                <integer>0</integer>
            </dict>
        """)
    }

    static func installSchedule(plistContent: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: plistPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: logPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        // F-11: Use bootout before re-installing to avoid stale service state
        if fm.fileExists(atPath: plistPath.path) {
            _ = runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plistPath.path])
        }
        try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
        // F-11: bootstrap/bootout replaces legacy load/unload on modern macOS
        let result = runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", plistPath.path])
        guard result.status == 0 else {
            throw scheduleError("Failed to bootstrap schedule: \(result.stderr)")
        }
    }

    static func removeSchedule() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: plistPath.path) {
            // F-11: bootout instead of legacy unload
            let result = runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plistPath.path])
            if result.status != 0 {
                let stderr = result.stderr.lowercased()
                if !stderr.contains("could not find specified service")
                    && !stderr.contains("no such process")
                    && !stderr.contains("3: no such process") {
                    throw scheduleError("Failed to bootout schedule: \(result.stderr)")
                }
            }
            try fm.removeItem(at: plistPath)
        }
    }

    static func scheduleStatus() -> ScheduleStatus {
        let installed = runLaunchctl(arguments: ["list", label]).status == 0
        guard let data = try? Data(contentsOf: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return ScheduleStatus(installed: installed, intervalMinutes: nil, dailyHour: nil)
        }

        if let intervalSeconds = plist["StartInterval"] as? Int {
            return ScheduleStatus(installed: installed, intervalMinutes: intervalSeconds / 60, dailyHour: nil)
        }

        if let schedule = plist["StartCalendarInterval"] as? [String: Any],
           let hour = schedule["Hour"] as? Int {
            return ScheduleStatus(installed: installed, intervalMinutes: nil, dailyHour: hour)
        }

        return ScheduleStatus(installed: installed, intervalMinutes: nil, dailyHour: nil)
    }

    private static func generatePlistBody(_ scheduleBlock: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>backup</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>Nice</key>
            <integer>10</integer>
            <key>LowPriorityIO</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logPath.path)</string>
            <key>StandardErrorPath</key>
            <string>\(errorLogPath.path)</string>
            \(scheduleBlock)
        </dict>
        </plist>
        """
    }

    /// 4.0 rename: replaces the 3.x LaunchAgent (com.roberdan.rusty-mac-backup) with the new
    /// one, keeping the same schedule and pointing at this binary. Returns what it did.
    /// The caller makes sure no backup is running: bootout stops the job's processes.
    static func migrateLegacyAgent(home: String = AppIdentity.home) -> String? {
        let legacy = home + "/Library/LaunchAgents/\(AppIdentity.legacyLaunchAgentLabel).plist"
        guard let dict = NSDictionary(contentsOfFile: legacy) as? [String: Any] else { return nil }
        let interval = dict["StartInterval"] as? Int
        let hour = (dict["StartCalendarInterval"] as? [String: Any])?["Hour"] as? Int
        _ = runLaunchctl(arguments: ["bootout", "gui/\(getuid())/\(AppIdentity.legacyLaunchAgentLabel)"])
        try? FileManager.default.removeItem(atPath: legacy)
        do {
            if let interval {
                try installSchedule(plistContent: generatePlist(intervalSeconds: interval))
                return "pianificazione spostata: ogni \(interval / 60) min"
            } else if let hour {
                try installSchedule(plistContent: generatePlistDaily(hour: hour))
                return "pianificazione spostata: ogni giorno alle \(hour)"
            }
            return "vecchia pianificazione rimossa"
        } catch {
            Log.error("Schedule migration failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func runLaunchctl(arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do { try process.run() } catch { return (1, "", error.localizedDescription) }
        process.waitUntilExit()

        let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func scheduleError(_ message: String) -> NSError {
        NSError(domain: "ScheduleManager", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
