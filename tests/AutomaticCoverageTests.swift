import Foundation

final class AutomaticCoverageTests {
    let safety = SafetyTests()

    func test_newFoldersAndToolsEnterTheNextBackup() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        try safety.write("old", to: box.home + "/existing/old.txt")
        try safety.write("new", to: box.home + "/NewFolder/new.txt")
        try safety.write("set number", to: box.home + "/.config/nvim/init.vim")
        let database = box.home + "/NewFolder/runtime/history.db"
        try FileManager.default.createDirectory(atPath: (database as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let created = Shell.run("/usr/bin/sqlite3", [database, "CREATE TABLE saved(value); INSERT INTO saved VALUES(7);"])
        try expect(created.ok, "create a real isolated project database: \(created.stderr)")
        let url = box.root.appendingPathComponent("config.toml")
        var config = safety.config(box, sources: ["existing"])
        config.protection.includeRightsManagedFiles = true
        config.databases.postgres = ["explicit-database"]
        config.topics = ["mine": ["existing"]]
        try config.save(to: url)

        let prepared = try AutomaticCoverage.prepare(from: url, home: box.home)
        try expect(prepared.source.paths.contains("~/NewFolder"), "new active folder included without confirmation")
        try expect(prepared.source.paths.contains("~/.config/nvim"), "new safe tool included individually")
        try expect(!prepared.source.paths.contains("~/.config"), "never widen to every tool's login tokens")
        try expect(prepared.protection.includeRightsManagedFiles, "saved protection choice preserved")
        try expectEqual(prepared.databases.postgres, ["explicit-database"], "no implicit PostgreSQL discovery")
        try expect(prepared.databases.sqlite.contains("~/NewFolder/runtime/history.db"),
                   "new project's excluded SQLite file gets a consistent backup on its first run: \(prepared.databases.sqlite)")
        try expectEqual(prepared.topics, config.topics, "restore topics preserved")
        try expectEqual(try Config.load(from: url).source.paths, prepared.source.paths, "additions persist")
        let bytes = try Data(contentsOf: url)
        _ = try AutomaticCoverage.prepare(from: url, home: box.home)
        try expectEqual(try Data(contentsOf: url), bytes, "repeat discovery never rewrites or duplicates")

        var engineConfig = prepared
        engineConfig.databases.postgres = []
        let result = try safety.runEngine(engineConfig, box)
        try expect(result.manifest.complete, "real backup is complete: \(result.manifest.incompleteReasons)")
        try expectEqual(try String(contentsOf: result.snapshot.appendingPathComponent("NewFolder/new.txt"), encoding: .utf8),
                        "new", "new folder actually copied in the very next snapshot")
        try expect(FileManager.default.fileExists(atPath: result.snapshot.path + "/.config/nvim/init.vim"),
                   "new tool actually copied")
        guard let record = result.manifest.databases.first, let copied = record.file else {
            throw TestFailure.failed("real SQLite backup missing from the first snapshot")
        }
        try expectNil(record.error, "automatic SQLite backup succeeded")
        let queried = Shell.run("/usr/bin/sqlite3", [result.snapshot.appendingPathComponent(copied).path, "SELECT value FROM saved;"])
        try expectEqual(queried.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "7",
                        "copied database really contains the source data")
    }

    func test_secretsExclusionsAndLinksAreNeverAutomatic() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        for path in ["existing/a.txt", "ignored/a.txt", "excluded/a.txt", "secrets/a.txt",
                     ".config/gh/hosts.yml", ".config/secrets/plain.txt", ".roberdan-os/private/data.txt",
                     ".copilot/session-state/state.txt", ".codex/auth.json", ".unknown-tool/token.json", "Dropbox/file.txt",
                     "GitHub/repo/worktrees/agent/a.txt", "GitHub/linked/a.txt"] {
            try safety.write("data", to: box.home + "/" + path)
        }
        try safety.write("gitdir: \(box.home)/GitHub/repo/.git/worktrees/linked\n", to: box.home + "/GitHub/linked/.git")
        try FileManager.default.createSymbolicLink(atPath: box.home + "/cloud-link", withDestinationPath: box.root.path)
        let url = box.root.appendingPathComponent("config.toml")
        var config = safety.config(box, sources: ["existing"])
        config.coverage.ignore = ["~/ignored", "~/GitHub/repo"]
        config.exclude.patterns.append("excluded")
        try config.save(to: url)
        let prepared = try AutomaticCoverage.prepare(from: url, home: box.home)
        let added = prepared.source.paths.filter { !config.source.paths.contains($0) }
        for path in added {
            try expect(!["ignored", "excluded", "secrets", ".config/gh", ".config/secrets",
                         ".roberdan-os", ".copilot", ".codex", ".unknown-tool", "cloud-link",
                         "GitHub", "Dropbox"].contains(String(path.dropFirst(2))), "unsafe or opted-out root auto-added: \(path)")
            try expect(!path.contains("worktrees") && !path.hasSuffix("/linked"), "temporary worktrees stay out")
        }
        let filter = ExcludeFilter(patterns: [])
        try expect(filter.isExcluded(relativePath: ".roberdan-os/private/data"), "private data blocked even with old config")
        try expect(filter.isExcluded(relativePath: ".config/secrets/data"), "secret directory blocked even with old config")
    }

    func test_pickerOptOutAndAutoIncludeSwitchPersist() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        try safety.write("x", to: box.home + "/kept/a.txt")
        try safety.write("x", to: box.home + "/declined/a.txt")
        try safety.write("x", to: box.home + "/newly-visible/a.txt")
        let url = box.root.appendingPathComponent("config.toml")
        try safety.config(box, sources: ["kept", "declined"]).save(to: url)
        let chosen = try AutomaticCoverage.prepare(from: url, selectedPaths: ["~/kept"], home: box.home)
        try expectEqual(chosen.source.paths, ["~/kept"], "picker remains the user's exact choice")
        let next = try AutomaticCoverage.prepare(from: url, home: box.home)
        try expectEqual(next.source.paths, ["~/kept"], "unchosen old and newly visible items stay off")
        try expect(next.coverage.ignore.contains("~/newly-visible"), "visible unchecked candidate remembered")
        var disabled = next
        disabled.coverage.autoInclude = false
        try disabled.save(to: url)
        try safety.write("x", to: box.home + "/later/a.txt")
        let stopped = try AutomaticCoverage.prepare(from: url, home: box.home)
        try expectEqual(stopped.source.paths, ["~/kept"], "explicit auto-include opt-out honored")
        try expect(!stopped.coverage.autoInclude, "auto-include switch round trips")
    }

    func test_partialSelectionNeverBroadensItsParent() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        try safety.write("x", to: box.home + "/GitHub/one/selected/file.txt")
        try safety.write("private", to: box.home + "/GitHub/one/unselected/file.txt")
        try safety.write("new", to: box.home + "/GitHub/two/file.txt")
        let url = box.root.appendingPathComponent("config.toml")
        try safety.config(box, sources: ["GitHub/one/selected"]).save(to: url)
        let prepared = try AutomaticCoverage.prepare(from: url, home: box.home)
        try expect(!prepared.source.paths.contains("~/GitHub"), "selected project is not permission for whole root")
        try expect(!prepared.source.paths.contains("~/GitHub/one"), "selected subtree is never broadened")
        try expect(prepared.source.paths.contains("~/GitHub/two"), "new independent project still added")
    }

    /// Scar 2026-10-31: choosing the projects one by one recorded their folder as rejected, so a
    /// project created later under it was neither added nor shown.
    func test_choosingFoldersOneByOneNeverRejectsTheirContainer() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        for project in ["one", "two", "skipped"] { try safety.write("x", to: box.home + "/GitHub/\(project)/file.txt") }
        let url = box.root.appendingPathComponent("config.toml")
        var config = safety.config(box, sources: [])
        config.source.paths = ["~/GitHub"]
        try config.save(to: url)

        let chosen = try AutomaticCoverage.prepare(from: url, selectedPaths: ["~/GitHub/one", "~/GitHub/two"], home: box.home)
        try expectEqual(chosen.source.paths, ["~/GitHub/one", "~/GitHub/two"], "the picker stays the exact choice")
        try expect(!chosen.coverage.ignore.contains("~/GitHub"),
                   "a folder holding chosen paths is not rejected: \(chosen.coverage.ignore)")
        try expect(chosen.coverage.ignore.contains("~/GitHub/skipped"), "what was left unchecked is still remembered")

        try safety.write("x", to: box.home + "/GitHub/new-project/file.txt")
        let next = try AutomaticCoverage.prepare(from: url, home: box.home)
        try expect(next.source.paths.contains("~/GitHub/new-project"),
                   "a new project under the same folder is added by itself: \(next.source.paths)")
        try expect(!next.source.paths.contains("~/GitHub") && !next.source.paths.contains("~/GitHub/skipped"),
                   "neither the whole folder nor the unchecked project comes back")
    }

    func test_pickerConfirmationHealsAContainerRejectedBefore() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        for project in ["one", "skipped"] { try safety.write("x", to: box.home + "/GitHub/\(project)/file.txt") }
        let url = box.root.appendingPathComponent("config.toml")
        var config = safety.config(box, sources: [])
        config.source.paths = ["~/GitHub/one"]
        config.coverage.ignore = ["~/GitHub", "~/GitHub/skipped"]
        try config.save(to: url)

        let chosen = try AutomaticCoverage.prepare(from: url, selectedPaths: ["~/GitHub/one"], home: box.home)
        try expectEqual(chosen.coverage.ignore, ["~/GitHub/skipped"],
                        "the stale rejection of the container goes, the explicit one stays")
        try safety.write("x", to: box.home + "/GitHub/new-project/file.txt")
        let next = try AutomaticCoverage.prepare(from: url, home: box.home)
        try expect(next.source.paths.contains("~/GitHub/new-project"), "new projects are no longer blocked: \(next.source.paths)")
        try expect(!next.source.paths.contains("~/GitHub/skipped"), "the explicit opt-out still wins")
    }

    func test_aFolderWithNothingChosenStaysRejected() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        try safety.write("x", to: box.home + "/GitHub/one/file.txt")
        try safety.write("x", to: box.home + "/Notes/a.txt")
        let url = box.root.appendingPathComponent("config.toml")
        var config = safety.config(box, sources: [])
        config.source.paths = ["~/GitHub", "~/Notes"]
        try config.save(to: url)

        let chosen = try AutomaticCoverage.prepare(from: url, selectedPaths: ["~/Notes"], home: box.home)
        try expect(chosen.coverage.ignore.contains("~/GitHub"), "unchecking a whole folder still rejects it: \(chosen.coverage.ignore)")
        try safety.write("x", to: box.home + "/GitHub/new-project/file.txt")
        let next = try AutomaticCoverage.prepare(from: url, home: box.home)
        try expect(!next.source.paths.contains("~/GitHub/new-project"), "nothing is added under a rejected folder")
    }

    /// The menu announces what the next backup adds; that must be exactly what it then adds,
    /// and announcing must never change anything.
    func test_nextBackupPreviewIsReadOnlyAndMatchesWhatTheBackupAdds() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        for path in ["existing/old.txt", "NewFolder/new.txt", ".config/nvim/init.vim", "ignored/a.txt", ".config/gh/hosts.yml"] {
            try safety.write("data", to: box.home + "/" + path)
        }
        let url = box.root.appendingPathComponent("config.toml")
        var config = safety.config(box, sources: ["existing"])
        config.coverage.ignore = ["~/ignored"]
        try config.save(to: url)
        let bytes = try Data(contentsOf: url)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        let loaded = try Config.load(from: url)
        let preview = AutomaticCoverage.pending(config: loaded, home: box.home).map(\.path)
        try expect(preview.contains("~/NewFolder") && preview.contains("~/.config/nvim"), "announces the new items: \(preview)")
        try expect(!preview.contains("~/ignored") && !preview.contains { $0.contains(".config/gh") },
                   "never announces opted-out folders or credentials: \(preview)")
        try expectEqual(try Data(contentsOf: url), bytes, "announcing never rewrites the settings")
        try expectEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, modified,
                        "nor touches the file")

        let prepared = try AutomaticCoverage.prepareReporting(from: url, home: box.home)
        try expectEqual(prepared.added, preview, "the backup adds exactly what was announced")
        try expect(AutomaticCoverage.pending(config: prepared.config, home: box.home).isEmpty, "nothing is announced twice")
        try expect(try AutomaticCoverage.prepareReporting(from: url, home: box.home).added.isEmpty,
                   "a second preparation adds nothing")
        var off = loaded
        off.coverage.autoInclude = false
        try expect(AutomaticCoverage.pending(config: off, home: box.home).isEmpty, "nothing comes by itself when the switch is off")
        let picked = try AutomaticCoverage.prepareReporting(from: url, selectedPaths: ["~/existing"], home: box.home)
        try expect(picked.added.isEmpty, "a confirmed picker choice adds nothing by itself")
    }

    /// Walking every source for databases takes minutes on a real configuration (measured on the
    /// maintainer's Mac: ~1-2 min): the menu preview must not do it, and relies on the last audit.
    func test_menuPreviewReadsDatabasesFromTheLastAuditInsteadOfWalkingEverySource() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        try safety.write("old", to: box.home + "/existing/old.txt")
        try safety.write("new", to: box.home + "/NewFolder/new.txt")
        for path in ["existing/runtime/old.db", "NewFolder/runtime/new.db"] {
            try FileManager.default.createDirectory(atPath: (box.home + "/" + path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            let made = Shell.run("/usr/bin/sqlite3", [box.home + "/" + path, "CREATE TABLE t(v); INSERT INTO t VALUES(1);"])
            try expect(made.ok, "isolated database \(path): \(made.stderr)")
        }
        let config = safety.config(box, sources: ["existing"])

        let full = Set(AutomaticCoverage.pending(config: config, home: box.home).map(\.path))
        try expect(full.isSuperset(of: ["~/NewFolder", "~/NewFolder/runtime/new.db", "~/existing/runtime/old.db"]),
                   "the backup's own discovery finds all three: \(full)")

        let quick = Set(AutomaticCoverage.pending(config: config, home: box.home, knownDatabaseGaps: []).map(\.path))
        try expect(quick.contains("~/NewFolder") && quick.contains("~/NewFolder/runtime/new.db"),
                   "a new project and its database are still announced: \(quick)")
        try expect(!quick.contains("~/existing/runtime/old.db"),
                   "databases of existing sources are not searched for in the menu path: \(quick)")

        let old = CoverageGap(kind: .database, path: "~/existing/runtime/old.db", lastModified: "", approximateBytes: 1)
        let cached = Set(AutomaticCoverage.pending(config: config, home: box.home, knownDatabaseGaps: [old]).map(\.path))
        try expect(cached.contains("~/existing/runtime/old.db"), "what the last audit found is announced: \(cached)")
        let folderOnly = CoverageGap(kind: .folder, path: "~/Elsewhere", lastModified: "", approximateBytes: 1)
        try expect(!AutomaticCoverage.pending(config: config, home: box.home, knownDatabaseGaps: [folderOnly])
                    .contains { $0.path == "~/Elsewhere" }, "only databases are taken from the cached report")
    }

    func test_automaticAdditionsAreRecordedAfterEveryBackup() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        try safety.write("old", to: box.home + "/existing/old.txt")
        try safety.write("new", to: box.home + "/NewFolder/new.txt")
        let url = box.root.appendingPathComponent("config.toml")
        try safety.config(box, sources: ["existing"]).save(to: url)
        let writer = StatusWriter(directory: box.state)

        func backup(selectedPaths: [String]? = nil) throws -> (result: BackupRunResult, prepared: Config?) {
            let options = BackupRunOptions(home: box.home, captureEnvironment: false, captureGit: false,
                                           captureDatabases: false, auditCoverage: false, captureApplications: false)
            let outcome = ResultBox<Result<BackupRunResult?, Error>>()
            let published = ResultBox<Config>()
            let done = DispatchSemaphore(value: 0)
            Task {
                do {
                    outcome.value = .success(try await AutomaticCoverage.prepareAndRun(
                        from: url, selectedPaths: selectedPaths, statusWriter: writer, options: options,
                        onPrepared: { published.value = $0 }))
                } catch { outcome.value = .failure(error) }
                done.signal()
            }
            done.wait()
            guard let result = try outcome.value!.get() else { throw TestFailure.failed("backup cancelled") }
            return (result, published.value)
        }

        let first = try backup()
        try expectEqual(first.prepared?.source.paths.contains("~/NewFolder"), true,
                        "the menu is told the settings before the copy starts")
        try expect(first.result.manifest.complete, "backup complete: \(first.result.manifest.incompleteReasons)")
        try expectEqual(try String(contentsOf: first.result.snapshot.appendingPathComponent("NewFolder/new.txt"), encoding: .utf8),
                        "new", "the new folder is in this very snapshot")
        try expectEqual(writer.read()?.autoIncluded, ["~/NewFolder"], "status records what was added for this backup")
        try expectEqual(first.result.manifest.automaticallyIncluded, ["~/NewFolder"], "so does the snapshot")
        let raw = try String(contentsOfFile: writer.statusPath, encoding: .utf8)
        try expect(raw.contains("\"auto_included\""), "scheduled runs write it where the menu reads it")

        let second = try backup()
        try expectEqual(writer.read()?.autoIncluded, [], "the next backup says zero, not a stale number")
        try expectNil(second.result.manifest.automaticallyIncluded, "nothing to record in its snapshot")
        let third = try backup(selectedPaths: ["~/existing"])
        try expectEqual(writer.read()?.autoIncluded, [], "a picker choice adds nothing by itself")
        try expect(third.result.manifest.complete, "and still completes")
    }

    /// The schedule runs whether or not the disk is there: what the settings gained by themselves for a
    /// run that could not start must still be reported by the backup that finally copies it.
    func test_additionsOfARunThatCouldNotStartAreReportedByTheNextOne() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        try safety.write("old", to: box.home + "/existing/old.txt")
        try safety.write("new", to: box.home + "/NewFolder/new.txt")
        let url = box.root.appendingPathComponent("config.toml")
        var config = safety.config(box, sources: ["existing"])
        config.destination.path = "/Volumes/mb4d-test-absent-\(UUID().uuidString)/MacBackup4Dev"
        try config.save(to: url)
        let writer = StatusWriter(directory: box.state)

        func run() throws -> BackupRunResult {
            let options = BackupRunOptions(home: box.home, captureEnvironment: false, captureGit: false,
                                           captureDatabases: false, auditCoverage: false, captureApplications: false)
            let outcome = ResultBox<Result<BackupRunResult?, Error>>()
            let done = DispatchSemaphore(value: 0)
            Task {
                do {
                    outcome.value = .success(try await AutomaticCoverage.prepareAndRun(
                        from: url, statusWriter: writer, options: options))
                } catch { outcome.value = .failure(error) }
                done.signal()
            }
            done.wait()
            guard let result = try outcome.value!.get() else { throw TestFailure.failed("backup cancelled") }
            return result
        }

        var refused = false
        do { _ = try run() } catch BackupError.volumeNotMounted { refused = true }
        try expect(refused, "the first run really could not start")
        try expect(try Config.load(from: url).source.paths.contains("~/NewFolder"), "the settings already hold the new folder")
        try expectEqual(writer.readPendingAdditions(), ["~/NewFolder"], "the addition is owed to a snapshot, not lost")
        try expectNil(writer.read()?.autoIncluded, "and not announced as part of a backup that never happened")

        var back = try Config.load(from: url)
        back.destination.path = box.dest
        try back.save(to: url)
        let second = try run()
        try expect(second.manifest.complete, "backup complete: \(second.manifest.incompleteReasons)")
        try expectEqual(writer.read()?.autoIncluded, ["~/NewFolder"], "the backup that copies it first reports it")
        try expectEqual(second.manifest.automaticallyIncluded, ["~/NewFolder"], "so does its snapshot")
        try expect(writer.readPendingAdditions().isEmpty, "nothing is owed once a snapshot records it")
        _ = try run()
        try expectEqual(writer.read()?.autoIncluded, [], "and the next one is back to zero")
    }

    func test_menuAnnouncesWhatWasAddedAndWhatComesNext() throws {
        let state = AppUIState()
        try expectNil(state.automaticallyAddedLabel, "no backup yet, nothing to announce")
        var status = BackupStatusFile()
        status.state = "idle"
        status.lastResult = "complete"
        state.status = status
        try expectNil(state.automaticallyAddedLabel, "a status written before 4.3.2 never recorded it: no invented zero")
        let old = #"{"state":"idle","phase":"","started_at":"","last_completed":"","last_duration_secs":0,"files_total":0,"files_done":0,"bytes_copied":0,"bytes_per_sec":0,"eta_secs":0,"errors":0,"files_skipped":0,"current_file":""}"#
        let decoded = try JSONDecoder().decode(BackupStatusFile.self, from: Data(old.utf8))
        try expectNil(decoded.autoIncluded, "old status files still decode")

        status.autoIncluded = ["~/GitHub/a", "~/.config/nvim"]
        state.status = status
        try expectEqual(state.automaticallyAddedLabel, "Aggiunte da sole: 2", "after a backup: how many were added by themselves")
        try expect(state.automaticallyAddedHelp.contains("~/GitHub/a") && state.automaticallyAddedHelp.contains("~/.config/nvim"),
                   "the names are one hover away")
        status.autoIncluded = []
        state.status = status
        try expectEqual(state.automaticallyAddedLabel, "Aggiunte da sole: 0", "a backup with nothing new still says so")
        state.appState = .running
        try expectNil(state.automaticallyAddedLabel, "not while a backup is running")
        state.appState = .idle

        try expectNil(state.pendingAutomaticTitle, "nothing announced when nothing is coming")
        func gap(_ path: String) -> CoverageGap { CoverageGap(kind: .folder, path: path, lastModified: "", approximateBytes: 0) }
        state.pendingAutomatic = ["~/A", "~/B", "~/C", "~/D"].map(gap)
        try expectEqual(state.pendingAutomaticTitle, "Entreranno al prossimo backup: 4", "how many will come by themselves")
        try expectEqual(state.pendingAutomaticDetail, "~/A, ~/B, ~/C e altre 1", "a few names, then the count")
        try expect(state.pendingAutomaticHelp.contains("~/D"), "every name is one hover away")
        state.coverageGaps = [gap("~/A"), gap("~/Other")]
        try expectEqual(state.visibleCoverageGaps.map(\.path), ["~/Other"],
                        "a gap the next backup takes care of is not shown as an open problem")
    }
}
