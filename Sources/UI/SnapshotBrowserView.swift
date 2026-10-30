import Cocoa
import SwiftUI

/// Chronological folder browser for "Ripristina": pick a folder, move through the complete
/// snapshots in time, restore a file or a whole folder. The restore itself is the existing
/// `SelectiveRestore` (preview, write beside the target and rename, per-file undo).
final class SnapshotBrowserModel: ObservableObject {
    /// How the page changed: drives the depth animation, never the data.
    enum Motion { case older, newer, deeper, up }
    struct Page: Equatable {
        let id = UUID()
        let motion: Motion
        let previous: [SnapshotBrowsing.Entry]
    }

    let destination: URL
    let home: String
    let undoRoot: URL
    var onDone: ((RestoreResult) -> Void)?

    /// Complete snapshots only, newest first.
    @Published private(set) var snapshots: [SnapshotInfo] = []
    @Published private(set) var index = 0
    @Published private(set) var directory = ""
    @Published private(set) var entries: [SnapshotBrowsing.Entry] = []
    @Published private(set) var folderMissing = false
    @Published private(set) var loaded = false
    @Published private(set) var page: Page?
    @Published private(set) var selected: String?
    @Published private(set) var plan: RestorePlan?
    @Published private(set) var skippedLoginSensitive = 0
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var messageIsError = false
    @Published private(set) var undoDir: URL?
    @Published var restoreToFolder = true {
        didSet { if oldValue != restoreToFolder { invalidatePlan() } }
    }

    private var listGeneration = 0
    private var planGeneration = 0

    init(destination: URL, home: String = FileManager.default.homeDirectoryForCurrentUser.path,
         undoRoot: URL = RestoreEngine.preRestoreBaseURL) {
        self.destination = destination
        self.home = home
        self.undoRoot = undoRoot
    }

    var current: SnapshotInfo? { snapshots.indices.contains(index) ? snapshots[index] : nil }
    var canGoOlder: Bool { index + 1 < snapshots.count }
    var canGoNewer: Bool { index > 0 }
    var breadcrumbs: [String] { directory.split(separator: "/").map(String.init) }
    var selectedEntry: SnapshotBrowsing.Entry? { entries.first { $0.relativePath == selected } }
    /// What "Ripristina" would bring back: the selected item, else the open folder.
    var target: String? { selected ?? (directory.isEmpty ? nil : directory) }
    var restoreRoot: String {
        restoreToFolder ? home + "/Desktop/Ripristinati \(current?.name ?? "")" : home
    }

    func dateLabel(_ s: SnapshotInfo) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE d MMMM yyyy · HH:mm"
        return f.string(from: s.timestamp)
    }

    // MARK: Navigation

    func load() {
        listGeneration += 1
        let gen = listGeneration
        let dest = destination
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = SnapshotBrowsing.browsableSnapshots(at: dest)
            DispatchQueue.main.async { [weak self, list] in
                guard let self, gen == self.listGeneration else { return }
                self.snapshots = list
                self.index = 0
                self.directory = ""
                self.selected = nil
                self.loaded = true
                self.busy = false
                self.invalidatePlan()
                self.refresh(motion: nil)
            }
        }
    }

    func open(_ relativePath: String) {
        guard let entry = entries.first(where: { $0.relativePath == relativePath }), entry.kind == .directory else { return }
        directory = entry.relativePath
        selected = nil
        refresh(motion: .deeper)
    }

    func goUp() { goTo(depth: breadcrumbs.count - 1) }

    /// `depth` 0 is the root; n keeps the first n folders.
    func goTo(depth: Int) {
        let comps = breadcrumbs
        guard depth >= 0, depth < comps.count else { return }
        directory = comps.prefix(depth).joined(separator: "/")
        selected = nil
        refresh(motion: .up)
    }

    func select(_ relativePath: String?) {
        guard selected != relativePath else { return }
        if let relativePath, entries.first(where: { $0.relativePath == relativePath })?.kind == .link { return }
        selected = relativePath
        invalidatePlan()
    }

    func goOlder() { move(to: index + 1) }
    func goNewer() { move(to: index - 1) }

    /// Change the date but keep the folder (and the selection, when it exists on that date).
    func move(to newIndex: Int) {
        guard snapshots.indices.contains(newIndex), newIndex != index else { return }
        let motion: Motion = newIndex > index ? .older : .newer
        index = newIndex
        refresh(motion: motion)
    }

    private func refresh(motion: Motion?) {
        invalidatePlan()
        guard let snap = current?.url else {
            entries = []; folderMissing = false; return
        }
        listGeneration += 1
        let gen = listGeneration
        let dir = directory
        let wanted = selected
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var isDir: ObjCBool = false
            let reachable = FileManager.default.fileExists(atPath: snap.path, isDirectory: &isDir) && isDir.boolValue
            let listing: Result<[SnapshotBrowsing.Entry], Error> = reachable
                ? Result { try SnapshotBrowsing.list(snapshot: snap, directory: dir) }
                : .failure(CocoaError(.fileReadNoSuchFile))
            DispatchQueue.main.async { [weak self, listing] in
                guard let self, gen == self.listGeneration else { return }
                self.busy = false
                let previous = self.entries
                switch listing {
                case .success(let list):
                    self.entries = list
                    self.folderMissing = false
                    self.message = ""
                    self.messageIsError = false
                case .failure(let error):
                    self.entries = []
                    if (error as? CocoaError)?.code == .fileNoSuchFile {
                        self.folderMissing = true
                        self.message = ""
                        self.messageIsError = false
                    } else {
                        Log.error("Restore browser cannot read \(snap.path): \(error.localizedDescription)")
                        self.folderMissing = false
                        self.messageIsError = true
                        self.message = "Non riesco a leggere questo backup. Controlla che il disco sia collegato: \(error.localizedDescription)"
                    }
                }
                if let wanted {
                    if let kept = self.entries.first(where: { $0.relativePath == wanted }), kept.kind != .link {
                        self.selected = wanted
                    } else {
                        self.selected = nil
                        if self.messageIsError == false {
                            self.message = "«\((wanted as NSString).lastPathComponent)» non c'è nel backup di questa data."
                        }
                    }
                }
                if let motion { self.page = Page(motion: motion, previous: previous) }
            }
        }
    }

    // MARK: Restore

    private func invalidatePlan() {
        planGeneration += 1
        plan = nil
        skippedLoginSensitive = 0
    }

    /// Nothing is written: compare the chosen item (recursively for a folder) with today.
    func preview() {
        guard let snap = current, let target else { return }
        let root = restoreRoot
        invalidatePlan()
        let gen = planGeneration
        message = ""; messageIsError = false; undoDir = nil
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = SnapshotBrowsing.restorableFiles(snapshot: snap.url, relative: target)
            let plan = SelectiveRestore.plan(snapshot: snap.url, paths: found.files, destinationRoot: root)
            DispatchQueue.main.async { [weak self, plan] in
                guard let self, gen == self.planGeneration else { return }
                self.busy = false
                self.plan = plan
                self.skippedLoginSensitive = found.skippedLoginSensitive
                if found.files.isEmpty {
                    self.messageIsError = true
                    self.message = "Non c'è niente da ripristinare in «\((target as NSString).lastPathComponent)»: è vuoto o contiene solo collegamenti."
                }
            }
        }
    }

    func restore() {
        guard let plan, !busy else { return }
        let undoRoot = self.undoRoot
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try SelectiveRestore.apply(plan, undoRoot: undoRoot) }
            DispatchQueue.main.async { [weak self, outcome] in
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let (r, undo)):
                    self.plan = nil
                    self.undoDir = undo
                    self.messageIsError = r.failed > 0 || (r.restored == 0 && plan.toCreate + plan.toReplace > 0)
                    self.message = "Ripristinati \(r.restored) file (\(r.overwritten) sostituiti) in \(plan.destinationRoot)."
                        + (r.failed > 0 ? " \(r.failed) non riusciti: controlla il registro." : "")
                    self.onDone?(r)
                case .failure(let e):
                    self.messageIsError = true
                    self.message = "Ripristino non riuscito: \(e.localizedDescription)"
                }
            }
        }
    }

    func undo() {
        guard let dir = undoDir, !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try SelectiveRestore.undoDetailed(dir) }
            DispatchQueue.main.async { [weak self, outcome] in
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let o):
                    let problems = o.failed + o.keptBecauseChanged.count
                    self.messageIsError = problems > 0
                    self.message = "Annullato: \(o.restored) file rimessi com'erano."
                        + (o.keptBecauseChanged.isEmpty ? "" : " \(o.keptBecauseChanged.count) lasciati perché modificati dopo il ripristino.")
                        + (o.failed > 0 ? " \(o.failed) non riusciti." : "")
                    if !FileManager.default.fileExists(atPath: dir.path) { self.undoDir = nil }
                case .failure(let e):
                    self.messageIsError = true
                    self.message = "Annullamento non riuscito: \(e.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - View

struct SnapshotBrowserView: View {
    @ObservedObject var model: SnapshotBrowserModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double = 1
    @State private var outgoing: [SnapshotBrowsing.Entry] = []
    @State private var motion: SnapshotBrowserModel.Motion = .older

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.loaded && model.snapshots.isEmpty {
                Text("Nessun backup completo da sfogliare. Collega il disco, oppure usa \"Cerca\" o \"Argomento\".")
                    .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                breadcrumbBar
                stage
                timeline
                restorePanel
            }
        }
        .onAppear { if !model.loaded { model.load() } }
    }

    // MARK: Folders

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                .help("Cartella superiore")
                .accessibilityLabel("Cartella superiore")
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.directory.isEmpty)
            Button("Home") { model.goTo(depth: 0) }
                .buttonStyle(.borderless).disabled(model.directory.isEmpty)
            ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { i, name in
                Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Button(name) { model.goTo(depth: i + 1) }
                    .buttonStyle(.borderless)
                    .disabled(i + 1 == model.breadcrumbs.count)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
        }
    }

    private var olderLayers: Int { min(3, max(0, model.snapshots.count - 1 - model.index)) }

    private var stage: some View {
        ZStack {
            ForEach(Array(stride(from: olderLayers, to: 0, by: -1)), id: \.self) { i in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35)))
                    .scaleEffect(1 - 0.03 * CGFloat(i))
                    .offset(y: -9 * CGFloat(i))
                    .opacity(1 - 0.22 * Double(i))
                    .accessibilityHidden(true)
            }
            ZStack {
                page(model.entries, interactive: true)
                    .opacity(progress)
                    .scaleEffect(incomingScale)
                if progress < 1 {
                    page(outgoing, interactive: false)
                        .opacity(1 - progress)
                        .scaleEffect(outgoingScale)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.top, CGFloat(olderLayers) * 9)
        .frame(minHeight: 200)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: olderLayers)
        .onChange(of: model.page) { _, new in
            guard let new else { return }
            outgoing = new.previous
            motion = new.motion
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { progress = 0 }
            DispatchQueue.main.async {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.42)) { progress = 1 }
            }
        }
    }

    /// Time moves through the screen: going back, the present page comes toward you and fades
    /// while the older one rises from behind. Folders use the same gesture, smaller.
    private var scales: (incomingFrom: Double, outgoingTo: Double) {
        if reduceMotion { return (1, 1) }
        switch motion {
        case .older: return (0.90, 1.10)
        case .newer: return (1.10, 0.90)
        case .deeper: return (1.04, 0.96)
        case .up: return (0.96, 1.04)
        }
    }
    private var incomingScale: CGFloat { CGFloat(scales.incomingFrom + (1 - scales.incomingFrom) * progress) }
    private var outgoingScale: CGFloat { CGFloat(1 + (scales.outgoingTo - 1) * progress) }

    @ViewBuilder
    private func page(_ list: [SnapshotBrowsing.Entry], interactive: Bool) -> some View {
        if list.isEmpty {
            Text(model.folderMissing ? "Questa cartella non esisteva nel backup di questa data. Sposta la data qui sotto."
                 : model.loaded && !model.busy ? "Cartella vuota." : "")
                .foregroundColor(.secondary).multilineTextAlignment(.center).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if interactive {
            List(list, selection: Binding(get: { model.selected }, set: { model.select($0) })) { entry in
                row(entry).tag(entry.relativePath)
            }
            .listStyle(.plain)
            .onKeyPress(.return) {
                if let e = model.selectedEntry, e.kind == .directory { model.open(e.relativePath); return .handled }
                return .ignored
            }
        } else {
            VStack(spacing: 0) {
                ForEach(list.prefix(14)) { row($0).padding(.horizontal, 10).padding(.vertical, 4) }
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ e: SnapshotBrowsing.Entry) -> some View {
        HStack {
            Image(systemName: e.kind == .directory ? "folder" : e.kind == .link ? "arrow.turn.down.right" : "doc")
                .foregroundColor(e.kind == .directory ? .mlGold : .secondary).frame(width: 20)
            Text(e.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(e.kind == .link ? "collegamento" : e.kind == .directory ? ProtectionSummary.dateLabel(e.modified)
                 : "\(ProtectionSummary.dateLabel(e.modified)) · \(Fmt.formatBytes(e.size))")
                .font(.caption).foregroundColor(.secondary)
            if e.kind == .directory {
                Button { model.open(e.relativePath) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).accessibilityLabel("Apri \(e.name)")
            }
        }
        .foregroundColor(e.kind == .link ? .secondary : .primary)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { if e.kind == .directory { model.open(e.relativePath) } })
        .accessibilityElement(children: .combine)
    }

    // MARK: Time

    private var timeline: some View {
        HStack(spacing: 8) {
            Button { model.goOlder() } label: { Image(systemName: "backward.end") }
                .help("Backup più vecchio").accessibilityLabel("Backup più vecchio")
                .keyboardShortcut("[", modifiers: .command).disabled(!model.canGoOlder)
            if model.snapshots.count > 1 {
                Slider(value: Binding(
                    get: { Double(model.snapshots.count - 1 - model.index) },
                    set: { model.move(to: model.snapshots.count - 1 - Int($0.rounded())) }),
                       in: 0...Double(model.snapshots.count - 1), step: 1)
                    .accessibilityLabel("Data del backup")
                    .accessibilityValue(model.current.map { model.dateLabel($0) } ?? "")
            } else {
                Spacer()
            }
            Button { model.goNewer() } label: { Image(systemName: "forward.end") }
                .help("Backup più recente").accessibilityLabel("Backup più recente")
                .keyboardShortcut("]", modifiers: .command).disabled(!model.canGoNewer)
        }
        .padding(.top, 2)
        .safeAreaInset(edge: .bottom, spacing: 2) {
            if let s = model.current {
                Text("\(model.dateLabel(s)) — \(model.snapshots.count - model.index) di \(model.snapshots.count)")
                    .font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Restore

    private var restorePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let target = model.target {
                Text("Da ripristinare: \((target as NSString).lastPathComponent)"
                     + (model.selectedEntry?.kind == .directory || model.selected == nil ? " (cartella e tutto ciò che contiene)" : ""))
                    .font(.callout.weight(.semibold))
            } else {
                Text("Scegli un file o una cartella, oppure entra in una cartella per ripristinarla.")
                    .font(.callout).foregroundColor(.secondary)
            }
            Toggle("Metti la copia sulla Scrivania invece di sostituire l'originale", isOn: $model.restoreToFolder)
                .font(.caption)
            if let plan = model.plan {
                Text("Destinazione: \(plan.destinationRoot)").font(.caption).foregroundColor(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Text("Anteprima: \(plan.summary)"
                         + (model.skippedLoginSensitive > 0 ? ", \(model.skippedLoginSensitive) avvii automatici non toccati" : ""))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("Ripristina") { model.restore() }
                        .buttonStyle(.borderedProminent).tint(.mlGold)
                        .disabled(plan.toCreate + plan.toReplace == 0 || model.busy)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Mostra anteprima") { model.preview() }
                        .disabled(model.target == nil || model.busy)
                }
            }
            if !model.message.isEmpty {
                Text(model.message).font(.callout).foregroundColor(model.messageIsError ? .red : .mlVerde)
                    .textSelection(.enabled)
            }
            if model.undoDir != nil {
                Button("Annulla questo ripristino") { model.undo() }.disabled(model.busy)
            }
        }
    }
}
