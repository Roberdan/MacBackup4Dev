import Foundation

/// 4.0: first-launch scan of a developer's Mac, and the programs a new Mac is offered.
struct OnboardingTests {
    private func sandbox() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rmb-onb-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
    private func write(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func test_brewfileAndPackageListsAreParsed() throws {
        let brewfile = """
        tap "homebrew/bundle"
        brew "jq"
        brew "postgresql@17", restart_service: :changed
        cask "warp"
        mas "Xcode", id: 497799835
        vscode "ms-python.python"
        # comment
        """
        let p = ToolInventory.parseBrewfile(brewfile)
        try expectEqual(p.map(\.id), ["tap:homebrew/bundle", "brew:jq", "brew:postgresql@17", "cask:warp", "mas:Xcode", "vscode:ms-python.python"],
                        "every kind read, options ignored")
        try expectEqual(p.first { $0.kind == .mas }?.storeID, "497799835", "App Store id kept")
        try expectEqual(ToolInventory.parseUVToolList("ruff v0.6.0\n- ruff\nllm v0.13\n- llm\n"), ["ruff", "llm"], "uv tool list")
        try expectEqual(ToolInventory.parseCargoInstallList("ripgrep v14.1.0:\n    rg\nbat v0.24.0:\n    bat\n"), ["ripgrep", "bat"], "cargo install --list")

        let snap = URL(fileURLWithPath: try sandbox()); defer { try? FileManager.default.removeItem(at: snap) }
        try write(brewfile, snap.path + "/_environment/Brewfile")
        try write("typescript\npnpm\n", snap.path + "/_environment/npm-global.txt")
        try write("ms-python.python\nother.ext\n", snap.path + "/_environment/vscode-extensions.txt")
        let all = ToolInventory.packages(snapshot: snap)
        try expect(all.contains { $0.id == "npm:typescript" }, "npm globals offered")
        try expect(!all.contains { $0.id == "vscode:other.ext" }, "Brewfile's VS Code list wins over the old list file (no duplicates)")
        try expectEqual(Set(all.map(\.id)).count, all.count, "no duplicates")
    }

    func test_newMacStartsWithBaseToolsThenPrograms() throws {
        let snap = URL(fileURLWithPath: try sandbox()).appendingPathComponent("2026-10-07_100000")
        defer { try? FileManager.default.removeItem(at: snap.deletingLastPathComponent()) }
        try write("brew \"jq\"\n", snap.path + "/_environment/Brewfile")
        try write("note", snap.path + "/Obsidian/n.md")
        let ids = NewMacRestore.stages(snapshot: snap, config: nil).map(\.id)
        try expectEqual(Array(ids.prefix(3)), ["base", "programmi", "dati"], "tools before files: \(ids)")
        try expect(!ids.contains("homebrew"), "the all-or-nothing Homebrew phase is gone")
        try expectEqual(ids.last, "servizi", "services still last")
    }

    func test_scanGroupsAndProtectsSecrets() throws {
        let home = try sandbox(); defer { try? FileManager.default.removeItem(atPath: home) }
        try write("[user]", home + "/.config/gh/hosts.yml")
        try write("x", home + "/.config/secrets/token")
        try write("set number", home + "/.config/nvim/init.vim")
        let children = DevEnvironment.configChildren(home: home)
        try expect(children.first { $0.label == "gh" }?.sensitive == true, "gh keeps a token: chosen by hand")
        try expect(children.first { $0.label == "nvim" }?.sensitive == false, "nvim is plain configuration")
        try expect(DevEnvironment.looksSecret("secrets") && DevEnvironment.looksSecret("api-token.json"), "secret-looking names")
        try expect(!DevEnvironment.looksSecret("nvim"), "normal names are not secret")
        try expectEqual(DevEnvironment.groupID(for: DiscoveredConfig(category: "App Configs", label: ".claude", paths: ["~/.claude"], sensitive: false)), "ai", "AI tool")
        try expectEqual(DevEnvironment.groupID(for: DiscoveredConfig(category: "App Configs", label: ".kube", paths: ["~/.kube"], sensitive: false)), "cloud", "cloud tool")
    }

    func test_projectRootsSkipCloudFoldersAndLinks() throws {
        let home = try sandbox(); defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/GitHub/app/.git", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/work/client/api/.git", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/OneDrive - Contoso/x/.git", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/cloud-target/y/.git", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/Linked", withDestinationPath: home + "/cloud-target")
        try fm.createDirectory(atPath: home + "/Pictures/z/.git", withIntermediateDirectories: true)
        let roots = DevEnvironment.projectRoots(home: home)
        try expect(roots.contains("GitHub") && roots.contains("work"), "known and found roots: \(roots)")
        try expect(!roots.contains("OneDrive - Contoso"), "cloud folder never walked")
        try expect(!roots.contains("Linked"), "links (e.g. into CloudStorage) never walked")
        try expect(!roots.contains("Pictures"), "media folders are not project roots")
        try expectEqual(DevEnvironment.gitRepositories(in: home + "/work", depth: 2).count, 1, "repo two levels down found")
    }

    func test_configFromChoicesKeepsOnlyWhatWasChosen() throws {
        var scan = DevScan()
        scan.groups = [
            DevGroup(id: "shell", title: "", symbol: "", items: [DevItem(id: "~/.zshrc", name: "zsh", paths: ["~/.zshrc"], sensitive: false)]),
            DevGroup(id: "credenziali", title: "", symbol: "", items: [DevItem(id: "~/.ssh", name: ".ssh", paths: ["~/.ssh"], sensitive: true)]),
            DevGroup(id: "database", title: "", symbol: "", items: [DevItem(id: "postgres:app", name: "app", paths: [], sensitive: false)]),
        ]
        scan.dataExclusions = ["x"]
        try expectEqual(scan.defaultSelection, ["~/.zshrc", "postgres:app"], "credentials never proposed")
        let config = DevEnvironment.config(from: scan, selected: scan.defaultSelection, backupPath: "/Volumes/D/MacBackup4Dev")
        try expect(config.source.paths.contains("~/.zshrc") && !config.source.paths.contains("~/.ssh"), "only chosen paths: \(config.source.paths)")
        try expect(config.source.paths.contains("~/.config/macbackup4dev"), "own settings always saved")
        try expectEqual(config.databases.postgres, ["app"], "chosen database dumped")
    }

    /// Review 4.0 #1: the real 3.x plist of this Mac (with the on-ac wrapper) must survive.
    func test_legacyScheduleKeepsWrapperAndFlags() throws {
        let old: [String: Any] = [
            "Label": "com.roberdan.rusty-mac-backup", "LowPriorityIO": true, "Nice": 10, "RunAtLoad": true,
            "ProgramArguments": ["/Users/u/.local/bin/on-ac", "/Applications/RustyMacBackup.app/Contents/MacOS/RustyMacBackup", "backup"],
            "StandardOutPath": "/Users/u/.local/share/rusty-mac-backup/backup.log",
            "StandardErrorPath": "/Users/u/.local/share/rusty-mac-backup/backup-error.log",
            "StartInterval": 3600,
        ]
        let new = ScheduleManager.migratedPlist(from: old, binary: "/Applications/MacBackup4Dev.app/Contents/MacOS/MacBackup4Dev")
        try expectEqual(new["Label"] as? String, "com.roberdan.macbackup4dev", "new label")
        try expectEqual(new["ProgramArguments"] as? [String],
                        ["/Users/u/.local/bin/on-ac", "/Applications/MacBackup4Dev.app/Contents/MacOS/MacBackup4Dev", "backup", "--scheduled"],
                        "wrapper kept, binary swapped, battery gate on")
        try expectEqual(new["StartInterval"] as? Int, 3600, "same interval")
        try expectEqual(new["StandardOutPath"] as? String, "/Users/u/.local/share/macbackup4dev/backup.log", "logs in the new folder")
        try expectEqual(new["Nice"] as? Int, 10, "other keys kept")
    }

    /// Review 4.0 #4: a folder holding a credential file is a credential.
    func test_folderWithACredentialIsACredential() throws {
        try expect(ConfigDiscovery.discover().first { $0.label == "Stripe config" }.map(\.sensitive) ?? true,
                   "Stripe config (API keys) is never proposed")
        try expectNil(ToolInventory.command(for: ToolInventory.Package(kind: .npm, name: "--global-style")),
                      "a package name that looks like an option is refused")
    }
}
