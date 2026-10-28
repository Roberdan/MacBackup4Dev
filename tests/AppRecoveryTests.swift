import Foundation
import Darwin

struct AppRecoveryTests {
    func test_realEngineAndNewMacRecoverAppsAndSelectedSettings() throws {
        let f = try AppTestFixture(); defer { f.cleanup() }
        let source = try f.app()
        let preference = "Library/Preferences/com.example.shoji.plist"
        try f.write("chosen settings", f.box.home + "/" + preference)
        var config = f.config
        config.source.paths.append(f.box.home + "/" + preference)
        let result = try f.backup(config: config)
        let entry = try AppCapture.read(from: result.snapshot)!.entries[0]
        let stages = NewMacRestore.stages(snapshot: result.snapshot, config: config)
        for stage in stages where stage.kind == .files {
            let out = NewMacRestore.runStage(stage, snapshot: result.snapshot, home: f.restoreHome, dryRun: false)
            try expect(out.ok, "file phase succeeds")
        }
        let stage = stages.first { $0.kind == .applications }!
        let preview = NewMacRestore.runStage(stage, snapshot: result.snapshot, home: f.restoreHome, dryRun: true,
            applications: [entry.id], applicationRoots: f.restoreRoots, applicationRunning: { _ in false })
        try expect(preview.ok && !FileManager.default.fileExists(atPath: f.restoreRoots[0].url.path), "preview never writes apps")
        let out = NewMacRestore.runStage(stage, snapshot: result.snapshot, home: f.restoreHome, dryRun: false,
            applications: [entry.id], applicationRoots: f.restoreRoots, applicationRunning: { _ in false })
        try expect(out.ok, "real New Mac app phase: \(out.lines)")
        let installed = f.restoreRoots[0].url.appendingPathComponent("Shoji.app")
        try expectEqual(try AppBundleCopy.fingerprint(installed), try AppBundleCopy.fingerprint(source), "full app restored")
        try expectEqual(try String(contentsOfFile: f.restoreHome + "/" + preference, encoding: .utf8), "chosen settings", "app and chosen settings recovered")
        try expect(!FileManager.default.fileExists(atPath: f.restoreHome + "/_apps"), "internal app archive never copied into home")
        let archived = result.snapshot.appendingPathComponent("_apps/system/Shoji.app/Contents/MacOS/Shoji")
        try expect(try AppInventory.metadata(archived).st_ino != AppInventory.metadata(installed.appendingPathComponent("Contents/MacOS/Shoji")).st_ino,
                   "restored apps never hardlink to backup data")
        let matches = try FileVersions.search("Shoji", in: result.snapshot)
        try expect(matches.contains(preference) && !matches.contains { $0.hasPrefix("_apps/") },
                   "plain file search finds selected preferences, never internal app bundles")
        try expectNil(SelectiveRestore.safeRelative("_apps/system/Shoji.app"), "plain restore cannot access bundle archive")
        let undo = NewMacRestore.undoStage("app", home: f.restoreHome, applicationRoots: f.restoreRoots)
        try expect(undo.contains("1 app"), "app phase has independent move-aside undo: \(undo)")
        try expect(!FileManager.default.fileExists(atPath: installed.path), "undo removes installed app from app root")
        try expect(FileManager.default.fileExists(atPath: f.restoreHome + "/" + preference), "undo app phase leaves data phase intact")
    }

    func test_existingRunningAndChangedAppsAreNeverOverwritten() throws {
        let f = try AppTestFixture(); defer { f.cleanup() }
        try f.app()
        let result = try f.backup()
        let entry = try AppCapture.read(from: result.snapshot)!.entries[0]
        let running = try AppRestore.restore(entry, snapshot: result.snapshot, roots: f.restoreRoots,
                                             home: f.restoreHome, running: { _ in true })
        try expect(!running.installed && running.message.contains("esecuzione"), "running app not touched")
        let report = try AppRestore.run(snapshot: result.snapshot, selected: [entry.id], home: f.restoreHome,
                                       roots: f.restoreRoots, dryRun: false, running: { _ in false })
        let installed = f.restoreRoots[0].url.appendingPathComponent("Shoji.app")
        try f.write("newer data", installed.path + "/Contents/user-changed")
        let before = try AppBundleCopy.fingerprint(installed)
        let again = try AppRestore.restore(entry, snapshot: result.snapshot, roots: f.restoreRoots,
                                          home: f.restoreHome, running: { _ in false })
        try expect(!again.installed, "existing bundle ID skipped")
        try expectEqual(try AppBundleCopy.fingerprint(installed), before, "existing app unchanged")
        let text = try AppRestore.undo(report.undoDirectory!, home: f.restoreHome, roots: f.restoreRoots, running: { _ in false })
        try expect(text.contains("1 cambiate"), "undo keeps an app changed after restore: \(text)")
        try expectEqual(try AppBundleCopy.fingerprint(installed), before, "undo does not destroy changed app")
    }

    func test_restoreRefusesTamperingLinksAndDestinationRace() throws {
        for scenario in ["path", "tamper", "parentLink", "race"] {
            let f = try AppTestFixture(); defer { f.cleanup() }
            try f.app("Dev/Shoji.app")
            let result = try f.backup()
            var entry = try AppCapture.read(from: result.snapshot)!.entries[0]
            if scenario == "path" { entry.relativePath = "../Escape.app" }
            if scenario == "tamper" {
                try f.write("bad", result.snapshot.path + "/_apps/system/Dev/Shoji.app/Contents/MacOS/Shoji")
            }
            if scenario == "parentLink" {
                try FileManager.default.createDirectory(at: f.restoreRoots[0].url, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: f.restoreRoots[0].url.path + "/Dev", withDestinationPath: f.restoreHome)
            }
            var failed = false
            do {
                _ = try AppRestore.restore(entry, snapshot: result.snapshot, roots: f.restoreRoots,
                    home: f.restoreHome, running: { _ in false }, beforeInstall: {
                        if scenario == "race" {
                            try f.write("keep", f.restoreRoots[0].url.path + "/Dev/Shoji.app/keep")
                        }
                    })
            } catch { failed = true }
            try expect(failed, "unsafe restore must fail: \(scenario)")
            if scenario == "race" {
                try expectEqual(try String(contentsOfFile: f.restoreRoots[0].url.path + "/Dev/Shoji.app/keep",
                                          encoding: .utf8), "keep", "atomic rename cannot replace a raced destination")
                let entries = try FileManager.default.contentsOfDirectory(atPath: f.restoreRoots[0].url.path + "/Dev")
                try expect(!entries.contains { $0.hasPrefix(".mb4d-app-") }, "failed staging cleaned")
            }
            try expect(!FileManager.default.fileExists(atPath: f.restoreHome + "/Shoji.app"), "never follows a grouping symlink")
        }
    }

    func test_cliUsesSameArchiveAndLegacySnapshotsStillWork() throws {
        let f = try AppTestFixture(); defer { f.cleanup() }
        try f.app()
        let result = try f.backup()
        let configURL = f.box.root.appendingPathComponent("config.toml")
        try f.config.save(to: configURL)
        try CLIHandler.runNewMac(subArgs: ["--stage", "app", "--all-apps"], configPath: configURL.path,
                                 home: f.restoreHome, applicationRoots: f.restoreRoots)
        try expect(!FileManager.default.fileExists(atPath: f.restoreRoots[0].url.path), "CLI preview writes nothing")
        try CLIHandler.runNewMac(subArgs: ["--stage", "app", "--all-apps", "--yes"], configPath: configURL.path,
                                 home: f.restoreHome, applicationRoots: f.restoreRoots)
        try expect(FileManager.default.fileExists(atPath: f.restoreRoots[0].url.path + "/Shoji.app/Contents/MacOS/Shoji"), "CLI actually restores app")

        let legacy = f.box.root.appendingPathComponent("legacy-snapshot")
        try f.write("cask \"warp\"\n", legacy.path + "/_environment/Brewfile")
        try expect(try AppCapture.read(from: legacy) == nil, "old snapshots have no app catalog")
        try expect(!NewMacRestore.stages(snapshot: legacy, config: nil).contains { $0.kind == .applications }, "old phases unchanged")
        try expectEqual(ToolInventory.packages(snapshot: legacy).map(\.id), ["cask:warp"], "old reinstall list preserved")
        try expectNotNil(SnapshotManifest.read(from: result.snapshot)?.applications, "new summary persisted")
    }

    func test_managerAppsAreNotInstalledTwiceAndInstallerAppsRemainListed() throws {
        let f = try AppTestFixture(); defer { f.cleanup() }
        let app = try f.app()
        let hint = AppInstallers.Hint(packageID: "cask:shoji", requiresInstaller: false)
        let result = try f.backup { $0.applicationInstallers = [app.path: hint] }
        try f.write("cask \"shoji\"\ncask \"docker\"\nbrew \"jq\"\n", result.snapshot.path + "/_environment/Brewfile")
        try expectEqual(ToolInventory.packages(snapshot: result.snapshot).map(\.id), ["cask:docker", "brew:jq"], "captured cask is restored from backup instead of downloaded again")
        let installer = try f.backup { $0.applicationInstallers = [app.path: .init(packageID: "cask:shoji", requiresInstaller: true)] }
        try f.write("cask \"shoji\"\n", installer.snapshot.path + "/_environment/Brewfile")
        try expectEqual(ToolInventory.packages(snapshot: installer.snapshot).map(\.id), ["cask:shoji"], "app requiring installer stays in program list")
        let hints = try AppInstallers.parse(#"{"casks":[{"token":"shoji","artifacts":[{"app":["Shoji.app"]}]},{"token":"driver","artifacts":[{"pkg":["Driver.pkg"]},{"app":["Driver.app"]}]}]}"#)
        try expect(hints["/Applications/Shoji.app"]?.requiresInstaller == false
                   && hints["/Applications/Driver.app"]?.requiresInstaller == true, "real Homebrew artifact shapes distinguish installers")
    }
}
