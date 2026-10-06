import Foundation

struct DiscoveredConfig {
    let category: String
    let label: String
    let paths: [String]
    let sensitive: Bool
}

enum ConfigDiscovery {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Discover all installed dev tools by merging built-in + custom candidates.
    /// Cheap: lists candidates without measuring anything.
    static func discover() -> [DiscoveredConfig] {
        discoverAll(measuringData: false).configs
    }

    /// Full discovery: the sources to back up, plus the data directories found inside
    /// them that must be excluded. Measuring costs a tree walk, so it is done only when
    /// a configuration is being generated, not when the list is merely displayed.
    static func discoverAll(measuringData: Bool = true) -> (configs: [DiscoveredConfig], dataExclusions: [String]) {
        var found: [DiscoveredConfig] = []
        let fm = FileManager.default
        let all = builtinCandidates + loadCustomCandidates()

        for candidate in all {
            // Filter out forbidden paths even if they exist
            let existing = candidate.paths.filter { fm.fileExists(atPath: expand($0)) && !isForbidden($0) }
            if !existing.isEmpty {
                found.append(DiscoveredConfig(
                    category: candidate.category,
                    label: candidate.label,
                    paths: existing,
                    sensitive: candidate.sensitive
                ))
            }
        }

        // Dynamic: every hidden entry in the home directory that looks like configuration
        let hidden = discoverHiddenHome(measuringData: measuringData)
        found.append(contentsOf: hidden.configs)

        // Dynamic: discover individual Git repos in ~/GitHub, ~/Developer, ~/Projects
        for repoDir in ["~/GitHub", "~/Developer", "~/Projects"] {
            let expanded = expand(repoDir)
            guard fm.fileExists(atPath: expanded),
                  let contents = try? fm.contentsOfDirectory(atPath: expanded) else { continue }
            for name in contents.sorted() {
                let repoPath = expanded + "/" + name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: repoPath, isDirectory: &isDir), isDir.boolValue else { continue }
                // Skip hidden dirs and non-repo junk
                if name.hasPrefix(".") || name == "node_modules" { continue }
                let contracted = contract(repoPath)
                found.append(DiscoveredConfig(
                    category: "Repos",
                    label: name,
                    paths: [contracted],
                    sensitive: false
                ))
            }
        }

        return (found, hidden.dataExclusions)
    }

    // MARK: - Path helpers

    static func expand(_ path: String) -> String {
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    static func contract(_ path: String) -> String {
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        if path == home { return "~" }
        return path
    }

    // MARK: - Custom discovery (user-defined, synced across machines)

    static var customDiscoveryPath: URL {
        URL(fileURLWithPath: ("~/.config/rusty-mac-backup/discovery-custom.toml" as NSString).expandingTildeInPath)
    }

    /// Load custom discovery entries from discovery-custom.toml
    private static func loadCustomCandidates() -> [Candidate] {
        guard let content = try? String(contentsOf: customDiscoveryPath, encoding: .utf8) else {
            return []
        }
        var candidates: [Candidate] = []
        var category = "Custom"
        var label = ""
        var paths: [String] = []
        var sensitive = false

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                // Save previous entry
                if !label.isEmpty && !paths.isEmpty {
                    candidates.append(Candidate(category: category, label: label,
                                                paths: paths, sensitive: sensitive))
                }
                label = String(line.dropFirst().dropLast())
                paths = []
                sensitive = false
                continue
            }

            if line.hasPrefix("category") {
                category = parseValue(line)
            } else if line.hasPrefix("path") && !line.hasPrefix("paths") {
                let p = parseValue(line)
                if !p.isEmpty { paths.append(p) }
            } else if line.hasPrefix("paths") {
                // inline array: paths = ["a", "b"]
                paths.append(contentsOf: parseArray(line))
            } else if line.hasPrefix("sensitive") {
                sensitive = parseValue(line) == "true"
            }
        }
        // Last entry
        if !label.isEmpty && !paths.isEmpty {
            candidates.append(Candidate(category: category, label: label,
                                        paths: paths, sensitive: sensitive))
        }
        return candidates
    }

    /// Generate a starter discovery-custom.toml with examples
    static func generateCustomTemplate() -> String {
        """
        # RustyMacBackup Custom Discovery
        # Add your own tools here. This file is backed up and works on any Mac.
        # Each [section] is a tool name. Paths use ~ for home directory.
        #
        # Example:
        # [My Tool]
        # category = Dev Tools
        # path = ~/.config/mytool
        # sensitive = false
        #
        # [Another Tool]
        # category = Cloud
        # paths = ["~/.config/another", "~/.another-rc"]
        # sensitive = true
        """
    }

    private static func parseValue(_ line: String) -> String {
        guard let eq = line.firstIndex(of: "=") else { return "" }
        var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if val.hasPrefix("\"") && val.hasSuffix("\"") {
            val = String(val.dropFirst().dropLast())
        }
        return val
    }

    private static func parseArray(_ line: String) -> [String] {
        guard let open = line.firstIndex(of: "["),
              let close = line.firstIndex(of: "]") else { return [] }
        let inner = String(line[line.index(after: open)..<close])
        return inner.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces)
                     .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Built-in candidates

    private typealias Candidate = (category: String, label: String, paths: [String], sensitive: Bool)

    private static let builtinCandidates: [Candidate] = [
        // Shell
        ("Shell", "zsh", ["~/.zshrc", "~/.zprofile", "~/.zshenv", "~/.zsh_history"], false),
        ("Shell", "bash", ["~/.bashrc", "~/.bash_profile", "~/.bash_history"], false),
        ("Shell", "fish", ["~/.config/fish"], false),

        // Git
        ("Git", "Git config", ["~/.gitconfig", "~/.gitignore_global", "~/.config/git"], false),

        // SSH (config + public keys, NOT private keys by default)
        ("SSH", "SSH config", ["~/.ssh/config", "~/.ssh/known_hosts"], false),

        // Terminal emulators
        ("Terminal", "Ghostty", ["~/.config/ghostty"], false),
        ("Terminal", "Warp", ["~/Library/Application Support/Warp"], false),
        ("Terminal", "iTerm2", ["~/Library/Application Support/iTerm2"], false),
        ("Terminal", "Alacritty", ["~/.config/alacritty"], false),
        ("Terminal", "kitty", ["~/.config/kitty"], false),

        // Multiplexers
        ("Terminal", "tmux", ["~/.tmux.conf", "~/.config/tmux"], false),
        ("Terminal", "zellij", ["~/.config/zellij"], false),

        // Editors (no Neovim/Helix -- add via custom discovery if needed)
        ("Editor", "Vim", ["~/.vimrc", "~/.vim"], false),
        ("Editor", "VS Code settings", ["~/Library/Application Support/Code/User/settings.json",
                                          "~/Library/Application Support/Code/User/keybindings.json"], false),
        ("Editor", "VS Code extensions", ["~/.vscode/extensions"], false),
        ("Editor", "Cursor settings", ["~/Library/Application Support/Cursor/User/settings.json",
                                         "~/Library/Application Support/Cursor/User/keybindings.json"], false),
        ("Editor", "Cursor extensions", ["~/.cursor/extensions"], false),
        ("Editor", "Zed", ["~/.config/zed"], false),
        ("Editor", "Xcode UserData", ["~/Library/Developer/Xcode/UserData"], false),
        ("Editor", "Xcode Provisioning", ["~/Library/MobileDevice/Provisioning Profiles"], false),

        // AI/LLM tools
        // Claude CLI -- specific safe subdirs only (full ~/.claude/ is 16 GB+)
        ("AI Tools", "Claude CLI settings", ["~/.claude/settings.json", "~/.claude/settings.local.json"], false),
        ("AI Tools", "Claude CLI agents", ["~/.claude/agents"], false),
        ("AI Tools", "Claude CLI memory", ["~/.claude/agent-memory"], false),
        ("AI Tools", "Claude CLI projects", ["~/.claude/projects"], false),
        ("AI Tools", "Claude AGENTS.md", ["~/.claude/AGENTS.md"], false),
        ("AI Tools", "Claude plans DB", ["~/.claude/data/plan-db.sqlite", "~/.claude/plans"], false),
        ("AI Tools", "Claude scripts", ["~/.claude/scripts"], false),
        ("AI Tools", "GitHub Copilot", ["~/.config/github-copilot"], false),
        ("AI Tools", "gh-copilot", ["~/.config/gh-copilot"], false),
        ("AI Tools", "OpenAI", ["~/.config/openai"], false),
        ("AI Tools", "Goose", ["~/.config/goose"], false),
        ("AI Tools", "shell_gpt", ["~/.config/shell_gpt"], false),

        // Dev tools
        ("Dev Tools", "oh-my-posh", ["~/.config/oh-my-posh"], false),
        ("Dev Tools", "starship", ["~/.config/starship.toml"], false),
        ("Dev Tools", "direnv", ["~/.config/direnv"], false),
        ("Dev Tools", "mise", ["~/.config/mise"], false),
        ("Dev Tools", "btop", ["~/.config/btop"], false),
        ("Dev Tools", "gitui", ["~/.config/gitui"], false),
        ("Dev Tools", "yazi", ["~/.config/yazi"], false),
        ("Dev Tools", "Cargo config", ["~/.cargo/config.toml"], false),
        ("Dev Tools", "uv (Python)", ["~/.config/uv"], false),
        ("Dev Tools", "Homebrew Bundle", ["~/.Brewfile", "~/Brewfile"], false),

        // Auth & Tokens -- separate from config so user can toggle independently
        ("Auth", "GitHub CLI auth", ["~/.config/gh/hosts.yml"], true),
        ("Auth", "SSH private keys", ["~/.ssh/id_ed25519", "~/.ssh/id_rsa",
                                       "~/.ssh/id_ed25519_innersource",
                                       "~/.ssh/id_ed25519_microsoft"], true),
        ("Auth", "npm auth", ["~/.npmrc"], true),
        ("Auth", "Cargo auth", ["~/.cargo/credentials.toml"], true),
        ("Auth", "Docker auth", ["~/.docker/config.json"], true),
        ("Auth", "AWS credentials", ["~/.aws/credentials"], true),
        ("Auth", "Azure tokens", ["~/.azure/azureProfile.json", "~/.azure/az.sess"], true),
        ("Auth", "GCP credentials", ["~/.config/gcloud/application_default_credentials.json"], true),
        ("Auth", "Stripe auth", ["~/.config/stripe/config.toml"], true),
        ("Auth", "VS Code auth", ["~/Library/Application Support/Code/User/globalStorage/github.login"], true),
        ("Auth", "Cursor auth", ["~/Library/Application Support/Cursor/User/globalStorage/github.login"], true),

        // Cloud CLIs (config only, NOT credentials)
        ("Cloud", "AWS config", ["~/.aws/config"], false),
        ("Cloud", "GCP config", ["~/.config/gcloud/properties"], false),
        ("Cloud", "Azure config", ["~/.azure/config"], false),
        ("Cloud", "Stripe config", ["~/.config/stripe"], false),
        ("Cloud", "Tailscale prefs", ["~/Library/Preferences/io.tailscale.ipn.macos.plist",
                                       "~/Library/Application Support/Tailscale"], false),

        // macOS scheduled jobs (per-user launchd agents: what runs automatically and when)
        ("macOS", "LaunchAgents", ["~/Library/LaunchAgents"], false),

        // macOS Preferences (safe plist files -- read-only copies)
        ("macOS", "Keyboard shortcuts", ["~/Library/Preferences/com.apple.symbolichotkeys.plist"], false),
        ("macOS", "Global preferences", ["~/Library/Preferences/.GlobalPreferences.plist"], false),
        ("macOS", "Dock layout", ["~/Library/Preferences/com.apple.dock.plist"], false),
        ("macOS", "Finder settings", ["~/Library/Preferences/com.apple.finder.plist"], false),
        ("macOS", "Terminal.app", ["~/Library/Preferences/com.apple.Terminal.plist"], false),
        ("macOS", "Custom dictionary", ["~/Library/Spelling/LocalDictionary"], false),
        ("macOS", "Custom fonts", ["~/Library/Fonts"], false),
    ]

    // MARK: - Hidden home discovery (dotfiles + dot directories)

    /// A configuration directory bigger than this is data, not configuration.
    /// Anything over the limit is opened one level deeper instead of taken whole.
    static let maxConfigDirBytes: Int64 = 200 * 1024 * 1024

    /// Individual dotfiles bigger than this are histories or databases, not configuration.
    static let maxConfigFileBytes: Int64 = 20 * 1024 * 1024

    /// How deep the scan is allowed to descend while trying to isolate the config
    /// part of an oversized directory.
    private static let maxHiddenDepth = 4

    /// Upper bound on entries visited while sizing one directory, so discovery stays
    /// responsive on trees with hundreds of thousands of excluded files.
    private static let maxSizeWalkEntries = 12_000

    /// Home-relative paths that are never configuration: package registries, downloaded
    /// language runtimes and models, browser profiles, per-machine state.
    static let hiddenDenyPaths: Set<String> = [
        ".Trash", ".cache", ".ollama", ".lmstudio", ".npm", ".npm-global", ".yarn",
        ".pnpm-store", ".nuget", ".dotnet", ".bun", ".deno", ".rustup", ".gradle",
        ".ivy2", ".gem", ".pyenv", ".nvm", ".rbenv", ".sdkman", ".android",
        ".cocoapods", ".swiftpm", ".conda", ".julia", ".texlive", ".cpanm",
        ".local/share", ".local/lib", ".cargo/registry", ".cargo/git", ".m2/repository",
        ".vscode/extensions", ".cursor/extensions", ".vscode-server", ".vscode-cli",
        ".zcompdump", ".zsh_sessions", ".bash_sessions", ".node_repl_history",
        ".lesshst", ".viminfo", ".wget-hsts", ".sudo_as_admin_successful",
        ".DS_Store", ".CFUserTextEncoding", ".Xauthority", ".localized",
        ".Spotlight-V100", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100",
        // VM/container engine disk images (huge, regenerable): never propose these as a
        // configuration source to back up (scar 2026-09-27, see ConfigManager.baseExcludePatterns)
        ".colima", ".lima", ".orbstack",
    ]

    /// Directory and file names that are never configuration, at any depth.
    /// Compared case-insensitively.
    static let cacheNames: Set<String> = [
        "cache", "caches", ".cache", "cacheddata", "cachedextensions", "gpucache",
        "code cache", "shadercache", "crashpad", "logs", "log", "tmp", "temp",
        "node_modules", "models", "blobs", "backup", "backups", "checkouts", "sessions",
        "session-state", "session-store", "history", "worktrees", "target", "dist",
        "build", "venv", ".venv", "__pycache__", "registry", "downloads",
        "language_servers", "shell-snapshots", "derivedddata", "deriveddata",
        "chromium-profile", "chrome-profile", "playwright-profiles", "trash",
    ]

    /// Name fragments that mark a directory as a runtime profile, cache or dump
    /// even when the exact name is unknown.
    private static let cacheNameSuffixes: [String] = [
        "-cache", "-caches", "-profile", "-profiles", "-backup", "-backups",
        "-logs", ".old", ".bak",
    ]

    /// Extensions that are never configuration.
    private static let cacheExtensions: Set<String> = [
        "log", "jsonl", "sqlite", "sqlite3", "db", "db-wal", "db-shm", "wal", "shm",
        "pyc", "tmp", "swp", "pid", "sock", "lock", "iso", "dmg", "zip", "tar", "gz",
        "sqlite-wal", "sqlite-shm", "cache", "bak", "old", "orig", "crdownload",
    ]

    /// Dot entries that hold credentials. When found by the dynamic scan they are
    /// marked sensitive, so the default configuration leaves them out; the curated
    /// candidates above still contribute their safe parts (for example ~/.ssh/config).
    static let secretBearingDotEntries: Set<String> = [
        ".ssh", ".gnupg", ".aws", ".azure", ".azureauth", ".docker", ".kube",
        ".netrc", ".pgpass", ".npmrc", ".pypirc", ".authinfo", ".git-credentials",
        ".password-store", ".chef", ".vault-token", ".databricks", ".snowflake",
    ]

    /// Result of the home scan: one source per hidden entry, plus the home-relative
    /// paths of the data directories found inside them.
    struct HiddenScan {
        var configs: [DiscoveredConfig] = []
        var dataExclusions: [String] = []
    }

    /// Scan the home directory for hidden entries that look like application
    /// configuration. Caches, registries, models and logs are filtered out by name;
    /// what survives is kept as a whole directory — so tools installed later are
    /// covered without touching this list — and any oversized data folder found
    /// inside it is reported as an exclusion instead of being listed around.
    static func discoverHiddenHome(measuringData: Bool = true) -> HiddenScan {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: home) else { return HiddenScan() }

        // Skip entries a curated candidate already covers in full.
        let curatedWholeDirs = Set(builtinCandidates.flatMap { $0.paths }
            .filter { $0.hasPrefix("~/") && !$0.dropFirst(2).contains("/") }
            .map { String($0.dropFirst(2)) })

        var files: [DiscoveredConfig] = []
        var dirs: [DiscoveredConfig] = []
        var exclusions: [String] = []

        for name in entries.sorted() where name.hasPrefix(".") {
            if name == "." || name == ".." { continue }
            if curatedWholeDirs.contains(name) { continue }
            if isDeniedHidden(relative: name) { continue }
            if isForbidden("~/" + name) { continue }

            let full = home + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            let sensitive = secretBearingDotEntries.contains(name.lowercased())

            if !isDir.boolValue {
                guard fileSize(atPath: full) <= maxConfigFileBytes else { continue }
                files.append(DiscoveredConfig(category: "Dotfiles", label: name,
                                              paths: ["~/" + name], sensitive: sensitive))
                continue
            }

            if measuringData {
                exclusions.append(contentsOf: dataSubdirectories(relative: name, depth: 1))
            }
            dirs.append(DiscoveredConfig(category: "App Configs", label: name,
                                         paths: ["~/" + name], sensitive: sensitive))
        }

        return HiddenScan(configs: files + dirs, dataExclusions: exclusions)
    }

    /// Home-relative paths of the directories inside `relative` that are too big to be
    /// configuration. Descends only into oversized branches, so the cost is bounded by
    /// the amount of data actually present, not by the number of files.
    private static func dataSubdirectories(relative: String, depth: Int) -> [String] {
        let full = home + "/" + relative
        if approximateSize(atPath: full, limit: maxConfigDirBytes) <= maxConfigDirBytes {
            return []
        }
        guard depth < maxHiddenDepth,
              let children = try? FileManager.default.contentsOfDirectory(atPath: full) else {
            // Too deep to isolate: exclude the whole branch rather than copy data.
            return depth >= maxHiddenDepth ? [relative] : []
        }

        var out: [String] = []
        for child in children.sorted() {
            let childRelative = relative + "/" + child
            if isDeniedHidden(relative: childRelative) { continue }
            if defaultFilter.shouldSkipDirectory(relativePath: child) { continue }
            if isForbidden("~/" + childRelative) { continue }

            let childFull = home + "/" + childRelative
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: childFull, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            let size = approximateSize(atPath: childFull, limit: maxConfigDirBytes)
            guard size > maxConfigDirBytes else { continue }

            let deeper = dataSubdirectories(relative: childRelative, depth: depth + 1)
            out.append(contentsOf: deeper.isEmpty ? [childRelative] : deeper)
        }
        return out
    }

    /// True when the path, or any of its components, is known not to be configuration.
    static func isDeniedHidden(relative: String) -> Bool {
        if hiddenDenyPaths.contains(relative) { return true }
        for component in relative.split(separator: "/").map(String.init) {
            if isDeniedName(component) { return true }
        }
        return false
    }

    static func isDeniedName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if cacheNames.contains(lower) { return true }
        for suffix in cacheNameSuffixes where lower.hasSuffix(suffix) { return true }
        // Timestamped copies: "config.bak-20260830", "settings.json.old-2"
        for marker in [".bak-", ".old-", ".backup-", ".orig-"] where lower.contains(marker) {
            return true
        }
        let ext = (lower as NSString).pathExtension
        if !ext.isEmpty && cacheExtensions.contains(ext) { return true }
        return false
    }

    /// Allocated size of a tree, ignoring anything the default exclusions would drop and
    /// stopping as soon as `limit` is passed, so a multi-gigabyte cache costs the same as
    /// a small directory to reject.
    static func approximateSize(atPath path: String, limit: Int64) -> Int64 {
        let filter = defaultFilter
        let root = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            return fileSize(atPath: path)
        }

        let rootPrefix = root.path + "/"
        var total: Int64 = 0
        var examined = 0
        for case let url as URL in enumerator {
            examined += 1
            // A tree this large that is still under budget is mostly excluded content:
            // accept it rather than spend minutes walking files nobody will copy.
            if examined > maxSizeWalkEntries { return total }
            let relative = url.path.hasPrefix(rootPrefix)
                ? String(url.path.dropFirst(rootPrefix.count))
                : url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

            if values.isDirectory == true {
                if filter.shouldSkipDirectory(relativePath: relative) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                  !filter.isExcluded(relativePath: relative) else { continue }

            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            if total > limit { return total }
        }
        return total
    }

    private static let defaultFilter = ExcludeFilter(patterns: defaultExcludePatterns)

    static func fileSize(atPath path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Drop paths already covered by another path in the list, so a directory and its
    /// own children are never both listed as backup sources.
    static func pruneRedundant(_ paths: [String]) -> [String] {
        var kept: [String] = []
        for path in paths.sorted() {
            let covered = kept.contains { parent in
                path == parent || path.hasPrefix(parent + "/")
            }
            if !covered { kept.append(path) }
        }
        return kept
    }

    // MARK: - Restore discovery

    /// Returns candidates whose paths are present in the given snapshot.
    /// Unlike discover(), does NOT require files to exist on the current machine —
    /// safe for cross-machine restore (fresh Mac).
    static func candidatesForRestore(snapshotTopLevels: Set<String>) -> [DiscoveredConfig] {
        var found: [DiscoveredConfig] = []
        for candidate in builtinCandidates {
            let inSnapshot = candidate.paths.filter { path in
                let rel = path.hasPrefix("~/") ? String(path.dropFirst(2)) : path
                let top: String
                if let slash = rel.firstIndex(of: "/") {
                    top = String(rel[rel.startIndex..<slash])
                } else {
                    top = rel
                }
                return snapshotTopLevels.contains(top)
            }
            if !inSnapshot.isEmpty {
                found.append(DiscoveredConfig(category: candidate.category, label: candidate.label,
                                              paths: inSnapshot, sensitive: candidate.sensitive))
            }
        }
        return found
    }

    // MARK: - Forbidden paths

    static let forbiddenPrefixes: [String] = [
        // TCC-protected user data (triggers tccd, may crash system)
        "~/Library/Mail", "~/Library/Messages", "~/Library/Safari",
        "~/Library/Suggestions", "~/Library/PersonalizationPortrait",
        // iCloud/cloud daemon-managed (touching crashes bird/tccd)
        "~/Library/Containers", "~/Library/Group Containers",
        "~/Library/Daemon Containers",
        "~/Library/Mobile Documents", "~/Library/Application Support/CloudDocs",
        // System-managed data stores
        "~/Library/Application Support/com.apple.TCC",
        "~/Library/Application Support/MobileSync",
        "~/Library/Application Support/AddressBook",
        "~/Library/Metadata", "~/Library/Biome",
        "~/Library/DuetExpertCenter", "~/Library/IntelligencePlatform",
        "~/Library/StatusKit", "~/Library/Trial",
        // Caches/regenerable
        "~/Library/Caches", "~/Library/Logs",
        "~/Library/Saved Application State", "~/Library/Updates",
        // Photos/Music
        "~/Pictures/Photos Library.photoslibrary",
        "~/Pictures/Photo Booth Library",
        "~/Music/Music/Media.localized",
        // Claude CLI build artifacts (16 GB+). NOT ~/.claude/scripts (under 1 MB, real
        // config the user edits) -- that stays a builtin candidate, see below.
        "~/.claude/rust", "~/.claude/debug", "~/.claude/worktrees",
        "~/.claude/node_modules", "~/.claude/file-history",
        "~/.claude/data", "~/.claude/backups",
        "~/.claude/logs", "~/.claude/.copilot-tracking",
        // System paths
        "/Library", "/System", "/etc", "/Applications", "/usr", "/opt", "/private",
    ]

    // Cloud-sync provider folders (OneDrive, Dropbox, Google Drive, iCloud's own mount here
    // too). Kept separate from forbiddenPrefixes: unlike Mail/Messages/Containers, touching
    // this does not crash a system daemon -- the risk here is a *provider* concern (a sync
    // client re-uploading a copy, an org's DLP/rights-management policy blocking the copy),
    // not a macOS stability one. Off by default (config-only; no UI checkbox -- a one-click
    // toggle next to the safe rights-management one would invite turning this on by mistake).
    static let cloudStoragePrefixes: [String] = ["~/Library/CloudStorage"]

    static func isForbidden(_ path: String, allowCloudStorage: Bool = false) -> Bool {
        let expanded = expand(path)
        for prefix in forbiddenPrefixes {
            let expandedPrefix = expand(prefix)
            if expanded == expandedPrefix || expanded.hasPrefix(expandedPrefix + "/") {
                return true
            }
        }
        if !allowCloudStorage {
            for prefix in cloudStoragePrefixes {
                let expandedPrefix = expand(prefix)
                if expanded == expandedPrefix || expanded.hasPrefix(expandedPrefix + "/") {
                    return true
                }
            }
        }
        return false
    }
}
