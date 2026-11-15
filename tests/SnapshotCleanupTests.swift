import Foundation

final class SnapshotCleanupTests {
    private let fm = FileManager.default

    private func fixture(_ names: [String]) throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("rmb-cleanup-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        return root
    }

    private func date(_ name: String) throws -> Date {
        guard let value = RetentionManager.parseBackupName(name) else {
            throw TestFailure.failed("Invalid fixture date: \(name)")
        }
        return value
    }

    private func expectFailure(_ action: () throws -> Void) throws {
        var failed = false
        do { try action() } catch { failed = true }
        try expect(failed, "Operation should report an error, not success")
    }

    func test_ageBoundariesAndPreview() throws {
        let names = [
            "2026-09-24_120000", "2026-08-24_120000", "2026-08-24_115959",
            "2026-03-24_120000", "2026-03-24_115959",
            "2025-09-24_120000", "2025-09-24_115959"
        ]
        let root = try fixture(names)
        defer { try? fm.removeItem(at: root) }
        let now = try date(names[0])
        for (age, expected) in [(CleanupAge.oneMonth, 5), (.sixMonths, 3), (.oneYear, 1)] {
            let cleanup = try SnapshotCleanup(at: root, age: age, now: now)
            try expectEqual(cleanup.candidates.count, expected, "Age must use calendar months and a strict cutoff")
            try expectEqual(cleanup.latest?.name, names[0], "Latest must be protected")
        }
        let remaining = try RetentionManager.readBackups(at: root)
        try expectEqual(remaining.count, names.count, "Preview must not delete snapshots")
        let leapNow = try date("2024-03-31_120000")
        let leapCutoff = try date("2024-02-29_120000")
        try expectEqual(CleanupAge.oneMonth.cutoff(from: leapNow), leapCutoff,
                        "Calendar month subtraction must handle leap years")
    }

    func test_latestAndNonSnapshotsSurvive() throws {
        let root = try fixture(["2024-01-01_000000", "2024-02-01_000000",
                                "in-progress-2023-01-01_000000", "notes", "2024-02-30_000000"])
        let outside = try fixture([])
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        try "source".write(to: outside.appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent("2023-01-01_000000"), withDestinationURL: outside)
        try "not a directory".write(to: root.appendingPathComponent("2023-02-01_000000"), atomically: true, encoding: .utf8)
        let cleanup = try SnapshotCleanup(at: root, age: .oneMonth, now: date("2026-09-24_120000"))
        try expectEqual(cleanup.candidates.map(\.name), ["2024-01-01_000000"], "Only real dated directories may be deleted")
        let deleted = try cleanup.execute().deleted
        try expectEqual(deleted, ["2024-01-01_000000"], "Delete exactly the preview")
        for name in ["2024-02-01_000000", "in-progress-2023-01-01_000000", "notes",
                     "2024-02-30_000000", "2023-01-01_000000", "2023-02-01_000000"] {
            try expect(fm.fileExists(atPath: root.appendingPathComponent(name).path), "Must preserve \(name)")
        }
        let original = try String(contentsOf: outside.appendingPathComponent("original.txt"))
        try expectEqual(original, "source", "Never touch symlink target")
    }

    func test_hardLinksAndOriginalSurvive() throws {
        let root = try fixture(["2024-01-01_000000", "2026-09-24_120000"])
        defer { try? fm.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        let old = root.appendingPathComponent("2024-01-01_000000/data.txt")
        let latest = root.appendingPathComponent("2026-09-24_120000/data.txt")
        try "precious data".write(to: original, atomically: true, encoding: .utf8)
        try fm.copyItem(at: original, to: old)
        try fm.linkItem(at: old, to: latest)
        let cleanup = try SnapshotCleanup(at: root, age: .sixMonths, now: date("2026-09-24_120000"))
        _ = try cleanup.execute()
        try expect(!fm.fileExists(atPath: old.path), "Old snapshot must actually be removed")
        let latestContents = try String(contentsOf: latest)
        let originalContents = try String(contentsOf: original)
        try expectEqual(latestContents, "precious data", "Shared inode must survive in retained snapshot")
        try expectEqual(originalContents, "precious data", "Source must remain unchanged")
    }

    func test_lockAndCancellation() throws {
        let root = try fixture(["2024-01-01_000000", "2026-09-24_120000"])
        defer { try? fm.removeItem(at: root) }
        var cleanup: SnapshotCleanup? = try SnapshotCleanup(at: root, age: .oneMonth)
        try expectNotNil(cleanup, "Preview must hold the lock")
        try expectFailure { _ = try DestinationLock(at: root) }
        try expectFailure { _ = try SnapshotCleanup(at: root, age: .sixMonths) }
        try expectFailure {
            _ = try RetentionManager.pruneBackups(at: root, policy: RetentionConfig(), dryRun: false)
        }
        cleanup = nil
        let lock = try DestinationLock(at: root)
        withExtendedLifetime(lock) {}
        let remaining = try RetentionManager.readBackups(at: root)
        try expectEqual(remaining.count, 2, "Cancellation must keep both snapshots")
    }

    func test_legacyLockAndInvalidDestination() throws {
        let root = try fixture([])
        defer { try? fm.removeItem(at: root) }
        let marker = root.appendingPathComponent("rustymacbackup.lock")
        try "\(ProcessInfo.processInfo.processIdentifier)\nlegacy".write(to: marker, atomically: true, encoding: .utf8)
        try expectFailure { _ = try SnapshotCleanup(at: root, age: .oneYear) }
        try fm.removeItem(at: marker)
        try expectFailure { _ = try SnapshotCleanup(at: root.appendingPathComponent("missing"), age: .oneYear) }
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: root)
        try expectFailure { _ = try SnapshotCleanup(at: alias, age: .oneYear) }
        try expect(!BackupEngine.isVolumeReallyMounted("/Volumes/rmb-missing-\(UUID().uuidString)/RustyMacBackup"),
                   "A path under /Volumes must not match the internal root filesystem")
    }

    func test_changedPreviewAndDeletionFailure() throws {
        let root = try fixture(["2024-01-01_000000", "2026-09-24_120000"])
        defer { try? fm.removeItem(at: root) }
        let cleanup = try SnapshotCleanup(at: root, age: .oneYear, now: date("2026-09-24_120000"))
        try fm.createDirectory(at: root.appendingPathComponent("2023-01-01_000000"), withIntermediateDirectories: true)
        try expectFailure { _ = try cleanup.execute() }
        let remaining = try RetentionManager.readBackups(at: root)
        try expectEqual(remaining.count, 3, "Changed preview must delete nothing")
        let missing = BackupEntry(name: "2022-01-01_000000", timestamp: try date("2022-01-01_000000"),
                                  url: root.appendingPathComponent("2022-01-01_000000"))
        try expectFailure { _ = try RetentionManager.deleteBackups([missing], at: root) }
    }

    func test_emptyAndSingleBackup() throws {
        let root = try fixture([])
        defer { try? fm.removeItem(at: root) }
        do {
            let cleanup = try SnapshotCleanup(at: root, age: .oneMonth)
            let result = try cleanup.execute()
            try expectEqual(result.deleted, [], "Empty destination should be a no-op")
            try expectEqual(result.freedBytes, 0, "Nothing deleted, nothing reported as freed")
        }
        try fm.createDirectory(at: root.appendingPathComponent("2020-01-01_000000"), withIntermediateDirectories: true)
        let cleanup = try SnapshotCleanup(at: root, age: .oneMonth)
        let deleted = try cleanup.execute().deleted
        try expectEqual(deleted, [], "Even an ancient single snapshot must be kept")
    }

    func test_cliOptions() throws {
        let now = try date("2026-11-15_120000")
        let week = try PruneOptions.parse(["--older-than", "7d"])
        try expectEqual(week.cutoff(from: now), now.addingTimeInterval(-604_800),
                        "Seven days must preserve the full preceding 168 hours")
        try expect(!week.confirmed, "Seven-day cleanup must default to preview")
        let confirmedWeek = try PruneOptions.parse(["--older-than", "7d", "--yes"])
        try expect(confirmedWeek.confirmed, "Seven-day deletion needs explicit confirmation")
        for (value, age) in [("1m", CleanupAge.oneMonth), ("6m", .sixMonths), ("1y", .oneYear)] {
            let preview = try PruneOptions.parse(["--older-than", value])
            try expectEqual(preview.age, age, "Parse exact supported ages")
            try expectEqual(preview.cutoff(from: now), age.cutoff(from: now), "Preserve calendar-month cutoffs")
            try expect(!preview.confirmed, "Destructive action must be opt-in")
            let confirmed = try PruneOptions.parse(["--older-than", value, "--yes"])
            try expect(confirmed.confirmed, "--yes confirms deletion")
        }
        for args in [["--older-than"], ["--older-than", "2m"], ["--yes", "--dry-run"],
                     ["--older-than", "1m", "--older-than", "6m"], ["--yse"], ["--older-than", "-1m"],
                     ["--older-than", "7d", "--older-than", "1m"],
                     ["--older-than", "1m", "--older-than", "7d"], ["--older-than", "6d"]] {
            try expectFailure { _ = try PruneOptions.parse(args) }
        }
        let legacy = try PruneOptions.parse([])
        try expect(!legacy.confirmed, "Legacy prune also defaults to preview")
    }

    func test_sevenDayBoundaryAndHardLinks() throws {
        let names = ["2026-11-15_120000", "2026-11-08_120001", "2026-11-08_120000",
                     "2026-11-08_115959", "2026-11-07_120000"]
        let root = try fixture(names)
        defer { try? fm.removeItem(at: root) }
        let options = try PruneOptions.parse(["--older-than", "7d"])
        guard let cutoff = options.cutoff(from: try date(names[0])) else {
            throw TestFailure.failed("Seven-day cleanup requires a cutoff")
        }
        let oldFile = root.appendingPathComponent(names[3] + "/data.txt")
        let retainedFile = root.appendingPathComponent(names[2] + "/data.txt")
        try "retained data".write(to: oldFile, atomically: true, encoding: .utf8)
        try fm.linkItem(at: oldFile, to: retainedFile)
        let cleanup = try SnapshotCleanup(at: root, cutoff: cutoff)
        try expectEqual(cleanup.candidates.map(\.name), Array(names.suffix(2)),
                        "Retain snapshots on and after the seven-day boundary")
        let result = try cleanup.execute()
        try expectEqual(result.deleted, Array(names.suffix(2)), "Delete only previewed old snapshots")
        let remaining = try RetentionManager.readBackups(at: root)
        try expectEqual(remaining.map(\.name), Array(names.prefix(3)), "Preserve every recent snapshot")
        let contents = try String(contentsOf: retainedFile)
        try expectEqual(contents, "retained data", "Deleting an old hard link must preserve the recent copy")
    }
}
