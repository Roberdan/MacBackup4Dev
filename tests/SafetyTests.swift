import Foundation

/// 3.0 safety net: each test reproduces something that went wrong on 2026-10-06.
final class SafetyTests {
    // MARK: - Helpers

    struct Sandbox {
        let root: URL
        var home: String { root.appendingPathComponent("home").path }
        var dest: String { root.appendingPathComponent("dest").path }
        var state: String { root.appendingPathComponent("state").path }
    }

    func makeSandbox() throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmb-safety-\(UUID().uuidString)")
        let box = Sandbox(root: root)
        for dir in [box.home, box.dest, box.state] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        return box
    }

    func cleanup(_ box: Sandbox) {
        _ = Shell.run("/bin/chmod", ["-R", "u+rwX", box.root.path])
        try? FileManager.default.removeItem(at: box.root)
    }

    func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func config(_ box: Sandbox, sources: [String]) -> Config {
        Config(source: SourceConfig(paths: sources.map { box.home + "/" + $0 }),
               destination: DestinationConfig(path: box.dest),
               exclude: ExcludeConfig(patterns: defaultExcludePatterns),
               retention: RetentionConfig())
    }

    func runEngine(_ cfg: Config, _ box: Sandbox, git: Bool = false) throws -> BackupRunResult {
        let options = BackupRunOptions(home: box.home, captureEnvironment: false, captureGit: git,
                                       captureDatabases: !cfg.databases.sqlite.isEmpty, auditCoverage: false)
        let writer = StatusWriter(directory: box.state)
        let box2 = ResultBox<Result<BackupRunResult?, Error>>()
        let done = DispatchSemaphore(value: 0)
        Task {
            do { box2.value = .success(try await BackupEngine.run(config: cfg, statusWriter: writer, options: options)) }
            catch { box2.value = .failure(error) }
            done.signal()
        }
        done.wait()
        switch box2.value! {
        case .success(let r): guard let r else { throw TestFailure.failed("backup cancelled") }; return r
        case .failure(let e): throw e
        }
    }

    func countFiles(_ path: String, skipping: [String] = [SnapshotManifest.directoryName]) -> Int {
        guard let e = FileManager.default.enumerator(atPath: path) else { return 0 }
        var n = 0
        while let rel = e.nextObject() as? String {
            if skipping.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) { continue }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path + "/" + rel, isDirectory: &isDir)
            if !isDir.boolValue { n += 1 }
        }
        return n
    }

    func git(_ args: [String], _ cwd: String) throws -> String {
        let r = Shell.run(Shell.git!, args, cwd: cwd, environment: [
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"])
        guard r.ok else { throw TestFailure.failed("git \(args.joined(separator: " ")): \(r.stderr)") }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Engine

    /// Scar: `.bufferingNewest(256)` silently dropped files. Every discovered file must land.
    func test_noFileIsDropped() throws {
        let box = try makeSandbox(); defer { cleanup(box) }
        let total = 6_000
        for i in 0..<total {
            try write("file \(i)", to: "\(box.home)/data/d\(i % 40)/f\(i).txt")
        }
        let result = try runEngine(config(box, sources: ["data"]), box)
        try expectEqual(countFiles(result.snapshot.path), total, "every file must be in the snapshot")
        try expectEqual(result.manifest.filesDiscovered, Int64(total), "discovered count")
        try expectEqual(result.manifest.filesProcessed, Int64(total), "processed count")
        try expect(result.manifest.complete, "snapshot must be complete: \(result.manifest.incompleteReasons)")
        try expectEqual(SnapshotCatalog.latestComplete(at: URL(fileURLWithPath: box.dest))?.name,
                        result.snapshot.lastPathComponent, "catalog sees it as complete")
    }

    /// Scar: a snapshot with copy errors was named like a good one and restored by default.
    func test_copyErrorMakesSnapshotIncomplete() throws {
        let box = try makeSandbox(); defer { cleanup(box) }
        try write("ok", to: "\(box.home)/data/good.txt")
        try write("secret", to: "\(box.home)/data/locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: "\(box.home)/data/locked.txt")
        let result = try runEngine(config(box, sources: ["data"]), box)
        try expect(!result.manifest.complete, "an unreadable file must make the snapshot incomplete")
        try expect(result.manifest.incompleteReasons.contains { $0.contains("errore") },
                   "reason names the copy error: \(result.manifest.incompleteReasons)")
        let dest = URL(fileURLWithPath: box.dest)
        try expectNil(SnapshotCatalog.latestComplete(at: dest), "no complete snapshot exists")
        try expectNil(SnapshotCatalog.defaultForRestore(at: dest), "an incomplete snapshot is never the restore default")
        let status = StatusWriter(directory: box.state).read()
        try expectEqual(status?.lastResult, "incomplete", "status says incomplete")
    }

    func test_shrinkWarningOnEmptiedHome() throws {
        var prev = SnapshotManifest(appVersion: "t", host: "h", startedAt: "", finishedAt: "", sources: [],
                                    missingSources: [], filesDiscovered: 10_000, filesProcessed: 10_000,
                                    filesCopied: 0, filesHardlinked: 0, filesSkipped: 0, bytesCopied: 0,
                                    errorCount: 0, traversalErrorCount: 0, git: [], databases: [],
                                    shrinkWarning: nil, complete: true, incompleteReasons: [])
        try expectNotNil(SnapshotManifest.shrinkWarning(processed: 900, previous: prev), "9% of files is a new Mac")
        try expectNil(SnapshotManifest.shrinkWarning(processed: 5_000, previous: prev), "50% is a normal cleanup")
        prev.complete = false
        try expectNil(SnapshotManifest.shrinkWarning(processed: 900, previous: prev), "only compare with a complete one")
        let (complete, reasons) = SnapshotManifest.evaluate(discovered: 10, processed: 10, walkerFinished: true,
            errors: 0, traversalErrors: 0, gitFailures: [], databaseFailures: [], shrinkWarning: "x")
        try expect(!complete && reasons == ["x"], "a shrunk snapshot is never complete")
    }

    // MARK: - Retention

    func makeSnapshot(_ dest: URL, _ name: String, complete: Bool?, shrink: String? = nil) throws {
        let url = dest.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "x".write(to: url.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        guard let complete else { return }
        let m = SnapshotManifest(appVersion: "t", host: "h", startedAt: "", finishedAt: "", sources: [],
                                 missingSources: [], filesDiscovered: 1, filesProcessed: 1, filesCopied: 1,
                                 filesHardlinked: 0, filesSkipped: 0, bytesCopied: 1, errorCount: 0,
                                 traversalErrorCount: 0, git: [], databases: [], shrinkWarning: shrink,
                                 complete: complete, incompleteReasons: complete ? [] : ["x"])
        try m.write(to: url)
    }

    func test_retentionProtectsLastCompleteSnapshots() throws {
        let box = try makeSandbox(); defer { cleanup(box) }
        let dest = URL(fileURLWithPath: box.dest)
        // Newest first: 2 incomplete on top, then 4 complete, all in the same hour.
        try makeSnapshot(dest, "2026-10-06_100600", complete: false)
        try makeSnapshot(dest, "2026-10-06_100500", complete: false)
        try makeSnapshot(dest, "2026-10-06_100400", complete: true)
        try makeSnapshot(dest, "2026-10-06_100300", complete: true)
        try makeSnapshot(dest, "2026-10-06_100200", complete: true)
        try makeSnapshot(dest, "2026-10-06_100100", complete: true)
        let policy = RetentionConfig(hourly: 1, daily: 1, weekly: 1, monthly: 1)
        let pruned = try RetentionManager.pruneLockedBackups(at: dest, policy: policy, dryRun: true)
        for kept in ["2026-10-06_100400", "2026-10-06_100300", "2026-10-06_100200"] {
            try expect(!pruned.contains(kept), "complete snapshot \(kept) must be protected")
        }
        try expect(pruned.contains("2026-10-06_100500"), "an incomplete snapshot is not protected")
        try expect(pruned.contains("2026-10-06_100100"), "the 4th complete one may go")
    }

    func test_retentionPausesAfterShrink() throws {
        let box = try makeSandbox(); defer { cleanup(box) }
        let dest = URL(fileURLWithPath: box.dest)
        try makeSnapshot(dest, "2026-10-06_100600", complete: false, shrink: "nuovo Mac")
        for i in 0..<5 { try makeSnapshot(dest, "2026-10-0\(i + 1)_000000", complete: true) }
        let pruned = try RetentionManager.pruneLockedBackups(
            at: dest, policy: RetentionConfig(hourly: 1, daily: 1, weekly: 1, monthly: 1), dryRun: true)
        try expectEqual(pruned, [], "nothing is pruned while the Mac looks new")
    }

    // MARK: - Git

    /// Scar: commits never pushed were lost because `.git/objects` is not copied.
    func test_unpushedCommitsSurviveRestore() throws {
        guard Shell.git != nil else { return }
        let box = try makeSandbox(); defer { cleanup(box) }
        let origin = box.root.appendingPathComponent("origin.git").path
        _ = try git(["init", "-q", "--bare", "-b", "main", origin], box.root.path)
        let repo = box.home + "/GitHub/app"
        _ = try git(["clone", "-q", origin, repo], box.root.path)
        try write("one", to: repo + "/a.txt")
        _ = try git(["add", "."], repo); _ = try git(["commit", "-q", "-m", "pushed"], repo)
        _ = try git(["push", "-q", "origin", "HEAD:main"], repo)
        _ = try git(["checkout", "-q", "-b", "feature"], repo)
        try write("two", to: repo + "/b.txt")
        _ = try git(["add", "."], repo); _ = try git(["commit", "-q", "-m", "never pushed"], repo)
        let featureSHA = try git(["rev-parse", "feature"], repo)
        try write("wip", to: repo + "/a.txt")
        _ = try git(["stash", "-q"], repo)

        let result = try runEngine(config(box, sources: ["GitHub"]), box, git: true)
        guard let record = result.manifest.git.first(where: { $0.relativePath == "GitHub/app" }) else {
            throw TestFailure.failed("repo not recorded: \(result.manifest.git)")
        }
        try expectNil(record.error, "no git error")
        try expectEqual(record.stashes, 1, "stash counted")
        try expect(record.unpushedCommits >= 1, "unpushed commit counted")
        guard let bundle = record.bundle else { throw TestFailure.failed("no bundle written") }
        try expect(result.manifest.complete, "complete: \(result.manifest.incompleteReasons)")

        // New Mac: clone from the remote, then put the saved commits back.
        let fresh = box.root.appendingPathComponent("fresh").path
        _ = try git(["clone", "-q", origin, fresh], box.root.path)
        let bundleURL = result.snapshot.appendingPathComponent(SnapshotManifest.directoryName)
            .appendingPathComponent(GitSafety.directoryName).appendingPathComponent(bundle)
        let applied = GitSafety.apply(bundle: bundleURL, to: URL(fileURLWithPath: fresh))
        try expect(applied.ok, "bundle applies: \(applied.stderr)")
        let restoredSHA = try git(["rev-parse", "feature"], fresh)
        try expectEqual(restoredSHA, featureSHA, "branch restored at the same commit")
        _ = try git(["rev-parse", "recupero/stash"], fresh)
    }

    // MARK: - Databases

    func test_sqliteIsCopiedConsistently() throws {
        guard let sqlite = DatabaseDumps.sqlite3 else { return }
        let box = try makeSandbox(); defer { cleanup(box) }
        let db = box.home + "/app/runtime/history.db"
        try FileManager.default.createDirectory(atPath: box.home + "/app/runtime", withIntermediateDirectories: true)
        let made = Shell.run(sqlite, [db, "create table t(x); insert into t values (1),(2),(3);"])
        try expect(made.ok, "sqlite fixture: \(made.stderr)")
        var cfg = config(box, sources: ["app"])
        cfg.databases.sqlite = [db]
        let result = try runEngine(cfg, box)
        guard let record = result.manifest.databases.first, let file = record.file else {
            throw TestFailure.failed("database not recorded: \(result.manifest.databases)")
        }
        try expectNil(record.error, "no database error")
        let copy = result.snapshot.appendingPathComponent(file).path
        let count = Shell.run(sqlite, [copy, "select count(*) from t;"])
        try expectEqual(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "3", "copy is a readable database")
    }

    // MARK: - Coverage

    /// Scar: ~/Obsidian was used every day and in no snapshot.
    func test_coverageFindsActiveUncoveredFolder() throws {
        let box = try makeSandbox(); defer { cleanup(box) }
        try write("x", to: box.home + "/covered/a.txt")
        try write("note", to: box.home + "/Obsidian/Vault/note.md")
        try write("x", to: box.home + "/Documents/private.txt")        // protected by macOS
        try write("x", to: box.home + "/ignored/a.txt")
        try write("x", to: box.home + "/GitHub/tracked/a.txt")
        try write("x", to: box.home + "/GitHub/untracked/a.txt")
        try write("x", to: box.home + "/.cache/blob")                  // cache, never config
        var cfg = config(box, sources: ["covered", "GitHub/tracked"])
        cfg.coverage.ignore = [box.home + "/ignored"]
        let paths = Set(CoverageAuditor.audit(config: cfg, home: box.home).filter { $0.kind == .folder }.map(\.path))
        try expect(paths.contains { $0.hasSuffix("/Obsidian") }, "Obsidian reported: \(paths)")
        try expect(paths.contains { $0.hasSuffix("/GitHub/untracked") }, "untracked project reported: \(paths)")
        for quiet in ["/covered", "/Documents", "/ignored", "/GitHub/tracked", "/.cache", "/GitHub"] {
            try expect(!paths.contains { $0.hasSuffix(quiet) }, "\(quiet) must not be reported: \(paths)")
        }
    }

    // MARK: - Config

    func test_configRoundTripNewSections() throws {
        let box = try makeSandbox(); defer { cleanup(box) }
        var cfg = config(box, sources: ["a"])
        cfg.databases = DatabaseConfig(sqlite: ["~/x/history.db"], postgres: ["casa_caccini"])
        cfg.coverage.ignore = ["~/Scratch"]
        cfg.topics = ["Mio progetto": ["~/GitHub/mio", "~/.config/mio"]]
        let url = box.root.appendingPathComponent("config.toml")
        try cfg.save(to: url)
        let back = try Config.load(from: url)
        try expectEqual(back.databases, cfg.databases, "databases survive")
        try expectEqual(back.coverage, cfg.coverage, "coverage survives")
        try expectEqual(back.topics, cfg.topics, "topics survive")
        try expectEqual(back.source.paths, cfg.source.paths, "sources unchanged")
    }
}
