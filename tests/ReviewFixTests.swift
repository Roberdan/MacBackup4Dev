import Foundation

/// One test per finding of the 2026-10-06 pre-release review (H1–H4, M4, M5, M8, shrink).
final class ReviewFixTests {
    let safety = SafetyTests()

    /// H1: a file edited after a restore must survive "undo".
    func test_undoKeepsFilesChangedAfterRestore() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let snap = URL(fileURLWithPath: box.dest).appendingPathComponent("2026-10-05_000000")
        try safety.write("from backup", to: snap.path + "/cfg/new.txt")
        try safety.write("old", to: snap.path + "/cfg/rep.txt")
        try safety.write("local", to: box.home + "/cfg/rep.txt")
        let plan = SelectiveRestore.plan(snapshot: snap, paths: ["cfg"], destinationRoot: box.home)
        let (_, undoDir) = try SelectiveRestore.apply(plan, undoRoot: box.root.appendingPathComponent("undo"))
        // A week of work later…
        try "edited after restore, longer".write(toFile: box.home + "/cfg/new.txt", atomically: true, encoding: .utf8)
        try "also edited, longer than before".write(toFile: box.home + "/cfg/rep.txt", atomically: true, encoding: .utf8)
        let outcome = try SelectiveRestore.undoDetailed(undoDir!)
        try expectEqual(Set(outcome.keptBecauseChanged), ["cfg/new.txt", "cfg/rep.txt"], "both reported as changed")
        try expectEqual(try String(contentsOfFile: box.home + "/cfg/new.txt", encoding: .utf8),
                        "edited after restore, longer", "created+edited file not deleted")
        try expectEqual(try String(contentsOfFile: box.home + "/cfg/rep.txt", encoding: .utf8),
                        "also edited, longer than before", "replaced+edited file not overwritten")
    }

    /// H2: a repository git cannot read makes the snapshot incomplete, never "nothing to save".
    func test_unreadableRepositoryMakesSnapshotIncomplete() throws {
        guard Shell.git != nil else { return }
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let repo = box.home + "/GitHub/broken"
        _ = try safety.git(["init", "-q", "-b", "main", repo], box.root.path)
        try safety.write("x", to: repo + "/a.txt")
        _ = try safety.git(["add", "."], repo); _ = try safety.git(["commit", "-q", "-m", "c"], repo)
        try "garbage".write(toFile: repo + "/.git/HEAD", atomically: true, encoding: .utf8)
        let result = try safety.runEngine(safety.config(box, sources: ["GitHub"]), box, git: true)
        let record = result.manifest.git.first { $0.relativePath == "GitHub/broken" }
        try expectNotNil(record?.error, "git failure recorded: \(result.manifest.git)")
        try expect(!result.manifest.complete, "snapshot incomplete when a repo cannot be read")
    }

    /// H3: a folder that was in the last complete snapshot and is gone now.
    func test_missingSourceAfterCompleteSnapshotIsIncomplete() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        try safety.write("a", to: box.home + "/keep/a.txt")
        try safety.write("b", to: box.home + "/projects/b.txt")
        let cfg = safety.config(box, sources: ["keep", "projects"])
        let first = try safety.runEngine(cfg, box)
        try expect(first.manifest.complete, "first run complete")
        try FileManager.default.removeItem(atPath: box.home + "/projects")
        let second = try safety.runEngine(cfg, box)
        try expect(!second.manifest.complete, "second run incomplete")
        try expect(second.manifest.incompleteReasons.contains { $0.contains("projects") },
                   "reason names the folder: \(second.manifest.incompleteReasons)")
    }

    /// H4: the remote branch was squash-merged and deleted; local commits sit on top of it.
    /// The bundle must still apply to a fresh clone (which never sees the deleted branch).
    func test_bundleAppliesWhenRemoteBranchWasDeleted() throws {
        guard Shell.git != nil else { return }
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let origin = box.root.appendingPathComponent("origin.git").path
        _ = try safety.git(["init", "-q", "--bare", "-b", "main", origin], box.root.path)
        let repo = box.home + "/GitHub/app"
        _ = try safety.git(["clone", "-q", origin, repo], box.root.path)
        try safety.write("1", to: repo + "/a.txt")
        _ = try safety.git(["add", "."], repo); _ = try safety.git(["commit", "-q", "-m", "base"], repo)
        _ = try safety.git(["push", "-q", "origin", "HEAD:main"], repo)
        _ = try safety.git(["remote", "set-head", "origin", "main"], repo)
        _ = try safety.git(["checkout", "-q", "-b", "feature"], repo)
        try safety.write("2", to: repo + "/b.txt")
        _ = try safety.git(["add", "."], repo); _ = try safety.git(["commit", "-q", "-m", "pushed to feature"], repo)
        _ = try safety.git(["push", "-q", "origin", "feature"], repo)
        // Deleted on the server (squash-merged); the local remote-tracking ref stays stale.
        _ = try safety.git(["--git-dir", origin, "branch", "-D", "feature"], box.root.path)
        try safety.write("3", to: repo + "/c.txt")
        _ = try safety.git(["add", "."], repo); _ = try safety.git(["commit", "-q", "-m", "local only"], repo)
        let tip = try safety.git(["rev-parse", "HEAD"], repo)

        let result = try safety.runEngine(safety.config(box, sources: ["GitHub"]), box, git: true)
        guard let record = result.manifest.git.first, let bundle = record.bundle else {
            throw TestFailure.failed("no bundle: \(result.manifest.git)")
        }
        let fresh = box.root.appendingPathComponent("fresh").path
        _ = try safety.git(["clone", "-q", origin, fresh], box.root.path)
        let url = result.snapshot.appendingPathComponent(SnapshotManifest.directoryName)
            .appendingPathComponent(GitSafety.directoryName).appendingPathComponent(bundle)
        let applied = GitSafety.apply(bundle: url, to: URL(fileURLWithPath: fresh))
        try expect(applied.ok, "bundle applies on a fresh clone: \(applied.stderr)")
        try expectEqual(try safety.git(["rev-parse", "feature"], fresh), tip, "branch restored with both commits")
    }

    /// M4: a folder where the snapshot has a file is left alone, never replaced.
    func test_typeConflictIsLeftAlone() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let snap = URL(fileURLWithPath: box.dest).appendingPathComponent("2026-10-05_000000")
        try safety.write("file", to: snap.path + "/cfg/thing")
        try safety.write("inside", to: box.home + "/cfg/thing/keep.txt")
        let plan = SelectiveRestore.plan(snapshot: snap, paths: ["cfg"], destinationRoot: box.home)
        try expectEqual(plan.items.map(\.action), [.conflict], "planned as conflict")
        _ = try SelectiveRestore.apply(plan, undoRoot: box.root.appendingPathComponent("undo"))
        try expect(FileManager.default.fileExists(atPath: box.home + "/cfg/thing/keep.txt"), "folder untouched")
    }

    /// M5: "." components and internal folders are refused.
    func test_safeRelativeRefusesTricks() throws {
        try expectNil(SelectiveRestore.safeRelative("./_environment/restore.sh"), "internal folder via ./")
        try expectNil(SelectiveRestore.safeRelative("."), "whole snapshot")
        try expectNil(SelectiveRestore.safeRelative("a/../../etc"), "..")
        try expectEqual(SelectiveRestore.safeRelative("./.warp//settings.toml"), ".warp/settings.toml", "normalised")
    }

    /// M8: within one day the complete snapshot is kept, not the later incomplete one.
    func test_retentionSlotPrefersComplete() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let dest = URL(fileURLWithPath: box.dest)
        for day in 1...4 {
            try safety.makeSnapshot(dest, "2026-09-0\(day)_100000", complete: true)
        }
        try safety.makeSnapshot(dest, "2026-09-05_090000", complete: true)
        try safety.makeSnapshot(dest, "2026-09-05_230000", complete: false)
        try safety.makeSnapshot(dest, "2026-09-06_100000", complete: true)
        try safety.makeSnapshot(dest, "2026-09-07_100000", complete: true)
        try safety.makeSnapshot(dest, "2026-09-08_100000", complete: true)
        let pruned = try RetentionManager.pruneLockedBackups(
            at: dest, policy: RetentionConfig(hourly: 0, daily: 30, weekly: 0, monthly: 1), dryRun: true)
        try expect(!pruned.contains("2026-09-05_090000"), "the complete one of the 5th is kept: \(pruned)")
        try expect(pruned.contains("2026-09-05_230000"), "the incomplete one of the 5th goes")
    }

    /// First 3.0 run on a wiped Mac: compared with the newest pre-3.0 snapshot.
    func test_shrinkAgainstUnverifiedBaseline() throws {
        try expectNotNil(SnapshotManifest.shrinkWarning(processed: 500, previous: nil, baselineFiles: 170_000),
                         "a wiped Mac is recognised against an old snapshot")
        try expectNil(SnapshotManifest.shrinkWarning(processed: 160_000, previous: nil, baselineFiles: 170_000),
                      "a normal day is not")
    }
}

/// Second review round (R1–R3).
final class ReviewRound2Tests {
    let safety = SafetyTests()

    /// R1: stopping while the queue is full must not trap (the old semaphore did).
    func test_stopMidBackupDoesNotCrash() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        for i in 0..<20_000 { try safety.write("\(i)", to: "\(box.home)/data/d\(i % 50)/f\(i)") }
        let cfg = safety.config(box, sources: ["data"])
        let writer = StatusWriter(directory: box.state)
        let out = ResultBox<BackupRunResult?>()
        let done = DispatchSemaphore(value: 0)
        Task {
            out.value = try? await BackupEngine.run(config: cfg, statusWriter: writer,
                options: BackupRunOptions(home: box.home, captureEnvironment: false, captureGit: false,
                                          captureDatabases: false, auditCoverage: false))
            done.signal()
        }
        usleep(150_000)
        BackupEngine.stop()
        let finished = done.wait(timeout: .now() + 120)
        try expect(finished == .success, "the run ends after stop")
        try expect(out.value ?? nil == nil, "a stopped run produces no snapshot")
        let leftovers = (try FileManager.default.contentsOfDirectory(atPath: box.dest)).filter { !$0.hasPrefix(".") && $0 != "rustymacbackup.lock" }
        try expectEqual(leftovers, [], "nothing that looks like a snapshot is left")
    }

    /// R2: long output is never cut.
    func test_longOutputIsComplete() throws {
        let r = Shell.run("/usr/bin/seq", ["1", "200000"])
        try expect(r.ok, "seq ran")
        let lines = r.stdout.split(separator: "\n")
        try expectEqual(lines.count, 200_000, "all lines captured")
        try expectEqual(lines.last.map(String.init), "200000", "last line present")
    }

    /// R3: an unchanged set of unpublished commits is hard-linked, not written again.
    func test_unchangedBundleIsHardLinked() throws {
        guard Shell.git != nil else { return }
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let origin = box.root.appendingPathComponent("origin.git").path
        _ = try safety.git(["init", "-q", "--bare", "-b", "main", origin], box.root.path)
        let repo = box.home + "/GitHub/app"
        _ = try safety.git(["clone", "-q", origin, repo], box.root.path)
        try safety.write("1", to: repo + "/a.txt")
        _ = try safety.git(["add", "."], repo); _ = try safety.git(["commit", "-q", "-m", "base"], repo)
        _ = try safety.git(["push", "-q", "origin", "HEAD:main"], repo)
        try safety.write("2", to: repo + "/b.txt")
        _ = try safety.git(["add", "."], repo); _ = try safety.git(["commit", "-q", "-m", "local"], repo)
        let cfg = safety.config(box, sources: ["GitHub"])
        let first = try safety.runEngine(cfg, box, git: true)
        let second = try safety.runEngine(cfg, box, git: true)
        func bundlePath(_ r: BackupRunResult) -> String? {
            r.manifest.git.first?.bundle.map { r.snapshot.appendingPathComponent(SnapshotManifest.directoryName)
                .appendingPathComponent(GitSafety.directoryName).appendingPathComponent($0).path }
        }
        guard let a = bundlePath(first), let b = bundlePath(second) else { throw TestFailure.failed("bundles missing") }
        let inodeA = (try FileManager.default.attributesOfItem(atPath: a))[.systemFileNumber] as? Int
        let inodeB = (try FileManager.default.attributesOfItem(atPath: b))[.systemFileNumber] as? Int
        try expectEqual(inodeA, inodeB, "second snapshot hard-links the same bundle")
    }
}

/// First real 3.0 run on the user's disk (2026-10-06).
final class RealRunTests {
    let safety = SafetyTests()

    /// A `.git` restored from a backup has no objects: a warning, not an incomplete snapshot.
    func test_objectlessGitIsAWarning() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        try safety.write("ref: refs/heads/main\n", to: box.home + "/GitHub/copy/.git/HEAD")
        try safety.write("[core]\n", to: box.home + "/GitHub/copy/.git/config")
        try safety.write("x", to: box.home + "/GitHub/copy/a.txt")
        let result = try safety.runEngine(safety.config(box, sources: ["GitHub"]), box, git: true)
        let record = result.manifest.git.first { $0.relativePath == "GitHub/copy" }
        try expectNil(record?.error, "no error for an objectless copy")
        try expectNotNil(record?.warnings, "but a warning")
        try expect(result.manifest.complete, "snapshot complete: \(result.manifest.incompleteReasons)")
    }

    /// A WAL database is copied (read-only open used to fail with "unable to open").
    func test_walDatabaseIsCopied() throws {
        guard let sqlite = DatabaseDumps.sqlite3 else { return }
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let db = box.home + "/app/history.db"
        try FileManager.default.createDirectory(atPath: box.home + "/app", withIntermediateDirectories: true)
        let made = Shell.run(sqlite, [db, "pragma journal_mode=wal; create table t(x); insert into t values (1),(2);"])
        try expect(made.ok, "fixture: \(made.stderr)")
        var cfg = safety.config(box, sources: ["app"])
        cfg.databases.sqlite = [db]
        let result = try safety.runEngine(cfg, box)
        let record = result.manifest.databases.first
        try expectNil(record?.error, "WAL database copied: \(String(describing: record))")
        try expect(result.manifest.complete, "complete: \(result.manifest.incompleteReasons)")
    }
}
