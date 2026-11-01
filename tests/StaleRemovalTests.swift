import Foundation
import Darwin

/// Interrupted runs and pruned snapshots must really disappear, even when macOS protects
/// part of them, without touching what a good snapshot still shares (2026-11-01: 13 left).
final class StaleRemovalTests {
    private let fm = FileManager.default

    private func destination() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("mb4d-stale-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sh(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "fixture command failed: \(arguments)")
    }

    private func age(_ url: URL, hours: Double) throws {
        try fm.setAttributes([.creationDate: Date(timeIntervalSinceNow: -hours * 3600)], ofItemAtPath: url.path)
    }

    private func flags(_ path: String) -> UInt32 {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_flags : 0
    }

    private func hasACL(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }

    /// Clears everything the fixtures locked, so the temporary folder can go.
    private func release(_ root: URL) {
        _ = try? sh(["/usr/bin/chflags", "-R", "nouchg", root.path])
        _ = try? sh(["/bin/chmod", "-R", "-N", root.path])
        _ = try? sh(["/bin/chmod", "-R", "u+rwx", root.path])
        try? fm.removeItem(at: root)
    }

    /// An interrupted run holding a protected folder, a read-only folder and a locked file.
    private func lockedRun(in root: URL, name: String, sharedWith good: URL) throws -> URL {
        let run = root.appendingPathComponent(name)
        let desktop = run.appendingPathComponent("Desktop/notes")
        let readOnly = run.appendingPathComponent("go/pkg/mod/module")
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        try fm.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try "draft".write(to: desktop.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "module".write(to: readOnly.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let locked = run.appendingPathComponent("locked.txt")
        try "locked".write(to: locked, atomically: true, encoding: .utf8)
        try fm.linkItem(at: good.appendingPathComponent("shared.txt"), to: run.appendingPathComponent("shared.txt"))
        try sh(["/bin/chmod", "+a", "group:everyone deny delete", run.appendingPathComponent("Desktop").path])
        try sh(["/bin/chmod", "0555", readOnly.path, readOnly.deletingLastPathComponent().path])
        try sh(["/usr/bin/chflags", "uchg", locked.path])
        try age(run, hours: 3)
        return run
    }

    private func goodSnapshot(in root: URL) throws -> URL {
        let good = root.appendingPathComponent("2026-10-31_235400")
        try fm.createDirectory(at: good, withIntermediateDirectories: true)
        try "kept".write(to: good.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        return good
    }

    func test_lockedInterruptedRunsAreRemovedAndGoodSnapshotUntouched() throws {
        let root = try destination()
        defer { release(root) }
        let good = try goodSnapshot(in: root)
        let shared = good.appendingPathComponent("shared.txt")
        try sh(["/bin/chmod", "+a", "group:everyone deny write", shared.path])
        let stale = try lockedRun(in: root, name: "in-progress-2026-10-12_100003", sharedWith: good)
        let pruned = try lockedRun(in: root, name: ".deleting-2026-10-01_000000-X", sharedWith: good)
        let fresh = root.appendingPathComponent("in-progress-2026-11-01_150000")
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)

        // The running backup writes its own PID in the marker before cleaning.
        try BackupEngine.acquireLock(at: root.appendingPathComponent("rustymacbackup.lock").path)
        BackupEngine.cleanStaleInProgress(at: root)

        try expect(!fm.fileExists(atPath: stale.path), "a protected interrupted run must be removed completely")
        try expect(!fm.fileExists(atPath: pruned.path), "a half-pruned snapshot must be removed completely")
        try expect(fm.fileExists(atPath: fresh.path), "a run younger than 2 hours may still be live")
        try expectEqual(try String(contentsOf: shared, encoding: .utf8), "kept", "the good snapshot keeps its file")
        try expect(hasACL(shared.path), "the good snapshot's file keeps its own protection")

        // Another live process in the marker: its run may still be in use.
        let other = root.appendingPathComponent("in-progress-2026-10-20_181842")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try age(other, hours: 3)
        try "\(getppid())\n2026-11-01T00:00:00Z\nX".write(to: root.appendingPathComponent("rustymacbackup.lock"),
                                              atomically: true, encoding: .utf8)
        BackupEngine.cleanStaleInProgress(at: root)
        try expect(fm.fileExists(atPath: other.path), "a run another live process may own is kept")
    }

    func test_sharedLockedFileIsNeverUnlockedAndFailureIsReported() throws {
        let root = try destination()
        defer { release(root) }
        let good = try goodSnapshot(in: root)
        let shared = good.appendingPathComponent("shared.txt")
        let stale = try lockedRun(in: root, name: "in-progress-2026-10-16_060005", sharedWith: good)
        try sh(["/usr/bin/chflags", "uchg", shared.path])

        var failed = false
        do { try SnapshotRemoval.remove(stale) } catch { failed = true }

        try expect(failed, "a file that cannot go must be reported, never ignored")
        try expect(flags(shared.path) & UInt32(UF_IMMUTABLE) != 0,
                   "a file shared with a good snapshot keeps its lock")
        try expectEqual(try String(contentsOf: shared, encoding: .utf8), "kept", "and its contents")
        try expect(!fm.fileExists(atPath: stale.appendingPathComponent("locked.txt").path),
                   "everything that belongs only to the interrupted run is still removed")
    }

    func test_retentionRemovesProtectedSnapshot() throws {
        let root = try destination()
        defer { release(root) }
        let good = try goodSnapshot(in: root)
        let old = try lockedRun(in: root, name: "2026-09-01_000000", sharedWith: good)
        let entry = BackupEntry(name: old.lastPathComponent,
                                timestamp: RetentionManager.parseBackupName(old.lastPathComponent)!, url: old)
        let removed = try RetentionManager.deleteBackups([entry], at: root)
        try expectEqual(removed, [old.lastPathComponent], "pruning reports the snapshot it removed")
        let left = try fm.contentsOfDirectory(atPath: root.path).filter { $0 != good.lastPathComponent }
        try expectEqual(left, [], "pruning leaves no protected remains behind")
        try expectEqual(try String(contentsOf: good.appendingPathComponent("shared.txt"), encoding: .utf8), "kept",
                        "the newer snapshot keeps the shared file")
    }
}
