import Foundation

final class WorktreePolicyTests {
    let safety = SafetyTests()

    func test_backupSkipsLinkedWorktreesEvenWithOldConfig() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        try safety.write("main", to: box.home + "/GitHub/main/file.txt")
        try safety.write("agent", to: box.home + "/GitHub/agent-checkout/file.txt")
        try safety.write("gitdir: \(box.home)/GitHub/main/.git/worktrees/agent\n",
                         to: box.home + "/GitHub/agent-checkout/.git")
        try safety.write("temporary", to: box.home + "/GitHub/main/.worktrees/another/file.txt")
        var config = safety.config(box, sources: ["GitHub", "GitHub/agent-checkout"])
        config.exclude.patterns = []
        let result = try safety.runEngine(config, box)
        try expect(result.manifest.complete, "worktree exclusion is intentional, not missing protected data")
        try expect(FileManager.default.fileExists(atPath: result.snapshot.path + "/GitHub/main/file.txt"), "ordinary source copied")
        try expect(!FileManager.default.fileExists(atPath: result.snapshot.path + "/GitHub/agent-checkout"),
                   "arbitrarily named linked checkout never copied")
        try expect(!FileManager.default.fileExists(atPath: result.snapshot.path + "/GitHub/main/.worktrees"),
                   "old configuration cannot reintroduce worktree containers")
        try expect(FileManager.default.fileExists(atPath: box.home + "/GitHub/agent-checkout/file.txt"),
                   "live working copy is never deleted")
    }

    func test_cleanupOnlyRemovesMissingLinkedCopiesAndRecordsIt() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let fm = FileManager.default
        try safety.write("source", to: box.home + "/GitHub/main/file.txt")
        try fm.createDirectory(atPath: box.home + "/GitHub/main/.git/worktrees", withIntermediateDirectories: true)
        let config = safety.config(box, sources: ["GitHub/main"])
        let snapshot = try safety.runEngine(config, box).snapshot
        let gone = snapshot.appendingPathComponent("GitHub/worktrees/main/gone")
        let live = snapshot.appendingPathComponent("GitHub/worktrees/main/live")
        for folder in [gone, live] {
            try safety.write("gitdir: \(box.home)/GitHub/main/.git/worktrees/\(folder.lastPathComponent)\n",
                             to: folder.path + "/.git")
            try safety.write("temporary", to: folder.path + "/file.txt")
        }
        try safety.write("unsaved", to: box.home + "/GitHub/worktrees/main/live/unsaved.txt")
        let ordinary = snapshot.appendingPathComponent("GitHub/worktrees/main/ordinary")
        try safety.write("history", to: ordinary.path + "/file.txt")
        let submodule = snapshot.appendingPathComponent("GitHub/submodule")
        try safety.write("gitdir: ../main/.git/modules/submodule\n", to: submodule.path + "/.git")
        try safety.write("keep", to: submodule.path + "/file.txt")
        let preserved = snapshot.appendingPathComponent("GitHub/main/preserved.txt")
        try fm.linkItem(at: gone.appendingPathComponent("file.txt"), to: preserved)
        let before = try fm.attributesOfItem(atPath: preserved.path)[.posixPermissions] as? NSNumber

        let report = try WorktreePolicy.cleanup(at: URL(fileURLWithPath: box.dest), home: box.home)
        try expectEqual(report.removed.count, 1, "only proven missing linked checkout removed")
        try expect(!fm.fileExists(atPath: gone.path), "obsolete copy actually removed")
        for path in [live.path, ordinary.path, submodule.path, preserved.path,
                     box.home + "/GitHub/worktrees/main/live/unsaved.txt"] {
            try expect(fm.fileExists(atPath: path), "unrelated or live data preserved: \(path)")
        }
        try expectEqual(try String(contentsOf: preserved, encoding: .utf8), "temporary", "shared hard-link content intact")
        try expectEqual(try fm.attributesOfItem(atPath: preserved.path)[.posixPermissions] as? NSNumber, before,
                        "cleanup never changes modes on shared files")
        let manifest = SnapshotManifest.read(from: snapshot)
        try expectEqual(manifest?.removedTemporaryWorktrees?.map(\.path), ["GitHub/worktrees/main/gone"],
                        "intentional cleanup is auditable")
        try expect((manifest?.removedTemporaryWorktrees?.first?.bytes ?? 0) > 0, "record includes measured size")
        try expect(manifest?.complete == true, "unrelated complete history remains usable")
        try expectEqual(try WorktreePolicy.cleanup(at: URL(fileURLWithPath: box.dest), home: box.home).removed.count, 0,
                        "repeat cleanup is idempotent")

        let lock = try DestinationLock(at: URL(fileURLWithPath: box.dest))
        var refused = false
        do { _ = try WorktreePolicy.cleanup(at: URL(fileURLWithPath: box.dest), home: box.home) }
        catch BackupError.lockExists { refused = true }
        _ = try withExtendedLifetime(lock) { try expect(refused, "cleanup never races a backup") }
    }
}
