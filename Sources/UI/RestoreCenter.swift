import Cocoa
import SwiftUI

/// "Ripristina": by topic, by file (with every version), or a whole new Mac.
/// Every write is preceded by a preview; every write can be undone file by file.
final class RestoreCenterModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case topic = "Argomento", file = "File", newMac = "Nuovo Mac"
        var id: String { rawValue }
    }

    let destination: URL
    let config: Config?
    @Published var tab: Tab = .topic
    @Published var snapshots: [SnapshotInfo] = []
    @Published var selectedSnapshot: String = "" { didSet { if oldValue != selectedSnapshot { stages = []; stageCounts = [:] } } }
    @Published var busy = false
    @Published var message: String = ""

    // Topic tab
    @Published var topics: [RestoreTopic] = []
    @Published var selectedTopics: Set<String> = []
    @Published var plan: RestorePlan?

    // File tab
    @Published var query: String = ""
    @Published var results: [String] = []
    @Published var selectedFile: String?
    @Published var versions: [FileVersion] = []
    @Published var restoreToFolder = false

    // New Mac tab
    @Published var checklist: [NewMacRestore.CheckItem] = []
    @Published var log: [String] = []
    @Published var stages: [NewMacRestore.Stage] = []
    /// "312 da aggiungere" per file phase, computed in the background.
    @Published var stageCounts: [String: String] = [:]
    @Published var progress: [NewMacRestore.ProgressEntry] = []
    @Published var services: [NewMacRestore.LaunchAgentInfo] = []
    /// Services to turn on: always empty to start with, one explicit toggle each.
    @Published var chosenServices: Set<String> = []
    // Programs of the old Mac (4.0): proposed = everything not installed yet.
    @Published var packages: [ToolInventory.Package] = []
    @Published var installedPackages: Set<String> = []
    @Published var chosenPackages: Set<String> = []
    @Published var packageFilter: String = ""
    @Published var showPackages = false
    @Published var prerequisites: [ToolInventory.Prerequisite] = []

    var onAdvanced: (() -> Void)?
    var onDone: ((RestoreResult) -> Void)?

    init(destination: URL, config: Config?) {
        self.destination = destination
        self.config = config
        self.topics = Topics.all(config: config)
    }

    var snapshotURL: URL? {
        snapshots.first { $0.name == selectedSnapshot }?.url
    }

    func load() {
        busy = true
        let dest = destination
        DispatchQueue.global(qos: .userInitiated).async {
            let list = SnapshotCatalog.list(at: dest)
            let preferred = SnapshotCatalog.defaultForRestore(at: dest)?.name ?? list.first?.name ?? ""
            DispatchQueue.main.async {
                self.snapshots = list
                self.selectedSnapshot = preferred
                self.busy = false
            }
        }
    }

    func label(for s: SnapshotInfo) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM yyyy · HH:mm"
        return "\(f.string(from: s.timestamp)) — \(s.state.label)"
    }

    // MARK: Topic

    func previewTopics() {
        guard let snap = snapshotURL else { return }
        let chosen = topics.filter { selectedTopics.contains($0.name) }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let files = chosen.flatMap { Topics.files(of: $0, in: snap) }
            let plan = SelectiveRestore.plan(snapshot: snap, paths: files)
            DispatchQueue.main.async { self.plan = plan; self.busy = false }
        }
    }

    func applyPlan() {
        guard let plan else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try SelectiveRestore.apply(plan) }
            DispatchQueue.main.async {
                self.busy = false
                switch outcome {
                case .success(let (r, _)):
                    self.message = "Ripristinati \(r.restored) file (\(r.overwritten) sostituiti), \(r.failed) non riusciti. Annullabile dal menu."
                    self.plan = nil
                    self.onDone?(r)
                case .failure(let e):
                    self.message = "Ripristino non riuscito: \(e.localizedDescription)"
                }
            }
        }
    }

    // MARK: File

    func search() {
        guard let snap = snapshotURL, query.count >= 2 else { results = []; return }
        let q = query
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let hits = FileVersions.search(q, in: snap)
            DispatchQueue.main.async { self.results = hits; self.busy = false }
        }
    }

    func selectFile(_ rel: String) {
        selectedFile = rel
        let dest = destination
        DispatchQueue.global(qos: .userInitiated).async {
            let v = FileVersions.list(relativePath: rel, at: dest)
            DispatchQueue.main.async { self.versions = v }
        }
    }

    func restore(version: FileVersion) {
        guard let rel = selectedFile,
              let snap = snapshots.first(where: { $0.name == version.snapshot })?.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let root = restoreToFolder ? home + "/Desktop/Ripristinati \(version.snapshot)" : home
        // Preview first, like every other restore: the user confirms with "Ripristina".
        self.plan = SelectiveRestore.plan(snapshot: snap, paths: [rel], destinationRoot: root)
        self.message = ""
    }

    // MARK: New Mac

    func loadChecklist() {
        guard let snap = snapshotURL else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let items = NewMacRestore.checklist(snapshot: snap, ignoredApps: self.ignoredApps)
            DispatchQueue.main.async { self.checklist = items; self.busy = false }
        }
    }

    var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// Apps the user said they do not want back (config.toml [coverage] ignore_apps).
    var ignoredApps: [String] { (try? Config.load(from: Config.defaultPath))?.coverage.ignoreApps ?? config?.coverage.ignoreApps ?? [] }

    func ignoreApps(_ apps: [String]) {
        guard var cfg = try? Config.load(from: Config.defaultPath) else { return }
        cfg.coverage.ignoreApps = Array(Set(cfg.coverage.ignoreApps + apps)).sorted()
        do { try cfg.save(to: Config.defaultPath) } catch { message = "Non salvato: \(error.localizedDescription)"; return }
        loadChecklist()
    }

    func loadStages() {
        guard let snap = snapshotURL else { return }
        busy = true
        let config = self.config, home = self.home
        DispatchQueue.global(qos: .userInitiated).async {
            let stages = NewMacRestore.stages(snapshot: snap, config: config)
            let services = NewMacRestore.availableLaunchAgents(snapshot: snap)
            let progress = NewMacRestore.progress(home: home)
            let prerequisites = ToolInventory.prerequisites()
            let packages = ToolInventory.packages(snapshot: snap)
            DispatchQueue.main.async {
                self.stages = stages; self.services = services; self.progress = progress
                self.chosenServices = []
                self.prerequisites = prerequisites
                self.packages = packages
                self.busy = false
            }
            let installed = ToolInventory.installed(packages)
            DispatchQueue.main.async {
                self.installedPackages = installed
                self.chosenPackages = Set(packages.filter { !ToolInventory.isInstalled($0, in: installed) }.map(\.id))
            }
            var counts: [String: String] = [:]
            for stage in stages where stage.kind == .files {
                let plan = SelectiveRestore.plan(snapshot: snap, paths: stage.paths, destinationRoot: home)
                counts[stage.id] = "\(plan.toCreate) file da aggiungere" + (plan.toReplace > 0 ? " · \(plan.toReplace) già presenti" : "")
            }
            DispatchQueue.main.async { self.stageCounts = counts }
        }
    }

    func done(_ id: String) -> NewMacRestore.ProgressEntry? {
        progress.last { $0.stageID == id && !$0.undone }
    }

    /// The first phase not done yet, in the recommended order (services never count: optional).
    var nextStageID: String? {
        stages.first { $0.kind != .services && done($0.id)?.ok != true }?.id
    }

    func refreshPrerequisites() {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = ToolInventory.prerequisites()
            DispatchQueue.main.async { self.prerequisites = p }
        }
    }

    func startPrerequisite(_ id: String) {
        DispatchQueue.global(qos: .userInitiated).async { ToolInventory.startPrerequisite(id) }
        log = [id == "brew" ? "Si è aperto il Terminale con l'installazione di Homebrew: segui le istruzioni, poi premi Controlla di nuovo."
                            : "Si è aperta la finestra di Apple: conferma l'installazione, poi premi Controlla di nuovo."]
    }

    func runStage(_ stage: NewMacRestore.Stage, dryRun: Bool) {
        guard let snap = snapshotURL else { return }
        let home = self.home, services = chosenServices, packages = chosenPackages
        log = [dryRun ? "Anteprima di \"\(stage.title)\" (niente viene scritto)…" : "Ripristino di \"\(stage.title)\"…"]
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let out = NewMacRestore.runStage(stage, snapshot: snap, home: home, dryRun: dryRun,
                                             services: services, packages: stage.kind == .packages ? packages : [], sink: { line in
                DispatchQueue.main.async { self.log.append(line) }
            })
            let progress = NewMacRestore.progress(home: home)
            let installed = stage.kind == .packages && !dryRun ? ToolInventory.installed(ToolInventory.packages(snapshot: snap)) : nil
            DispatchQueue.main.async {
                self.busy = false
                self.progress = progress
                if !dryRun && stage.kind == .services { self.chosenServices = [] }
                if let installed {
                    self.installedPackages = installed
                    let byID = Dictionary(uniqueKeysWithValues: self.packages.map { ($0.id, $0) })
                    self.chosenPackages = self.chosenPackages.filter { id in
                        byID[id].map { !ToolInventory.isInstalled($0, in: installed) } ?? false
                    }
                }
                if !dryRun {
                    self.log.append(out.ok ? (stage.restartAfter ? "Fatto. Riavvia il Mac prima della fase successiva: se qualcosa non va, sai che è stata questa." : "Fatto.")
                                           : "Fatto con problemi: leggi le righe sopra.")
                }
            }
        }
    }

    func undo(_ id: String) {
        let home = self.home
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let text = NewMacRestore.undoStage(id, home: home)
            let progress = NewMacRestore.progress(home: home)
            DispatchQueue.main.async {
                self.busy = false; self.progress = progress
                self.log = ["Annullato: \(text)"]
            }
        }
    }
}

struct RestoreCenterView: View {
    @ObservedObject var model: RestoreCenterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $model.tab) {
                    ForEach(RestoreCenterModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            HStack {
                Text("Da:").foregroundColor(.secondary)
                Picker("", selection: $model.selectedSnapshot) {
                    ForEach(model.snapshots, id: \.name) { s in Text(model.label(for: s)).tag(s.name) }
                }
                .labelsHidden()
                .onChange(of: model.selectedSnapshot) { _, _ in model.plan = nil; model.results = []; model.checklist = [] }
            }
            if let s = model.snapshots.first(where: { $0.name == model.selectedSnapshot }), s.state == .incomplete {
                Text("Questo snapshot è incompleto: alcuni file mancano. " + (s.manifest?.incompleteReasons.first ?? ""))
                    .font(.caption).foregroundColor(.orange)
            }
            Divider()
            switch model.tab {
            case .topic: topicTab
            case .file: fileTab
            case .newMac: newMacTab
            }
            if !model.message.isEmpty {
                Text(model.message).font(.callout).foregroundColor(.mlVerde)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { model.load() }
    }

    // MARK: Topic

    private var topicTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scegli cosa rimettere com'era").font(.headline)
            List {
                ForEach(model.topics, id: \.name) { t in
                    Toggle(isOn: Binding(
                        get: { model.selectedTopics.contains(t.name) },
                        set: { on in
                            if on { model.selectedTopics.insert(t.name) } else { model.selectedTopics.remove(t.name) }
                            model.plan = nil
                        })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name)
                            Text(t.paths.map { "~/\($0)" }.joined(separator: " · "))
                                .font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
            }
            .frame(minHeight: 200)
            if let plan = model.plan {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Anteprima: \(plan.summary)").font(.callout.weight(.semibold))
                    Text("Le versioni attuali dei file sostituiti si possono rimettere dal menu, anche una per una.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            HStack {
                Button("Selezione avanzata (cartelle)…") { model.onAdvanced?() }.buttonStyle(.borderless)
                Spacer()
                Button("Mostra anteprima") { model.previewTopics() }
                    .disabled(model.selectedTopics.isEmpty || model.busy)
                Button("Ripristina") { model.applyPlan() }
                    .buttonStyle(.borderedProminent).tint(.mlGold)
                    .disabled(model.plan == nil || (model.plan?.toCreate ?? 0) + (model.plan?.toReplace ?? 0) == 0 || model.busy)
            }
        }
    }

    // MARK: File

    private var fileTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Cerca un file (es. settings.toml)", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search() }
                Button("Cerca") { model.search() }.disabled(model.query.count < 2)
            }
            HSplitView {
                List(model.results, id: \.self, selection: Binding(
                    get: { model.selectedFile }, set: { if let f = $0 { model.selectFile(f) } })) { rel in
                    Text("~/" + rel).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
                .frame(minWidth: 260)
                VStack(alignment: .leading, spacing: 6) {
                    if let file = model.selectedFile {
                        Text((file as NSString).lastPathComponent).font(.headline)
                        Text("\(model.versions.count) versioni diverse").font(.caption).foregroundColor(.secondary)
                        List(model.versions, id: \.snapshot) { v in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("modificato " + ProtectionSummary.dateLabel(v.modified)).font(.callout)
                                    Text("\(v.snapshot) · \(v.state.label) · \(Fmt.formatBytes(v.size))")
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Scegli") { model.restore(version: v) }.controlSize(.small)
                            }
                        }
                        Toggle("Metti la copia sulla Scrivania invece di sostituire l'originale", isOn: $model.restoreToFolder)
                            .font(.caption)
                        if let plan = model.plan {
                            HStack {
                                Text("Anteprima: \(plan.summary)").font(.caption.weight(.semibold))
                                Spacer()
                                Button("Ripristina") { model.applyPlan() }
                                    .buttonStyle(.borderedProminent).tint(.mlGold)
                                    .disabled(plan.toCreate + plan.toReplace == 0 || model.busy)
                            }
                        }
                    } else {
                        Text("Cerca un file e selezionalo per vedere le sue versioni.")
                            .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 240)
            }
        }
    }

    // MARK: New Mac

    private func stageRow(_ stage: NewMacRestore.Stage) -> some View {
        let entry = model.done(stage.id)
        let isNext = model.nextStageID == stage.id
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry == nil ? "circle" : (entry!.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                .foregroundColor(entry == nil ? .secondary : (entry!.ok ? .mlVerde : .orange))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(stage.title).font(.callout.weight(.semibold))
                    if isNext { Text("prossima").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.mlGold.opacity(0.25))) }
                }
                Text(entry.map { "Fatta il \(Self.when($0.date))" } ?? model.stageCounts[stage.id] ?? stage.detail)
                    .font(.caption).foregroundColor(.secondary)
                if stage.restartAfter {
                    Text("Dopo questa fase riavvia il Mac prima di andare avanti.").font(.caption2).foregroundColor(.orange)
                }
            }
            Spacer()
            if let entry, entry.undoDir != nil {
                Button("Annulla") { model.undo(stage.id) }.disabled(model.busy)
            }
            Button("Anteprima") { model.runStage(stage, dryRun: true) }.disabled(model.busy)
            Button("Ripristina") { model.runStage(stage, dryRun: false) }
                .buttonStyle(.borderedProminent).tint(isNext ? .mlGold : .gray)
                .disabled(model.busy)
        }
    }

    private func servicesRow(_ stage: NewMacRestore.Stage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle").foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.title).font(.callout.weight(.semibold))
                    Text("Partono da soli al login. Nessuno è acceso: scegli tu quali, uno alla volta. Ognuno viene osservato per qualche secondo; se esce con un errore lo fermo e lo metto da parte.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(model.services, id: \.label) { agent in
                let active = model.done("servizio:" + agent.label) != nil
                HStack {
                    Toggle(isOn: Binding(
                        get: { model.chosenServices.contains(agent.label) },
                        set: { on in if on { model.chosenServices.insert(agent.label) } else { model.chosenServices.remove(agent.label) } })) {
                        Text(agent.label).font(.system(.caption, design: .monospaced))
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    .disabled(active || !agent.programExists || model.busy)
                    Spacer()
                    if active {
                        Text("attivo").font(.caption2).foregroundColor(.mlVerde)
                        Button("Spegni") { model.undo("servizio:" + agent.label) }.controlSize(.small).disabled(model.busy)
                    } else if !agent.programExists {
                        Text("manca il programma").font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(.leading, 24)
            }
            HStack {
                Spacer()
                Button("Accendi i servizi scelti (\(model.chosenServices.count))") { model.runStage(stage, dryRun: false) }
                    .disabled(model.busy || model.chosenServices.isEmpty)
            }
        }
    }

    private func prerequisitesRow(_ stage: NewMacRestore.Stage) -> some View {
        let allOK = !model.prerequisites.isEmpty && model.prerequisites.allSatisfy(\.ok)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: allOK ? "checkmark.circle.fill" : "wrench.and.screwdriver")
                    .foregroundColor(allOK ? .mlVerde : .orange)
                Text(stage.title).font(.callout.weight(.semibold))
                Spacer()
                Button("Controlla di nuovo") { model.refreshPrerequisites() }.controlSize(.small)
            }
            ForEach(model.prerequisites) { p in
                HStack {
                    Image(systemName: p.ok ? "checkmark" : "xmark").foregroundColor(p.ok ? .mlVerde : .orange).frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.title).font(.caption)
                        Text(p.hint).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    if !p.ok { Button("Installa") { model.startPrerequisite(p.id) }.controlSize(.small) }
                }
                .padding(.leading, 24)
            }
        }
    }

    private func packagesRow(_ stage: NewMacRestore.Stage) -> some View {
        let filter = model.packageFilter.lowercased()
        let visible = model.packages.filter { filter.isEmpty || $0.name.lowercased().contains(filter) }
        let entry = model.done(stage.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: entry?.ok == true ? "checkmark.circle.fill" : "shippingbox")
                    .foregroundColor(entry?.ok == true ? .mlVerde : .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.title).font(.callout.weight(.semibold))
                    Text("\(model.packages.count) del vecchio Mac · \(model.packages.filter { ToolInventory.isInstalled($0, in: model.installedPackages) }.count) già presenti · \(model.chosenPackages.count) scelti")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(model.showPackages ? "Nascondi" : "Scegli…") { model.showPackages.toggle() }
            }
            if model.showPackages {
                TextField("Cerca", text: $model.packageFilter).textFieldStyle(.roundedBorder).padding(.leading, 24)
                ForEach(ToolInventory.Package.Kind.allCases, id: \.self) { kind in
                    let items = visible.filter { $0.kind == kind }
                    if !items.isEmpty {
                        HStack {
                            Text(kind.title).font(.caption.weight(.semibold))
                            Spacer()
                            Button("Tutti") { items.filter { !ToolInventory.isInstalled($0, in: model.installedPackages) }.forEach { model.chosenPackages.insert($0.id) } }
                                .buttonStyle(.link).font(.caption2)
                            Button("Nessuno") { items.forEach { model.chosenPackages.remove($0.id) } }
                                .buttonStyle(.link).font(.caption2)
                        }
                        .padding(.leading, 24).padding(.top, 4)
                        ForEach(items) { p in
                            let installed = ToolInventory.isInstalled(p, in: model.installedPackages)
                            Toggle(isOn: Binding(get: { model.chosenPackages.contains(p.id) },
                                                 set: { on in if on { model.chosenPackages.insert(p.id) } else { model.chosenPackages.remove(p.id) } })) {
                                HStack {
                                    Text(p.name).font(.system(.caption, design: .monospaced))
                                    if installed { Text("già presente").font(.caption2).foregroundColor(.mlVerde) }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(installed || model.busy)
                            .padding(.leading, 36)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Anteprima") { model.runStage(stage, dryRun: true) }.disabled(model.busy || model.chosenPackages.isEmpty)
                Button("Installa i selezionati (\(model.chosenPackages.count))") { model.runStage(stage, dryRun: false) }
                    .buttonStyle(.borderedProminent).tint(.mlGold)
                    .disabled(model.busy || model.chosenPackages.isEmpty)
            }
        }
    }

    static func when(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "dd/MM 'alle' HH:mm"; return f.string(from: date)
    }

    private var newMacTab: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rimette questo Mac com'era una fase alla volta, senza sovrascrivere niente. Ogni fase si può annullare. Quello che parte da solo al login non viene mai rimesso, se non lo accendi tu.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            GroupBox("Controlli") {
                VStack(alignment: .leading, spacing: 4) {
                    if model.checklist.isEmpty {
                        Button("Controlla login e app") { model.loadChecklist() }
                    }
                    ForEach(model.checklist, id: \.title) { item in
                        HStack(alignment: .top) {
                            Image(systemName: item.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundColor(item.ok ? .mlVerde : .orange)
                            VStack(alignment: .leading) {
                                Text(item.title).font(.callout)
                                Text(item.hint).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            if !item.missingApps.isEmpty {
                                Spacer()
                                Button("Non mi servono") { model.ignoreApps(item.missingApps) }
                                    .controlSize(.small)
                                    .help("Non segnalarle più come mancanti")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Fasi, una alla volta") {
                VStack(alignment: .leading, spacing: 8) {
                    if model.stages.isEmpty {
                        Button("Prepara le fasi") { model.loadStages() }.disabled(model.busy)
                    }
                    ForEach(model.stages) { stage in
                        switch stage.kind {
                        case .services: servicesRow(stage)
                        case .prerequisites: prerequisitesRow(stage)
                        case .packages: packagesRow(stage)
                        default: stageRow(stage)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120)
            .background(Color(.textBackgroundColor).opacity(0.5))
        }
        .padding(.trailing, 6)
        }
    }
}

final class RestoreCenterWindowController: NSWindowController {
    init(model: RestoreCenterModel) {
        let hosting = NSHostingController(rootView: RestoreCenterView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 640, height: 600))
        window.center()
        window.isReleasedWhenClosed = false
        window.title = "Ripristina"
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
