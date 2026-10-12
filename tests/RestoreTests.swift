import Foundation

/// 3.0 restore: per file, per topic, undo per file, new Mac.
final class RestoreTests {
    let safety = SafetyTests()

    func snapshotDir(_ box: SafetyTests.Sandbox, _ name: String) throws -> URL {
        let url = URL(fileURLWithPath: box.dest).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_hiddenVolumeMakesDeletedFilesRestorable() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let volume = box.root.appendingPathComponent("encrypted-volume")
        let destination = volume.appendingPathComponent(AppIdentity.backupFolderName)
        let older = "2026-10-12_090000"
        let newer = "2026-10-12_120000"
        try safety.makeSnapshot(destination, older, complete: true)
        try safety.makeSnapshot(destination, newer, complete: true)
        let relativePath = "Documents/deleted.txt"
        try safety.write("saved before deletion",
                         to: destination.appendingPathComponent(older).path + "/" + relativePath)

        let backups = RestoreEngine.findBackupSnapshots { options in
            options.contains(.skipHiddenVolumes) ? [] : [volume]
        }
        try expectEqual(backups.count, 1, "the hidden encrypted store must be discoverable")
        let backup = backups[0]
        try expectEqual(backup.backupDir.path, destination.path, "discovery finds the stored backup folder")
        try expectEqual(backup.snapshots, [newer, older], "older snapshots remain available")
        let state = AppUIState()
        state.config = Config(source: SourceConfig(paths: []),
                              destination: DestinationConfig(path: destination.path),
                              exclude: ExcludeConfig(patterns: []), retention: RetentionConfig())
        state.cachedHasBackups = !backups.isEmpty
        state.cachedBackupAccessible = true
        try expect(state.hasBackups, "restore is available when the encrypted store has backups")

        let model = RestoreCenterModel(destination: destination, config: state.config, home: box.home)
        try expectEqual(model.tab, .file, "restore starts with file recovery")
        try expect(model.restoreToFolder, "file recovery defaults to a separate Desktop copy")
        func waitForModel(_ model: RestoreCenterModel) throws {
            let deadline = Date().addingTimeInterval(5)
            while model.busy && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            try expect(!model.busy, "sandbox restore model completes its background read")
        }
        try safety.makeSnapshot(destination, "2026-10-12_130000", complete: false)
        model.load()
        try waitForModel(model)
        try expectEqual(model.selectedSnapshot, newer, "an incomplete newest backup is never the default")
        model.query = "deleted"
        model.search()
        try waitForModel(model)
        try expectEqual(model.results, [relativePath], "the actual restore search reaches older retained files")
        let onlyIncomplete = box.root.appendingPathComponent("incomplete-history")
        try safety.makeSnapshot(onlyIncomplete, newer, complete: false)
        let incompleteModel = RestoreCenterModel(destination: onlyIncomplete, config: nil, home: box.home)
        incompleteModel.load()
        try waitForModel(incompleteModel)
        try expectEqual(incompleteModel.selectedSnapshot, "", "only incomplete history requires an explicit choice")
        let history = SnapshotCatalog.list(at: destination).map(\.url)
        try expectEqual(FileVersions.search("DELETED", in: history), [relativePath],
                        "search finds a deleted file even though the latest snapshot does not have it")
        try expect(try FileVersions.search("deleted", in: destination.appendingPathComponent(newer)).isEmpty,
                   "fixture pins a file absent from the newest snapshot")
        try safety.write("common", to: destination.appendingPathComponent(newer).path + "/Documents/common.txt")
        try safety.write("common", to: destination.appendingPathComponent(older).path + "/Documents/common.txt")
        try expectEqual(Set(FileVersions.search(".txt", in: history, limit: 2)),
                        Set([relativePath, "Documents/common.txt"]),
                        "duplicate paths do not consume the history search limit")
        try expectEqual(FileVersions.search(".txt", in: history, limit: 1).count, 1,
                        "history search retains the existing result bound")
        do {
            _ = try FileVersions.search("deleted", in: [box.root.appendingPathComponent("missing-snapshot")])
            throw TestFailure.failed("missing snapshot must report a search error")
        } catch is CocoaError {
            // An unavailable backup is not a successful search with zero matches.
        }

        let versions = FileVersions.list(relativePath: relativePath, at: backup.backupDir)
        try expectEqual(versions.map(\.snapshot), [older], "a deleted file is found in its older snapshot")
        model.snapshots = SnapshotCatalog.list(at: destination)
        model.selectedFile = relativePath
        model.restore(version: versions[0])
        try expectEqual(model.plan?.destinationRoot, box.home + "/Desktop/Ripristinati \(older)",
                        "the first preview saves a separate copy and never uses the real home")
        try expectEqual(model.plan?.snapshot.path, model.snapshots.first { $0.name == older }?.url.path,
                        "preview uses the chosen older version, not the newest snapshot")
        model.restoreToFolder = false
        try expectNil(model.plan, "changing the destination invalidates the old preview")
        model.restore(version: versions[0])
        try expectEqual(model.plan?.destinationRoot, box.home, "original-location recovery is an explicit choice")
        model.tab = .topic
        try expectNil(model.plan, "switching recovery mode invalidates the old preview")
        try expect(!FileManager.default.fileExists(atPath: box.home + "/" + relativePath),
                   "the file is absent from the test home before restore")
        let plan = SelectiveRestore.plan(snapshot: backup.backupDir.appendingPathComponent(older),
                                         paths: [relativePath], destinationRoot: box.home)
        let (result, _) = try SelectiveRestore.apply(plan, undoRoot: box.root.appendingPathComponent("undo"))
        try expectEqual(result.restored, 1, "the deleted file is recovered")
        try expectEqual(result.failed, 0, "the sandbox restore succeeds")
        try expectEqual(try String(contentsOfFile: box.home + "/" + relativePath, encoding: .utf8),
                        "saved before deletion", "the recovered file has its original contents")
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
        var progress: [(Int, Int)] = []
        let progressSnapshot = box.root.appendingPathComponent("progress-snapshot")
        let captured = GitSafety.captureAll(sources: [box.home + "/GitHub"],
                                            excludeFilter: ExcludeFilter(patterns: []),
                                            home: box.home, into: progressSnapshot,
                                            onProgress: { progress.append(($0, $1)) })
        try expectEqual(captured.count, 1, "progress does not change repository capture")
        try expectEqual(progress.map { $0.0 }, [1], "actual repository index is reported")
        try expectEqual(progress.map { $0.1 }, [1], "actual repository total is reported")

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

/// The menu's first line: protected, attention, or a Mac that looks new.
final class ProtectionSummaryTests {
    let safety = SafetyTests()

    func name(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    func test_levels() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let dest = URL(fileURLWithPath: box.dest)
        let now = Date()
        try expectEqual(ProtectionSummary.build(destination: dest, now: now).headline, "Nessun backup", "empty disk")

        try safety.makeSnapshot(dest, name(now.addingTimeInterval(-3 * 86_400)), complete: nil)  // pre-3.0
        var s = ProtectionSummary.build(destination: dest, now: now)
        try expectEqual(s.level, .attention, "only unverified snapshots: attention")

        try safety.makeSnapshot(dest, name(now.addingTimeInterval(-7_500)), complete: true)  // 2 h 05: names drop sub-seconds
        s = ProtectionSummary.build(destination: dest, now: now)
        try expectEqual(s.level, .protected, "recent complete snapshot: protected")
        try expect(s.headline.contains("2 ore fa"), "headline says how long ago: \(s.headline)")
        try expectEqual(s.days.count, 14, "14-day strip")
        try expectEqual(s.days.last, .complete, "today is green")
        try expectNil(s.lastCompleteFinishedDate, "legacy empty timestamp does not become a finish time")
        let completedSnapshot = dest.appendingPathComponent(name(now.addingTimeInterval(-7_500)))
        guard var manifest = SnapshotManifest.read(from: completedSnapshot) else {
            throw TestFailure.failed("complete fixture has no manifest")
        }
        let finishedAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-7_000))
        manifest.finishedAt = finishedAt
        try manifest.write(to: completedSnapshot)
        s = ProtectionSummary.build(destination: dest, now: now)
        try expectEqual(s.lastCompleteFinishedDate, ISO8601DateFormatter().date(from: finishedAt),
                        "summary reads completion from the manifest, not folder naming")

        try safety.makeSnapshot(dest, name(now.addingTimeInterval(-600)), complete: false)
        s = ProtectionSummary.build(destination: dest, now: now)
        try expectEqual(s.level, .attention, "latest incomplete: attention")
        try expect(s.latestIsIncomplete, "flag set")

        try safety.makeSnapshot(dest, name(now.addingTimeInterval(-60)), complete: false, shrink: "nuovo")
        s = ProtectionSummary.build(destination: dest, now: now)
        try expectEqual(s.level, .unprotected, "new Mac: red")
        try expect(s.looksLikeNewMac, "new Mac detected")
    }
}

final class RestoreGuardTests {
    let safety = SafetyTests()

    func test_symlinksAndDotDotAreLeftAlone() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let snap = URL(fileURLWithPath: box.dest).appendingPathComponent("2026-10-05_000000")
        try safety.write("from backup", to: snap.path + "/.claude/agents/twin.md")
        try safety.write("canon", to: box.root.path + "/canon/twin.md")
        try FileManager.default.createDirectory(atPath: box.home + "/.claude/agents", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: box.home + "/.claude/agents/twin.md",
                                                   withDestinationPath: box.root.path + "/canon/twin.md")
        let plan = SelectiveRestore.plan(snapshot: snap, paths: [".claude", "../outside", "a/../../x"], destinationRoot: box.home)
        try expectEqual(plan.items.map(\.action), [.keepLink], "only the link, kept: \(plan.items)")
        _ = try SelectiveRestore.apply(plan, undoRoot: box.root.appendingPathComponent("undo"))
        try expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: box.home + "/.claude/agents/twin.md"),
                        box.root.path + "/canon/twin.md", "symlink untouched")
    }
}
