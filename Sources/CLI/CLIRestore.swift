import Foundation

/// 3.0 commands: snapshot states, coverage, per-file and per-topic restore, new Mac.
/// Every command that writes shows a preview unless `--yes` is given.
extension CLIHandler {
    struct Flags {
        var positional: [String] = []
        var values: [String: String] = [:]
        var switches: Set<String> = []

        init(_ args: [String], valued: Set<String>) {
            var i = 0
            while i < args.count {
                let a = args[i]
                if valued.contains(a), i + 1 < args.count { values[a] = args[i + 1]; i += 2; continue }
                if a.hasPrefix("--") { switches.insert(a) } else { positional.append(a) }
                i += 1
            }
        }
    }

    static func destination(_ configPath: String?) throws -> (Config, URL) {
        let cfg = try loadConfig(configPath: configPath)
        let dest = URL(fileURLWithPath: cfg.destination.path)
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw err("Disco di backup non collegato: \(cfg.destination.path)")
        }
        return (cfg, dest)
    }

    /// `--snapshot NAME` or the default restore snapshot (newest complete).
    static func pickSnapshot(_ flags: Flags, at dest: URL) throws -> SnapshotInfo {
        let all = SnapshotCatalog.list(at: dest)
        if let name = flags.values["--snapshot"] {
            guard let s = all.first(where: { $0.name == name }) else { throw err("Snapshot non trovato: \(name)") }
            if s.state == .incomplete {
                print(yellow("Attenzione: \(name) è INCOMPLETO. Lo uso perché l'hai chiesto tu."))
            }
            return s
        }
        guard let s = SnapshotCatalog.defaultForRestore(at: dest) else {
            throw err("Nessuno snapshot completo o verificabile. Indica --snapshot NOME (vedi: snapshots).")
        }
        return s
    }

    static func runSnapshots(configPath: String?) throws {
        let (_, dest) = try destination(configPath)
        let all = SnapshotCatalog.list(at: dest)
        if all.isEmpty { print("Nessuno snapshot."); return }
        print(bold("Snapshot (più recente in alto)"))
        for s in all {
            let label: String
            switch s.state {
            case .complete: label = green("completo      ")
            case .incomplete: label = red("INCOMPLETO    ")
            case .unverified: label = yellow("non verificato")
            }
            var extra = ""
            if let m = s.manifest {
                extra = "\(m.filesProcessed) file"
                let unpushed = m.git.filter { $0.bundle != nil }.count
                if unpushed > 0 { extra += " · \(unpushed) repo con commit non pubblicati salvati" }
                if !m.databases.isEmpty { extra += " · \(m.databases.filter { $0.file != nil }.count) database" }
            }
            print("  \(s.name)  \(label)  \(extra)")
            if let m = s.manifest, !m.complete {
                for r in m.incompleteReasons { print("      - \(r)") }
            }
        }
        if let best = SnapshotCatalog.defaultForRestore(at: dest) {
            print("\nRipristino predefinito: \(bold(best.name)) (\(best.state.label))")
        }
    }

    static func runCoverage(subArgs: [String], configPath: String?) throws {
        let cfg = try loadConfig(configPath: configPath)
        let flags = Flags(subArgs, valued: ["--days"])
        let days = Int(flags.values["--days"] ?? "30") ?? 30
        let gaps = CoverageAuditor.audit(config: cfg, days: days)
        try? StatusWriter().writeCoverage(CoverageReport(checkedAt: ISO8601DateFormatter().string(from: Date()), gaps: gaps))
        if gaps.isEmpty { print(green("Copertura ok: niente di attivo resta fuori dal backup.")); return }
        print(bold("Attivo negli ultimi \(days) giorni ma NON salvato:"))
        for g in gaps {
            print("  \(g.kind == .database ? "database" : "cartella")  \(g.path)  (\(BackupEngine.formatBytes(UInt64(max(0, g.approximateBytes)))))")
        }
        print("\nPer salvarla: aggiungi il percorso in [source] paths (cartelle) o [databases] sqlite (database).")
        print("Per non vederla più: aggiungila a [coverage] ignore.")
    }

    static func runVersions(subArgs: [String], configPath: String?) throws {
        guard let path = subArgs.first else { throw err("Uso: versions <file>") }
        let (_, dest) = try destination(configPath)
        let rel = Topics.normalize(expandPath(path))
        let versions = FileVersions.list(relativePath: rel, at: dest)
        if versions.isEmpty { print("Nessuna versione di ~/\(rel) negli snapshot."); return }
        let df = DateFormatter(); df.dateFormat = "dd/MM/yyyy HH:mm"
        print(bold("Versioni di ~/\(rel)"))
        for v in versions {
            print("  \(v.snapshot)  \(v.state.label.padding(toLength: 14, withPad: " ", startingAt: 0))  modificato \(df.string(from: v.modified))  \(BackupEngine.formatBytes(v.size))")
        }
        print("\nPer rimetterne una: restore-file ~/\(rel) --snapshot <nome> [--to <cartella>] --yes")
    }

    static func runFind(subArgs: [String], configPath: String?) throws {
        let flags = Flags(subArgs, valued: ["--snapshot"])
        guard let query = flags.positional.first else { throw err("Uso: find <testo> [--snapshot S]") }
        let (_, dest) = try destination(configPath)
        let snap = try pickSnapshot(flags, at: dest)
        let hits = FileVersions.search(query, in: snap.url)
        print(bold("In \(snap.name) (\(snap.state.label)): \(hits.count) file"))
        for h in hits { print("  ~/\(h)") }
    }

    static func runTopics(configPath: String?) throws {
        let cfg = try? loadConfig(configPath: configPath)
        print(bold("Argomenti ripristinabili"))
        for t in Topics.all(config: cfg) {
            print("  \(bold(t.name))")
            print("      " + t.paths.map { "~/\($0)" }.joined(separator: " · "))
        }
        print("\nNuovi argomenti: sezione [topics] in config.toml, es.  \"Mio progetto\" = [\"~/GitHub/mio\"]")
    }

    static func printPlan(_ plan: RestorePlan) {
        print("  \(plan.summary) · \(BackupEngine.formatBytes(plan.bytes)) da scrivere")
        for item in plan.items where item.action == .create || item.action == .replace {
            print("    \(item.action == .create ? "+" : "~") ~/\(item.relativePath)")
        }
    }

    static func runRestoreTopic(subArgs: [String], configPath: String?) throws {
        let flags = Flags(subArgs, valued: ["--snapshot"])
        guard let name = flags.positional.first else { throw err("Uso: restore-topic <nome> [--snapshot S] [--yes]  (vedi: topics)") }
        let (cfg, dest) = try destination(configPath)
        guard let topic = Topics.all(config: cfg).first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw err("Argomento sconosciuto: \(name) (vedi: topics)")
        }
        let snap = try pickSnapshot(flags, at: dest)
        let files = Topics.files(of: topic, in: snap.url)
        let plan = SelectiveRestore.plan(snapshot: snap.url, paths: files)
        print(bold("\(topic.name) da \(snap.name) (\(snap.state.label))"))
        try applyOrPreview(plan, yes: flags.switches.contains("--yes"))
    }

    static func runRestoreFile(subArgs: [String], configPath: String?) throws {
        let flags = Flags(subArgs, valued: ["--snapshot", "--to"])
        guard let path = flags.positional.first else { throw err("Uso: restore-file <file|cartella> [--snapshot S] [--to <cartella>] [--yes]") }
        let (_, dest) = try destination(configPath)
        let snap = try pickSnapshot(flags, at: dest)
        let rel = Topics.normalize(expandPath(path))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var root = home
        if let to = flags.values["--to"] {
            // Normalise first: "~/../../etc" must not pass the home check (review M5).
            let expanded = URL(fileURLWithPath: expandPath(to)).standardizedFileURL.path
            guard expanded == home || expanded.hasPrefix(home + "/") else { throw err("La destinazione deve stare nella tua home") }
            root = expanded
        }
        let plan = SelectiveRestore.plan(snapshot: snap.url, paths: [rel], destinationRoot: root)
        if plan.items.isEmpty { throw err("~/\(rel) non è in \(snap.name). Vedi: versions \(path)") }
        print(bold("~/\(rel) da \(snap.name) (\(snap.state.label)) → \(ConfigDiscovery.contract(root))"))
        try applyOrPreview(plan, yes: flags.switches.contains("--yes"))
    }

    static func applyOrPreview(_ plan: RestorePlan, yes: Bool) throws {
        printPlan(plan)
        guard yes else { print(yellow("\nAnteprima: niente è stato scritto. Aggiungi --yes per ripristinare.")); return }
        let operationLock = try DestinationLock(at: plan.snapshot.deletingLastPathComponent())
        defer { withExtendedLifetime(operationLock) {} }
        let (r, undo) = try SelectiveRestore.apply(plan)
        print(green("\nRipristinati \(r.restored) file (\(r.overwritten) sostituiti), falliti \(r.failed)."))
        if let undo { print("Per annullare: undo \(undo.path)   (o un solo file: --file <percorso>)") }
    }

    static func runUndo(subArgs: [String]) throws {
        let flags = Flags(subArgs, valued: ["--file"])
        let dir: URL
        if let p = flags.positional.first { dir = URL(fileURLWithPath: expandPath(p)) }
        else {
            let base = RestoreEngine.preRestoreBaseURL
            let entries = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
                .filter { FileManager.default.fileExists(atPath: base.appendingPathComponent($0).appendingPathComponent("undo.json").path) }
                .sorted()
            guard let last = entries.last else { throw err("Nessun ripristino da annullare") }
            dir = base.appendingPathComponent(last)
        }
        let only = flags.values["--file"].map { Set([Topics.normalize(expandPath($0))]) }
        let r = try SelectiveRestore.undoDetailed(dir, only: only)
        print(green("Annullato: \(r.restored) file rimessi com'erano, \(r.failed) non riusciti."))
        if !r.keptBecauseChanged.isEmpty {
            print(yellow("Lasciati come sono perché li hai modificati dopo il ripristino:"))
            for f in r.keptBecauseChanged { print("  ~/\(f)") }
        }
    }

    static func runNewMac(subArgs: [String], configPath: String?) throws {
        let flags = Flags(subArgs, valued: ["--snapshot", "--steps", "--agents", "--stage", "--undo"])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let id = flags.values["--undo"] {
            print(NewMacRestore.undoStage(id, home: home))
            return
        }
        let (config, dest) = try destination(configPath)
        let snap = try pickSnapshot(flags, at: dest)
        let yes = flags.switches.contains("--yes")
        print(bold("Nuovo Mac da \(snap.name) (\(snap.state.label))\n"))

        // Legacy 3.0 form: whole steps at once (login items are still never copied).
        if let s = flags.values["--steps"] {
            let steps = Set(try s.split(separator: ",").map { raw -> NewMacRestore.Step in
                guard let step = NewMacRestore.Step(rawValue: String(raw)) else { throw err("Passo sconosciuto: \(raw)") }
                return step
            })
            let agents = Set((flags.values["--agents"] ?? "").split(separator: ",").map(String.init))
            let report = NewMacRestore.run(snapshot: snap.url, steps: steps, launchAgents: agents, dryRun: !yes) { print($0) }
            if !yes { print(yellow("\nAnteprima: niente è stato scritto. Aggiungi --yes per eseguire.")) }
            for f in report.failures { print(red("  - \(f)")) }
            return
        }

        let stages = NewMacRestore.stages(snapshot: snap.url, config: config)
        guard let wanted = flags.values["--stage"] else {
            print(bold("Controlli"))
            for item in NewMacRestore.checklist(snapshot: snap.url) {
                print("  \(item.ok ? green("✓") : yellow("!")) \(item.title): \(item.hint)")
            }
            print(bold("\nFasi, nell'ordine consigliato") + " (una alla volta: new-mac --stage <id> [--yes])")
            for stage in stages {
                let done = NewMacRestore.lastDone(stage.id, home: home)
                let mark = done != nil ? green("✓") : "·"
                print("  \(mark) \(stage.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(stage.title)" + (stage.restartAfter ? yellow("  (poi riavvia)") : ""))
            }
            print("\nServizi automatici: nessuno viene acceso da solo. Uno alla volta: --stage servizi --agents <label> --yes")
            print("Annullare una fase: new-mac --undo <id>   ·   spegnere un servizio: new-mac --undo servizio:<label>")
            return
        }
        let agents = Set((flags.values["--agents"] ?? "").split(separator: ",").map(String.init))
        for id in wanted.split(separator: ",").map(String.init) {
            guard let stage = stages.first(where: { $0.id == id }) else { throw err("Fase sconosciuta: \(id)") }
            let out = NewMacRestore.runStage(stage, snapshot: snap.url, home: home, dryRun: !yes, services: agents) { print($0) }
            if yes && stage.restartAfter && out.ok { print(yellow("Riavvia il Mac prima della fase successiva.")) }
            if !out.ok { print(red("Fase \(id) con problemi: leggi le righe sopra.")) }
        }
        if !yes { print(yellow("\nAnteprima: niente è stato scritto. Aggiungi --yes per eseguire.")) }
    }
}
