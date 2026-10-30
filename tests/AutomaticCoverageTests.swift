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
}
