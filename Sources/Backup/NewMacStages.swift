import Foundation

/// "Nuovo Mac" a tappe (3.3): the restore of a whole Mac split into small phases that run one
/// at a time, each with its own undo, in an order where the things that run by themselves at
/// login come last. Scar 2026-10-06: restoring everything in one go also put back every
/// LaunchAgent and the shell start-up files at once; after the reboot the Mac did not come
/// back to a usable login, and nothing said which of the hundreds of files was the cause.
///
/// Rules:
/// - file phases only ADD files (existing ones are left as they are), like the 3.0 step;
/// - nothing that starts at login (LaunchAgents, login items, another Mac's system and
///   per-host preferences) is ever copied by a file phase; services come back one by one;
/// - after the shell phase a fresh login shell must start and finish within 20 s, otherwise
///   the phase undoes itself;
/// - after a service starts it is watched for a few seconds: if it exits with an error it is
///   stopped and its file moved aside, never deleted.
extension NewMacRestore {
    struct Stage: Identifiable, Equatable {
        enum Kind: Equatable { case prerequisites, packages, files, repos, databases, homebrew, services }
        let id: String
        let title: String
        let detail: String
        let kind: Kind
        /// Snapshot-relative files (only for `.files`).
        var paths: [String] = []
        /// Runs at login or changes how the Mac starts: suggest a restart before the next phase.
        var restartAfter = false
    }

    /// Paths that make the Mac do something at login, or that belong to another Mac.
    static let loginSensitivePrefixes: [String] = [
        "Library/LaunchAgents/", "Library/LaunchDaemons/",
        "Library/Application Support/com.apple.backgroundtaskmanagementagent/",
        "Library/Preferences/ByHost/",
        "Library/Preferences/com.apple.",
        "Library/Preferences/loginwindow",
        "Library/StartupItems/",
    ]

    static func isLoginSensitive(_ rel: String) -> Bool {
        loginSensitivePrefixes.contains { rel.hasPrefix($0) }
    }

    static let shellTopic = "Terminale e shell"
    static let servicesTopic = "Servizi automatici"

    // MARK: - Phases

    /// The phases for this snapshot, in the recommended order.
    static func stages(snapshot: URL, config: Config?) -> [Stage] {
        let fm = FileManager.default
        let manifest = SnapshotManifest.read(from: snapshot)
        let repoPaths = repositories(in: snapshot, manifest: manifest).map(\.relativePath)
        func insideRepo(_ rel: String) -> Bool { repoPaths.contains { rel == $0 || rel.hasPrefix($0 + "/") } }

        let tops = ((try? fm.contentsOfDirectory(atPath: snapshot.path)) ?? [])
            .filter { !SelectiveRestore.internalDirectories.contains($0) && $0 != ".DS_Store" }
            .sorted()
        var all: [String] = []
        for top in tops { all.append(contentsOf: SelectiveRestore.filesBelow(top, in: snapshot)) }
        let usable = all.filter { !insideRepo($0) && !isLoginSensitive($0) }
        var claimed = Set<String>()
        var out: [Stage] = []

        // 0. A new Mac needs Apple's developer tools (git) and Homebrew before anything else,
        //    then the programs of the old Mac, each with its own checkbox.
        out.append(Stage(id: "base", title: "Strumenti di base",
                         detail: "Strumenti per sviluppatori di Apple (git) e Homebrew.", kind: .prerequisites))
        let packages = ToolInventory.packages(snapshot: snapshot)
        if !packages.isEmpty {
            out.append(Stage(id: "programmi", title: "Programmi",
                             detail: "\(packages.count) programmi del vecchio Mac: scegli quali reinstallare.", kind: .packages))
        }

        // 1. Plain folders: documents, vaults, project data. Nothing here runs by itself.
        let data = usable.filter { rel in
            let top = rel.split(separator: "/").first.map(String.init) ?? rel
            return !top.hasPrefix(".") && top != "Library" && rel.contains("/")
        }
        claimed.formUnion(data)
        out.append(Stage(id: "dati", title: "Cartelle e documenti",
                         detail: "Le tue cartelle di lavoro. Non parte niente da solo.", kind: .files, paths: data))
        out.append(Stage(id: "repo", title: "Repository",
                         detail: "Da GitHub, con i file locali e i commit non pubblicati.", kind: .repos))
        if !(manifest?.databases ?? []).isEmpty {
            out.append(Stage(id: "database", title: "Database",
                             detail: "Solo quelli che non esistono già.", kind: .databases))
        }

        // 2. One phase per tool, so a broken tool points at itself.
        let topics = Topics.all(config: config)
        for topic in topics where topic.name != shellTopic && topic.name != servicesTopic {
            let files = Topics.files(of: topic, in: snapshot)
                .filter { !claimed.contains($0) && !insideRepo($0) && !isLoginSensitive($0) }
            guard !files.isEmpty else { continue }
            claimed.formUnion(files)
            out.append(Stage(id: "tema:" + topic.name, title: topic.name,
                             detail: "Configurazione di \(topic.name).", kind: .files, paths: files))
        }

        // 3. Everything else that is not login-sensitive.
        let shellFiles = topicFiles(shellTopic, topics, snapshot)
        let rest = usable.filter { !claimed.contains($0) && !shellFiles.contains($0) }
        claimed.formUnion(rest)
        if !rest.isEmpty {
            out.append(Stage(id: "altre", title: "Altre configurazioni",
                             detail: "File di strumenti senza un argomento proprio.", kind: .files, paths: rest))
        }

        // 4. The shell runs at every terminal start: checked after restoring, undone if it breaks.
        let shell = shellFiles.filter { !insideRepo($0) && !isLoginSensitive($0) }.sorted()
        if !shell.isEmpty {
            out.append(Stage(id: "shell", title: shellTopic,
                             detail: "Controllata dopo il ripristino: se la shell non parte, la fase si annulla da sola.",
                             kind: .files, paths: shell, restartAfter: true))
        }
        // 5. Last: what starts at login, one service at a time.
        out.append(Stage(id: "servizi", title: servicesTopic,
                         detail: "Uno alla volta. Ognuno viene osservato: se esce con un errore lo fermo e lo metto da parte.",
                         kind: .services, restartAfter: true))
        return out
    }

    private static func topicFiles(_ name: String, _ topics: [RestoreTopic], _ snapshot: URL) -> Set<String> {
        guard let topic = topics.first(where: { $0.name == name }) else { return [] }
        return Set(Topics.files(of: topic, in: snapshot))
    }

    // MARK: - Progress (which phases are done, and how to undo them)

    struct ProgressEntry: Codable, Equatable {
        var stageID: String
        var title: String
        var date: Date
        var outcome: String
        var ok: Bool
        var undoDir: String?
        var undone = false
    }

    static func progressURL(home: String) -> URL {
        URL(fileURLWithPath: home + "/.rustybackup-pre-restore/nuovo-mac.json")
    }

    static func progress(home: String) -> [ProgressEntry] {
        guard let data = try? Data(contentsOf: progressURL(home: home)) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ProgressEntry].self, from: data)) ?? []
    }

    static func record(_ entry: ProgressEntry, home: String) {
        var list = progress(home: home)
        list.append(entry)
        save(list, home: home)
    }

    private static func save(_ list: [ProgressEntry], home: String) {
        let url = progressURL(home: home)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(list) { try? data.write(to: url, options: .atomic) }
    }

    /// The latest still-valid record for a phase (or a service: "servizio:<label>").
    static func lastDone(_ id: String, home: String) -> ProgressEntry? {
        progress(home: home).last { $0.stageID == id && $0.ok && !$0.undone }
    }

    // MARK: - Run one phase

    struct StageOutcome {
        var lines: [String] = []
        var ok = true
        var undoDir: URL?
    }

    /// Applies one phase. `dryRun` only counts. `shellCheck` is injectable for tests.
    static func runStage(_ stage: Stage, snapshot: URL, home: String, dryRun: Bool,
                         services: Set<String> = [], packages: Set<String> = [],
                         shellCheck: (String) -> String? = NewMacRestore.shellProblem,
                         serviceSettle: TimeInterval = 8,
                         sink: ((String) -> Void)? = nil) -> StageOutcome {
        var out = StageOutcome()
        func log(_ s: String) { out.lines.append(s); sink?(s) }
        log("== \(stage.title)")
        switch stage.kind {
        case .prerequisites:
            for p in ToolInventory.prerequisites() { log("  \(p.ok ? "✓" : "✗") \(p.title): \(p.hint)") }
            if ToolInventory.prerequisites().contains(where: { !$0.ok }) { out.ok = false }
        case .packages:
            let all = ToolInventory.packages(snapshot: snapshot)
            let chosen = all.filter { packages.contains($0.id) }
            if chosen.isEmpty {
                log("  \(all.count) programmi disponibili: scegli quali reinstallare")
                break
            }
            if dryRun {
                for p in chosen { log("  installerei: \(p.name) (\(p.kind.title))") }
                break
            }
            let r = ToolInventory.install(chosen) { log($0) }
            log("  installati \(r.ok), non riusciti \(r.failed)")
            if r.failed > 0 { out.ok = false }
        case .files:
            let plan = SelectiveRestore.plan(snapshot: snapshot, paths: stage.paths, destinationRoot: home)
            let onlyNew = RestorePlan(snapshot: snapshot, destinationRoot: home,
                                      items: plan.items.filter { $0.action == .create })
            log("  \(onlyNew.items.count) file da aggiungere, \(plan.toReplace) già presenti e diversi (lasciati come sono)")
            guard !dryRun, !onlyNew.items.isEmpty else { break }
            do {
                let (r, undo) = try SelectiveRestore.apply(onlyNew, undoRoot: URL(fileURLWithPath: home + "/.rustybackup-pre-restore"))
                out.undoDir = undo
                log("  aggiunti \(r.restored), falliti \(r.failed)")
                if r.failed > 0 { out.ok = false }
            } catch {
                log("  errore: \(error.localizedDescription)"); out.ok = false; break
            }
            if stage.id == "shell", let problem = shellCheck(home) {
                log("  ⚠ la shell non parte più: \(problem)")
                if let undo = out.undoDir, let u = try? SelectiveRestore.undoDetailed(undo) {
                    log("  fase annullata da sola: \(u.restored) file rimessi com'erano")
                }
                out.ok = false
                out.undoDir = nil
            } else if stage.id == "shell" {
                log("  shell controllata: parte e si chiude normalmente")
            }
        case .repos:
            let manifest = SnapshotManifest.read(from: snapshot)
            for repo in repositories(in: snapshot, manifest: manifest) {
                let r = restoreRepository(repo, snapshot: snapshot, home: home, dryRun: dryRun)
                log("  \(r.path): \(r.outcome)")
                for lost in r.lostCommits { log("    ⚠ \(lost)"); out.ok = false }
            }
        case .databases:
            for db in SnapshotManifest.read(from: snapshot)?.databases ?? [] {
                log("  " + restoreDatabase(db, snapshot: snapshot, home: home, dryRun: dryRun))
            }
        case .homebrew:
            let r = run(snapshot: snapshot, steps: [.homebrew], home: home, dryRun: dryRun)
            r.lines.dropFirst().forEach { log($0) }
            if !r.failures.isEmpty { out.ok = false }
        case .services:
            let agents = availableLaunchAgents(snapshot: snapshot)
            if services.isEmpty {
                for a in agents { log("  \(a.programExists ? "pronto" : "manca il programma"): \(a.label)") }
                log("  scegli i servizi uno alla volta")
            }
            for agent in agents where services.contains(agent.label) {
                let line = installAndWatch(agent, home: home, dryRun: dryRun, settle: serviceSettle)
                log("  " + line.text)
                if !line.ok { out.ok = false }
                if !dryRun, line.installed {
                    record(ProgressEntry(stageID: "servizio:" + agent.label, title: agent.label, date: Date(),
                                         outcome: line.text, ok: true, undoDir: nil), home: home)
                }
            }
        }
        if !dryRun && stage.kind != .services && stage.kind != .prerequisites
            && !(stage.kind == .packages && packages.isEmpty) {
            record(ProgressEntry(stageID: stage.id, title: stage.title, date: Date(),
                                 outcome: out.lines.dropFirst().joined(separator: " · "), ok: out.ok,
                                 undoDir: out.undoDir?.path), home: home)
        }
        return out
    }

    /// Undo a phase (files) or a service. Repositories, databases and Homebrew only ever add
    /// things, so they have nothing to undo.
    static func undoStage(_ id: String, home: String) -> String {
        var list = progress(home: home)
        guard let index = list.lastIndex(where: { $0.stageID == id && $0.ok && !$0.undone }) else {
            return "Niente da annullare per questa fase"
        }
        let entry = list[index]
        var text: String
        if id.hasPrefix("servizio:") {
            text = removeService(label: String(id.dropFirst("servizio:".count)), home: home)
        } else if let dir = entry.undoDir {
            guard let u = try? SelectiveRestore.undoDetailed(URL(fileURLWithPath: dir)) else {
                return "Annullamento non riuscito: \(dir)"
            }
            text = "\(u.restored) file rimessi com'erano"
            if !u.keptBecauseChanged.isEmpty { text += ", \(u.keptBecauseChanged.count) lasciati perché modificati dopo" }
        } else {
            return "Questa fase aggiunge soltanto: non c'è niente da annullare"
        }
        list[index].undone = true
        save(list, home: home)
        return text
    }

    // MARK: - Checks

    /// nil when a fresh interactive login shell starts and finishes within 20 s.
    static func shellProblem(home: String) -> String? {
        let marker = "RMB_SHELL_OK"
        let r = Shell.run("/bin/zsh", ["-i", "-l", "-c", "print -r -- \(marker)"], timeout: 20,
                          environment: ["HOME": home, "ZDOTDIR": home, "TERM": "dumb"])
        if r.status == -2 { return "si blocca all'avvio (oltre 20 secondi)" }
        if !r.stdout.contains(marker) {
            let why = r.stderr.split(separator: "\n").last.map(String.init) ?? "codice \(r.status)"
            return "si chiude prima di partire (\(why))"
        }
        return nil
    }

    struct ServiceLine { var text: String; var ok: Bool; var installed: Bool }

    /// Installs one LaunchAgent, waits `settle` seconds and checks it did not fail.
    static func installAndWatch(_ agent: LaunchAgentInfo, home: String, dryRun: Bool,
                                settle: TimeInterval) -> ServiceLine {
        let text = installLaunchAgent(agent, home: home, dryRun: dryRun)
        guard !dryRun, text.hasSuffix(": attivo") else {
            return ServiceLine(text: text, ok: !text.contains("non "), installed: false)
        }
        Thread.sleep(forTimeInterval: settle)
        let printed = Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(agent.label)"], timeout: 15)
        if let problem = serviceProblem(launchctlPrint: printed.stdout) {
            let removed = removeService(label: agent.label, home: home)
            return ServiceLine(text: "\(agent.label): \(problem) → fermato. \(removed)", ok: false, installed: false)
        }
        return ServiceLine(text: "\(agent.label): attivo e in salute", ok: true, installed: true)
    }

    /// Reads `launchctl print`: a non-zero last exit code or a crash signal is a problem.
    static func serviceProblem(launchctlPrint text: String) -> String? {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("last exit code = ") {
                let value = line.dropFirst("last exit code = ".count)
                if value.hasPrefix("0") || value.hasPrefix("(never exited)") { continue }
                return "esce con errore (\(value))"
            }
            if line.hasPrefix("last terminating signal = ") {
                return "si è chiuso da solo (\(line.dropFirst("last terminating signal = ".count)))"
            }
        }
        return nil
    }

    /// Stops a service and moves its file aside (never deletes it).
    static func removeService(label: String, home: String) -> String {
        let fm = FileManager.default
        let dir = home + "/Library/LaunchAgents"
        let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { name in
            name.hasSuffix(".plist") && (NSDictionary(contentsOfFile: dir + "/" + name)?["Label"] as? String) == label
        }
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 20)
        guard let name = names.first else { return "Servizio fermato." }
        let aside = movedAsideRoot(home: home) + "/LaunchAgents"
        try? fm.createDirectory(atPath: aside, withIntermediateDirectories: true)
        let target = aside + "/" + name
        try? fm.removeItem(atPath: target)
        do {
            try fm.moveItem(atPath: dir + "/" + name, toPath: target)
            return "File messo da parte in \(target.replacingOccurrences(of: home, with: "~"))."
        } catch {
            return "File non spostato: \(error.localizedDescription)"
        }
    }
}
