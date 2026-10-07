import Foundation

/// "Nuovo Mac": what took a whole day by hand on 2026-10-06, as ordered, repeatable steps.
/// Every step only adds: existing files are never overwritten, a half-restored repository is
/// moved aside (never deleted), an existing database is never touched.
enum NewMacRestore {
    enum Step: String, CaseIterable {
        case config, repos, databases, homebrew, launchAgents = "launch-agents"

        var title: String {
            switch self {
            case .config: return "Configurazioni e file"
            case .repos: return "Repository (da GitHub + file locali + commit non pubblicati)"
            case .databases: return "Database"
            case .homebrew: return "Programmi Homebrew"
            case .launchAgents: return "Servizi automatici scelti"
            }
        }
    }

    struct CheckItem: Equatable {
        let title: String
        let ok: Bool
        let hint: String
        /// Apps still missing (only for the apps item), so the window can offer "Non mi servono".
        var missingApps: [String] = []
    }

    struct RepoReport: Equatable {
        var path: String
        var outcome: String
        var lostCommits: [String] = []
    }

    struct Report {
        var lines: [String] = []
        var repos: [RepoReport] = []
        var failures: [String] = []
        mutating func log(_ s: String, _ sink: ((String) -> Void)?) { lines.append(s); sink?(s) }
    }

    static func movedAsideRoot(home: String) -> String { home + "/RustyMacBackup-copie-parziali" }

    // MARK: - Checklist (read-only)

    static func checklist(snapshot: URL, home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                          ignoredApps: [String] = []) -> [CheckItem] {
        let fm = FileManager.default
        var items: [CheckItem] = []

        let sshKeys = ((try? fm.contentsOfDirectory(atPath: home + "/.ssh")) ?? []).filter { $0.hasPrefix("id_") && !$0.hasSuffix(".pub") }
        items.append(CheckItem(title: "Chiave SSH", ok: !sshKeys.isEmpty,
                               hint: sshKeys.isEmpty ? "Nessuna chiave in ~/.ssh: creane una o copiala, poi aggiungila a GitHub." : sshKeys.joined(separator: ", ")))

        let hostsFile = snapshot.appendingPathComponent(".config/gh/hosts.yml").path
        if let hosts = try? String(contentsOfFile: hostsFile, encoding: .utf8) {
            let wanted = hosts.split(separator: "\n").compactMap { line -> String? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasSuffix(":"), !t.hasPrefix("github.com"), !t.contains(" ") else { return nil }
                let name = String(t.dropLast())
                return ["users", "git_protocol", "oauth_token", "user"].contains(name) ? nil : name
            }
            let gh = Shell.find(["/opt/homebrew/bin/gh", "/usr/local/bin/gh"])
            let status = gh.map { Shell.run($0, ["auth", "status"], timeout: 20) }
            let text = (status?.stdout ?? "") + (status?.stderr ?? "")
            for account in Set(wanted).sorted() {
                let ok = text.contains("account \(account)") && !text.contains("Failed to log in to github.com account \(account)")
                items.append(CheckItem(title: "GitHub: \(account)", ok: ok,
                                       hint: ok ? "collegato" : "Esegui: gh auth login (account \(account))"))
            }
        }

        if fm.fileExists(atPath: snapshot.appendingPathComponent(".azure").path) || fm.fileExists(atPath: snapshot.appendingPathComponent(".azureauth").path) {
            let az = Shell.find(["/opt/homebrew/bin/az", "/usr/local/bin/az"])
            let ok = az.map { Shell.run($0, ["account", "get-access-token", "--query", "expiresOn", "-o", "tsv"], timeout: 30).ok } ?? false
            items.append(CheckItem(title: "Azure CLI", ok: ok, hint: ok ? "collegato" : "Esegui: az login"))
        }

        let appsFile = snapshot.appendingPathComponent("_environment/installed-apps.txt").path
        if let apps = try? String(contentsOfFile: appsFile, encoding: .utf8) {
            // Apps are often grouped in folders (/Applications/Dev, /Applications/AI): look one level down too.
            var roots = ["/Applications", home + "/Applications", "/System/Applications"]
            for base in ["/Applications", home + "/Applications"] {
                for sub in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where !sub.hasSuffix(".app") && !sub.hasPrefix(".") {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: base + "/" + sub, isDirectory: &isDir), isDir.boolValue { roots.append(base + "/" + sub) }
                }
            }
            let missing = apps.split(separator: "\n").map(String.init).filter { name in
                !name.isEmpty && !ignoredApps.contains(name) && !roots.contains { fm.fileExists(atPath: "\($0)/\(name).app") }
            }
            items.append(CheckItem(title: "App del vecchio Mac", ok: missing.isEmpty,
                                   hint: missing.isEmpty ? "tutte presenti" : "Mancano: " + missing.joined(separator: ", "),
                                   missingApps: missing))
        }
        return items
    }

    // MARK: - Run

    static func run(snapshot: URL, steps: Set<Step>, launchAgents: Set<String> = [],
                    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                    dryRun: Bool = false, sink: ((String) -> Void)? = nil) -> Report {
        var report = Report()
        let manifest = SnapshotManifest.read(from: snapshot)
        let repos = repositories(in: snapshot, manifest: manifest)
        let repoPaths = Set(repos.map(\.relativePath))

        if steps.contains(.config) {
            report.log("== \(Step.config.title)", sink)
            let tops = ((try? FileManager.default.contentsOfDirectory(atPath: snapshot.path)) ?? [])
                .filter { !SelectiveRestore.internalDirectories.contains($0) && $0 != ".DS_Store" }
            let plan = SelectiveRestore.plan(snapshot: snapshot, paths: tops.sorted(), destinationRoot: home)
            // Repositories are rebuilt by the repos step; only their own folders are left out,
            // loose files and plain folders next to them still come back (review M7).
            func insideRepo(_ rel: String) -> Bool {
                repoPaths.contains { rel == $0 || rel.hasPrefix($0 + "/") }
            }
            let onlyNew = RestorePlan(snapshot: snapshot, destinationRoot: home,
                                      items: plan.items.filter { $0.action == .create && !insideRepo($0.relativePath)
                                          && !isLoginSensitive($0.relativePath) })
            report.log("  \(onlyNew.items.count) file da aggiungere, \(plan.toReplace) già presenti e diversi (lasciati come sono)", sink)
            if !dryRun, !onlyNew.items.isEmpty {
                do {
                    let (r, undo) = try SelectiveRestore.apply(onlyNew, undoRoot: URL(fileURLWithPath: home + "/.rustybackup-pre-restore"))
                    report.log("  aggiunti \(r.restored), falliti \(r.failed)\(undo.map { " · annullabile da \($0.path)" } ?? "")", sink)
                    if r.failed > 0 { report.failures.append("\(r.failed) file di configurazione non ripristinati") }
                } catch {
                    report.failures.append("configurazioni: \(error.localizedDescription)")
                }
            }
        }

        if steps.contains(.repos) {
            report.log("== \(Step.repos.title)", sink)
            for repo in repos {
                let r = restoreRepository(repo, snapshot: snapshot, home: home, dryRun: dryRun)
                report.repos.append(r)
                report.log("  \(r.path): \(r.outcome)", sink)
                for lost in r.lostCommits { report.log("    ⚠ \(lost)", sink) }
            }
        }

        if steps.contains(.databases), let manifest {
            report.log("== \(Step.databases.title)", sink)
            for db in manifest.databases {
                report.log("  " + restoreDatabase(db, snapshot: snapshot, home: home, dryRun: dryRun), sink)
            }
        }

        if steps.contains(.homebrew) {
            report.log("== \(Step.homebrew.title)", sink)
            let brewfile = snapshot.appendingPathComponent("_environment/Brewfile").path
            if !FileManager.default.fileExists(atPath: brewfile) {
                report.log("  nessun Brewfile nello snapshot", sink)
            } else if let brew = Shell.find(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) {
                if dryRun {
                    report.log("  installerei: brew bundle install --file \(brewfile)", sink)
                } else {
                    let r = Shell.run(brew, ["bundle", "install", "--file=\(brewfile)"], timeout: 7200,
                                      environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
                    report.log(r.ok ? "  programmi installati" : "  brew bundle con errori: \(r.stderr.suffix(300))", sink)
                    if !r.ok { report.failures.append("brew bundle") }
                }
            } else {
                report.log("  Homebrew non installato: installalo da https://brew.sh e rilancia", sink)
                report.failures.append("Homebrew mancante")
            }
        }

        if steps.contains(.launchAgents) {
            report.log("== \(Step.launchAgents.title)", sink)
            for agent in availableLaunchAgents(snapshot: snapshot) where launchAgents.contains(agent.label) {
                report.log("  " + installLaunchAgent(agent, home: home, dryRun: dryRun), sink)
            }
        }
        return report
    }

    // MARK: - Repositories

    struct RepoSource: Equatable {
        var relativePath: String
        var remote: String?
        var head: String
        var headSHA: String
        var bundle: String?
        var branches: [String: String]  // name -> sha
    }

    /// From the manifest when the snapshot has one; for older snapshots, from the copied
    /// `.git/config`, `HEAD`, `refs` and `packed-refs` (objects were never copied).
    static func repositories(in snapshot: URL, manifest: SnapshotManifest?) -> [RepoSource] {
        if let manifest, !manifest.git.isEmpty {
            return manifest.git.map {
                RepoSource(relativePath: $0.relativePath, remote: $0.remotes["origin"] ?? $0.remotes.values.first,
                           head: $0.head, headSHA: $0.headSHA, bundle: $0.bundle,
                           branches: Dictionary(uniqueKeysWithValues: $0.branches.map { ($0.name, $0.sha) }))
            }
        }
        var out: [RepoSource] = []
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: snapshot.path) else { return [] }
        while let rel = e.nextObject() as? String {
            let depth = rel.split(separator: "/").count
            if depth > 5 || rel.hasPrefix("Library") || SelectiveRestore.internalDirectories.contains(where: { rel.hasPrefix($0) }) {
                e.skipDescendants(); continue
            }
            guard rel.hasSuffix("/.git") || rel == ".git" else { continue }
            e.skipDescendants()
            let gitDir = snapshot.appendingPathComponent(rel)
            let repoRel = String(rel.dropLast(rel == ".git" ? 4 : 5))
            guard let configText = try? String(contentsOf: gitDir.appendingPathComponent("config"), encoding: .utf8) else { continue }
            var remote: String?
            var inOrigin = false
            for line in configText.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("[") { inOrigin = t == "[remote \"origin\"]" }
                if inOrigin, t.hasPrefix("url") { remote = t.split(separator: "=", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) }
            }
            let headText = (try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let head = headText.hasPrefix("ref: refs/heads/") ? String(headText.dropFirst("ref: refs/heads/".count)) : "(detached)"
            var branches: [String: String] = [:]
            if let packed = try? String(contentsOf: gitDir.appendingPathComponent("packed-refs"), encoding: .utf8) {
                for line in packed.split(separator: "\n") where line.contains(" refs/heads/") {
                    let parts = line.split(separator: " ")
                    branches[String(parts[1].dropFirst("refs/heads/".count))] = String(parts[0])
                }
            }
            if let refs = fm.enumerator(atPath: gitDir.appendingPathComponent("refs/heads").path) {
                while let b = refs.nextObject() as? String {
                    if let sha = try? String(contentsOf: gitDir.appendingPathComponent("refs/heads/" + b), encoding: .utf8) {
                        branches[b] = sha.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            out.append(RepoSource(relativePath: repoRel, remote: remote, head: head,
                                  headSHA: branches[head] ?? (head == "(detached)" ? headText : ""),
                                  bundle: nil, branches: branches))
        }
        return out
    }

    static func sshVariant(_ url: String) -> String? {
        guard url.hasPrefix("https://github.com/") else { return nil }
        var path = String(url.dropFirst("https://github.com/".count))
        if !path.hasSuffix(".git") { path += ".git" }
        return "git@github.com:" + path
    }

    static func restoreRepository(_ repo: RepoSource, snapshot: URL, home: String, dryRun: Bool) -> RepoReport {
        let fm = FileManager.default
        var report = RepoReport(path: repo.relativePath, outcome: "")
        let dest = home + "/" + repo.relativePath
        if fm.fileExists(atPath: dest + "/.git/objects") {
            report.outcome = "già presente con la sua cronologia: non toccato"
            return report
        }
        guard let remote = repo.remote else {
            report.outcome = "nessun remote: lo ripristina il passo Configurazioni come cartella"
            return report
        }
        guard let git = Shell.git else { report.outcome = "git non trovato"; return report }
        if dryRun {
            report.outcome = "clonerei \(remote), branch \(repo.head)\(repo.bundle != nil ? " + commit non pubblicati" : "")"
            return report
        }
        if fm.fileExists(atPath: dest) {
            let aside = movedAsideRoot(home: home) + "/" + repo.relativePath
            do {
                try fm.createDirectory(atPath: (aside as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: dest, toPath: aside)
            } catch {
                report.outcome = "c'è già una cartella senza cronologia e non riesco a spostarla: \(error.localizedDescription)"
                return report
            }
        }
        try? fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var clone = Shell.run(git, ["clone", "-q", remote, dest], timeout: 3600)
        if !clone.ok, let ssh = sshVariant(remote) {
            try? fm.removeItem(atPath: dest)
            clone = Shell.run(git, ["clone", "-q", ssh, dest], timeout: 3600)
            if clone.ok { _ = Shell.run(git, ["-C", dest, "remote", "set-url", "origin", ssh]) }
        }
        guard clone.ok else {
            report.outcome = "clone non riuscito (\(clone.stderr.prefix(160))). Controlla il login GitHub."
            return report
        }
        if let bundle = repo.bundle {
            let b = snapshot.appendingPathComponent(SnapshotManifest.directoryName)
                .appendingPathComponent(GitSafety.directoryName).appendingPathComponent(bundle)
            let applied = GitSafety.apply(bundle: b, to: URL(fileURLWithPath: dest))
            if !applied.ok { report.lostCommits.append("commit non pubblicati non reinseriti: \(applied.stderr.prefix(160))") }
        }
        for (branch, sha) in repo.branches.sorted(by: { $0.key < $1.key }) {
            if !Shell.run(git, ["-C", dest, "cat-file", "-e", sha + "^{commit}"]).ok {
                report.lostCommits.append("branch \(branch) (\(sha.prefix(8))): commit non presenti su GitHub né nel backup")
            }
        }
        // Same branch and commit as on the old Mac, then the old working files on top: git
        // status then shows exactly what was not committed.
        var where_ = "branch di default"
        if repo.head != "(detached)", !repo.headSHA.isEmpty,
           Shell.run(git, ["-C", dest, "cat-file", "-e", repo.headSHA + "^{commit}"]).ok {
            _ = Shell.run(git, ["-C", dest, "checkout", "-q", "-B", repo.head, repo.headSHA])
            _ = Shell.run(git, ["-C", dest, "branch", "-q", "--set-upstream-to=origin/\(repo.head)"])
            where_ = "\(repo.head) @ \(repo.headSHA.prefix(8))"
        }
        let src = snapshot.appendingPathComponent(repo.relativePath)
        _ = copyTree(from: src, to: URL(fileURLWithPath: dest), skipping: [".git"])
        let status = Shell.run(git, ["-C", dest, "status", "--porcelain"]).stdout.split(separator: "\n")
        let changed = status.filter { !$0.hasPrefix("??") }.count
        let untracked = status.filter { $0.hasPrefix("??") }.count
        report.outcome = "ripristinato su \(where_) · \(changed) file modificati, \(untracked) non tracciati"
        return report
    }

    /// Copy a tree file by file, replacing what is there (used inside a fresh clone only).
    @discardableResult
    static func copyTree(from src: URL, to dst: URL, skipping: Set<String>) -> Int {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: src.path) else { return 0 }
        var n = 0
        while let rel = e.nextObject() as? String {
            if skipping.contains(rel.split(separator: "/").first.map(String.init) ?? "") { e.skipDescendants(); continue }
            let s = src.appendingPathComponent(rel), d = dst.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: s.path, isDirectory: &isDir)
            if isDir.boolValue { try? fm.createDirectory(at: d, withIntermediateDirectories: true); continue }
            try? fm.removeItem(at: d)
            if (try? HardLinker.copyFile(from: s.path, to: d.path)) != nil { n += 1 }
        }
        return n
    }

    // MARK: - Databases

    static func restoreDatabase(_ db: DatabaseRecord, snapshot: URL, home: String, dryRun: Bool) -> String {
        guard let file = db.file else { return "\(db.source): non era stato salvato (\(db.error ?? "assente"))" }
        let dump = snapshot.appendingPathComponent(file)
        switch db.kind {
        case "sqlite":
            let target = ConfigDiscovery.expand(db.source)
            if FileManager.default.fileExists(atPath: target) { return "\(db.source): esiste già, non toccato" }
            if dryRun { return "\(db.source): lo rimetterei al suo posto" }
            do {
                try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try HardLinker.copyFile(from: dump.path, to: target)
                return "\(db.source): ripristinato"
            } catch { return "\(db.source): non ripristinato (\(error.localizedDescription))" }
        case "postgres":
            guard let pgDump = DatabaseDumps.pgDump else { return "\(db.source): Postgres non installato" }
            let bin = (pgDump as NSString).deletingLastPathComponent
            let list = Shell.run(bin + "/psql", ["-X", "-At", "-d", "postgres", "-c",
                                                 "select 1 from pg_database where datname = '\(db.source.replacingOccurrences(of: "'", with: "''"))'"])
            guard list.ok else { return "\(db.source): Postgres non risponde (avvialo e rilancia)" }
            if list.stdout.contains("1") { return "\(db.source): esiste già, non toccato" }
            if dryRun { return "\(db.source): lo ricreerei dal dump" }
            let r = Shell.run(bin + "/pg_restore", ["--create", "--no-owner", "-d", "postgres", dump.path], timeout: 3600)
            return r.ok ? "\(db.source): ricreato dal dump" : "\(db.source): ricreato con avvisi (\(r.stderr.prefix(160)))"
        default:
            return "\(db.source): tipo sconosciuto"
        }
    }

    // MARK: - LaunchAgents

    struct LaunchAgentInfo: Equatable {
        let label: String
        let plist: URL
        let program: String?
        var programExists: Bool { program.map { FileManager.default.fileExists(atPath: ConfigDiscovery.expand($0)) } ?? false }
    }

    static func availableLaunchAgents(snapshot: URL) -> [LaunchAgentInfo] {
        let dir = snapshot.appendingPathComponent("Library/LaunchAgents")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".plist") }
        return files.sorted().compactMap { name in
            let url = dir.appendingPathComponent(name)
            guard let dict = NSDictionary(contentsOf: url) as? [String: Any],
                  let label = dict["Label"] as? String else { return nil }
            let args = dict["ProgramArguments"] as? [String] ?? []
            let program = (dict["Program"] as? String)
                ?? args.first(where: { $0.hasPrefix("/") && !$0.hasPrefix("/bin/") && !$0.hasPrefix("/usr/") })
                ?? args.first
            return LaunchAgentInfo(label: label, plist: url, program: program)
        }
    }

    static func installLaunchAgent(_ agent: LaunchAgentInfo, home: String, dryRun: Bool) -> String {
        let target = home + "/Library/LaunchAgents/" + agent.plist.lastPathComponent
        if FileManager.default.fileExists(atPath: target) { return "\(agent.label): già installato" }
        guard agent.programExists else { return "\(agent.label): saltato, manca \(agent.program ?? "il programma")" }
        if dryRun { return "\(agent.label): lo installerei" }
        do {
            try FileManager.default.createDirectory(atPath: home + "/Library/LaunchAgents", withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: agent.plist.path, toPath: target)
        } catch { return "\(agent.label): non copiato (\(error.localizedDescription))" }
        let domain = "gui/\(getuid())"
        _ = Shell.run("/bin/launchctl", ["enable", "\(domain)/\(agent.label)"])
        let r = Shell.run("/bin/launchctl", ["bootstrap", domain, target])
        return r.ok ? "\(agent.label): attivo" : "\(agent.label): copiato, non avviato (\(r.stderr.prefix(120)))"
    }
}
