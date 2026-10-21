import Foundation

struct ScheduleStatus {
    let installed: Bool
    let intervalMinutes: Int?
    let dailyHour: Int?
    /// Wall-clock start times (minutes after midnight, sorted). Empty for a launchd
    /// StartInterval, whose next run depends on when the job was loaded.
    var slots: [Int] = []

    /// The next automatic start after `now`, or nil when it cannot be known exactly.
    func nextRun(after now: Date, calendar: Calendar = .current) -> Date? {
        guard installed, !slots.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for minute in slots {
                if let date = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day),
                   date > now { return date }
            }
        }
        return nil
    }
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
        if let slots = calendarSlots(intervalSeconds: intervalSeconds) {
            let entries = slots.indices.map { index in
                let minute = index * (intervalSeconds / 60)
                return """
                <dict>
                    <key>Hour</key><integer>\(minute / 60)</integer>
                    <key>Minute</key><integer>\(minute % 60)</integer>
                </dict>
                """
            }.joined(separator: "\n")
            return generatePlistBody("""
                <key>StartCalendarInterval</key>
                <array>
                    \(entries)
                </array>
            """)
        }
        return generatePlistBody("""
            <key>StartInterval</key>
            <integer>\(intervalSeconds)</integer>
        """)
    }

    private static func calendarSlots(intervalSeconds: Int) -> [[String: Int]]? {
        guard intervalSeconds > 0, intervalSeconds % 60 == 0, 86_400 % intervalSeconds == 0 else { return nil }
        return stride(from: 0, to: 1440, by: intervalSeconds / 60).map {
            ["Hour": $0 / 60, "Minute": $0 % 60]
        }
    }

    static func calendarPlist(from old: [String: Any]) -> [String: Any]? {
        guard old["StartCalendarInterval"] == nil,
              let interval = old["StartInterval"] as? Int,
              let slots = calendarSlots(intervalSeconds: interval) else { return nil }
        var new = old
        new.removeValue(forKey: "StartInterval")
        new["StartCalendarInterval"] = slots
        return new
    }

    /// App replacement can invalidate launchd's cached code requirement even when the job
    /// is still listed. Refresh its registration while holding the backup's operation lock.
    static func refreshScheduleRegistrationWhenIdle(
        destination: URL, path: URL = plistPath,
        jobIsRunning: () throws -> Bool = { try scheduleJobIsRunning() },
        install: (String) throws -> Void = { try installSchedule(plistContent: $0, beforeUnload: { try ensureScheduleJobIdle() }) }
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: path.path),
              FileManager.default.fileExists(atPath: destination.path) else { return false }
        let data = try Data(contentsOf: path)
        guard let old = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw scheduleError("Invalid backup schedule")
        }
        let migrated = calendarPlist(from: old)
        let converted = try PropertyListSerialization.data(fromPropertyList: migrated ?? old, format: .xml, options: 0)
        guard let xml = String(data: converted, encoding: .utf8) else {
            throw scheduleError("Cannot encode calendar schedule")
        }
        let operationLock = try DestinationLock(at: destination)
        defer { withExtendedLifetime(operationLock) {} }
        // A scheduled process can still be opening the encrypted store, before its lock.
        guard try !jobIsRunning() else { throw BackupError.lockExists }
        do {
            try install(xml)
        } catch BackupError.lockExists {
            // The job started after the first check: install stopped before unloading it.
            throw BackupError.lockExists
        } catch {
            let originalError = error
            guard let original = String(data: data, encoding: .utf8) else { throw originalError }
            do { try install(original) }
            catch { Log.error("Schedule rollback failed: \(error.localizedDescription)") }
            throw originalError
        }
        Log.info(migrated == nil ? "Backup schedule registration refreshed"
                 : "Backup schedule registration refreshed and migrated to fixed calendar times")
        return true
    }

    typealias LaunchctlRunner = ([String]) -> (status: Int32, stdout: String, stderr: String)

    /// True while launchd reports a process for the scheduled job. Errors other than
    /// "not loaded" are thrown: an unknown state must not be treated as idle.
    static func scheduleJobIsRunning(launchctl: LaunchctlRunner = { runLaunchctl(arguments: $0) }) throws -> Bool {
        let result = launchctl(["list", label])
        guard result.status == 0 else {
            if result.stderr.lowercased().contains("could not find service") { return false }
            throw scheduleError("Cannot inspect scheduled backup: \(result.stderr)")
        }
        return result.stdout.contains("\"PID\" = ")
    }

    /// Re-checked by the refresh right before `bootout`, which would kill a job that started
    /// after the first check. launchd offers no atomic "unload if idle": a job can still
    /// start between this `list` and the `bootout` (two launchctl calls, milliseconds apart).
    /// The backup's operation lock is held meanwhile, so such a job cannot write a snapshot.
    static func ensureScheduleJobIdle(launchctl: LaunchctlRunner = { runLaunchctl(arguments: $0) }) throws {
        guard try !scheduleJobIsRunning(launchctl: launchctl) else { throw BackupError.lockExists }
    }

    /// Readable text for a failed registration refresh; launchctl's raw error goes to the log.
    static let registrationRefreshFailureMessage =
        "I backup automatici potrebbero non partire dopo l'aggiornamento dell'app. "
        + "Apri il menu di MacBackup4Dev e scegli di nuovo la frequenza dei backup."

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

    /// `beforeUnload` runs right before an existing job is booted out; throwing there leaves
    /// the job and its plist untouched.
    static func installSchedule(plistContent: String, path: URL = plistPath,
                                logDirectory: URL = logPath.deletingLastPathComponent(),
                                launchctl: LaunchctlRunner = { runLaunchctl(arguments: $0) },
                                beforeUnload: () throws -> Void = {}) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        // F-11: Use bootout before re-installing to avoid stale service state
        if fm.fileExists(atPath: path.path) {
            try beforeUnload()
            _ = launchctl(["bootout", "gui/\(getuid())", path.path])
        }
        try plistContent.write(to: path, atomically: true, encoding: .utf8)
        // F-11: bootstrap/bootout replaces legacy load/unload on modern macOS
        let result = launchctl(["bootstrap", "gui/\(getuid())", path.path])
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

        return scheduleStatus(from: plist, installed: installed)
    }

    static func scheduleStatus(from plist: [String: Any], installed: Bool) -> ScheduleStatus {
        if let intervalSeconds = plist["StartInterval"] as? Int {
            return ScheduleStatus(installed: installed, intervalMinutes: intervalSeconds / 60, dailyHour: nil)
        }

        if let slots = plist["StartCalendarInterval"] as? [[String: Int]],
           !slots.isEmpty {
            var minutes: [Int] = []
            for slot in slots {
                guard Set(slot.keys) == Set(["Hour", "Minute"]),
                      let hour = slot["Hour"], (0..<24).contains(hour),
                      let minute = slot["Minute"], (0..<60).contains(minute) else {
                    return ScheduleStatus(installed: installed, intervalMinutes: nil, dailyHour: nil)
                }
                minutes.append(hour * 60 + minute)
            }
            minutes.sort()
            let gaps = minutes.indices.map { i in
                i + 1 < minutes.count ? minutes[i + 1] - minutes[i] : 1440 + minutes[0] - minutes[i]
            }
            if let interval = gaps.first, interval > 0, gaps.allSatisfy({ $0 == interval }) {
                return ScheduleStatus(installed: installed, intervalMinutes: interval, dailyHour: nil, slots: minutes)
            }
            return ScheduleStatus(installed: installed, intervalMinutes: nil, dailyHour: nil, slots: minutes)
        }

        if let schedule = plist["StartCalendarInterval"] as? [String: Any],
           let hour = schedule["Hour"] as? Int {
            let minute = schedule["Minute"] as? Int ?? 0
            return ScheduleStatus(installed: installed, intervalMinutes: nil, dailyHour: hour, slots: [hour * 60 + minute])
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
                <string>--scheduled</string>
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

    /// 4.0 rename, pure: the new LaunchAgent from a 3.x one. Everything the user had is kept
    /// (a wrapper such as `on-ac`, extra flags, interval or daily time, priority); only the
    /// label, the binary path and the log folder change, and the backup is marked
    /// `--scheduled` so the battery gate applies.
    static func migratedPlist(from old: [String: Any], binary: String) -> [String: Any] {
        var new = old
        new["Label"] = AppIdentity.launchAgentLabel
        if var args = old["ProgramArguments"] as? [String] {
            args = args.map { arg in
                arg.hasSuffix("/\(AppIdentity.legacyName).app/Contents/MacOS/\(AppIdentity.legacyName)")
                    || arg.hasSuffix("/\(AppIdentity.name).app/Contents/MacOS/\(AppIdentity.name)") ? binary : arg
            }
            if args.contains("backup") && !args.contains("--scheduled") { args.append("--scheduled") }
            new["ProgramArguments"] = args
        }
        for key in ["StandardOutPath", "StandardErrorPath"] {
            if let path = old[key] as? String {
                new[key] = path.replacingOccurrences(of: "/.local/share/rusty-mac-backup/", with: "/.local/share/macbackup4dev/")
            }
        }
        return new
    }

    /// 4.0 rename: replaces the 3.x LaunchAgent with the new one. The new one is installed and
    /// started FIRST; the old one is removed only if that worked, so a failure never leaves
    /// the Mac without a schedule. The caller makes sure no backup is running (bootout stops
    /// the job's processes).
    static func migrateLegacyAgent(home: String = AppIdentity.home) -> String? {
        let legacy = home + "/Library/LaunchAgents/\(AppIdentity.legacyLaunchAgentLabel).plist"
        guard let dict = NSDictionary(contentsOfFile: legacy) as? [String: Any] else { return nil }
        let target = home + "/Library/LaunchAgents/\(AppIdentity.launchAgentLabel).plist"
        let newDict = migratedPlist(from: dict, binary: binaryPath)
        let domain = "gui/\(getuid())"
        do {
            try FileManager.default.createDirectory(atPath: AppIdentity.dataDir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: newDict, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: target), options: .atomic)
        } catch {
            Log.error("Schedule migration: cannot write \(target): \(error.localizedDescription)")
            return nil
        }
        _ = runLaunchctl(arguments: ["bootout", "\(domain)/\(AppIdentity.launchAgentLabel)"])
        let started = runLaunchctl(arguments: ["bootstrap", domain, target])
        guard started.status == 0 else {
            Log.error("Schedule migration: new agent did not start (\(started.stderr)); old one kept")
            try? FileManager.default.removeItem(atPath: target)
            return nil
        }
        _ = runLaunchctl(arguments: ["bootout", "\(domain)/\(AppIdentity.legacyLaunchAgentLabel)"])
        try? FileManager.default.removeItem(atPath: legacy)
        if let seconds = dict["StartInterval"] as? Int { return "pianificazione spostata: ogni \(seconds / 60) min" }
        if let hour = (dict["StartCalendarInterval"] as? [String: Any])?["Hour"] as? Int { return "pianificazione spostata: ogni giorno alle \(hour)" }
        return "pianificazione spostata"
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
