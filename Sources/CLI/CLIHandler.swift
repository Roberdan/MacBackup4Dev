import Foundation
import Darwin
import UserNotifications

enum CLIHandler {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static func run(args: [String], config: Config? = nil) {
        _ = config
        var configPath: String?
        var commandArgs = args
        if let idx = commandArgs.firstIndex(of: "-c") ?? commandArgs.firstIndex(of: "--config") {
            guard idx + 1 < commandArgs.count else {
                printError("Missing path after -c/--config")
                exit(1)
            }
            configPath = commandArgs[idx + 1]
            commandArgs.removeSubrange(idx...idx + 1)
        }

        guard let command = commandArgs.first else { printUsage(); exit(1) }
        let subArgs = Array(commandArgs.dropFirst())

        do {
            switch command {
            case "version", "--version", "-v": print("RustyMacBackup v\(version)")
            case "help", "--help", "-h": printUsage()
            case "init": try runInit(configPath: configPath)
            case "backup": try runBackup(configPath: configPath)
            case "stop": try runStop(configPath: configPath)
            case "status": try runStatus(configPath: configPath)
            case "prune": try runPrune(subArgs: subArgs, configPath: configPath)
            case "list": try runList(configPath: configPath)
            case "restore": try runRestore(subArgs: subArgs, configPath: configPath)
            case "config": try runConfig(subArgs: subArgs, configPath: configPath)
            case "schedule": try runSchedule(subArgs: subArgs)
            case "discover": try runDiscover(subArgs: subArgs)
            case "errors": runErrors(subArgs: subArgs)
            case "snapshots": try runSnapshots(configPath: configPath)
            case "coverage": try runCoverage(subArgs: subArgs, configPath: configPath)
            case "versions": try runVersions(subArgs: subArgs, configPath: configPath)
            case "find": try runFind(subArgs: subArgs, configPath: configPath)
            case "topics": try runTopics(configPath: configPath)
            case "restore-topic": try runRestoreTopic(subArgs: subArgs, configPath: configPath)
            case "restore-file": try runRestoreFile(subArgs: subArgs, configPath: configPath)
            case "undo": try runUndo(subArgs: subArgs)
            case "new-mac": try runNewMac(subArgs: subArgs, configPath: configPath)
            case "measure-menu":
                MainActor.assumeIsolated { measureMenu() }
            case "render-menu":
                let dir = subArgs.first ?? FileManager.default.temporaryDirectory.path
                try MainActor.assumeIsolated { try renderMenu(to: dir) }
            default:
                printError("Unknown command: \(command)")
                printUsage()
                exit(1)
            }
            exit(0)
        } catch {
            printError(error.localizedDescription)
            exit(1)
        }
    }

    static func commandNeedsConfig(_ command: String) -> Bool {
        ["backup", "stop", "list", "status", "prune", "restore", "config", "schedule", "errors",
         "snapshots", "coverage", "versions", "find", "topics", "restore-topic", "restore-file", "new-mac"].contains(command)
    }

    static func printUsage() {
        print("""
        \(bold("RustyMacBackup v\(version) -- Safe Dev Config Backup"))

        Usage: RustyMacBackup [options] <command>

        Options:
          -c, --config <path>    Use custom config file

        Commands:
          init            Setup wizard (discovers dev tool configs)
          backup          Run backup now
          stop            Stop running backup
          status          Show backup status
          list            List backup snapshots
          prune           Clean up old backups (preview unless --yes)
                          --older-than 1m|6m|1y [--dry-run | --yes]
          restore         Restore from backup
          config          Manage configuration
          schedule        Manage backup schedule
          discover        Show detected dev tool configs
          discover add    Add custom discovery entry (portable across Macs)
          errors          Show backup errors

        Ripristino e sicurezza (3.0):
          snapshots                     Elenco snapshot: completo / incompleto / non verificato
          coverage [--days N]           Cartelle attive e database che il backup non salva
          versions <file>               Tutte le versioni di un file negli snapshot
          find <testo> [--snapshot S]   Cerca file in uno snapshot
          topics                        Argomenti ripristinabili (Warp, Terminale, Claude…)
          restore-topic <nome> [--snapshot S] [--yes]
          restore-file <file> [--snapshot S] [--to <cartella>] [--yes]
                                        Senza --yes mostra solo l'anteprima
          undo [cartella] [--file <file>]   Annulla l'ultimo ripristino, o un solo file
          new-mac [--snapshot S] [--steps config,repos,databases,homebrew,launch-agents]
                  [--agents label1,label2] [--yes]
                                        Ripristino guidato di un Mac nuovo
          version         Show version
          help            Show this help
        """)
    }

    /// Scheduled backups run this CLI, not the menu app: without this a failed night is silent.
    static func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let done = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in done.signal() }
        _ = done.wait(timeout: .now() + 3)
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data("\(red("Error")): \(message)\n".utf8))
    }

    private static func runDiscover(subArgs: [String]) throws {
        if subArgs.first == "add" {
            try runDiscoverAdd(subArgs: Array(subArgs.dropFirst()))
            return
        }

        let found = ConfigDiscovery.discover()
        if found.isEmpty {
            print("No dev tool configs detected.")
            return
        }
        print(bold("Detected dev tool configurations:\n"))
        var currentCategory = ""
        for item in found {
            if item.category != currentCategory {
                currentCategory = item.category
                print(bold(blue("  \(currentCategory)")))
            }
            let sens = item.sensitive ? yellow(" [sensitive]") : ""
            print("    \(item.label)\(sens)")
            for path in item.paths {
                print("      \(path)")
            }
        }
        print("")
        print("Custom discovery file: \(ConfigDiscovery.customDiscoveryPath.path)")
        print("Add custom entries: RustyMacBackup discover add \"Tool Name\" ~/.config/tool")
    }

    private static func runDiscoverAdd(subArgs: [String]) throws {
        guard subArgs.count >= 2 else {
            throw err("Usage: discover add \"Tool Name\" <path> [--category Cat] [--sensitive]")
        }
        let label = subArgs[0]
        let path = subArgs[1]

        // Safety check: never allow forbidden paths even in custom discovery
        if ConfigDiscovery.isForbidden(path) {
            throw err("Path is system-protected and cannot be backed up: \(path)")
        }
        let category = subArgs.firstIndex(of: "--category").flatMap {
            $0 + 1 < subArgs.count ? subArgs[$0 + 1] : nil
        } ?? "Custom"
        let sensitive = subArgs.contains("--sensitive")

        let url = ConfigDiscovery.customDiscoveryPath
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Create template if doesn't exist
        if !fm.fileExists(atPath: url.path) {
            try ConfigDiscovery.generateCustomTemplate()
                .write(to: url, atomically: true, encoding: .utf8)
        }

        let entry = """
        \n[\(label)]
        category = \(category)
        path = \(path)
        sensitive = \(sensitive)
        """
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(entry.utf8))
        handle.closeFile()

        print(green("Added custom discovery: \(label) -> \(path)"))
        print("File: \(url.path)")
    }

    private static func runBackup(configPath: String?) throws {
        let cfg = try loadConfig(configPath: configPath)
        let sem = DispatchSemaphore(value: 0)
        final class ErrorBox: @unchecked Sendable { var error: Error? }
        let box = ErrorBox()
        Task {
            do {
                if let r = try await BackupEngine.run(config: cfg) {
                    if r.manifest.complete {
                        print(green("Backup completo: \(r.snapshot.lastPathComponent) · \(r.manifest.filesProcessed) file"))
                    } else {
                        print(yellow("Backup INCOMPLETO: \(r.snapshot.lastPathComponent)"))
                        for reason in r.manifest.incompleteReasons { print("  - \(reason)") }
                        notify(title: "Backup incompleto", body: r.manifest.incompleteReasons.first ?? "Apri il menu per i dettagli.")
                    }
                }
            }
            catch {
                box.error = error
                notify(title: "Backup non riuscito", body: error.localizedDescription)
            }
            sem.signal()
        }
        sem.wait()
        if let err = box.error { throw err }
    }

    private static func runStop(configPath: String?) throws {
        let cfg = try loadConfig(configPath: configPath)
        let lockURL = URL(fileURLWithPath: cfg.destination.path).appendingPathComponent("rustymacbackup.lock")
        guard FileManager.default.fileExists(atPath: lockURL.path) else {
            print("No backup running."); return
        }
        let content = try String(contentsOf: lockURL, encoding: .utf8)
        guard let pid = parsePID(from: content) else {
            try? FileManager.default.removeItem(at: lockURL)
            print(green("Stale lock removed.")); return
        }
        if Darwin.kill(pid, 0) != 0 {
            try? FileManager.default.removeItem(at: lockURL)
            print(green("No active process (stale lock removed).")); return
        }
        if Darwin.kill(pid, SIGTERM) == 0 {
            print(green("Stop signal sent to backup (PID \(pid))."))
        } else {
            throw err("Cannot terminate process PID \(pid)")
        }
    }

    private static func runStatus(configPath: String?) throws {
        let cfg = try loadConfig(configPath: configPath)
        print(bold(blue("RustyMacBackup Status\n")))

        let statusURL = URL(fileURLWithPath: StatusWriter.statusPath)
        if FileManager.default.fileExists(atPath: statusURL.path),
           let data = try? Data(contentsOf: statusURL),
           let status = try? JSONDecoder().decode(BackupStatusFile.self, from: data) {
            switch status.state {
            case "running":
                print("State: \(yellow(bold("RUNNING")))")
                print("Progress: \(status.filesDone)/\(status.filesTotal) files")
                print("Speed: \(BackupEngine.formatBytes(status.bytesPerSec))/s")
            case "idle":
                print("State: \(green("IDLE"))")
                if !status.lastCompleted.isEmpty {
                    print("Last backup: \(status.lastCompleted)")
                    print("Duration: \(String(format: "%.1f", status.lastDurationSecs))s")
                    print("Files: \(status.filesTotal)")
                }
            case "error":
                print("State: \(red(bold("ERROR")))")
                print("Errors: \(status.errors)")
            default:
                print("State: \(status.state)")
            }
        } else {
            print(yellow("No status file found."))
        }

        print("")
        print(bold("Backup Folders"))
        for path in cfg.source.paths {
            let exists = FileManager.default.fileExists(atPath: ConfigDiscovery.expand(path))
            print("  \(exists ? green("*") : red("x")) \(path)")
        }

        print("")
        let diskInfo = DiskDiagnostics.diskSpace(at: cfg.destination.path)
        print(bold("Disk"))
        print("Volume: \(volumeDisplayName(path: cfg.destination.path))")
        print("Free: \(BackupEngine.formatBytes(diskInfo.free)) / \(BackupEngine.formatBytes(diskInfo.total))")

        let backups = RetentionManager.listBackups(at: URL(fileURLWithPath: cfg.destination.path))
        print("Snapshots: \(backups.count)")
    }

    private static func runPrune(subArgs: [String], configPath: String?) throws {
        let cfg = try loadConfig(configPath: configPath)
        let options = try PruneOptions.parse(subArgs)
        let dryRun = !options.confirmed
        let destination = URL(fileURLWithPath: cfg.destination.path)
        let pruned: [String]
        if let age = options.age {
            let cleanup = try SnapshotCleanup(at: destination, age: age)
            print("Destination: \(destination.path)")
            print("Before: \(cleanup.cutoff.formatted(date: .abbreviated, time: .standard))")
            print("Latest snapshot is always kept. Shared hard-linked data may not free space.")
            print("Free space: \(BackupEngine.formatBytes(cleanup.freeBytes))")
            for entry in cleanup.candidates { print("  \(entry.name)") }
            if dryRun {
                pruned = cleanup.candidates.map(\.name)
            } else {
                let result = try cleanup.execute()
                pruned = result.deleted
                print("Freed: \(BackupEngine.formatBytes(result.freedBytes)) "
                      + "(free now: \(BackupEngine.formatBytes(result.freeAfterBytes)))")
            }
        } else {
            pruned = try RetentionManager.pruneBackups(
                at: destination, policy: cfg.retention, dryRun: dryRun)
        }
        print(pruned.isEmpty ? green("Nothing to prune.") : "\(dryRun ? "Would prune" : "Pruned") \(pruned.count) backup(s)")
        if dryRun && !pruned.isEmpty { print("Preview only. Add --yes to permanently delete these snapshots.") }
    }

    private static func runList(configPath: String?) throws {
        let cfg = try loadConfig(configPath: configPath)
        let backups = RetentionManager.listBackups(at: URL(fileURLWithPath: cfg.destination.path))
        if backups.isEmpty { print("No backups found."); return }
        print(bold("Backups"))
        for b in backups {
            print("  \(b.name)  \(BackupEngine.formatBytes(RetentionManager.directorySize(at: b.url)))")
        }
        print("\n\(backups.count) backup(s)")
    }

    private static func runRestore(subArgs: [String], configPath: String?) throws {
        guard let snapshot = subArgs.first else {
            throw err("Usage: restore <snapshot> [path] --to <destination>")
        }
        var relativePath: String?
        var toPath: String?
        var i = 1
        while i < subArgs.count {
            if subArgs[i] == "--to" {
                guard i + 1 < subArgs.count else { throw err("Missing --to value") }
                toPath = subArgs[i + 1]; i += 2
            } else if relativePath == nil {
                relativePath = subArgs[i]; i += 1
            } else { throw err("Unexpected: \(subArgs[i])") }
        }

        let cfg = try loadConfig(configPath: configPath)
        let snapshotURL = URL(fileURLWithPath: cfg.destination.path).appendingPathComponent(snapshot)
        let operationLock = try DestinationLock(at: URL(fileURLWithPath: cfg.destination.path))
        defer { withExtendedLifetime(operationLock) {} }
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            throw err("Snapshot not found: \(snapshot)")
        }

        let sourceURL = relativePath.map { snapshotURL.appendingPathComponent($0) } ?? snapshotURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw err("Path not found in snapshot: \(relativePath ?? ".")")
        }

        // Restrict restore to home directory by default
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let destBase: URL
        if let tp = toPath {
            let expanded = expandPath(tp)
            guard expanded.hasPrefix(home) else {
                throw err("Restore destination must be within your home directory")
            }
            destBase = URL(fileURLWithPath: expanded)
        } else {
            destBase = URL(fileURLWithPath: home)
        }

        let destURL = resolvedDest(source: sourceURL, dest: destBase)
        guard !FileManager.default.fileExists(atPath: destURL.path) else {
            throw err("Destination already exists: \(destURL.path)")
        }

        try FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        print(green("Restored: \(destURL.path)"))
    }

    private static func runConfig(subArgs: [String], configPath: String?) throws {
        guard let action = subArgs.first else {
            throw err("Usage: config <show|add|remove|excludes|retention|edit>")
        }
        let pathURL = URL(fileURLWithPath: configPath.map(expandPath) ?? Config.defaultPath.path)

        switch action {
        case "show":
            let cfg = try loadConfig(configPath: configPath)
            print(bold("Config: \(pathURL.path)\n"))
            print(bold(blue("[source]")))
            print("paths = [")
            for p in cfg.source.paths { print("  \"\(p)\",") }
            print("]\n")
            print(bold(blue("[destination]")))
            print("path = \"\(cfg.destination.path)\"\n")
            print(bold(blue("[exclude]")))
            for p in cfg.exclude.patterns { print("  \(p)") }
            print("")
            print(bold(blue("[retention]")))
            print("hourly=\(cfg.retention.hourly) daily=\(cfg.retention.daily) weekly=\(cfg.retention.weekly) monthly=\(cfg.retention.monthly)")

        case "add":
            guard subArgs.count >= 2 else { throw err("Usage: config add <path>") }
            var cfg = try loadConfig(configPath: configPath)
            let path = ConfigDiscovery.contract(expandPath(subArgs[1]))
            guard !ConfigDiscovery.isForbidden(path, allowCloudStorage: cfg.protection.includeCloudStorage) else {
                throw err("Path is system-protected: \(path)")
            }
            guard !cfg.source.paths.contains(path) else {
                print(yellow("Already in config: \(path)")); return
            }
            cfg.source.paths.append(path)
            try cfg.save(to: pathURL)
            print(green("Added: \(path)"))

        case "remove":
            guard subArgs.count >= 2 else { throw err("Usage: config remove <path>") }
            var cfg = try loadConfig(configPath: configPath)
            let path = subArgs[1]
            let old = cfg.source.paths.count
            cfg.source.paths.removeAll { $0 == path }
            guard cfg.source.paths.count < old else {
                print(yellow("Not found: \(path)")); return
            }
            try cfg.save(to: pathURL)
            print(green("Removed: \(path)"))

        case "edit":
            let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "nano"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [editor, pathURL.path]
            try p.run(); p.waitUntilExit()

        default:
            throw err("Unknown config action: \(action)")
        }
    }

    private static func runSchedule(subArgs: [String]) throws {
        guard let action = subArgs.first else {
            printScheduleStatus(ScheduleManager.scheduleStatus()); return
        }
        switch action {
        case "on":
            try ScheduleManager.installSchedule(plistContent: ScheduleManager.generatePlist(intervalSeconds: 3600))
            print(green("Schedule on: every 60 min"))
        case "off":
            try ScheduleManager.removeSchedule()
            print(green("Schedule off"))
        case "status":
            printScheduleStatus(ScheduleManager.scheduleStatus())
        case "interval":
            guard subArgs.count > 1, let m = Int(subArgs[1]) else { throw err("Usage: schedule interval <minutes>") }
            try ScheduleManager.installSchedule(plistContent: ScheduleManager.generatePlist(intervalSeconds: m * 60))
            print(green("Schedule: every \(m) min"))
        case "daily":
            guard subArgs.count > 1, let h = Int(subArgs[1]), (0...23).contains(h) else {
                throw err("Usage: schedule daily <hour 0-23>")
            }
            try ScheduleManager.installSchedule(plistContent: ScheduleManager.generatePlistDaily(hour: h))
            print(green("Schedule: daily at \(h):00"))
        default: throw err("Unknown schedule action: \(action)")
        }
    }

    private static func runInit(configPath: String?) throws {
        let volumes = discoverVolumes()
        guard !volumes.isEmpty else {
            throw err("No external disk found. Connect a disk and retry.")
        }
        print("\nAvailable disks:")
        for (i, vol) in volumes.enumerated() {
            let space = DiskDiagnostics.diskSpace(at: vol.path)
            print("  \(i + 1). \(vol.lastPathComponent)  (\(space.free / 1_073_741_824) GB free)")
        }
        print("Select disk (1-\(volumes.count)): ", terminator: "")
        guard let raw = readLine(), let sel = Int(raw), (1...volumes.count).contains(sel) else {
            throw err("Invalid selection")
        }
        let backupDir = volumes[sel - 1].appendingPathComponent("RustyMacBackup")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let config = generateDefaultConfig(backupPath: backupDir.path)
        let configURL = URL(fileURLWithPath: configPath.map(expandPath) ?? Config.defaultPath.path)
        try config.save(to: configURL)
        print(green("Config saved: \(configURL.path)"))
        print("\nBacking up \(config.source.paths.count) paths:")
        for p in config.source.paths { print("  \(p)") }
        print("\nRun 'RustyMacBackup backup' to start.")
    }

    private static func runErrors(subArgs: [String]) {
        let showAll = subArgs.contains("--all")
        guard FileManager.default.fileExists(atPath: StatusWriter.errorPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: StatusWriter.errorPath)),
              let errorFile = try? JSONDecoder().decode(BackupErrorFile.self, from: data) else {
            print("No errors recorded."); return
        }
        print(ErrorReporter.formatActionableMessage(error: errorFile))
        if showAll {
            for (cat, info) in errorFile.categories where info.count > 0 {
                print("\n\(cat):")
                for file in info.files { print("  \(file)") }
            }
        }
    }

    // MARK: - Helpers

    static func discoverVolumes() -> [URL] {
        let fm = FileManager.default
        guard let volumes = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]) else { return [] }
        return volumes.filter { u in
            let p = u.path
            return p != "/" && p != "/System/Volumes/Data"
                && u.lastPathComponent != "Macintosh HD" && p.hasPrefix("/Volumes/")
        }
    }

    private static func printScheduleStatus(_ s: ScheduleStatus) {
        if !s.installed { print("Schedule: off"); return }
        if let m = s.intervalMinutes { print("Schedule: every \(m) min") }
        else if let h = s.dailyHour { print("Schedule: daily at \(h):00") }
        else { print("Schedule: on") }
    }

    static func loadConfig(configPath: String?) throws -> Config {
        try Config.load(from: configPath.map { URL(fileURLWithPath: expandPath($0)) } ?? Config.defaultPath)
    }

    private static func parsePID(from content: String) -> Int32? {
        for line in content.split(separator: "\n") {
            let part = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if part.hasPrefix("pid:") {
                return Int32(part.replacingOccurrences(of: "pid:", with: "").trimmingCharacters(in: .whitespaces))
            } else if let v = Int32(part) { return v }
        }
        return nil
    }

    private static func resolvedDest(source: URL, dest: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
            return dest.appendingPathComponent(source.lastPathComponent)
        }
        return dest
    }

    private static func volumeDisplayName(path: String) -> String {
        let c = URL(fileURLWithPath: path).pathComponents
        return c.count > 2 && c[1] == "Volumes" ? c[2] : URL(fileURLWithPath: path).lastPathComponent
    }

    static func expandPath(_ p: String) -> String { (p as NSString).expandingTildeInPath }
    static func err(_ msg: String) -> NSError {
        NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    static func colored(_ t: String, _ c: String) -> String {
        isatty(STDOUT_FILENO) != 0 ? "\u{001B}[\(c)m\(t)\u{001B}[0m" : t
    }
    static func green(_ t: String) -> String { colored(t, "32") }
    static func red(_ t: String) -> String { colored(t, "31") }
    static func yellow(_ t: String) -> String { colored(t, "33") }
    static func blue(_ t: String) -> String { colored(t, "34") }
    static func bold(_ t: String) -> String { colored(t, "1") }
}
