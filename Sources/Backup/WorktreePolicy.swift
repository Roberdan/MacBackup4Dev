import Foundation
import Darwin

enum WorktreePolicy {
    struct Removal: Codable, Equatable {
        let path: String
        let bytes: UInt64
        let reason: String
        let removedAt: String
        let stagingName: String
    }

    struct CleanupResult {
        var removed: [String] = []
        var freedBytes: UInt64 = 0
        /// Old snapshots still to search because the time allowed for it ran out.
        var unsearched = 0
    }

    static func gitDirectory(of directory: URL) -> String? {
        let marker = directory.appendingPathComponent(".git")
        guard let values = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size < 4_096,
              let text = try? String(contentsOf: marker, encoding: .utf8),
              let first = text.split(separator: "\n").first, first.hasPrefix("gitdir: ") else { return nil }
        let path = String(first.dropFirst("gitdir: ".count))
        let parts = path.components(separatedBy: "/")
        guard path.hasPrefix("/"), !parts.contains(".."), !parts.contains("."),
              parts.count >= 4, parts[parts.count - 3] == ".git",
              parts[parts.count - 2] == "worktrees", parts.last?.isEmpty == false else { return nil }
        return path
    }

    static func isTemporarySource(_ path: String, home: String) -> Bool {
        let components = path.split(separator: "/")
        if components.contains("worktrees") || components.contains(".worktrees") { return true }
        var url = URL(fileURLWithPath: path)
        while url.path.hasPrefix(home + "/") {
            if gitDirectory(of: url) != nil { return true }
            url.deleteLastPathComponent()
        }
        return false
    }

    /// Snapshots made before 4.3.0 can hold saved checkouts of linked worktrees; the scanner
    /// has refused them ever since, so later snapshots are never searched.
    static let firstVersionWithoutCopies = "4.3.0"
    /// Seconds a backup may spend searching old snapshots for marked copies; the search resumes
    /// at the next backup, one snapshot at a time, because every searched snapshot is remembered.
    static let scanBudget: TimeInterval = 30

    static func cleanup(at destination: URL,
                        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                        scanBudget: TimeInterval = WorktreePolicy.scanBudget, searchAgain: Bool = false,
                        cancelled: () -> Bool = { false }) throws -> CleanupResult {
        try RetentionManager.validateDestination(destination)
        let lock = try DestinationLock(at: destination)
        return try withExtendedLifetime(lock) {
            try cleanupLocked(at: destination, home: home, scanBudget: scanBudget,
                              searchAgain: searchAgain, cancelled: cancelled)
        }
    }

    private enum CopyState { case vanished, keep, obsolete }

    /// Only disposable linked checkouts are removed, never repository history or live data.
    /// `searchAgain` (an explicit request) ignores what earlier searches remembered.
    static func cleanupLocked(at destination: URL, home liveHome: String,
                              scanBudget: TimeInterval = WorktreePolicy.scanBudget, searchAgain: Bool = false,
                              cancelled: () -> Bool = { false }) throws -> CleanupResult {
        let fm = FileManager.default
        let home = liveHome.count > 1 && liveHome.hasSuffix("/") ? String(liveHome.dropLast()) : liveHome
        guard isRealDirectory(URL(fileURLWithPath: home)) else { return CleanupResult() }
        let backups = try RetentionManager.readBackups(at: destination)
        if let latest = backups.first, SnapshotManifest.read(from: latest.url)?.shrinkWarning != nil {
            Log.warn("Worktree cleanup deferred: the newest backup reports an emptied Mac")
            return CleanupResult()
        }
        let before = BackupEngine.diskFreeSpace(at: destination.path)
        let deadline = Date().addingTimeInterval(scanBudget)
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        var result = CleanupResult()
        for backup in backups {
            if cancelled() { break }
            guard var manifest = SnapshotManifest.read(from: backup.url), manifest.host == host else { continue }
            let metadata = backup.url.appendingPathComponent(SnapshotManifest.directoryName)
            guard isRealDirectory(metadata) else { continue }
            for record in manifest.removedTemporaryWorktrees ?? [] {
                let prefix = ".obsolete-worktree-"
                guard record.stagingName.hasPrefix(prefix),
                      UUID(uuidString: String(record.stagingName.dropFirst(prefix.count))) != nil else { continue }
                let staged = metadata.appendingPathComponent(record.stagingName)
                if isRealDirectory(staged) { try fm.removeItem(at: staged) }
            }
            let known: [String]
            var searched = false
            if !searchAgain, let remembered = manifest.temporaryWorktreeCopies {
                known = remembered
            } else if mayHoldCopies(manifest) {
                guard Date() < deadline else { result.unsearched += 1; continue }
                guard let found = markedCopies(in: backup.url, cancelled: cancelled) else { break }
                known = found
                searched = true
            } else {
                continue
            }
            var remaining = known
            let snapshotRoot = FileScanner.realPath(backup.url.path)
            for relative in known {
                guard isSafeRelative(relative) else {
                    Log.warn("Worktree search of \(backup.name): ignoring the remembered path \(relative)")
                    remaining.removeAll { $0 == relative }
                    continue
                }
                let candidate = backup.url.appendingPathComponent(relative)
                switch assess(candidate, relative: relative, in: snapshotRoot, home: home, reportUnverified: searched) {
                case .keep: continue
                case .vanished: remaining.removeAll { $0 == relative }
                case .obsolete:
                    let record = Removal(path: relative, bytes: try allocatedBytes(in: candidate),
                        reason: "Linked git worktree: exact live source is absent (ENOENT).",
                        removedAt: ISO8601DateFormatter().string(from: Date()),
                        stagingName: ".obsolete-worktree-" + UUID().uuidString)
                    let staged = metadata.appendingPathComponent(record.stagingName)
                    try fm.moveItem(at: candidate, to: staged)
                    manifest.removedTemporaryWorktrees = (manifest.removedTemporaryWorktrees ?? []) + [record]
                    manifest.temporaryWorktreeCopies = remaining.filter { $0 != relative }
                    do {
                        try manifest.write(to: backup.url)
                    } catch {
                        manifest.removedTemporaryWorktrees?.removeLast()
                        manifest.temporaryWorktreeCopies = remaining
                        do { try fm.moveItem(at: staged, to: candidate) }
                        catch {
                            Log.error("Worktree cleanup rollback failed; preserved copy at \(staged.path): \(error.localizedDescription)")
                        }
                        throw error
                    }
                    remaining.removeAll { $0 == relative }
                    // Unlink only: chmod would mutate regular files shared with other snapshots.
                    try fm.removeItem(at: staged)
                    result.removed.append(backup.name + "/" + relative)
                    Log.info("Removed obsolete worktree copy: \(backup.name)/\(relative), \(record.bytes) allocated bytes; \(record.reason)")
                }
            }
            if searched || manifest.temporaryWorktreeCopies != remaining {
                manifest.temporaryWorktreeCopies = remaining
                do { try manifest.write(to: backup.url) }
                catch { Log.warn("Worktree search of \(backup.name) not remembered; it is repeated next time: \(error.localizedDescription)") }
            }
            if searched {
                Log.info("Worktree search of \(backup.name): \(known.count) marked copies, \(remaining.count) kept")
            }
        }
        let after = BackupEngine.diskFreeSpace(at: destination.path)
        result.freedBytes = after > before ? after - before : 0
        if !result.removed.isEmpty { EncryptedStore.markSpaceFreed(destination: destination) }
        return result
    }

    static func mayHoldCopies(_ manifest: SnapshotManifest) -> Bool {
        AutoUpdater.isNewer(firstVersionWithoutCopies, than: manifest.appVersion)
    }

    /// Top-level folders of a snapshot that are not the user's files (the app's own data, other volumes).
    private static let reservedTopLevel: Set<String> = [SnapshotManifest.directoryName, "_environment", "Volumes"]

    /// Remembered paths come from a file: only plain paths inside the snapshot are ever acted on.
    static func isSafeRelative(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        return !relative.isEmpty && !relative.hasPrefix("/") && !relative.contains("\0")
            && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
            && !reservedTopLevel.contains(String(parts[0]))
    }

    /// Every saved checkout of a linked worktree in a snapshot, found by its marker wherever it sits.
    /// Nil when cancelled. Repository stores, links, the app's own folders and other volumes are not entered.
    static func markedCopies(in snapshot: URL, cancelled: () -> Bool) -> [String]? {
        var found: [String] = []
        var pending: [(url: URL, relative: String)] = [(snapshot, "")]
        while let (directory, relative) = pending.popLast() {
            if cancelled() { return nil }
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                Log.warn("Worktree search skipped an unreadable folder \(directory.path): \(error.localizedDescription)")
                continue
            }
            if !relative.isEmpty, children.contains(where: { $0.lastPathComponent == ".git" }),
               gitDirectory(of: directory) != nil {
                found.append(relative)
                continue
            }
            for child in children {
                let name = child.lastPathComponent
                if name == ".git" || (relative.isEmpty && reservedTopLevel.contains(name)) { continue }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                pending.append((child, relative.isEmpty ? name : relative + "/" + name))
            }
        }
        return found.sorted()
    }

    private static func assess(_ copy: URL, relative: String, in snapshotRoot: String, home: String,
                               reportUnverified: Bool) -> CopyState {
        // No link may lead out of the snapshot on the way to the copy.
        guard isRealDirectory(copy), FileScanner.realPath(copy.path) == snapshotRoot + "/" + relative,
              let gitDirectory = gitDirectory(of: copy) else { return .vanished }
        // A missing/unmounted main repository is not proof that its work is disposable.
        let main = URL(fileURLWithPath: gitDirectory).deletingLastPathComponent().deletingLastPathComponent()
        guard main.path.hasPrefix(home + "/"), isRealDirectory(main) else {
            if reportUnverified { Log.warn("Worktree copy retained: main repository cannot be verified at \(main.path)") }
            return .keep
        }
        // A snapshot path is relative to the home folder, or to / for sources outside it:
        // the copy is obsolete only when neither place exists.
        return isMissing(URL(fileURLWithPath: home + "/" + relative))
            && isMissing(URL(fileURLWithPath: "/" + relative)) ? .obsolete : .keep
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isMissing(_ url: URL) -> Bool {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 { return false }
        let code = errno
        if code != ENOENT { Log.warn("Worktree copy retained: cannot verify source \(url.path), errno \(code)") }
        return code == ENOENT
    }

    private static func allocatedBytes(in directory: URL) throws -> UInt64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var traversalError: Error?
        guard let walker = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
                traversalError = error
                return false
            }) else {
            throw BackupError.notWritable(directory.path)
        }
        var total: UInt64 = 0
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: keys)
            if values.isRegularFile == true, values.isSymbolicLink != true {
                total += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        }
        if let traversalError { throw traversalError }
        return total
    }
}
