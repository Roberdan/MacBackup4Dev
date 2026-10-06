import Foundation

/// 3.0 restore: per file, per topic, undo per file, new Mac.
final class RestoreTests {
    let safety = SafetyTests()

    func snapshotDir(_ box: SafetyTests.Sandbox, _ name: String) throws -> URL {
        let url = URL(fileURLWithPath: box.dest).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_topicFilesExpandWildcardsAndSkipJunk() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let snap = try snapshotDir(box, "2026-10-05_000000")
        try safety.write("a", to: snap.path + "/.warp/settings.toml")
        try safety.write("a", to: snap.path + "/.warp/.DS_Store")
        try safety.write("a", to: snap.path + "/Library/Preferences/dev.warp.Warp-Stable.plist")
        try safety.write("a", to: snap.path + "/Library/Preferences/com.other.plist")
        let warp = Topics.all(config: nil).first { $0.name == "Warp" }!
        let files = Set(Topics.files(of: warp, in: snap))
        try expect(files.contains(".warp/settings.toml"), "settings found: \(files)")
        try expect(files.contains("Library/Preferences/dev.warp.Warp-Stable.plist"), "wildcard pref found: \(files)")
        try expect(!files.contains("Library/Preferences/com.other.plist"), "other prefs excluded")
        try expect(!files.contains(".warp/.DS_Store"), "Finder junk excluded")
    }

    func test_configTopicsOverrideAndExtend() throws {
        var cfg = Config(source: SourceConfig(paths: []), destination: DestinationConfig(path: "/x"),
                         exclude: ExcludeConfig(patterns: []), retention: RetentionConfig())
        cfg.topics = ["Warp": ["~/.warp"], "Casa": ["~/GitHub/casa-caccini"]]
        let topics = Topics.all(config: cfg)
        try expectEqual(topics.first { $0.name == "Warp" }?.paths, [".warp"], "config replaces built-in")
        try expectEqual(topics.first { $0.name == "Casa" }?.paths, ["GitHub/casa-caccini"], "config adds a topic")
    }

    func test_planApplyAndPerFileUndo() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let snap = try snapshotDir(box, "2026-10-05_000000")
        try safety.write("old-a", to: snap.path + "/cfg/a.txt")
        try safety.write("old-b", to: snap.path + "/cfg/b.txt")
        try safety.write("same", to: snap.path + "/cfg/c.txt")
        try safety.write("new-a", to: box.home + "/cfg/a.txt")      // will be replaced
        try safety.write("same", to: box.home + "/cfg/c.txt")       // identical
        let plan = SelectiveRestore.plan(snapshot: snap, paths: ["cfg"], destinationRoot: box.home)
        try expectEqual(plan.toReplace, 1, "a.txt replaced")
        try expectEqual(plan.toCreate, 1, "b.txt created")
        try expectEqual(plan.unchanged, 1, "c.txt already equal")
        let undoRoot = box.root.appendingPathComponent("undo")
        let (result, undoDir) = try SelectiveRestore.apply(plan, undoRoot: undoRoot)
        try expectEqual(result.failed, 0, "no failures")
        try expectEqual(try String(contentsOfFile: box.home + "/cfg/a.txt", encoding: .utf8), "old-a", "a restored")
        try expectEqual(try String(contentsOfFile: box.home + "/cfg/b.txt", encoding: .utf8), "old-b", "b created")
        guard let undoDir else { throw TestFailure.failed("no undo dir") }

        // Undo one file only: a.txt goes back to the local version, b.txt stays.
        _ = try SelectiveRestore.undo(undoDir, only: ["cfg/a.txt"])
        try expectEqual(try String(contentsOfFile: box.home + "/cfg/a.txt", encoding: .utf8), "new-a", "a undone")
        try expect(FileManager.default.fileExists(atPath: box.home + "/cfg/b.txt"), "b untouched by per-file undo")
        // Undo the rest: the created file disappears (the old engine left it behind).
        _ = try SelectiveRestore.undo(undoDir)
        try expect(!FileManager.default.fileExists(atPath: box.home + "/cfg/b.txt"), "created file removed by undo")
        try expect(!FileManager.default.fileExists(atPath: undoDir.path), "undo dir cleaned up when empty")
    }

    func test_versionsAreDistinctNewestFirst() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let s1 = try snapshotDir(box, "2026-10-01_000000")
        let s2 = try snapshotDir(box, "2026-10-02_000000")
        let s3 = try snapshotDir(box, "2026-10-03_000000")
        try safety.write("v1", to: s1.path + "/.zshrc")
        try FileManager.default.linkItem(atPath: s1.path + "/.zshrc", toPath: s2.path + "/.zshrc") // unchanged day
        try safety.write("version two", to: s3.path + "/.zshrc")
        let versions = FileVersions.list(relativePath: ".zshrc", at: URL(fileURLWithPath: box.dest))
        try expectEqual(versions.map(\.snapshot), ["2026-10-03_000000", "2026-10-02_000000"],
                        "hard-linked twin collapsed, newest first")
    }

    /// The whole day of 2026-10-06 in one call: repo cloned, same branch, unpushed commit
    /// back, local edits on top, a half-restored copy moved aside instead of deleted.
    func test_newMacRebuildsRepository() throws {
        guard Shell.git != nil else { return }
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let origin = box.root.appendingPathComponent("origin.git").path
        _ = try safety.git(["init", "-q", "--bare", "-b", "main", origin], box.root.path)
        let repo = box.home + "/GitHub/app"
        _ = try safety.git(["clone", "-q", origin, repo], box.root.path)
        try safety.write("one", to: repo + "/a.txt")
        _ = try safety.git(["add", "."], repo); _ = try safety.git(["commit", "-q", "-m", "c1"], repo)
        _ = try safety.git(["push", "-q", "origin", "HEAD:main"], repo)
        _ = try safety.git(["checkout", "-q", "-b", "work"], repo)
        try safety.write("two", to: repo + "/b.txt")
        _ = try safety.git(["add", "."], repo); _ = try safety.git(["commit", "-q", "-m", "c2 local only"], repo)
        let workSHA = try safety.git(["rev-parse", "HEAD"], repo)
        try safety.write("uncommitted edit", to: repo + "/a.txt")
        try safety.write("cfg", to: box.home + "/.zshrc")

        let result = try safety.runEngine(safety.config(box, sources: ["GitHub", ".zshrc"]), box, git: true)

        // "New Mac": an empty home except for a partial copy of the repo.
        let newHome = box.root.appendingPathComponent("newhome").path
        try safety.write("partial", to: newHome + "/GitHub/app/a.txt")
        let report = NewMacRestore.run(snapshot: result.snapshot, steps: [.config, .repos], home: newHome)
        let restored = newHome + "/GitHub/app"
        try expectEqual(try safety.git(["rev-parse", "--abbrev-ref", "HEAD"], restored), "work", "same branch: \(report.lines)")
        try expectEqual(try safety.git(["rev-parse", "HEAD"], restored), workSHA, "same commit, including the unpushed one")
        try expectEqual(try String(contentsOfFile: restored + "/a.txt", encoding: .utf8), "uncommitted edit", "local edit back")
        let status = try safety.git(["status", "--porcelain"], restored)
        try expect(status.contains("a.txt") && !status.contains("b.txt"), "git status shows only the real local change: \(status)")
        try expectEqual(try String(contentsOfFile: newHome + "/.zshrc", encoding: .utf8), "cfg", "config file restored")
        try expect(report.repos.first?.lostCommits.isEmpty ?? false, "nothing lost: \(report.repos)")
        try expectEqual(try String(contentsOfFile: NewMacRestore.movedAsideRoot(home: newHome) + "/GitHub/app/a.txt", encoding: .utf8),
                        "partial", "partial copy moved aside, not deleted")
    }
}
