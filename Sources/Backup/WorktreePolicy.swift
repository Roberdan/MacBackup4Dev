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
                        home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> CleanupResult {
        try RetentionManager.validateDestination(destination)
        let lock = try DestinationLock(at: destination)
        return try withExtendedLifetime(lock) { try cleanupLocked(at: destination, home: home) }
    }

    /// Only disposable linked checkouts are removed, never repository history or live data.
    static func cleanupLocked(at destination: URL, home: String) throws -> CleanupResult {
        let fm = FileManager.default
        let liveRoot = URL(fileURLWithPath: home).appendingPathComponent("GitHub")
        guard isRealDirectory(liveRoot) else { return CleanupResult() }
        let backups = try RetentionManager.readBackups(at: destination)
        if let latest = backups.first, SnapshotManifest.read(from: latest.url)?.shrinkWarning != nil {
            Log.warn("Worktree cleanup deferred: the newest backup reports an emptied Mac")
            return CleanupResult()
        }
        let before = BackupEngine.diskFreeSpace(at: destination.path)
        var result = CleanupResult()
        for backup in backups {
            guard var manifest = SnapshotManifest.read(from: backup.url),
                  manifest.host == (Host.current().localizedName ?? ProcessInfo.processInfo.hostName) else { continue }
            let metadata = backup.url.appendingPathComponent(SnapshotManifest.directoryName)
            guard isRealDirectory(metadata) else { continue }
            for record in manifest.removedTemporaryWorktrees ?? [] {
                let prefix = ".obsolete-worktree-"
                guard record.stagingName.hasPrefix(prefix),
                      UUID(uuidString: String(record.stagingName.dropFirst(prefix.count))) != nil else { continue }
                let staged = metadata.appendingPathComponent(record.stagingName)
                if isRealDirectory(staged) { try fm.removeItem(at: staged) }
            }
            let root = backup.url.appendingPathComponent("GitHub")
            guard isRealDirectory(root) else { continue }
            let candidates = try obsoleteCopies(in: root, liveRoot: liveRoot, repositoryRoot: liveRoot, depth: 0)
            for candidate in candidates {
                let relative = "GitHub/" + String(candidate.path.dropFirst(root.path.count + 1))
                let live = URL(fileURLWithPath: home).appendingPathComponent(relative)
                guard isMissing(live), gitDirectory(of: candidate) != nil else { continue }
                let record = Removal(path: relative, bytes: try allocatedBytes(in: candidate),
                    reason: "Linked git worktree: exact live source is absent (ENOENT).",
                    removedAt: ISO8601DateFormatter().string(from: Date()),
                    stagingName: ".obsolete-worktree-" + UUID().uuidString)
                let staged = metadata.appendingPathComponent(record.stagingName)
                try fm.moveItem(at: candidate, to: staged)
                manifest.removedTemporaryWorktrees = (manifest.removedTemporaryWorktrees ?? []) + [record]
                do {
                    try manifest.write(to: backup.url)
                } catch {
                    do { try fm.moveItem(at: staged, to: candidate) }
                    catch {
                        Log.error("Worktree cleanup rollback failed; preserved copy at \(staged.path): \(error.localizedDescription)")
                    }
                    throw error
                }
                // Unlink only: chmod would mutate regular files shared with other snapshots.
                try fm.removeItem(at: staged)
                result.removed.append(backup.name + "/" + relative)
                Log.info("Removed obsolete worktree copy: \(backup.name)/\(relative), \(record.bytes) allocated bytes; \(record.reason)")
            }
        }
        let after = BackupEngine.diskFreeSpace(at: destination.path)
        result.freedBytes = after > before ? after - before : 0
        if !result.removed.isEmpty { EncryptedStore.markSpaceFreed(destination: destination) }
        return result
    }

    private static func obsoleteCopies(in directory: URL, liveRoot: URL,
                                       repositoryRoot: URL, depth: Int) throws -> [URL] {
        if let gitDirectory = gitDirectory(of: directory) {
            // A missing/unmounted main repository is not proof that its work is disposable.
            let common = URL(fileURLWithPath: gitDirectory).deletingLastPathComponent().deletingLastPathComponent()
            guard common.path.hasPrefix(repositoryRoot.path + "/"), isRealDirectory(common) else {
                Log.warn("Worktree copy retained: main repository cannot be verified at \(common.path)")
                return []
            }
            return isMissing(liveRoot) ? [directory] : []
        }
        guard depth < 4 else { return [] }
        let children = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var found: [URL] = []
        for child in children where child.lastPathComponent != ".git" {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            // Main repositories need only their conventional worktree containers inspected.
            if isRealDirectory(directory.appendingPathComponent(".git")),
               !["worktrees", ".worktrees"].contains(child.lastPathComponent) { continue }
            found += try obsoleteCopies(in: child, liveRoot: liveRoot.appendingPathComponent(child.lastPathComponent),
                                        repositoryRoot: repositoryRoot, depth: depth + 1)
        }
        return found
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
