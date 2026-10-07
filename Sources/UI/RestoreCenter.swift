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
            let items = NewMacRestore.checklist(snapshot: snap)
            DispatchQueue.main.async { self.checklist = items; self.busy = false }
        }
    }

    var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    func loadStages() {
        guard let snap = snapshotURL else { return }
        busy = true
        let config = self.config, home = self.home
        DispatchQueue.global(qos: .userInitiated).async {
            let stages = NewMacRestore.stages(snapshot: snap, config: config)
            let services = NewMacRestore.availableLaunchAgents(snapshot: snap)
            let progress = NewMacRestore.progress(home: home)
            DispatchQueue.main.async {
                self.stages = stages; self.services = services; self.progress = progress
                self.chosenServices = []
                self.busy = false
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

    func runStage(_ stage: NewMacRestore.Stage, dryRun: Bool) {
        guard let snap = snapshotURL else { return }
        let home = self.home, services = chosenServices
        log = [dryRun ? "Anteprima di \"\(stage.title)\" (niente viene scritto)…" : "Ripristino di \"\(stage.title)\"…"]
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let out = NewMacRestore.runStage(stage, snapshot: snap, home: home, dryRun: dryRun, services: services) { line in
                DispatchQueue.main.async { self.log.append(line) }
            }
            let progress = NewMacRestore.progress(home: home)
            DispatchQueue.main.async {
                self.busy = false
                self.progress = progress
                if !dryRun && stage.kind == .services { self.chosenServices = [] }
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
                        if stage.kind == .services { servicesRow(stage) } else { stageRow(stage) }
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
