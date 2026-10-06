import Foundation

struct BackupEntry {
    let name: String
    let timestamp: Date
    let url: URL
}

enum RetentionManager {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        return formatter
    }()

    /// Parse backup directory name to timestamp.
    /// Format: YYYY-MM-DD_HHMMSS (17 chars)
    static func parseBackupName(_ name: String) -> Date? {
        guard name.count == 17 else { return nil }
        guard let date = formatter.date(from: name),
              formatter.string(from: date) == name else { return nil }
        return date
    }

    /// List all backup snapshots at destination, sorted newest first.
    static func listBackups(at destination: URL) -> [BackupEntry] {
        do {
            return try readBackups(at: destination)
        } catch {
            Log.error("Cannot list backups at \(destination.path): \(error.localizedDescription)")
            return []
        }
    }

    static func readBackups(at destination: URL) throws -> [BackupEntry] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        return try contents.compactMap { url -> BackupEntry? in
            let name = url.lastPathComponent
            guard let timestamp = parseBackupName(name) else { return nil }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return BackupEntry(name: name, timestamp: timestamp, url: url)
        }.sorted { $0.timestamp > $1.timestamp }
    }

    /// Prune backups according to retention policy.
    /// Returns list of pruned backup names.
    static func pruneBackups(at destination: URL, policy: RetentionConfig, dryRun: Bool) throws -> [String] {
        try validateDestination(destination)
        let lock = try DestinationLock(at: destination)
        return try withExtendedLifetime(lock) {
            try pruneLockedBackups(at: destination, policy: policy, dryRun: dryRun)
        }
    }

    /// Caller must hold the destination lock (backup also prunes when space is low).
    static func pruneLockedBackups(at destination: URL, policy: RetentionConfig, dryRun: Bool) throws -> [String] {
        let backups = try readBackups(at: destination)
        guard backups.count > 1 else { return [] } // Always keep at least one

        // A Mac that looks new or emptied must not lose its good history to a pruning pass
        // computed from a near-empty snapshot (scar 2026-10-06).
        if let newest = backups.first, SnapshotManifest.read(from: newest.url)?.shrinkWarning != nil {
            Log.warn("Pruning skipped: the newest snapshot looks like a new or emptied Mac")
            return []
        }

        var keep = protectedNames(backups)

        if let latest = backups.first { keep.insert(latest.name) }

        keepBySlot(backups: backups, keep: &keep, count: Int(policy.hourly)) { entry in
            Calendar.current.dateComponents([.year, .month, .day, .hour], from: entry.timestamp)
        }

        keepBySlot(backups: backups, keep: &keep, count: Int(policy.daily)) { entry in
            Calendar.current.dateComponents([.year, .month, .day], from: entry.timestamp)
        }

        keepBySlot(backups: backups, keep: &keep, count: Int(policy.weekly)) { entry in
            Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: entry.timestamp)
        }

        if policy.monthly == 0 {
            keepBySlot(backups: backups, keep: &keep, count: Int.max) { entry in
                Calendar.current.dateComponents([.year, .month], from: entry.timestamp)
            }
        } else {
            keepBySlot(backups: backups, keep: &keep, count: Int(policy.monthly)) { entry in
                Calendar.current.dateComponents([.year, .month], from: entry.timestamp)
            }
        }

        let candidates = backups.filter { !keep.contains($0.name) }
        if dryRun {
            for backup in candidates { print("  Would prune: \(backup.name)") }
            return candidates.map(\.name)
        }
        return try deleteBackups(candidates, at: destination)
    }

    /// Snapshots no pruning may delete: the 3 newest complete ones. For automatic retention,
    /// when fewer than 3 are complete (history from before 3.0), the newest unverified ones
    /// fill the gap; a manual cleanup the user previews and confirms protects complete ones only.
    /// Incomplete snapshots are never protected: they are exactly what may go.
    static func protectedNames(_ backups: [BackupEntry], keepComplete: Int = 3,
                               fillWithUnverified: Bool = true) -> Set<String> {
        var complete: [String] = []
        var unverified: [String] = []
        for backup in backups {   // newest first
            switch SnapshotManifest.read(from: backup.url) {
            case .some(let m) where m.complete: complete.append(backup.name)
            case .none: unverified.append(backup.name)
            default: break
            }
        }
        var names = Array(complete.prefix(keepComplete))
        if fillWithUnverified, names.count < keepComplete {
            names += unverified.prefix(keepComplete - names.count)
        }
        return Set(names)
    }

    static func validateDestination(_ destination: URL) throws {
        guard BackupEngine.isVolumeReallyMounted(destination.path) else {
            throw BackupError.volumeNotMounted(destination.path)
        }
        let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw BackupError.notWritable(destination.path)
        }
    }

    static func deleteBackups(_ backups: [BackupEntry], at destination: URL) throws -> [String] {
        var removed: [String] = []
        for backup in backups {
            let staged = destination.appendingPathComponent(".deleting-\(backup.name)-\(UUID().uuidString)")
            do {
                let values = try backup.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw BackupError.notWritable(backup.url.path)
                }
                // A failed/partial deletion must never remain a restorable snapshot.
                try FileManager.default.moveItem(at: backup.url, to: staged)
                try FileManager.default.removeItem(at: staged)
                removed.append(backup.name)
                Log.info("Pruned: \(backup.name)")
            } catch {
                throw NSError(domain: "SnapshotCleanup", code: 2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Pulizia interrotta dopo \(removed.count) backup eliminati: \(backup.name). "
                        + "\(error.localizedDescription) Eventuali resti: \(staged.path)",
                    NSUnderlyingErrorKey: error
                ])
            }
        }
        return removed
    }

    /// Helper: keep one backup per unique slot (hour/day/week/month), up to `count` slots.
    private static func keepBySlot(
        backups: [BackupEntry],
        keep: inout Set<String>,
        count: Int,
        slotKey: (BackupEntry) -> DateComponents
    ) {
        guard count > 0 else { return }
        // Each slot's representative: the newest COMPLETE snapshot of that slot; only when
        // the slot has none, the newest unverified, then the newest at all (review M8: a
        // late incomplete run must not push the complete one of the same day out).
        func rank(_ b: BackupEntry) -> Int {
            switch SnapshotManifest.read(from: b.url) {
            case .some(let m) where m.complete: return 0
            case .none: return 1
            default: return 2
            }
        }
        var seen: [DateComponents: (name: String, rank: Int)] = [:]
        for backup in backups {   // newest first
            let slot = slotKey(backup)
            let r = rank(backup)
            if let current = seen[slot], current.rank <= r { continue }
            seen[slot] = (backup.name, r)
        }

        var slotsKept = 0
        var seenSlots = Set<DateComponents>()
        for backup in backups {
            if slotsKept >= count { break }
            let slot = slotKey(backup)
            if !seenSlots.contains(slot) {
                seenSlots.insert(slot)
                if let entry = seen[slot] { keep.insert(entry.name) }
                slotsKept += 1
            }
        }
    }

    /// Print retention summary for CLI.
    static func printRetentionSummary(policy: RetentionConfig, backups: [BackupEntry]) {
        print("Retention policy:")
        print("  Hourly:  keep \(policy.hourly)")
        print("  Daily:   keep \(policy.daily)")
        print("  Weekly:  keep \(policy.weekly)")
        print("  Monthly: \(policy.monthly == 0 ? "keep forever" : "keep \(policy.monthly)")")
        print("Current backups: \(backups.count)")
    }

    /// Calculate directory size (for list command).
    static func directorySize(at url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var totalSize: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            totalSize += UInt64(values.fileSize ?? 0)
        }
        return totalSize
    }
}
