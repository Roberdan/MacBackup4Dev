import Cocoa
import SwiftUI

/// First launch (4.0): find the developer environment, let the user choose, pick the disk
/// and the schedule, start the first backup. Or, on a new Mac, go straight to the guided
/// restore from an existing backup.
final class OnboardingModel: ObservableObject {
    enum Step: Int { case welcome, choose, disk, schedule, summary }
    enum Schedule: String, CaseIterable, Identifiable {
        case hourly = "Ogni ora", sixHours = "Ogni 6 ore", nightly = "Ogni notte alle 2", manual = "Solo quando lo chiedo"
        var id: String { rawValue }
        /// Encoding used by AppDelegate.handleSetSchedule (minutes, or -hour for nightly).
        var option: Int?? {
            switch self {
            case .hourly: return .some(60)
            case .sixHours: return .some(360)
            case .nightly: return .some(-2)
            case .manual: return .some(nil)
            }
        }
    }

    @Published var step: Step = .welcome
    @Published var scanning = false
    @Published var scan = DevScan()
    @Published var selected: Set<String> = []
    @Published var volumes: [URL] = []
    @Published var volume: URL?
    @Published var schedule: Schedule = .hourly
    @Published var preparing = false
    /// Backups found on connected disks (for "Questo è un Mac nuovo").
    @Published var existingBackups: [(volume: String, backupDir: URL, snapshots: [String])] = []

    var onFinish: ((Config, Int??) -> Void)?
    var onRestoreNewMac: ((URL) -> Void)?

    func refreshDisks() {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        volumes = vols.filter { $0.path.hasPrefix("/Volumes/") && $0.path != "/" }
        if volume == nil || !volumes.contains(volume!) { volume = volumes.first }
        existingBackups = RestoreEngine.findBackupSnapshots()
    }

    func startScan() {
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DevEnvironment.scan()
            DispatchQueue.main.async {
                self.scan = result
                self.selected = result.defaultSelection
                self.scanning = false
                self.step = .choose
            }
        }
    }

    var selectedItems: [DevItem] { scan.allItems.filter { selected.contains($0.id) } }

    func finish() {
        guard let volume else { return }
        preparing = true
        let scan = self.scan, selected = self.selected, option = schedule.option
        DispatchQueue.global(qos: .userInitiated).async {
            let folder = AppIdentity.backupFolder(on: volume)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let config = DevEnvironment.config(from: scan, selected: selected, backupPath: folder.path)
            DispatchQueue.main.async {
                self.preparing = false
                self.onFinish?(config, option)
            }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                switch model.step {
                case .welcome: welcome
                case .choose: choose
                case .disk: disk
                case .schedule: schedule
                case .summary: summary
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear { model.refreshDisks() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 22, weight: .semibold)).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppIdentity.name).font(.title2.weight(.bold))
                Text("Il tuo ambiente di sviluppo, al sicuro e pronto da rimettere su un Mac nuovo.")
                    .font(.callout).foregroundColor(.secondary)
            }
            Spacer()
            if model.step != .welcome {
                Text("Passo \(model.step.rawValue) di 4").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Cosa vuoi fare?").font(.title3.weight(.semibold))
            choiceCard(symbol: "shield.lefthalf.filled", title: "Proteggere questo Mac",
                       text: "Trovo da solo progetti, configurazioni di terminale, editor, assistenti AI, linguaggi, database e programmi installati. Tu scegli cosa tenere.",
                       action: "Analizza questo Mac", busy: model.scanning) { model.startScan() }
            if let backup = model.existingBackups.first {
                choiceCard(symbol: "laptopcomputer.and.arrow.down", title: "Questo è un Mac nuovo",
                           text: "Ho trovato un backup su \(backup.volume) (\(backup.snapshots.count) copie). Lo rimetto una fase alla volta: progetti, configurazioni, database e programmi da reinstallare. Niente parte da solo senza il tuo consenso.",
                           action: "Rimetti questo Mac com'era", busy: false) { model.onRestoreNewMac?(backup.backupDir) }
            } else {
                Text("Mac nuovo? Collega il disco con il backup del vecchio Mac e potrai rimetterlo com'era da qui.")
                    .font(.callout).foregroundColor(.secondary)
                Button("Ho collegato il disco") { model.refreshDisks() }
            }
        }
    }

    private func choiceCard(symbol: String, title: String, text: String, action: String, busy: Bool,
                            perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundColor(.accentColor).frame(width: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(action, action: perform).buttonStyle(.borderedProminent).disabled(busy)
                    if busy { ProgressView().controlSize(.small); Text("Analizzo…").font(.caption).foregroundColor(.secondary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separatorColor)))
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ecco cosa ho trovato. Ho già scelto quello che serve: togli quello che non vuoi.")
                .font(.callout)
            List {
                ForEach(model.scan.groups) { group in
                    Section {
                        ForEach(group.items) { item in itemRow(item, group: group) }
                    } header: {
                        groupHeader(group)
                    }
                }
                if !model.scan.toolchains.isEmpty {
                    Section {
                        ForEach(model.scan.toolchains, id: \.self) { t in
                            HStack {
                                Image(systemName: "checkmark.seal").foregroundColor(.green)
                                Text(t.name)
                                Spacer()
                                Text(t.detail).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Label("Programmi e linguaggi installati", systemImage: "hammer")
                    } footer: {
                        Text("Non li copio: salvo l'elenco a ogni backup, e su un Mac nuovo ti propongo di reinstallarli uno per uno.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            footer(back: .welcome, next: .disk, nextTitle: "Avanti (\(model.selected.count) scelti)")
        }
    }

    private func groupHeader(_ group: DevGroup) -> some View {
        let ids = group.items.filter { !$0.sensitive }.map(\.id)
        let all = !ids.isEmpty && ids.allSatisfy { model.selected.contains($0) }
        return HStack {
            Label(group.title, systemImage: group.symbol).font(.headline)
            Spacer()
            if group.id != "credenziali" && !ids.isEmpty {
                Button(all ? "Nessuno" : "Tutti") {
                    if all { ids.forEach { model.selected.remove($0) } } else { ids.forEach { model.selected.insert($0) } }
                }
                .buttonStyle(.link).font(.caption)
            }
        }
    }

    private func itemRow(_ item: DevItem, group: DevGroup) -> some View {
        Toggle(isOn: Binding(get: { model.selected.contains(item.id) },
                             set: { on in if on { model.selected.insert(item.id) } else { model.selected.remove(item.id) } })) {
            HStack(spacing: 6) {
                if item.sensitive { Image(systemName: "key.fill").foregroundColor(.orange).font(.caption) }
                Text(item.name)
                Spacer()
                Text(item.detail).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .help(item.sensitive ? "Contiene credenziali. Il disco di backup non è cifrato: sceglilo solo se il disco lo è." : item.paths.joined(separator: "\n"))
    }

    private var disk: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dove salvo i backup?").font(.title3.weight(.semibold))
            if model.volumes.isEmpty {
                Text("Nessun disco esterno collegato. Collegane uno (meglio se cifrato) e premi Aggiorna.")
                    .foregroundColor(.orange)
            }
            ForEach(model.volumes, id: \.self) { vol in
                HStack {
                    Image(systemName: model.volume == vol ? "largecircle.fill.circle" : "circle").foregroundColor(.accentColor)
                    Image(systemName: "externaldrive")
                    VStack(alignment: .leading) {
                        Text(vol.lastPathComponent).font(.body.weight(.medium))
                        Text(diskDetail(vol)).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { model.volume = vol }
            }
            Button("Aggiorna") { model.refreshDisks() }
            Spacer()
            footer(back: .choose, next: .schedule, nextTitle: "Avanti", nextEnabled: model.volume != nil)
        }
    }

    private func diskDetail(_ vol: URL) -> String {
        let values = try? vol.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        let free = UInt64(values?.volumeAvailableCapacity ?? 0), total = UInt64(values?.volumeTotalCapacity ?? 0)
        let existing = FileManager.default.fileExists(atPath: vol.appendingPathComponent(AppIdentity.legacyName).path)
            ? " · contiene già dei backup" : ""
        return "\(Fmt.formatBytes(free)) liberi su \(Fmt.formatBytes(total))\(existing)"
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quando faccio il backup?").font(.title3.weight(.semibold))
            Picker("", selection: $model.schedule) {
                ForEach(OnboardingModel.Schedule.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("Se il disco non è collegato, lo salto e riprovo all'orario successivo. Ogni backup copia solo quello che è cambiato.")
                .font(.callout).foregroundColor(.secondary)
            Spacer()
            footer(back: .disk, next: .summary, nextTitle: "Avanti")
        }
    }

    private var summary: some View {
        let items = model.selectedItems
        let dbs = items.filter { $0.id.hasPrefix("postgres:") }.count
        let creds = items.filter(\.sensitive).count
        return VStack(alignment: .leading, spacing: 12) {
            Text("Tutto pronto").font(.title3.weight(.semibold))
            summaryRow("folder", "\(items.count - dbs) cose da salvare")
            if dbs > 0 { summaryRow("cylinder.split.1x2", "\(dbs) database, copiati in modo coerente") }
            if creds > 0 { summaryRow("key.fill", "\(creds) credenziali scelte da te (il disco deve essere cifrato)") }
            summaryRow("externaldrive", "Disco: \(model.volume?.lastPathComponent ?? "-")")
            summaryRow("clock", "Frequenza: \(model.schedule.rawValue)")
            summaryRow("hammer", "Elenco dei programmi installati: salvato a ogni backup")
            Spacer()
            HStack {
                Button("Indietro") { model.step = .schedule }
                Spacer()
                if model.preparing { ProgressView().controlSize(.small); Text("Preparo…").font(.caption).foregroundColor(.secondary) }
                Button("Inizia il primo backup") { model.finish() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.preparing || model.volume == nil)
            }
        }
    }

    private func summaryRow(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.body)
    }

    private func footer(back: OnboardingModel.Step, next: OnboardingModel.Step, nextTitle: String,
                        nextEnabled: Bool = true) -> some View {
        HStack {
            Button("Indietro") { model.step = back }
            Spacer()
            Button(nextTitle) { model.step = next }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!nextEnabled)
        }
    }
}

final class OnboardingWindowController: NSWindowController {
    init(model: OnboardingModel) {
        let hosting = NSHostingController(rootView: OnboardingView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 760, height: 620))
        window.center()
        window.isReleasedWhenClosed = false
        window.title = "Benvenuto in \(AppIdentity.name)"
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
