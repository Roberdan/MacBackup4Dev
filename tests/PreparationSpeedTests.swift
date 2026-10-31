import Foundation

/// Scar 2026-10-31: before every backup the settings were prepared by walking every source for
/// databases, which took 1 to 5 minutes on 171 folders. The preparation now reuses the last audit.
final class PreparationSpeedTests {
    let safety = SafetyTests()

    private func database(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let made = Shell.run("/usr/bin/sqlite3", [path, "CREATE TABLE t(v); INSERT INTO t VALUES(1);"])
        try expect(made.ok, "isolated database \(path): \(made.stderr)")
    }

    private func gap(_ path: String) -> CoverageGap {
        CoverageGap(kind: .database, path: path, lastModified: "", approximateBytes: 1)
    }

    /// A home with one saved folder holding two databases, and a new project holding a third.
    private func fixture() throws -> (box: SafetyTests.Sandbox, url: URL) {
        let box = try safety.makeSandbox()
        try safety.write("old", to: box.home + "/existing/old.txt")
        try database(box.home + "/existing/runtime/known.db")
        try database(box.home + "/existing/runtime/fresh.db")
        try safety.write("new", to: box.home + "/NewFolder/new.txt")
        try database(box.home + "/NewFolder/runtime/new.db")
        let url = box.root.appendingPathComponent("config.toml")
        try safety.config(box, sources: ["existing"]).save(to: url)
        return (box, url)
    }

    func test_aBackupDoesNotWalkTheSavedFoldersForDatabases() throws {
        let (box, url) = try fixture()
        defer { safety.cleanup(box) }
        let known = [gap("~/existing/runtime/known.db")]

        let prepared = try AutomaticCoverage.prepareReporting(from: url, home: box.home, knownDatabaseGaps: known).config
        try expect(prepared.databases.sqlite.contains("~/existing/runtime/known.db"),
                   "what the last audit found is added: \(prepared.databases.sqlite)")
        try expect(!prepared.databases.sqlite.contains("~/existing/runtime/fresh.db"),
                   "the saved folder is not walked again: \(prepared.databases.sqlite)")
        try expect(prepared.source.paths.contains("~/NewFolder")
                   && prepared.databases.sqlite.contains("~/NewFolder/runtime/new.db"),
                   "a new project and its database are still added right now: \(prepared.databases.sqlite)")

        try safety.config(box, sources: ["existing"]).save(to: url)
        let walked = try AutomaticCoverage.prepareReporting(from: url, home: box.home).config
        try expect(walked.databases.sqlite.contains("~/existing/runtime/fresh.db")
                   && walked.databases.sqlite.contains("~/existing/runtime/known.db"),
                   "without an audit the sources are walked, as before: \(walked.databases.sqlite)")
    }

    func test_theAuditOfAFinishedBackupFeedsTheNextPreparation() throws {
        let (box, url) = try fixture()
        defer { safety.cleanup(box) }
        let writer = StatusWriter(directory: box.state)
        try writer.writeCoverage(CoverageReport(checkedAt: ISO8601DateFormatter().string(from: Date()),
                                                gaps: [gap("~/existing/runtime/known.db")]))
        func backup() throws -> Config {
            let options = BackupRunOptions(home: box.home, captureEnvironment: false, captureGit: false,
                                           captureDatabases: false, auditCoverage: true, captureApplications: false)
            let outcome = ResultBox<Result<BackupRunResult?, Error>>()
            let published = ResultBox<Config>()
            let done = DispatchSemaphore(value: 0)
            Task {
                do {
                    outcome.value = .success(try await AutomaticCoverage.prepareAndRun(
                        from: url, statusWriter: writer, options: options, onPrepared: { published.value = $0 }))
                } catch { outcome.value = .failure(error) }
                done.signal()
            }
            done.wait()
            guard try outcome.value!.get() != nil, let config = published.value else { throw TestFailure.failed("backup cancelled") }
            return config
        }

        let first = try backup()
        try expect(first.databases.sqlite.contains("~/existing/runtime/known.db")
                   && !first.databases.sqlite.contains("~/existing/runtime/fresh.db"),
                   "the first backup prepares from the audit it finds: \(first.databases.sqlite)")
        let audited = writer.readCoverage()?.gaps.filter { $0.kind == .database }.map(\.path) ?? []
        try expect(audited.contains("~/existing/runtime/fresh.db"),
                   "its own audit, at the end, looks at the saved folders: \(audited)")
        let second = try backup()
        try expect(second.databases.sqlite.contains("~/existing/runtime/fresh.db"),
                   "and the next backup adds the database it found, without walking: \(second.databases.sqlite)")
    }

    func test_aDatabaseTheAuditListedButThatChangedIsNotAdded() throws {
        let (box, url) = try fixture()
        defer { safety.cleanup(box) }
        let fm = FileManager.default
        let runtime = box.home + "/existing/runtime"
        try safety.write("", to: runtime + "/empty.db")
        try database(runtime + "/stale.db")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86_400)], ofItemAtPath: runtime + "/stale.db")
        try fm.createSymbolicLink(atPath: runtime + "/link.db", withDestinationPath: runtime + "/known.db")
        let listed = ["known", "gone", "empty", "stale", "link"].map { gap("~/existing/runtime/\($0).db") }

        let kept = AutomaticCoverage.stillThere(listed, home: box.home).map(\.path)
        try expectEqual(kept, ["~/existing/runtime/known.db"],
                        "gone, empty, untouched for a month and linked databases are dropped")
        let folder = CoverageGap(kind: .folder, path: "~/Elsewhere", lastModified: "", approximateBytes: 1)
        try expect(AutomaticCoverage.stillThere([folder], home: box.home).isEmpty, "only databases are taken from the audit")
        // The audit's file is read back: a hand-edited or damaged path must not reach the string checks that follow.
        let tampered = ["~/existing/../.config/secrets/x.db", "~/existing/./runtime/known.db",
                        "~/existing//runtime/known.db", "~/existing/runtime/known.db/"].map(gap)
        try expect(AutomaticCoverage.stillThere(tampered, home: box.home).isEmpty,
                   "paths with ., .. or empty parts are not trusted: \(AutomaticCoverage.stillThere(tampered, home: box.home))")

        let prepared = try AutomaticCoverage.prepareReporting(from: url, home: box.home, knownDatabaseGaps: listed).config
        try expectEqual(prepared.databases.sqlite.filter { $0.hasPrefix("~/existing/") }, ["~/existing/runtime/known.db"],
                        "a backup adds only what is still there")

        try database(box.home + "/Documents/outside.db")
        try safety.config(box, sources: ["existing"]).save(to: url)
        let outside = listed + [gap("~/Documents/outside.db")]
        let again = try AutomaticCoverage.prepareReporting(from: url, home: box.home, knownDatabaseGaps: outside).config
        try expect(!again.databases.sqlite.contains("~/Documents/outside.db"),
                   "a database outside the saved folders, from an old audit, is not added: \(again.databases.sqlite)")
    }

    /// Round 1 of @thor: a `..` in a path made the search for links turn for ever, and so stalled every backup.
    /// Round 2: the first version of this test never got into the loop, because nothing it named existed
    /// and the first look at the path already failed; the folders and the file must be there.
    func test_aPathWithParentPartsNeverHangsTheSearchForLinks() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        try FileManager.default.createDirectory(atPath: box.home + "/existing", withIntermediateDirectories: true)
        try safety.write("x", to: box.home + "/.config/secrets/x.db")
        let done = DispatchSemaphore(value: 0)
        let answer = ResultBox<Bool>()
        let path = box.home + "/existing/../.config/secrets/x.db"
        try expect(FileManager.default.fileExists(atPath: path), "fixture: the path really leads to a file")
        let home = box.home
        Thread.detachNewThread {
            answer.value = AutomaticCoverage.hasLinkedAncestor(path, home: home)
            done.signal()
        }
        try expect(done.wait(timeout: .now() + 10) == .success, "the search for links ends")
        try expectEqual(answer.value, true, "and a path it cannot climb is not trusted")
    }

    /// Scar 2026-10-31: the cleanup of old saved worktree copies ran before the copy and made it wait up to
    /// 30 s at every backup. It runs once the snapshot is made, and never on the snapshot just made.
    func test_theCleanupOfOldWorktreeCopiesWaitsForTheCopy() throws {
        guard Shell.git != nil else { return }
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let fm = FileManager.default
        try safety.write("source", to: box.home + "/GitHub/main/file.txt")
        try safety.makeRepository(box.home + "/GitHub/main")
        let config = safety.config(box, sources: ["GitHub/main"])
        let first = try safety.runEngine(config, box).snapshot
        let copy = first.appendingPathComponent("GitHub/worktrees/main/gone")
        try safety.write("gitdir: \(box.home)/GitHub/main/.git/worktrees/gone\n", to: copy.path + "/.git")
        try safety.write("temporary", to: copy.path + "/file.txt")

        // The environment capture runs once the new snapshot is complete, before the cleanup.
        let stillThere = ResultBox<Bool>()
        var options = BackupRunOptions(home: box.home, captureEnvironment: true, captureGit: false,
                                       captureDatabases: false, auditCoverage: false, captureApplications: false)
        options.environmentCapture = { _ in stillThere.value = FileManager.default.fileExists(atPath: copy.path + "/file.txt") }
        let runOptions = options
        let outcome = ResultBox<Result<BackupRunResult?, Error>>()
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                outcome.value = .success(try await BackupEngine.run(config: config, statusWriter: StatusWriter(directory: box.state),
                                                                    options: runOptions))
            } catch { outcome.value = .failure(error) }
            done.signal()
        }
        done.wait()
        guard let second = try outcome.value!.get() else { throw TestFailure.failed("backup cancelled") }
        try expectEqual(stillThere.value, true, "the old copy is still there while the new snapshot is being made")
        try expect(!fm.fileExists(atPath: copy.path), "and it is gone when the backup has finished")
        try expectEqual(SnapshotManifest.read(from: second.snapshot)?.removedTemporaryWorktrees?.count ?? 0, 0,
                        "the snapshot just made is left alone: the removal is recorded in the old one")
        try expectEqual(SnapshotManifest.read(from: first)?.removedTemporaryWorktrees?.map(\.path), ["GitHub/worktrees/main/gone"],
                        "in the snapshot that held the copy")
    }
}
