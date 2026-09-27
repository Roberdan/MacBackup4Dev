import Foundation

final class HiddenDiscoveryTests {
    func test_deniedCacheNames() throws {
        try expect(ConfigDiscovery.isDeniedName("Caches"), "Caches is not config")
        try expect(ConfigDiscovery.isDeniedName("node_modules"), "node_modules is not config")
        try expect(ConfigDiscovery.isDeniedName("chromium-profile"), "browser profile is not config")
        try expect(ConfigDiscovery.isDeniedName("m-playwright-profiles"), "-profiles suffix is not config")
        try expect(ConfigDiscovery.isDeniedName(".ado_orgs.cache"), ".cache extension is not config")
        try expect(ConfigDiscovery.isDeniedName("logs_2.sqlite-wal"), "sqlite sidecars are not config")
        try expect(ConfigDiscovery.isDeniedName(".npmrc.bak-20260830-105410"), "timestamped copies are not config")
    }

    func test_realConfigSurvives() throws {
        for name in [".zshrc", ".gitconfig", "settings.json", "config.toml", ".codex", "skills", "agents"] {
            try expect(!ConfigDiscovery.isDeniedName(name), "\(name) must stay in the backup")
        }
    }

    func test_deniedPaths() throws {
        try expect(ConfigDiscovery.isDeniedHidden(relative: ".local/share"), ".local/share is data")
        try expect(ConfigDiscovery.isDeniedHidden(relative: ".ollama"), "model store is data")
        try expect(ConfigDiscovery.isDeniedHidden(relative: ".cargo/registry"), "crate registry is data")
        try expect(ConfigDiscovery.isDeniedHidden(relative: ".gstack/chromium-profile"), "nested profile is data")
        try expect(!ConfigDiscovery.isDeniedHidden(relative: ".local/bin"), ".local/bin is user content")
        try expect(!ConfigDiscovery.isDeniedHidden(relative: ".codex"), ".codex is config")
    }

    func test_secretsStayOptIn() throws {
        let scan = ConfigDiscovery.discoverHiddenHome(measuringData: false)
        for entry in scan.configs where ["~/.ssh", "~/.gnupg", "~/.aws"].contains(entry.paths.first ?? "") {
            try expect(entry.sensitive, "\(entry.label) must be marked sensitive")
        }
    }

    func test_pruneRedundant() throws {
        let pruned = ConfigDiscovery.pruneRedundant([
            "~/.claude/agents", "~/.claude", "~/.claude/settings.json", "~/.claudex",
        ])
        try expectEqual(pruned, ["~/.claude", "~/.claudex"], "children of an included dir are dropped")
    }

    func test_sizeIgnoresExcludedContent() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let modules = root + "/node_modules"
        try FileManager.default.createDirectory(atPath: modules, withIntermediateDirectories: true)
        let big = Data(count: 4 * 1024 * 1024)
        try big.write(to: URL(fileURLWithPath: modules + "/blob.bin"))
        try Data("theme = dark".utf8).write(to: URL(fileURLWithPath: root + "/config.toml"))

        let size = ConfigDiscovery.approximateSize(atPath: root, limit: 1024 * 1024)
        try expect(size < 1024 * 1024, "node_modules must not count toward the config size, got \(size)")
    }

    func test_claudeScriptsIsBackedUpNotForbidden() throws {
        // Regression: ~/.claude/scripts (under 1 MB, hand-edited automation scripts) was
        // listed both as a builtin candidate AND in forbiddenPrefixes ("build artifacts
        // 16 GB+"), so isForbidden always won and it was silently never backed up.
        try expect(!ConfigDiscovery.isForbidden("~/.claude/scripts"),
                   "~/.claude/scripts is real hand-edited config, not a 16 GB+ build artifact")
    }

    func test_launchAgentsAreDiscovered() throws {
        // ~/Library/LaunchAgents holds the plists that decide what runs automatically and
        // when (backup schedule included) -- it isn't a dotfile, so it needs an explicit
        // builtin candidate; the dynamic hidden-home scan never sees it.
        let found = ConfigDiscovery.discover()
        try expect(found.contains { $0.label == "LaunchAgents" && $0.paths == ["~/Library/LaunchAgents"] },
                   "~/Library/LaunchAgents must be a discovered source")
    }

    func test_checkoutsIsADeniedName() throws {
        // ~/.gbrain/checkouts (11 GB+ of re-clonable git checkouts) must never be sized or
        // listed as configuration, same treatment as "backups" already gets.
        try expect(ConfigDiscovery.isDeniedName("checkouts"), "checkouts is re-clonable data, not config")
    }

    func test_cloudStorageForbiddenByDefault() throws {
        try expect(ConfigDiscovery.isForbidden("~/Library/CloudStorage/OneDrive-Microsoft/FY27"),
                   "OneDrive/CloudStorage must stay excluded with no config override")
        try expect(ConfigDiscovery.isForbidden("~/Library/CloudStorage"),
                   "the CloudStorage root itself must also stay excluded")
    }

    func test_cloudStorageAllowedOnlyWithExplicitOptIn() throws {
        try expect(!ConfigDiscovery.isForbidden("~/Library/CloudStorage/OneDrive-Microsoft/FY27",
                                                 allowCloudStorage: true),
                   "protection.include_cloud_storage = true must let it through")
        // The opt-in must not weaken the unrelated, daemon-crash-risk forbidden paths.
        try expect(ConfigDiscovery.isForbidden("~/Library/Containers", allowCloudStorage: true),
                   "allowCloudStorage must not also unlock Containers")
        try expect(ConfigDiscovery.isForbidden("~/Library/Mail", allowCloudStorage: true),
                   "allowCloudStorage must not also unlock Mail")
    }

    private func makeTempDir() throws -> String {
        let path = NSTemporaryDirectory() + "rmb-hidden-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
