import Foundation
import Darwin

// MARK: - Utility helpers for BackupEngine

extension BackupEngine {

    // F-03: Verify via mountedVolumeURLs — statfs() passes on stale /Volumes/ mountpoints
    // that point to internal disk paths, causing backup to silently target the wrong disk.
    static func isVolumeReallyMounted(_ path: String) -> Bool {
        // Hidden volumes included: the encrypted store is mounted "nobrowse" (not in the Finder).
        guard let vols = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []) else { return false }
        let target = URL(fileURLWithPath: path).standardized.path
        return vols.contains { vol in
            let vp = vol.standardized.path
            if target.hasPrefix("/Volumes/") && !vp.hasPrefix("/Volumes/") { return false }
            return target == vp || target.hasPrefix(vp == "/" ? vp : vp + "/")
        }
    }

    static func preflightWriteTest(at destURL: URL) -> Bool {
        let testURL = destURL.appendingPathComponent(".rustymacbackup-write-test-\(Int.random(in: 0...999_999))")
        do {
            try "test".write(to: testURL, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: testURL)
            return true
        } catch {
            return false
        }
    }

    // F-01: Check age (>2h) and active lock before removing — avoids deleting dirs
    // that belong to a concurrent backup that hasn't yet acquired the lock.
    static func cleanStaleInProgress(at destURL: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: destURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: []) else { return }
        let staleThreshold: TimeInterval = 2 * 3600
        let lockPath = destURL.appendingPathComponent("rustymacbackup.lock").path
        let activePID: Int32? = {
            guard let content = try? String(contentsOfFile: lockPath, encoding: .utf8) else { return nil }
            let first = content.split(separator: "\n").first.map(String.init) ?? content
            return Int32(first.trimmingCharacters(in: .whitespaces))
        }()
        for url in contents where url.lastPathComponent.hasPrefix("in-progress-") {
            let values = try? url.resourceValues(forKeys: [.creationDateKey])
            let age = Date().timeIntervalSince(values?.creationDate ?? .distantPast)
            guard age > staleThreshold else { continue }
            if let pid = activePID, Darwin.kill(pid, 0) == 0 { continue }
            try? FileManager.default.removeItem(at: url)
            Log.info("Cleaned stale in-progress dir: \(url.lastPathComponent)")
        }
    }

    static func diskFreeSpace(at path: String) -> UInt64 {
        var buf = statfs()
        guard statfs(path, &buf) == 0 else { return 0 }
        return buf.f_bavail * UInt64(buf.f_bsize)
    }

    static func findLatestBackup(at destURL: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: destURL, includingPropertiesForKeys: nil) else { return nil }
        // Match YYYY-MM-DD_HHMMSS format
        let candidates = contents.filter { url in
            let name = url.lastPathComponent
            guard name.count == 17 else { return false }
            let parts = name.split(separator: "_", maxSplits: 1)
            return parts.count == 2 && parts[0].count == 10 && parts[1].count == 6
                && parts[0].allSatisfy({ $0.isNumber || $0 == "-" })
                && parts[1].allSatisfy({ $0.isNumber })
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return candidates.last
    }

    // F-01: Lock file format: "PID\nTIMESTAMP\nSESSION_UUID" — richer stale detection.
    static func acquireLock(at path: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let first = content.split(separator: "\n").first.map(String.init) ?? content
                if let pid = Int32(first.trimmingCharacters(in: .whitespaces)),
                   Darwin.kill(pid, 0) == 0 {
                    throw BackupError.lockExists
                }
            }
            try? fm.removeItem(atPath: path)
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let content = "\(pid)\n\(ISO8601DateFormatter().string(from: Date()))\n\(UUID().uuidString)"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // F-06: Delegate to ErrorReporter — semantic keys (permission_denied, not_found, etc.)
    // Removed duplicate categorizeErrors() that used Swift type names as keys.

    static func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        if bytes >= 1_048_576    { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1_024        { return String(format: "%.1f KB", Double(bytes) / 1_024) }
        return "\(bytes) B"
    }

    static func processFile(entry: FileEntry, destFile: String, prevFile: String?,
                            protectionGuard: RightsManagementGuard = RightsManagementGuard(),
                            directories: BackupDirectories = BackupDirectories()) async -> FileResult {
        // Apply the user's exclusion before both hard links and copies. Old snapshots
        // remain untouched, but excluded files must not enter a new snapshot.
        do {
            if let reason = try protectionGuard.skipReason(forFileAt: entry.absolutePath) {
                if reason.hasPrefix("Protection inspection failed") {
                    Log.warn("\(entry.relativePath): \(reason)")
                }
                return .skipped(path: entry.relativePath, reason: reason)
            }
        } catch {
            return .error(path: entry.relativePath, error: error)
        }

        let fm = FileManager.default
        let destDir = URL(fileURLWithPath: destFile).deletingLastPathComponent().path
        do {
            try directories.prepare(destDir)
        } catch {
            return .error(path: entry.relativePath, error: error)
        }

        // Attempt hard link from previous backup
        if let prev = prevFile,
           HardLinker.shouldHardLink(sourcePath: entry.absolutePath, sourceSize: entry.size,
                                     sourceMtime: entry.mtime, previousBackupPath: prev) {
            if (try? HardLinker.hardLink(from: prev, to: destFile)) != nil {
                return .hardlinked
            }
        }

        // Fall back to a copy without clone flags.
        func copy() throws -> FileResult {
            try HardLinker.copyFile(from: entry.absolutePath, to: destFile)
            HardLinker.preserveModificationTime(at: destFile, mtime: entry.mtime)
            return .copied(bytes: entry.size)
        }
        do {
            return try copy()
        } catch {
            directories.invalidate(destDir)
            guard !fm.fileExists(atPath: destDir) else {
                return .error(path: entry.relativePath, error: error)
            }
            do {
                try directories.prepare(destDir)
                return try copy()
            } catch {
                directories.invalidate(destDir)
                return .error(path: entry.relativePath, error: error)
            }
        }
    }

    static func processResult(_ result: FileResult, stats: inout BackupStats,
                               errors: inout [(path: String, error: Error)],
                               skips: inout [(path: String, reason: String)]) {
        switch result {
        case .hardlinked:
            stats.filesHardlinked += 1
        case .copied(let bytes):
            stats.filesCopied += 1
            stats.bytesCopied += bytes
        case .skipped(let path, let reason):
            stats.filesSkipped += 1
            skips.append((path: path, reason: reason))
        case .error(let path, let err):
            // The exact reason per file: "permesso negato" alone cannot be acted upon.
            if errors.count < 200 { Log.warn("Not copied: \(path): \(err.localizedDescription)") }
            errors.append((path: path, error: err))
        }
    }

    /// Check if iCloud Desktop & Documents sync is enabled.
    static func isiCloudDesktopActive() -> Bool {
        let desktop = UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "FXICloudDriveDesktop") ?? false
        let docs = UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "FXICloudDriveDocuments") ?? false
        return desktop || docs
    }
}
