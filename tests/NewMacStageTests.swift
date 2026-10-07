import Foundation

/// 3.3: "Nuovo Mac" a tappe. Scar 2026-10-06: everything at once, LaunchAgents included,
/// and the Mac did not come back to a usable login.
struct NewMacStageTests {
    private func write(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// A fake snapshot with one file per kind, and an empty new home.
    private func fixture() throws -> (root: URL, snap: URL, home: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rmb-stages-\(UUID().uuidString)")
        let snap = root.appendingPathComponent("2026-10-07_100000")
        let s = snap.path
        try write("note", s + "/Obsidian/n.md")
        try write("warp", s + "/.warp/settings.yaml")
        try write("zsh", s + "/.zshrc")
        try write("claude", s + "/.claude/settings.json")
        try write("other", s + "/.toolx/config")
        try write("<plist/>", s + "/Library/LaunchAgents/com.example.agent.plist")
        try write("<plist/>", s + "/Library/Preferences/com.apple.dock.plist")
        try write("<plist/>", s + "/Library/Preferences/ByHost/x.plist")
        let home = root.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return (root, snap, home)
    }

    func test_loginItemsAreNeverInAFilePhase() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let stages = NewMacRestore.stages(snapshot: f.snap, config: nil)
        let ids = stages.map(\.id)
        try expect(ids.first == "dati", "documents first: \(ids)")
        try expect(ids.last == "servizi", "services last: \(ids)")
        try expect(ids.firstIndex(of: "shell")! > ids.firstIndex(of: "tema:Warp")!, "shell after the tool phases: \(ids)")
        let everyPath = stages.flatMap(\.paths)
        try expect(!everyPath.contains { $0.hasPrefix("Library/LaunchAgents/") }, "no LaunchAgent in any file phase")
        try expect(!everyPath.contains { $0.hasPrefix("Library/Preferences/com.apple.") || $0.contains("/ByHost/") },
                   "no system or per-host preferences of the old Mac")
        try expectEqual(Set(everyPath).count, everyPath.count, "each file belongs to exactly one phase")
        try expect(everyPath.contains("Obsidian/n.md") && everyPath.contains(".toolx/config"), "the rest is all there")

        for stage in stages where stage.kind == .files {
            _ = NewMacRestore.runStage(stage, snapshot: f.snap, home: f.home, dryRun: false, shellCheck: { _ in nil })
        }
        try expect(FileManager.default.fileExists(atPath: f.home + "/.zshrc"), "shell file restored")
        try expect(!FileManager.default.fileExists(atPath: f.home + "/Library/LaunchAgents"), "no LaunchAgent restored by phases")

        // Topics and the 3.0 one-shot step never copy them either.
        let byTopic = Topics.files(of: RestoreTopic(name: "x", paths: ["Library"]), in: f.snap)
        try expect(!byTopic.contains { NewMacRestore.isLoginSensitive($0) }, "topics skip login items: \(byTopic)")
        let legacyHome = f.root.appendingPathComponent("legacy").path
        _ = NewMacRestore.run(snapshot: f.snap, steps: [.config], home: legacyHome)
        try expect(FileManager.default.fileExists(atPath: legacyHome + "/.warp/settings.yaml"), "legacy step still restores config")
        try expect(!FileManager.default.fileExists(atPath: legacyHome + "/Library/LaunchAgents"), "legacy step skips LaunchAgents")
    }

    func test_brokenShellUndoesItsPhase() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let shell = NewMacRestore.stages(snapshot: f.snap, config: nil).first { $0.id == "shell" }!
        let out = NewMacRestore.runStage(shell, snapshot: f.snap, home: f.home, dryRun: false,
                                         shellCheck: { _ in "si blocca all'avvio" })
        try expect(!out.ok, "phase reported as failed")
        try expect(!FileManager.default.fileExists(atPath: f.home + "/.zshrc"), ".zshrc taken back out: \(out.lines)")
        try expect(NewMacRestore.lastDone("shell", home: f.home) == nil, "not marked as done")

        let good = NewMacRestore.runStage(shell, snapshot: f.snap, home: f.home, dryRun: false, shellCheck: { _ in nil })
        try expect(good.ok && FileManager.default.fileExists(atPath: f.home + "/.zshrc"), "a healthy shell stays")
    }

    func test_realShellCheckCatchesExitAndPassesHealthy() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try write("export X=1\n", f.home + "/.zshrc")
        try expectNil(NewMacRestore.shellProblem(home: f.home), "a normal .zshrc passes")
        try write("exit 3\n", f.home + "/.zshrc")
        try expectNotNil(NewMacRestore.shellProblem(home: f.home), "a .zshrc that kills the shell is caught")
    }

    func test_eachPhaseUndoesOnItsOwn() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let stages = NewMacRestore.stages(snapshot: f.snap, config: nil)
        let data = stages.first { $0.id == "dati" }!, warp = stages.first { $0.id == "tema:Warp" }!
        _ = NewMacRestore.runStage(data, snapshot: f.snap, home: f.home, dryRun: false)
        _ = NewMacRestore.runStage(warp, snapshot: f.snap, home: f.home, dryRun: false)
        try expectNotNil(NewMacRestore.lastDone("tema:Warp", home: f.home), "phase recorded")
        _ = NewMacRestore.undoStage("tema:Warp", home: f.home)
        try expect(!FileManager.default.fileExists(atPath: f.home + "/.warp/settings.yaml"), "Warp undone")
        try expect(FileManager.default.fileExists(atPath: f.home + "/Obsidian/n.md"), "the other phase untouched")
        try expectNil(NewMacRestore.lastDone("tema:Warp", home: f.home), "no longer marked as done")
        try expect(NewMacRestore.undoStage("tema:Warp", home: f.home).hasPrefix("Niente"), "undoing twice does nothing")
    }

    func test_serviceHealthFromLaunchctl() throws {
        try expectNil(NewMacRestore.serviceProblem(launchctlPrint: "\tstate = running\n\tlast exit code = (never exited)\n"), "running, never exited")
        try expectNil(NewMacRestore.serviceProblem(launchctlPrint: "\tlast exit code = 0\n"), "clean exit")
        try expectNotNil(NewMacRestore.serviceProblem(launchctlPrint: "\tlast exit code = 78: EX_CONFIG\n"), "error exit")
        try expectNotNil(NewMacRestore.serviceProblem(launchctlPrint: "\tlast terminating signal = Segmentation fault: 11\n"), "crash")
    }

    func test_removedServiceIsMovedAsideNotDeleted() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let label = "com.rmb.test.\(UUID().uuidString.prefix(6))"
        let plist = f.home + "/Library/LaunchAgents/\(label).plist"
        try FileManager.default.createDirectory(atPath: (plist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try (["Label": label, "ProgramArguments": ["/usr/bin/true"]] as NSDictionary).write(to: URL(fileURLWithPath: plist))
        _ = NewMacRestore.removeService(label: label, home: f.home)
        try expect(!FileManager.default.fileExists(atPath: plist), "no longer in LaunchAgents")
        try expect(FileManager.default.fileExists(atPath: NewMacRestore.movedAsideRoot(home: f.home) + "/LaunchAgents/\(label).plist"),
                   "kept aside")
    }

    func test_ignoredAppsAreNeverListedAndSurviveSave() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try write("Ghostty\nMicrosoft OneNote\nNonEsiste\n", f.snap.path + "/_environment/installed-apps.txt")
        let item = NewMacRestore.checklist(snapshot: f.snap, home: f.home, ignoredApps: ["Ghostty", "Microsoft OneNote"])
            .first { $0.title == "App del vecchio Mac" }
        try expectEqual(item?.missingApps ?? [], ["NonEsiste"], "ignored apps not listed: \(String(describing: item))")

        let url = f.root.appendingPathComponent("config.toml")
        try "[destination]\npath = \"/Volumes/X/RustyMacBackup\"\n".write(to: url, atomically: true, encoding: .utf8)
        var config = try Config.load(from: url)
        config.coverage.ignoreApps = ["Ghostty", "Microsoft OneNote"]
        try config.save(to: url)
        try expectEqual(try Config.load(from: url).coverage.ignoreApps, ["Ghostty", "Microsoft OneNote"], "survives save + load")
    }
}
