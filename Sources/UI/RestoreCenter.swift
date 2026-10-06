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
    @Published var selectedSnapshot: String = ""
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
    @Published var steps: Set<NewMacRestore.Step> = [.config, .repos, .databases]
    @Published var log: [String] = []

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

    func runNewMac(dryRun: Bool) {
        guard let snap = snapshotURL else { return }
        let chosen = steps
        log = [dryRun ? "Anteprima (niente viene scritto)…" : "Ripristino in corso…"]
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let report = NewMacRestore.run(snapshot: snap, steps: chosen, dryRun: dryRun) { line in
                DispatchQueue.main.async { self.log.append(line) }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.log.append(report.failures.isEmpty ? "Fatto." : "Da sistemare: " + report.failures.joined(separator: "; "))
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

    private var newMacTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rimette questo Mac com'era, senza sovrascrivere niente di quello che c'è già.")
                .font(.callout)
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
            GroupBox("Passi") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(NewMacRestore.Step.allCases.filter { $0 != .launchAgents }, id: \.self) { step in
                        Toggle(step.title, isOn: Binding(
                            get: { model.steps.contains(step) },
                            set: { on in if on { model.steps.insert(step) } else { model.steps.remove(step) } }))
                    }
                    Text("I servizi automatici si scelgono uno per uno dal terminale: RustyMacBackup new-mac --steps launch-agents")
                        .font(.caption2).foregroundColor(.secondary)
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
            HStack {
                Spacer()
                Button("Anteprima") { model.runNewMac(dryRun: true) }.disabled(model.busy || model.steps.isEmpty)
                Button("Esegui") { model.runNewMac(dryRun: false) }
                    .buttonStyle(.borderedProminent).tint(.mlGold)
                    .disabled(model.busy || model.steps.isEmpty)
            }
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
