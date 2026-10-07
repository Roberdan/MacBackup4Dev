import Foundation

/// First-launch scan of a developer's Mac (4.0): what to back up, grouped the way a developer
/// thinks about it, plus what is installed (languages, package managers, containers) so the
/// backup can rebuild it on a new Mac. Built on `ConfigDiscovery` (curated catalog + every
/// hidden entry of the home), then regrouped, deduplicated, with projects counted per folder
/// and local Postgres databases found.
struct DevItem: Identifiable, Hashable {
    let id: String
    let name: String
    let paths: [String]
    var detail: String = ""
    /// Holds credentials: never selected by default, chosen one by one.
    let sensitive: Bool
    /// Selected when the list appears (false for credentials and things that look temporary).
    var proposed: Bool = true
}

struct DevGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    var items: [DevItem]
}

struct DevToolchain: Hashable {
    let name: String
    let detail: String
}

struct DevScan {
    var groups: [DevGroup] = []
    var toolchains: [DevToolchain] = []
    var postgres: [String] = []
    var dataExclusions: [String] = []

    var allItems: [DevItem] { groups.flatMap(\.items) }
    var defaultSelection: Set<String> { Set(allItems.filter { !$0.sensitive && $0.proposed }.map(\.id)) }
}

enum DevEnvironment {
    /// Group order on screen, with the SF Symbol shown next to each.
    static let groupOrder: [(id: String, title: String, symbol: String)] = [
        ("progetti", "Progetti e repository", "folder.badge.gearshape"),
        ("shell", "Terminale e shell", "terminal"),
        ("git", "Git e SSH", "arrow.triangle.branch"),
        ("editor", "Editor e IDE", "chevron.left.forwardslash.chevron.right"),
        ("ai", "Assistenti AI", "sparkles"),
        ("linguaggi", "Linguaggi e pacchetti", "shippingbox"),
        ("cloud", "Cloud e container", "cloud"),
        ("database", "Database", "cylinder.split.1x2"),
        ("mac", "Impostazioni del Mac", "macwindow"),
        ("altro", "Altre configurazioni", "gearshape.2"),
        ("credenziali", "Credenziali (una per una)", "key"),
    ]

    /// Folders where developers keep projects. Any other top-level folder with git
    /// repositories inside (two levels deep) is found as well.
    static let projectRootNames = ["GitHub", "Developer", "Projects", "projects", "code", "Code", "src",
                                   "dev", "Dev", "workspace", "Workspace", "repos", "Repos", "git", "Sites"]
    private static let notProjectRoots: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures",
                                                       "Public", "Downloads", "Desktop"]

    /// Fast: lists what is there without measuring folder sizes (seconds, not minutes).
    /// `config(from:)` measures only the folders the user kept.
    static func scan(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> DevScan {
        var scan = DevScan()
        let configs = ConfigDiscovery.discoverAll(measuringData: false).configs

        var byGroup: [String: [DevItem]] = [:]
        var covered = Set<String>()
        // ~/.config is many tools in one folder, some holding tokens (gh): one item each.
        let expanded = configs.flatMap { config -> [DiscoveredConfig] in
            guard config.paths == ["~/.config"] else { return [config] }
            return configChildren(home: home)
        }
        // Whole hidden folders (".claude") make the curated sub-items ("Claude CLI agents")
        // redundant; a dotfile listed by the curated catalog is not listed twice either.
        // A folder that contains a credential file is itself a credential (Stripe's config.toml
        // holds the API keys): the safe flag must not depend on which entry came first.
        let secretPaths = expanded.filter(\.sensitive).flatMap(\.paths)
        func holdsSecret(_ path: String) -> Bool { secretPaths.contains { $0 == path || $0.hasPrefix(path + "/") } }
        let wholeDirs = expanded.filter { $0.category == "App Configs" || $0.category == "Config" }.flatMap(\.paths)
        for config in expanded where config.category != "Repos" {
            let paths = config.paths.filter { path in
                !covered.contains(path) && !isDeniedData(path)
                    && !(config.category != "App Configs" && config.category != "Config"
                         && wholeDirs.contains { path.hasPrefix($0 + "/") })
            }
            guard !paths.isEmpty else { continue }
            covered.formUnion(paths)
            let sensitive = config.sensitive || looksSecret(config.label)
                || paths.contains { looksSecret(($0 as NSString).lastPathComponent) || holdsSecret($0) }
            let group = sensitive ? "credenziali" : groupID(for: config)
            byGroup[group, default: []].append(DevItem(id: paths[0], name: config.label, paths: paths,
                                                       detail: paths.joined(separator: ", "), sensitive: sensitive))
        }
        for jet in jetBrainsSettings(home: home) where !covered.contains(jet.paths[0]) {
            byGroup["editor", default: []].append(jet)
        }

        for root in projectRoots(home: home) {
            let count = gitRepositories(in: home + "/" + root, depth: 2).count
            byGroup["progetti", default: []].append(DevItem(
                id: "~/" + root, name: "~/" + root, paths: ["~/" + root],
                detail: "\(count) repository, con le modifiche non ancora salvate su GitHub", sensitive: false))
        }

        scan.postgres = postgresDatabases()
        for db in scan.postgres {
            let looksTemporary = ["test", "tmp", "temp", "scratch"].contains { db.lowercased().contains($0) }
            byGroup["database", default: []].append(DevItem(
                id: "postgres:" + db, name: db, paths: [],
                detail: looksTemporary ? "sembra un database di prova: non proposto" : "Postgres locale, copiato con pg_dump",
                sensitive: false, proposed: !looksTemporary))
        }

        scan.groups = groupOrder.compactMap { g in
            guard let items = byGroup[g.id], !items.isEmpty else { return nil }
            return DevGroup(id: g.id, title: g.title, symbol: g.symbol,
                            items: items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
        scan.toolchains = toolchains(home: home)
        return scan
    }

    /// The configuration for the chosen items.
    static func config(from scan: DevScan, selected: Set<String>, backupPath: String) -> Config {
        let chosen = scan.allItems.filter { selected.contains($0.id) }
        var paths = chosen.flatMap(\.paths).filter { !ConfigDiscovery.isForbidden($0) }
        paths.append("~/.config/macbackup4dev")
        paths = ConfigDiscovery.pruneRedundant(Array(Set(paths)).sorted())
        let exclusions = scan.dataExclusions.isEmpty ? ConfigDiscovery.dataExclusions(forSources: paths) : scan.dataExclusions
        var config = Config(
            source: SourceConfig(paths: paths),
            destination: DestinationConfig(path: backupPath),
            exclude: ExcludeConfig(patterns: defaultExcludePatterns + Array(Set(exclusions)).sorted()),
            retention: RetentionConfig())
        config.databases.postgres = chosen.filter { $0.id.hasPrefix("postgres:") }.map { String($0.id.dropFirst("postgres:".count)) }
        return config
    }

    // MARK: - Grouping

    /// Tools under ~/.config that keep login tokens next to their settings.
    static let tokenBearingConfigDirs: Set<String> = ["gh", "gcloud", "op", "hub", "doctl", "heroku", "stripe", "netlify", "vercel"]

    /// One item per tool inside ~/.config.
    static func configChildren(home: String) -> [DiscoveredConfig] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: home + "/.config")) ?? []).sorted()
        return names.compactMap { name in
            let relative = ".config/" + name
            if name == ".DS_Store" || ConfigDiscovery.isDeniedHidden(relative: relative) || ConfigDiscovery.isDeniedName(name) { return nil }
            return DiscoveredConfig(category: "Config", label: name, paths: ["~/" + relative],
                                    sensitive: tokenBearingConfigDirs.contains(name))
        }
    }

    /// A name that says it holds secrets: chosen by hand, never proposed.
    static func looksSecret(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["secret", "credential", "token", "password", "passwd", "private-key", "keychain", ".pem", ".p12", "vault-token"]
            .contains { n.contains($0) }
    }

    /// Folders discovery itself treats as data (".vscode/extensions", ".local/share" …).
    static func isDeniedData(_ path: String) -> Bool {
        guard path.hasPrefix("~/.") else { return false }
        return ConfigDiscovery.isDeniedHidden(relative: String(path.dropFirst(2)))
    }

    static func groupID(for config: DiscoveredConfig) -> String {
        switch config.category {
        case "Shell", "Terminal": return "shell"
        case "Git", "SSH": return "git"
        case "Editor": return "editor"
        case "AI Tools": return "ai"
        case "Dev Tools": return "linguaggi"
        case "Cloud": return "cloud"
        case "macOS": return "mac"
        default: break
        }
        let name = config.label.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        func has(_ keys: [String]) -> Bool { keys.contains { name == $0 || name.hasPrefix($0) } }
        if has(["claude", "copilot", "codex", "gemini", "cursor", "windsurf", "aider", "continue", "ollama", "opencode", "goose", "amp"]) { return "ai" }
        if has(["zsh", "bash", "profile", "inputrc", "tmux", "oh-my-zsh", "p10k", "hushlogin", "zfunc", "warp", "wezterm", "fish", "starship", "atuin"]) { return "shell" }
        if has(["git", "ssh", "gnupg", "gh"]) { return "git" }
        if has(["vim", "nvim", "emacs", "vscode", "idea", "zed", "helix", "editorconfig"]) { return "editor" }
        if has(["cargo", "rustup", "npm", "nvm", "pnpm", "yarn", "bun", "deno", "pyenv", "rbenv", "gem", "m2", "gradle",
                "sdkman", "volta", "fnm", "pip", "conda", "uv", "local", "go", "mise", "asdf", "tool-versions", "pypirc", "julia", "swiftpm"]) { return "linguaggi" }
        if has(["aws", "azure", "kube", "docker", "terraform", "pulumi", "orbstack", "colima", "helm", "gcloud", "fly", "vercel", "netlify", "supabase"]) { return "cloud" }
        if has(["psql", "pgpass", "mysql", "sqlite", "redis", "mongo"]) { return "database" }
        return "altro"
    }

    // MARK: - Projects

    /// Home-relative folders that hold git repositories.
    static func projectRoots(home: String) -> [String] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: home)) ?? []
        var roots: [String] = []
        for name in entries.sorted() where !name.hasPrefix(".") && !notProjectRoots.contains(name) {
            // Cloud folders (OneDrive, Dropbox, iCloud…) are often links into
            // ~/Library/CloudStorage: walking them can download files. Never.
            let full = home + "/" + name
            if (try? fm.destinationOfSymbolicLink(atPath: full)) != nil { continue }
            if ["OneDrive", "Dropbox", "Google Drive", "Box", "iCloud"].contains(where: { name.hasPrefix($0) }) { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: home + "/" + name, isDirectory: &isDir), isDir.boolValue,
                  !ConfigDiscovery.isForbidden("~/" + name) else { continue }
            let known = projectRootNames.contains(name)
            if known || !gitRepositories(in: home + "/" + name, depth: 2, stopAtFirst: true).isEmpty {
                // A known root with nothing inside is still worth backing up only if not empty.
                if known && ((try? fm.contentsOfDirectory(atPath: home + "/" + name)) ?? []).isEmpty { continue }
                roots.append(name)
            }
        }
        return roots
    }

    /// Git repositories inside `dir`, up to `depth` levels (a repository's own subfolders
    /// are not searched).
    static func gitRepositories(in dir: String, depth: Int, stopAtFirst: Bool = false) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        func walk(_ path: String, _ level: Int) {
            if stopAtFirst && !found.isEmpty { return }
            if fm.fileExists(atPath: path + "/.git") { found.append(path); return }
            guard level < depth, let names = try? fm.contentsOfDirectory(atPath: path) else { return }
            for name in names where !name.hasPrefix(".") && name != "node_modules" {
                var isDir: ObjCBool = false
                let child = path + "/" + name
                if fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue { walk(child, level + 1) }
            }
        }
        walk(dir, 0)
        return found
    }

    // MARK: - Editors with versioned settings

    /// JetBrains keeps settings per IDE version; only the small settings folders, never plugins.
    static func jetBrainsSettings(home: String) -> [DevItem] {
        let base = "Library/Application Support/JetBrains"
        let fm = FileManager.default
        let ides = ((try? fm.contentsOfDirectory(atPath: home + "/" + base)) ?? []).sorted()
        return ides.compactMap { ide in
            let paths = ["options", "keymaps", "codestyles", "templates", "colors", "inspection"]
                .map { "\(base)/\(ide)/\($0)" }
                .filter { fm.fileExists(atPath: home + "/" + $0) }
                .map { "~/" + $0 }
            return paths.isEmpty ? nil : DevItem(id: paths[0], name: ide, paths: paths, detail: "impostazioni, senza plugin", sensitive: false)
        }
    }

    // MARK: - Databases

    /// Local Postgres databases (not the templates, not `postgres`).
    static func postgresDatabases() -> [String] {
        guard let psql = Shell.find(["/opt/homebrew/bin/psql", "/usr/local/bin/psql",
                                     "/opt/homebrew/opt/postgresql@17/bin/psql", "/opt/homebrew/opt/postgresql@16/bin/psql",
                                     "/Applications/Postgres.app/Contents/Versions/latest/bin/psql"]) else { return [] }
        let r = Shell.run(psql, ["-d", "postgres", "-At", "-c", "select datname from pg_database where not datistemplate"], timeout: 10)
        guard r.ok else { return [] }
        return r.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty && $0 != "postgres" }.sorted()
    }

    // MARK: - Installed toolchains (shown, and rebuilt on a new Mac)

    static func toolchains(home: String) -> [DevToolchain] {
        let fm = FileManager.default
        func exists(_ p: String) -> Bool { fm.fileExists(atPath: p.hasPrefix("~/") ? home + p.dropFirst(1) : p) }
        func count(_ dir: String) -> Int { ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.count }
        var out: [DevToolchain] = []
        let brewPrefix = exists("/opt/homebrew/bin/brew") ? "/opt/homebrew" : (exists("/usr/local/bin/brew") ? "/usr/local" : nil)
        if let brewPrefix {
            out.append(DevToolchain(name: "Homebrew", detail: "\(count(brewPrefix + "/Cellar")) programmi, \(count(brewPrefix + "/Caskroom")) app"))
        }
        if exists("/Library/Developer/CommandLineTools") || exists("/Applications/Xcode.app") || Shell.find(["/usr/bin/xcode-select"]) != nil,
           Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 5).ok {
            out.append(DevToolchain(name: "Xcode / strumenti a riga di comando", detail: "installati"))
        }
        let checks: [(String, [String], String)] = [
            ("Node.js", ["~/.nvm", "~/.fnm", "~/.volta", "/opt/homebrew/bin/node", "/usr/local/bin/node"], "node"),
            ("Bun", ["~/.bun"], "bun"),
            ("Deno", ["~/.deno"], "deno"),
            ("Python (uv)", ["~/.local/share/uv", "/opt/homebrew/bin/uv", "~/.local/bin/uv"], "uv"),
            ("Python (pyenv)", ["~/.pyenv"], "pyenv"),
            ("Rust", ["~/.rustup", "~/.cargo/bin/rustc"], "rust"),
            ("Go", ["/opt/homebrew/bin/go", "/usr/local/go", "~/go"], "go"),
            ("Java (SDKMAN)", ["~/.sdkman"], "java"),
            ("Ruby (rbenv)", ["~/.rbenv"], "ruby"),
            ("mise", ["~/.local/share/mise", "/opt/homebrew/bin/mise"], "mise"),
            ("asdf", ["~/.asdf"], "asdf"),
            ("Docker", ["/Applications/Docker.app", "/opt/homebrew/bin/docker"], "docker"),
            ("OrbStack", ["/Applications/OrbStack.app"], "orbstack"),
            ("Kubernetes (kubectl)", ["/opt/homebrew/bin/kubectl", "/usr/local/bin/kubectl"], "kubectl"),
            ("Terraform", ["/opt/homebrew/bin/terraform", "/usr/local/bin/terraform"], "terraform"),
            ("Postgres", ["/opt/homebrew/opt/postgresql@17", "/opt/homebrew/opt/postgresql@16", "/Applications/Postgres.app"], "postgres"),
            ("GitHub CLI", ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"], "gh"),
            ("Azure CLI", ["/opt/homebrew/bin/az"], "az"),
            ("AWS CLI", ["/opt/homebrew/bin/aws", "/usr/local/bin/aws"], "aws"),
            ("Google Cloud CLI", ["/opt/homebrew/bin/gcloud", "~/google-cloud-sdk"], "gcloud"),
        ]
        for (name, places, _) in checks where places.contains(where: exists) {
            out.append(DevToolchain(name: name, detail: "trovato"))
        }
        if count(home + "/.vscode/extensions") > 0 {
            out.append(DevToolchain(name: "Estensioni VS Code", detail: "\(count(home + "/.vscode/extensions")) installate"))
        }
        return out
    }
}
