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

    /// The path every backup takes (preparation, then the real engine), in the sandbox; databases saved.
    private func prepareAndBackUp(_ url: URL, _ writer: StatusWriter, _ box: SafetyTests.Sandbox,
                                  captureDatabases: Bool = true) throws -> (result: BackupRunResult, config: Config) {
        let options = BackupRunOptions(home: box.home, captureEnvironment: false, captureGit: false,
                                       captureDatabases: captureDatabases, auditCoverage: true, captureApplications: false)
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
        guard let result = try outcome.value!.get(), let config = published.value else {
            throw TestFailure.failed("backup cancelled")
        }
        return (result, config)
    }

    /// Roberto's choice of 2026-11-01 (card 261031-212344): database files are left out of the plain copy, so a
    /// database created inside a saved folder after the last check, which the preparation no longer looks for,
    /// stayed out of every snapshot for one more run. The backup's own search, made right before the databases
    /// are saved, saves it in the same run.
    func test_aNewDatabaseInASavedFolderIsSavedByTheSameBackup() throws {
        let (box, url) = try fixture()
        defer { safety.cleanup(box) }
        let fm = FileManager.default
        let writer = StatusWriter(directory: box.state)
        // The last check found nothing new: the database below appears after it.
        try writer.writeCoverage(CoverageReport(checkedAt: ISO8601DateFormatter().string(from: Date()), gaps: []))
        let created = "existing/app/data/brand-new.db"
        try database(box.home + "/" + created)

        let (result, _) = try prepareAndBackUp(url, writer, box)
        let snapshot = result.snapshot
        try expect(!fm.fileExists(atPath: snapshot.appendingPathComponent(created).path),
                   "fixture: database files stay out of the plain copy, as in the real settings")
        let dump = snapshot.appendingPathComponent(SnapshotManifest.directoryName)
            .appendingPathComponent(DatabaseDumps.directoryName).appendingPathComponent("sqlite").appendingPathComponent(created)
        try expect(fm.fileExists(atPath: dump.path), "the new database is in the backup that ran after its creation: \(dump.path)")
        let read = Shell.run("/usr/bin/sqlite3", [dump.path, "SELECT count(*) FROM t;"])
        try expectEqual(read.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "1", "and its copy is a readable database")
        let record = result.manifest.databases.first { $0.source == "~/" + created }
        try expect(record != nil && record?.error == nil && record?.file != nil,
                   "the snapshot lists it as saved: \(result.manifest.databases.map(\.source))")
        for older in ["existing/runtime/known.db", "existing/runtime/fresh.db"] {
            try expect(result.manifest.databases.contains { $0.source == "~/" + older && $0.error == nil },
                       "so are the databases of the saved folder that the last check did not list: \(older)")
        }
        try expect(result.manifest.complete, "the snapshot is complete: \(result.manifest.incompleteReasons)")
    }

    /// What a backup saved by itself is announced once, by that backup: its snapshot, its status and the check's
    /// file say so, the settings are not touched while it runs, and the next preparation writes it in from the
    /// file, without a walk and without announcing it a second time.
    func test_whatABackupSavedByItselfIsAnnouncedOnceAndEntersTheSettingsNext() throws {
        let (box, url) = try fixture()
        defer { safety.cleanup(box) }
        let writer = StatusWriter(directory: box.state)
        try writer.writeCoverage(CoverageReport(checkedAt: ISO8601DateFormatter().string(from: Date()), gaps: []))
        let created = "~/existing/app/data/brand-new.db"
        try database(ConfigDiscovery.expand(created, home: box.home))

        let first = try prepareAndBackUp(url, writer, box)
        try expect(!first.config.databases.sqlite.contains(created), "fixture: the preparation did not know it")
        try expect(!(try Config.load(from: url)).databases.sqlite.contains(created), "the settings are not touched during the backup")
        try expect(first.result.manifest.automaticallyIncluded?.contains(created) == true,
                   "the snapshot records it as added by itself: \(first.result.manifest.automaticallyIncluded ?? [])")
        try expect(writer.read()?.autoIncluded?.contains(created) == true,
                   "so does the status, for the menu's \"Aggiunte da sole\": \(writer.read()?.autoIncluded ?? [])")
        guard let report = writer.readCoverage() else { throw TestFailure.failed("no coverage report") }
        try expect(report.addedByBackup?.contains { $0.path == created } == true, "the check's file says this backup saved it")
        try expect(!report.gaps.contains { $0.path == created }, "and no longer lists it as a gap: \(report.gaps.map(\.path))")
        let coming = AutomaticCoverage.pending(config: try Config.load(from: url), home: box.home, knownDatabaseGaps: report.gaps)
        try expect(!coming.contains { $0.path == created }, "the menu does not announce it as still to come: \(coming.map(\.path))")

        let second = try prepareAndBackUp(url, writer, box)
        try expect(second.config.databases.sqlite.contains(created) && (try Config.load(from: url)).databases.sqlite.contains(created),
                   "the next preparation writes it into the settings: \(second.config.databases.sqlite)")
        try expect(!(writer.read()?.autoIncluded ?? []).contains(created) && !(second.result.manifest.automaticallyIncluded ?? []).contains(created),
                   "without announcing it again: \(writer.read()?.autoIncluded ?? [])")
        try expect(second.result.manifest.databases.contains { $0.source == created && $0.error == nil },
                   "and the backup saves it from the settings: \(second.result.manifest.databases.map(\.source))")
        try expect(writer.readCoverage()?.addedByBackup == nil, "nothing was left to save by itself")
    }

    /// The backup saves by itself only what a preparation would add: never a database the user left out or one in a
    /// folder named like a secret, and nothing when automatic additions are switched off. The check still lists them.
    func test_theBackupSavesByItselfOnlyWhatAPreparationWouldAdd() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        try safety.write("notes", to: box.home + "/existing/notes.txt")
        for name in ["app/data/kept.db", "credentials/app.db", "ignored/app.db"] {
            try database(box.home + "/existing/" + name)
        }
        var config = safety.config(box, sources: ["existing"])
        config.coverage.ignore = ["~/existing/ignored"]
        let url = box.root.appendingPathComponent("config.toml")
        try config.save(to: url)
        let writer = StatusWriter(directory: box.state)

        // No earlier check at all (first backup, or its file was removed): the preparation does not walk the saved
        // folders either; the backup's own check finds what they hold.
        let first = try prepareAndBackUp(url, writer, box)
        try expect(first.config.databases.sqlite.isEmpty, "the preparation did not walk: \(first.config.databases.sqlite)")
        let saved = first.result.manifest.databases.map(\.source)
        try expectEqual(saved, ["~/existing/app/data/kept.db"], "only what a preparation would add is saved by itself")

        config.coverage.autoInclude = false
        try config.save(to: url)
        try writer.writeCoverage(CoverageReport(checkedAt: ISO8601DateFormatter().string(from: Date()), gaps: []))
        let off = try prepareAndBackUp(url, writer, box).result.manifest
        try expect(off.databases.isEmpty && off.automaticallyIncluded == nil,
                   "with automatic additions off nothing is saved by itself: \(off.databases.map(\.source))")
        let listed = writer.readCoverage()?.gaps.map(\.path) ?? []
        for name in ["app/data/kept.db", "credentials/app.db", "ignored/app.db"] {
            try expect(listed.contains("~/existing/" + name), "the check still lists \(name): \(listed)")
        }
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
                   "its own check looks at the saved folders: \(audited)")
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
