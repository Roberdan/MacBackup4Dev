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
        /// Copies whose source is gone but that stay: they hold files git ignores that nothing else
        /// has, or git could not say what they hold. Listed, so nobody loses them unseen.
        var kept: [KeptCopy] = []
        /// Copies left for the next backup because the time allowed for looking at them ran out.
        var deferred = 0
    }

    struct KeptCopy: Equatable {
        enum Reason: Equatable { case ignoredFiles([String]), unverified(String) }
        let path: String
        let reason: Reason
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

    static func cleanup(at destination: URL,
                        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                        scanBudget: TimeInterval = WorktreePolicy.scanBudget, searchAgain: Bool = false,
                        maxFolders: Int = .max, cancelled: () -> Bool = { false }) throws -> CleanupResult {
        try RetentionManager.validateDestination(destination)
        let lock = try DestinationLock(at: destination)
        return try withExtendedLifetime(lock) {
            try cleanupLocked(at: destination, home: home, scanBudget: scanBudget, searchAgain: searchAgain,
                              maxFolders: maxFolders, cancelled: cancelled)
        }
    }

    private enum CopyState { case vanished, keep, obsolete(repository: URL) }

    /// Only disposable linked checkouts are removed, never repository history or live data.
    /// `searchAgain` (an explicit request) ignores what earlier searches remembered.
    /// `maxFolders` bounds a search the way the time does, for tests that need a small step.
    /// `skipping` names snapshots to leave alone: the backup that has just made one passes it.
    static func cleanupLocked(at destination: URL, home liveHome: String,
                              scanBudget: TimeInterval = WorktreePolicy.scanBudget, searchAgain: Bool = false,
                              maxFolders: Int = .max, skipping: Set<String> = [],
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
        snapshots: for backup in backups {
            if cancelled() { break snapshots }
            if skipping.contains(backup.name) { continue }
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
                let outcome = search(backup.url, from: searchAgain ? nil : manifest.worktreeSearch,
                                     until: deadline, maxFolders: maxFolders, cancelled: cancelled)
                switch outcome {
                case .unfinished(let progress):
                    // Out of time (or stopped): keep what the search has seen, continue next time.
                    manifest.worktreeSearch = progress
                    do { try manifest.write(to: backup.url) }
                    catch { Log.warn("Worktree search of \(backup.name) not saved; it restarts next time: \(error.localizedDescription)") }
                    result.unsearched += 1
                    if cancelled() { break snapshots }
                    continue snapshots
                case .finished(let found):
                    known = found
                    manifest.worktreeSearch = nil
                    searched = true
                }
            } else {
                continue
            }
            var remaining = known
            if searched { manifest.retainedWorktreeCopies = nil }
            var retained = manifest.retainedWorktreeCopies ?? []
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
                case .obsolete(let repository):
                    guard Date() < deadline, !cancelled() else { result.deferred += 1; continue }
                    let allowed = max(5, min(60, deadline.timeIntervalSinceNow))
                    switch WorktreeContents.inspect(copy: candidate, repository: repository, timeout: allowed, cancelled: cancelled) {
                    case .disposable:
                        break
                    case .holdsIgnoredFiles(let sample):
                        // Not a cache: possibly the only copy of files that are in no commit. Kept for
                        // good (not looked at again) and listed.
                        remaining.removeAll { $0 == relative }
                        retained.append(relative)
                        manifest.retainedWorktreeCopies = retained
                        result.kept.append(.init(path: backup.name + "/" + relative, reason: .ignoredFiles(sample)))
                        Log.warn("Worktree copy kept: \(backup.name)/\(relative) holds files git ignores that may exist nowhere else: \(sample.joined(separator: ", "))")
                        continue
                    case .unverified(let why):
                        result.kept.append(.init(path: backup.name + "/" + relative, reason: .unverified(why)))
                        Log.warn("Worktree copy kept: \(backup.name)/\(relative) cannot be examined: \(why)")
                        continue
                    }
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
        if result.deferred > 0 { Log.info("Worktree cleanup: \(result.deferred) copies left for the next backup (time ran out)") }
        if !result.removed.isEmpty { EncryptedStore.markSpaceFreed(destination: destination) }
        return result
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
            && isMissing(URL(fileURLWithPath: "/" + relative)) ? .obsolete(repository: main) : .keep
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// ENOENT proves absence only where the place the path would be in can be reached: a link to an
    /// unplugged disk, or a folder that cannot be read, makes the path "not found" just the same.
    /// So the nearest folder that exists above it must be a real, reachable directory.
    private static func isMissing(_ url: URL) -> Bool {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 { return false }
        guard errno == ENOENT else {
            Log.warn("Worktree copy retained: cannot verify source \(url.path), errno \(errno)")
            return false
        }
        var ancestor = url.deletingLastPathComponent().path
        while true {
            if lstat(ancestor, &metadata) == 0 {
                var reached = stat()
                let isDirectory = metadata.st_mode & S_IFMT == S_IFLNK
                    ? stat(ancestor, &reached) == 0 && reached.st_mode & S_IFMT == S_IFDIR
                    : metadata.st_mode & S_IFMT == S_IFDIR
                if !isDirectory { Log.warn("Worktree copy retained: \(ancestor) cannot be reached to verify \(url.path)") }
                return isDirectory
            }
            guard errno == ENOENT, ancestor != "/" else { return false }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
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
