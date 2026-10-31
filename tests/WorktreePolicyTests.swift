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

        let next = try safety.runEngine(config, box)
        try expect(next.manifest.complete, "the next backup automatically cleans obsolete worktree copies")
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

        let cliGone = snapshot.appendingPathComponent("GitHub/worktrees/main/cli-gone")
        try safety.write("gitdir: \(box.home)/GitHub/main/.git/worktrees/cli-gone\n",
                         to: cliGone.path + "/.git")
        try safety.write("temporary", to: cliGone.path + "/file.txt")
        let configPath = box.root.appendingPathComponent("config.toml")
        try config.save(to: configPath)
        let cli = Shell.run(CommandLine.arguments[0],
                            ["--worktree-cli-worker", box.home, "-c", configPath.path, "cleanup-worktrees"],
                            timeout: 30)
        try expect(cli.ok, "the cleanup CLI succeeds: \(cli.failureReason)")
        try expect(cli.stdout.contains("Worktree obsoleti rimossi: 1"), "the CLI reports the actual removal")
        try expect(!fm.fileExists(atPath: cliGone.path), "the CLI removes the obsolete copy")
        try expectEqual(SnapshotManifest.read(from: snapshot)?.removedTemporaryWorktrees?.map(\.path),
                        ["GitHub/worktrees/main/gone", "GitHub/worktrees/main/cli-gone"],
                        "the CLI also persists its audit record")

        let lock = try DestinationLock(at: URL(fileURLWithPath: box.dest))
        var refused = false
        do { _ = try WorktreePolicy.cleanup(at: URL(fileURLWithPath: box.dest), home: box.home) }
        catch BackupError.lockExists { refused = true }
        _ = try withExtendedLifetime(lock) { try expect(refused, "cleanup never races a backup") }
    }

    func test_cleanupFailureDoesNotBlockSubsequentBackups() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let fm = FileManager.default
        try safety.write("source", to: box.home + "/GitHub/main/file.txt")
        try fm.createDirectory(atPath: box.home + "/GitHub/main/.git/worktrees", withIntermediateDirectories: true)
        let config = safety.config(box, sources: ["GitHub/main"])
        let snapshot = try safety.runEngine(config, box).snapshot
        let gone = snapshot.appendingPathComponent("GitHub/worktrees/main/gone")
        try safety.write("gitdir: \(box.home)/GitHub/main/.git/worktrees/gone\n", to: gone.path + "/.git")
        try safety.write("preserve", to: gone.path + "/read-only/file.txt")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: gone.path + "/read-only")

        for attempt in 1...2 {
            let result = try safety.runEngine(config, box)
            try expect(result.manifest.complete, "cleanup failure must not stop backup \(attempt)")
            try expectEqual(try String(contentsOfFile: result.snapshot.path + "/GitHub/main/file.txt", encoding: .utf8),
                            "source", "protected data still reaches backup \(attempt)")
            guard let record = SnapshotManifest.read(from: snapshot)?.removedTemporaryWorktrees?.first else {
                throw TestFailure.failed("failed cleanup must retain its audit record")
            }
            let staged = snapshot.appendingPathComponent(SnapshotManifest.directoryName)
                .appendingPathComponent(record.stagingName)
            try expectEqual(try String(contentsOf: staged.appendingPathComponent("read-only/file.txt"), encoding: .utf8),
                            "preserve", "unremoved files remain available for retry")
            try expect(try String(contentsOf: Log.logURL, encoding: .utf8)
                .contains("Worktree cleanup deferred; backup will continue:"),
                       "maintenance failure is logged instead of silently ignored")
        }
    }

    /// Saved checkouts of deleted worktrees were left behind whenever they sat outside
    /// GitHub/worktrees (201 of them on 2026-10-31): the marker, not the place, identifies them.
    func test_cleanupFindsLinkedCopiesByMarkerWhereverTheyWereSaved() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let fm = FileManager.default
        try safety.write("source", to: box.home + "/GitHub/main/file.txt")
        try fm.createDirectory(atPath: box.home + "/GitHub/main/.git/worktrees", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: box.home + "/Code/other/.git/worktrees", withIntermediateDirectories: true)
        let snapshot = try safety.runEngine(safety.config(box, sources: ["GitHub/main"]), box).snapshot
        // Saved repositories carry their own .git directory.
        try safety.write("ref: refs/heads/main\n", to: snapshot.path + "/GitHub/main/.git/HEAD")
        @discardableResult
        func plant(_ relative: String, main: String = "GitHub/main") throws -> URL {
            let copy = snapshot.appendingPathComponent(relative)
            try safety.write("gitdir: \(box.home)/\(main)/.git/worktrees/\((relative as NSString).lastPathComponent)\n",
                             to: copy.path + "/.git")
            try safety.write("temporary", to: copy.path + "/file.txt")
            return copy
        }
        let obsolete = ["GitHub/main/.claude/worktrees/agent-1", "GitHub/agents/2026/10/28/run-7/step/a/wt",
                        "Documents/notes/agent-checkout", "Code/scratch/wt-outside"]
        for relative in obsolete { try plant(relative, main: relative.hasPrefix("Code/") ? "Code/other" : "GitHub/main") }

        let livePresent = try plant("Scratch/live-wt")
        try safety.write("unsaved", to: box.home + "/Scratch/live-wt/unsaved.txt")
        let mainGone = try plant("Archive/old-wt", main: "GitHub/vanished")
        let foreign = snapshot.appendingPathComponent("Archive/foreign-wt")
        try safety.write("gitdir: /opt/elsewhere/.git/worktrees/foreign-wt\n", to: foreign.path + "/.git")
        try safety.write("keep", to: foreign.path + "/file.txt")
        let submodule = snapshot.appendingPathComponent("Code/submodule")
        try safety.write("gitdir: ../main/.git/modules/submodule\n", to: submodule.path + "/.git")
        try safety.write("keep", to: submodule.path + "/file.txt")
        let repository = snapshot.appendingPathComponent("Code/other-copy")
        try safety.write("keep", to: repository.path + "/.git/objects/pack/p")
        let reserved = try plant("_rustymacbackup/stash/wt")
        let volume = try plant("Volumes/Data/wt")
        let preserved = snapshot.appendingPathComponent("GitHub/main/preserved.txt")
        try fm.linkItem(at: snapshot.appendingPathComponent(obsolete[0] + "/file.txt"), to: preserved)
        let before = try fm.attributesOfItem(atPath: preserved.path)[.posixPermissions] as? NSNumber

        let outcome = try WorktreePolicy.cleanup(at: URL(fileURLWithPath: box.dest), home: box.home)
        try expectEqual(Set(outcome.removed), Set(obsolete.map { snapshot.lastPathComponent + "/" + $0 }),
                        "every absent linked copy is found, wherever it is")
        for relative in obsolete { try expect(!fm.fileExists(atPath: snapshot.path + "/" + relative), "removed: \(relative)") }
        for kept in [livePresent, mainGone, foreign, submodule, repository, reserved, volume] {
            try expect(fm.fileExists(atPath: kept.path + "/file.txt") || fm.fileExists(atPath: kept.path + "/.git/objects/pack/p"),
                       "not provably obsolete, so kept: \(kept.path)")
        }
        try expectEqual(try String(contentsOf: preserved, encoding: .utf8), "temporary", "shared hard-link content intact")
        try expectEqual(try fm.attributesOfItem(atPath: preserved.path)[.posixPermissions] as? NSNumber, before,
                        "cleanup never changes modes on shared files")
        try expectEqual(try String(contentsOfFile: box.home + "/Scratch/live-wt/unsaved.txt", encoding: .utf8),
                        "unsaved", "live working copies are never touched")
        let manifest = SnapshotManifest.read(from: snapshot)
        try expectEqual(Set(manifest?.removedTemporaryWorktrees?.map(\.path) ?? []), Set(obsolete),
                        "each removal is auditable with its snapshot-relative path")
        try expect(manifest?.removedTemporaryWorktrees?.allSatisfy { $0.bytes > 0 } == true, "records include measured size")
        try expectEqual(try WorktreePolicy.cleanup(at: URL(fileURLWithPath: box.dest), home: box.home).removed.count, 0,
                        "repeat cleanup is idempotent")
    }

    /// Searching every old snapshot at every backup would slow each one down: a searched snapshot
    /// is remembered, and only the copies found in it are checked again.
    func test_searchedSnapshotsAreRememberedAndOnlyKnownCopiesAreChecked() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let fm = FileManager.default
        try safety.write("source", to: box.home + "/GitHub/main/file.txt")
        try fm.createDirectory(atPath: box.home + "/GitHub/main/.git/worktrees", withIntermediateDirectories: true)
        let snapshot = try safety.runEngine(safety.config(box, sources: ["GitHub/main"]), box).snapshot
        func plant(_ relative: String) throws {
            try safety.write("gitdir: \(box.home)/GitHub/main/.git/worktrees/\((relative as NSString).lastPathComponent)\n",
                             to: snapshot.path + "/" + relative + "/.git")
            try safety.write("temporary", to: snapshot.path + "/" + relative + "/file.txt")
        }
        let destination = URL(fileURLWithPath: box.dest)
        try plant("Scratch/still-live")
        try safety.write("unsaved", to: box.home + "/Scratch/still-live/unsaved.txt")

        try expectEqual(try WorktreePolicy.cleanup(at: destination, home: box.home).removed.count, 0,
                        "a copy whose live checkout exists is kept")
        try expectEqual(SnapshotManifest.read(from: snapshot)?.temporaryWorktreeCopies, ["Scratch/still-live"],
                        "the search is remembered together with what it found")

        try fm.removeItem(atPath: box.home + "/Scratch")
        try plant("Elsewhere/appeared-later")
        let later = try WorktreePolicy.cleanup(at: destination, home: box.home)
        try expectEqual(later.removed, [snapshot.lastPathComponent + "/Scratch/still-live"],
                        "the remembered copy is checked again and goes once its live checkout is gone")
        try expect(fm.fileExists(atPath: snapshot.path + "/Elsewhere/appeared-later/file.txt"),
                   "an already searched snapshot is not walked again")
        try expectEqual(SnapshotManifest.read(from: snapshot)?.temporaryWorktreeCopies, [], "nothing is left to check")

        let explicit = try WorktreePolicy.cleanup(at: destination, home: box.home, searchAgain: true)
        try expectEqual(explicit.removed, [snapshot.lastPathComponent + "/Elsewhere/appeared-later"],
                        "an explicit request searches again")
    }

    /// The remembered list is a file: whatever it says, nothing outside the snapshot is touched.
    func test_aTamperedMemoNeverLeadsOutsideTheSnapshot() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let fm = FileManager.default
        try safety.write("source", to: box.home + "/GitHub/main/file.txt")
        try fm.createDirectory(atPath: box.home + "/GitHub/main/.git/worktrees", withIntermediateDirectories: true)
        let snapshot = try safety.runEngine(safety.config(box, sources: ["GitHub/main"]), box).snapshot
        func decoy(_ path: String) throws {
            try safety.write("gitdir: \(box.home)/GitHub/main/.git/worktrees/wt\n", to: path + "/.git")
            try safety.write("precious", to: path + "/file.txt")
        }
        try decoy(box.dest + "/stray")
        try decoy(box.root.path + "/outside/wt")
        try fm.createSymbolicLink(atPath: snapshot.path + "/Linked", withDestinationPath: box.root.path + "/outside")
        try decoy(snapshot.path + "/_rustymacbackup/stash/wt")
        var manifest = SnapshotManifest.read(from: snapshot)!
        manifest.temporaryWorktreeCopies = ["../stray", box.root.path + "/outside/wt", "Linked/wt",
                                            "_rustymacbackup/stash/wt", "a//b", ""]
        try manifest.write(to: snapshot)

        let outcome = try WorktreePolicy.cleanup(at: URL(fileURLWithPath: box.dest), home: box.home)
        try expect(outcome.removed.isEmpty, "nothing is removed on the word of a file: \(outcome.removed)")
        for path in [box.dest + "/stray", box.root.path + "/outside/wt", snapshot.path + "/_rustymacbackup/stash/wt"] {
            try expectEqual(try String(contentsOfFile: path + "/file.txt", encoding: .utf8), "precious", "untouched: \(path)")
        }
        try expectEqual(SnapshotManifest.read(from: snapshot)?.temporaryWorktreeCopies, [],
                        "the unusable entries are dropped from the list")
    }

    /// A search that runs out of time must not be a promise it cannot keep: it stops between two
    /// folders and the next backup goes on from there, never from scratch.
    func test_aSearchThatRunsOutOfTimeContinuesWhereItStopped() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let fm = FileManager.default
        try safety.write("source", to: box.home + "/GitHub/main/file.txt")
        try fm.createDirectory(atPath: box.home + "/GitHub/main/.git/worktrees", withIntermediateDirectories: true)
        let snapshot = try safety.runEngine(safety.config(box, sources: ["GitHub/main"]), box).snapshot
        for index in 0..<6 { try safety.write("x", to: snapshot.path + "/Documents/area\(index)/sub/note.txt") }
        let copy = snapshot.appendingPathComponent("Documents/area3/sub/agent-wt")
        try safety.write("gitdir: \(box.home)/GitHub/main/.git/worktrees/agent-wt\n", to: copy.path + "/.git")
        try safety.write("temporary", to: copy.path + "/file.txt")
        var folders = 0
        if let walker = fm.enumerator(at: snapshot, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if url.lastPathComponent == SnapshotManifest.directoryName { walker.skipDescendants() } else { folders += 1 }
            }
        }
        let destination = URL(fileURLWithPath: box.dest)

        var runs = 0
        var lastFound = 0
        var outcome = try WorktreePolicy.cleanup(at: destination, home: box.home, maxFolders: 2)
        while outcome.unsearched > 0 {
            runs += 1
            try expect(runs <= folders, "the search keeps making progress (\(runs) runs for \(folders) folders)")
            let progress = SnapshotManifest.read(from: snapshot)?.worktreeSearch
            try expectNotNil(progress, "an unfinished search is written down")
            try expectNil(SnapshotManifest.read(from: snapshot)?.temporaryWorktreeCopies, "and not yet taken for a finished one")
            try expect((progress?.found.count ?? 0) >= lastFound, "what was found is never forgotten")
            lastFound = progress?.found.count ?? 0
            try expect(fm.fileExists(atPath: copy.path), "nothing is removed before the search is over")
            outcome = try WorktreePolicy.cleanup(at: destination, home: box.home, maxFolders: 2)
        }
        try expect(runs >= 2, "the fixture really needed several steps: \(runs)")
        try expectEqual(outcome.removed, [snapshot.lastPathComponent + "/Documents/area3/sub/agent-wt"],
                        "the last step finds and removes the copy")
        let manifest = SnapshotManifest.read(from: snapshot)
        try expectNil(manifest?.worktreeSearch, "a finished search leaves no progress behind")
        try expectEqual(manifest?.temporaryWorktreeCopies, [], "and is remembered")
    }

    /// What a half-done search says comes from a file, like the remembered list.
    func test_aTamperedSearchProgressIsCheckedLikeAnyOtherPath() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let fm = FileManager.default
        try safety.write("source", to: box.home + "/GitHub/main/file.txt")
        try fm.createDirectory(atPath: box.home + "/GitHub/main/.git/worktrees", withIntermediateDirectories: true)
        let snapshot = try safety.runEngine(safety.config(box, sources: ["GitHub/main"]), box).snapshot
        func plant(_ path: String) throws {
            try safety.write("gitdir: \(box.home)/GitHub/main/.git/worktrees/wt\n", to: path + "/.git")
            try safety.write("precious", to: path + "/file.txt")
        }
        try plant(box.dest + "/stray")
        try plant(box.root.path + "/elsewhere/wt")
        try plant(snapshot.path + "/Documents/real-wt")
        var manifest = SnapshotManifest.read(from: snapshot)!
        manifest.worktreeSearch = WorktreePolicy.Search(found: ["../stray", "/etc"],
                                                        pending: ["../../elsewhere", box.root.path + "/elsewhere", ""])
        try manifest.write(to: snapshot)

        let outcome = try WorktreePolicy.cleanup(at: URL(fileURLWithPath: box.dest), home: box.home)
        try expectEqual(outcome.removed, [snapshot.lastPathComponent + "/Documents/real-wt"],
                        "only what the real search finds is removed")
        for path in [box.dest + "/stray", box.root.path + "/elsewhere/wt"] {
            try expectEqual(try String(contentsOfFile: path + "/file.txt", encoding: .utf8), "precious", "untouched: \(path)")
        }
    }

    func test_searchTimeVersionAndCancellationBoundTheWork() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let fm = FileManager.default
        try safety.write("source", to: box.home + "/GitHub/main/file.txt")
        try fm.createDirectory(atPath: box.home + "/GitHub/main/.git/worktrees", withIntermediateDirectories: true)
        let snapshot = try safety.runEngine(safety.config(box, sources: ["GitHub/main"]), box).snapshot
        let copy = snapshot.appendingPathComponent("Elsewhere/wt")
        try safety.write("gitdir: \(box.home)/GitHub/main/.git/worktrees/wt\n", to: copy.path + "/.git")
        try safety.write("temporary", to: copy.path + "/file.txt")
        let destination = URL(fileURLWithPath: box.dest)

        let cancelled = try WorktreePolicy.cleanup(at: destination, home: box.home, cancelled: { true })
        try expect(cancelled.removed.isEmpty && fm.fileExists(atPath: copy.path), "a cancelled run touches nothing")
        try expectNil(SnapshotManifest.read(from: snapshot)?.temporaryWorktreeCopies, "and remembers nothing")

        let hurried = try WorktreePolicy.cleanup(at: destination, home: box.home, scanBudget: 0)
        try expectEqual(hurried.unsearched, 1, "the snapshot left for later is counted")
        try expect(hurried.removed.isEmpty && fm.fileExists(atPath: copy.path), "no time, no search")
        try expectNil(SnapshotManifest.read(from: snapshot)?.temporaryWorktreeCopies, "so it is searched next time")

        var manifest = SnapshotManifest.read(from: snapshot)!
        manifest.appVersion = "4.3.2"
        try manifest.write(to: snapshot)
        try expect(try WorktreePolicy.cleanup(at: destination, home: box.home).removed.isEmpty,
                   "snapshots made since 4.3.0 cannot hold such copies and are never searched")
        try expectNil(SnapshotManifest.read(from: snapshot)?.temporaryWorktreeCopies, "nothing remembered for them either")

        manifest.appVersion = "4.2.0"
        try manifest.write(to: snapshot)
        let found = try WorktreePolicy.cleanup(at: destination, home: box.home)
        try expectEqual(found.removed, [snapshot.lastPathComponent + "/Elsewhere/wt"], "older snapshots are searched")
        try expectEqual(found.unsearched, 0, "nothing was left over")
    }
}
