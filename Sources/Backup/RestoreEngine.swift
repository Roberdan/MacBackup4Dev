import Foundation

// F-05: Manifest tracks exact paths overwritten during restore — enables safe undo.
private struct RestoreManifest: Codable {
    let overwritten: [String]  // relative paths from home
}

struct RestoreItem {
    let relativePath: String
    let absoluteSource: String
    let absoluteDest: String
    let isDirectory: Bool
    let size: UInt64
    let existsAtDest: Bool
}

struct RestoreResult {
    var restored: Int = 0
    var overwritten: Int = 0
    var failed: Int = 0
    var backedUpTo: String = ""
}

enum RestoreEngine {

    /// Pre-restore backup directory -- keeps copies of files before overwriting.
    static func preRestoreBackupDir() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".rustybackup-pre-restore/\(timestamp)")
    }

    /// Scan a backup snapshot and return top-level restorable items.
    static func scanSnapshot(at snapshotURL: URL) -> [RestoreItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        guard let contents = try? fm.contentsOfDirectory(
            at: snapshotURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        ) else { return [] }

        var items: [RestoreItem] = []
        for url in contents {
            let name = url.lastPathComponent
            if SelectiveRestore.internalDirectories.contains(name) { continue }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDir = values?.isDirectory ?? false
            let size = UInt64(values?.fileSize ?? 0)
            let dest = home + "/" + name
            let exists = fm.fileExists(atPath: dest)

            items.append(RestoreItem(
                relativePath: name,
                absoluteSource: url.path,
                absoluteDest: dest,
                isDirectory: isDir,
                size: size,
                existsAtDest: exists
            ))
        }
        return items.sorted { $0.relativePath < $1.relativePath }
    }

    /// Find backup snapshots on all connected volumes.
    static func findBackupSnapshots() -> [(volume: String, backupDir: URL, snapshots: [String])] {
        let fm = FileManager.default
        guard let volumes = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]) else { return [] }

        var results: [(volume: String, backupDir: URL, snapshots: [String])] = []
        for vol in volumes {
            let backupDir = vol.appendingPathComponent("RustyMacBackup")
            guard fm.fileExists(atPath: backupDir.path) else { continue }
            let snapshots = RetentionManager.listBackups(at: backupDir)
            if !snapshots.isEmpty {
                results.append((vol.lastPathComponent, backupDir,
                                snapshots.map(\.name)))
            }
        }
        return results
    }

    /// Estimate total bytes needed to restore the given items (sum of file sizes, recursive).
    /// Used for preflight free-space check before starting restore.
    static func estimateRestoreSize(snapshotURL: URL, items: [String]) -> UInt64 {
        let fm = FileManager.default
        var total: UInt64 = 0
        for rel in items {
            let url = snapshotURL.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let enumerator = fm.enumerator(
                    at: url, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
                for case let fileURL as URL in enumerator {
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    total += UInt64(size)
                }
            } else {
                let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0
                total += size
            }
        }
        return total
    }

    /// Restore items from a snapshot.
    /// - Backs up existing files to ~/.rustybackup-pre-restore/TIMESTAMP/ before overwriting
    /// - Creates parent directories as needed
    static func restore(snapshotURL: URL, items: [String],
                        destinationOverrides: [String: String] = [:],
                        progress: ((String, Int, Int) -> Void)? = nil) -> RestoreResult {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let backupDir = preRestoreBackupDir()
        var result = RestoreResult()
        let operationLock: DestinationLock
        do {
            operationLock = try DestinationLock(at: snapshotURL.deletingLastPathComponent())
        } catch {
            Log.error("Restore blocked: \(error.localizedDescription)")
            result.failed = items.count
            return result
        }
        defer { withExtendedLifetime(operationLock) {} }
        result.backedUpTo = backupDir.path
        let total = items.count
        var didBackup = false
        var overwrittenRels: [String] = []  // F-05: track for manifest

        for (i, rel) in items.enumerated() {
            let source = snapshotURL.appendingPathComponent(rel)
            let dest: URL
            if let customDest = destinationOverrides[rel] {
                let expanded = NSString(string: customDest).expandingTildeInPath
                dest = URL(fileURLWithPath: expanded)
                    .appendingPathComponent(URL(fileURLWithPath: rel).lastPathComponent)
            } else {
                dest = URL(fileURLWithPath: home + "/" + rel)
            }
            progress?(rel, i + 1, total)

            do {
                if fm.fileExists(atPath: dest.path) {
                    if !didBackup {
                        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
                        didBackup = true
                    }
                    let backupDest = backupDir.appendingPathComponent(rel)
                    try fm.createDirectory(at: backupDest.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try fm.copyItem(at: dest, to: backupDest)
                    try fm.removeItem(at: dest)
                    overwrittenRels.append(rel)  // F-05: record overwritten path
                    result.overwritten += 1
                }

                try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: dest)
                result.restored += 1
            } catch {
                result.failed += 1
            }
        }

        // F-05: Write manifest so undoRestore() can restore only exact paths, not top-level dirs
        if didBackup && !overwrittenRels.isEmpty {
            let manifest = RestoreManifest(overwritten: overwrittenRels)
            let manifestURL = backupDir.appendingPathComponent("manifest.json")
            if let data = try? JSONEncoder().encode(manifest) {
                try? data.write(to: manifestURL, options: .atomic)
            }
        }

        if !didBackup { result.backedUpTo = "" }
        return result
    }

    // MARK: - Undo restore

    static var preRestoreBaseURL: URL { preRestoreBase }

    private static var preRestoreBase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".rustybackup-pre-restore")
    }

    /// Check if any pre-restore backups exist.
    static func hasPreRestoreBackup() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: preRestoreBase.path),
              let contents = try? fm.contentsOfDirectory(atPath: preRestoreBase.path) else {
            return false
        }
        return !contents.filter({ !$0.hasPrefix(".") }).isEmpty
    }

    /// Find the most recent pre-restore backup directory.
    static func latestPreRestoreBackup() -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: preRestoreBase,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return contents
            .filter { $0.lastPathComponent.count == 15 } // YYYYMMDD_HHMMSS
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    /// List items in a pre-restore backup (relative paths).
    static func scanPreRestoreBackup(at backupDir: URL) -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: backupDir, includingPropertiesForKeys: nil, options: []
        ) else { return [] }
        return contents.map(\.lastPathComponent).sorted()
    }

    /// Undo the last restore by copying pre-restore files back to home.
    /// F-05: Uses manifest.json (if present) to restore only exact overwritten paths —
    /// not entire top-level directories, which would destroy files created after restore.
    static func undoRestore(from backupDir: URL) -> RestoreResult {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var result = RestoreResult()

        // Manifest-based restore: only touch the exact paths that were overwritten
        let manifestURL = backupDir.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(RestoreManifest.self, from: data) {
            for rel in manifest.overwritten {
                let source = backupDir.appendingPathComponent(rel)
                let dest = home.appendingPathComponent(rel)
                do {
                    if fm.fileExists(atPath: dest.path) {
                        try fm.removeItem(at: dest)
                        result.overwritten += 1
                    }
                    try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try fm.copyItem(at: source, to: dest)
                    result.restored += 1
                } catch {
                    result.failed += 1
                }
            }
            if result.failed == 0 { try? fm.removeItem(at: backupDir) }
            return result
        }

        // Fallback: no manifest (legacy backup dir) — restore top-level items with a warning
        Log.warn("No manifest.json in pre-restore backup — using legacy top-level restore (may overwrite newer files)")
        let items = scanPreRestoreBackup(at: backupDir)
        for rel in items {
            let source = backupDir.appendingPathComponent(rel)
            let dest = home.appendingPathComponent(rel)
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                    result.overwritten += 1
                }
                try fm.copyItem(at: source, to: dest)
                result.restored += 1
            } catch {
                result.failed += 1
            }
        }
        if result.failed == 0 { try? fm.removeItem(at: backupDir) }
        return result
    }

    /// Run brew bundle install from the Brewfile in the snapshot.
    static func restoreHomebrew(snapshotURL: URL,
                                progress: ((String) -> Void)? = nil) -> Bool {
        let brewfile = snapshotURL
            .appendingPathComponent("_environment")
            .appendingPathComponent("Brewfile")
        guard FileManager.default.fileExists(atPath: brewfile.path) else { return false }

        progress?("Installing Homebrew packages...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["brew", "bundle", "install",
                             "--file=\(brewfile.path)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
