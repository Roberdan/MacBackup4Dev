import SwiftUI

/// SwiftUI content of the menu bar popover (3.0).
/// First line answers "am I protected, and since when?" counting only COMPLETE snapshots;
/// then the problems, each with the button that fixes it; then the actions.
/// Observes AppUIState via @EnvironmentObject; all actions go through state callbacks.
struct PopoverView: View {
    @EnvironmentObject var state: AppUIState
    @State private var volumes: [URL] = []
    @State private var showAllIssues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            updateBanner
            VStack(alignment: .leading, spacing: 14) {
                if state.appState == .needsSetup {
                    diskSetupSection
                } else {
                    heroCard
                    if state.isRunning, let s = state.status { progressSection(status: s) }
                    if let phase = state.cleanupPhase { cleanupRow(phase) }
                    if state.appState == .error { errorCard }
                    if let result = state.restoreResult { restoreResultCard(result) }
                    issuesList
                    if let p = state.protection, state.appState != .diskAbsent { timeline(p) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
            Divider()
            primaryActions
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .disabled(state.isCleaning)
            Divider()
            secondaryActions
                .disabled(state.isCleaning)
                .padding(.vertical, 6)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if state.appState == .needsSetup { refreshVolumes() } }
        .onChange(of: state.appState) { _, newState in
            if newState == .needsSetup { refreshVolumes() }
        }
    }

    // MARK: - Header

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var headerSection: some View {
        HStack(spacing: 8) {
            Circle().fill(levelColor).frame(width: 9, height: 9)
                .accessibilityLabel("Stato: \(heroHeadline)")
            Text("Backup").font(.headline)
            Spacer()
            if let c = state.config { diskLabel(c) }
            Text("v\(appVersion)").font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func diskLabel(_ config: Config) -> some View {
        let (free, total) = DiskDiagnostics.diskSpace(at: config.destination.path)
        let vol = URL(fileURLWithPath: config.destination.path).deletingLastPathComponent().lastPathComponent
        if total > 0 {
            Text("\(vol) · \(Fmt.formatBytes(free)) liberi")
                .font(.caption).foregroundColor(diskSpaceColor(free: free))
        } else {
            Text("\(vol) non collegato").font(.caption).foregroundColor(.mlRosso)
        }
    }

    // MARK: - Hero

    private var heroLevel: ProtectionSummary.Level {
        switch state.appState {
        case .error, .diskAbsent: return state.protection?.level == .protected ? .attention : (state.protection?.level ?? .unprotected)
        default: return state.protection?.level ?? .unprotected
        }
    }

    private var levelColor: Color {
        if state.appState == .running || state.appState == .restoring { return .mlGold }
        switch heroLevel {
        case .protected: return .mlVerde
        case .attention: return .orange
        case .unprotected: return .mlRosso
        }
    }

    private var heroHeadline: String {
        switch state.appState {
        case .running: return "Backup in corso…"
        case .stopping: return "Interrompo il backup…"
        case .restoring: return "Ripristino in corso…"
        case .diskAbsent:
            return "Disco di backup non collegato" + (state.protection?.lastCompleteDate.map { " · ultimo completo \(ProtectionSummary.ago(Date().timeIntervalSince($0)))" } ?? "")
        case .error: return "L'ultimo backup non è riuscito"
        default: return state.protection?.headline ?? "Nessun backup"
        }
    }

    private var heroDetail: String {
        switch state.appState {
        case .diskAbsent: return "Collega il disco: il backup riparte da solo all'orario previsto."
        case .error: return state.protection?.lastCompleteDate.map { "Ultimo completo: \(ProtectionSummary.dateLabel($0))" } ?? ""
        case .running, .stopping, .restoring:
            return state.protection?.lastCompleteDate.map { "Ultimo completo: \(ProtectionSummary.dateLabel($0))" } ?? ""
        default:
            return state.protection?.detail ?? ""
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(heroHeadline).font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !heroDetail.isEmpty {
                Text(heroDetail).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let p = state.protection, p.level == .protected, state.appState == .idle {
                HStack(spacing: 6) {
                    chip(p.reposWithSavedCommits > 0 ? "\(p.reposWithSavedCommits) repo con commit salvati" : "Commit non pubblicati: nessuno", ok: true)
                    if p.databasesSaved > 0 { chip("\(p.databasesSaved) database salvati", ok: true) }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(levelColor.opacity(0.12))
        .cornerRadius(10)
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String, ok: Bool) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background((ok ? Color.mlVerde : Color.orange).opacity(0.14))
            .foregroundColor(ok ? .mlVerde : .orange)
            .clipShape(Capsule())
    }

    // MARK: - Issues

    private struct Issue: Identifiable {
        let id: String
        let title: String
        let detail: String
        let primary: (String, () -> Void)?
        let secondary: (String, () -> Void)?
    }

    private var issues: [Issue] {
        var out: [Issue] = []
        if let p = state.protection, p.latestIsIncomplete, state.appState == .idle || state.appState == .stale {
            out.append(Issue(id: "incomplete", title: "Ultimo backup incompleto",
                             detail: p.latestReasons.prefix(2).joined(separator: " "),
                             primary: ("Riprova", { state.onRequestBackup?() }), secondary: nil))
        }
        for gap in state.coverageGaps {
            out.append(Issue(id: "gap-\(gap.path)",
                             title: gap.kind == .database ? "Un database non viene copiato" : "Una cartella non viene salvata",
                             detail: "\(gap.path) · cambiata \(ProtectionSummary.dateLabel(ISO8601DateFormatter().date(from: gap.lastModified) ?? Date()))",
                             primary: ("Aggiungi", { state.onAddCoverage?(gap) }),
                             secondary: ("Ignora", { state.onIgnoreCoverage?(gap) })))
        }
        return out
    }

    @ViewBuilder
    private var issuesList: some View {
        let all = issues
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(showAllIssues ? all : Array(all.prefix(3))) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title).font(.subheadline.weight(.semibold))
                            Text(issue.detail).font(.caption).foregroundColor(.secondary)
                                .lineLimit(2).truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        if let s = issue.secondary {
                            Button(s.0, action: s.1).buttonStyle(.borderless).font(.caption)
                        }
                        if let p = issue.primary {
                            Button(p.0, action: p.1).buttonStyle(.borderedProminent).tint(.mlGold)
                                .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(8)
                }
                if all.count > 3 {
                    Button(showAllIssues ? "Mostra meno" : "Altri \(all.count - 3) avvisi") { showAllIssues.toggle() }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }

    // MARK: - Timeline (last 14 days)

    private func timeline(_ p: ProtectionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ultimi 14 giorni").font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 3) {
                ForEach(Array(p.days.enumerated()), id: \.offset) { _, day in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(day == .complete ? Color.mlVerde : day == .incomplete ? Color.orange : Color.secondary.opacity(0.18))
                        .frame(height: 14)
                }
            }
            .accessibilityLabel("\(p.days.filter { $0 == .complete }.count) giorni con un backup completo su 14")
        }
    }

    // MARK: - Progress, cleanup, error, restore result

    private func progressSection(status s: BackupStatusFile) -> some View {
        let pct = s.filesTotal > 0 ? Double(s.filesDone) / Double(s.filesTotal) : 0
        return VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: pct).tint(.mlGold)
                .accessibilityValue("\(Int(pct * 100)) percento completato")
            HStack(spacing: 8) {
                Text("\(Fmt.formatFileCount(s.filesDone)) file").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                Spacer()
                if s.etaSecs > 0 { Text("ancora \(Fmt.formatDuration(Double(s.etaSecs)))").font(.caption).foregroundColor(.secondary) }
            }
            if !s.currentFile.isEmpty {
                Text(s.currentFile).font(.caption2).foregroundColor(Color(.tertiaryLabelColor))
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func cleanupRow(_ phase: CleanupPhase) -> some View {
        HStack(spacing: 6) {
            if phase.showsProgress { ProgressView().controlSize(.small) }
            Text(phase.label).font(.subheadline)
        }
    }

    @ViewBuilder
    private var errorCard: some View {
        if let errors = loadErrors(), let top = topErrorCategory(errors) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ErrorReporter.localizedTitle(for: top)).font(.caption.weight(.semibold)).foregroundColor(.mlRosso)
                Text(ErrorReporter.suggestedAction(for: top)).font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Mostra log") { NSWorkspace.shared.open(ErrorReporter.logURL) }
                    Button("Riprova") { state.onRequestBackup?() }
                }
                .buttonStyle(.borderless).font(.caption)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.mlRosso.opacity(0.08))
            .cornerRadius(8)
        }
    }

    private func loadErrors() -> BackupErrorFile? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: StatusWriter.errorPath)) else { return nil }
        return try? JSONDecoder().decode(BackupErrorFile.self, from: data)
    }

    private func topErrorCategory(_ errors: BackupErrorFile) -> String? {
        errors.categories.filter { $0.value.count > 0 }.max(by: { $0.value.count < $1.value.count })?.key
    }

    private func restoreResultCard(_ result: RestoreResultSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Ripristino completato").font(.caption.weight(.semibold)).foregroundColor(.mlVerde)
            Text("\(result.restored) ripristinati · \(result.overwritten) sostituiti · \(result.failed) non riusciti")
                .font(.caption2).foregroundColor(.secondary)
            if !result.backedUpTo.isEmpty {
                Text("Le versioni precedenti sono annullabili dal menu.").font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mlVerde.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Actions

    @ViewBuilder
    private var primaryActions: some View {
        HStack(spacing: 8) {
            switch state.appState {
            case .running:
                Button { state.onRequestStop?() } label: {
                    Label("Interrompi", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.mlRosso)
            case .stopping, .restoring:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            case .needsSetup, .diskAbsent:
                Button { state.onRequestRestore?() } label: {
                    Label("Ripristina…", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!state.hasBackups)
            default:
                Button { state.onRequestBackup?() } label: {
                    Label("Esegui ora", systemImage: "arrow.up.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.mlGold)
                Button { state.onRequestRestore?() } label: {
                    Label("Ripristina…", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!state.hasBackups)
            }
        }
        .controlSize(.large)
    }

    private var secondaryActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.canUndo {
                row("Annulla l'ultimo ripristino", icon: "arrow.uturn.backward") { state.onRequestUndoRestore?() }
            }
            row("Scegli cosa salvare…", icon: "checklist") { state.onRequestChooseSources?() }
                .disabled(state.isRunning || state.config == nil)
            if state.onRequestScheduleMenu != nil {
                row("Pianificazione: \(state.scheduleLabel)", icon: "clock") { state.onRequestScheduleMenu?() }
            }
            row("Libera spazio…", icon: "trash") { state.onRequestCleanupMenu?() }
                .disabled(state.isRunning || state.config == nil || state.appState == .diskAbsent)
            row("Apri cartella dei backup", icon: "folder") { state.onRequestOpenFolder?() }
            row("Espelli disco", icon: "eject") { state.onRequestEject?() }
                .disabled(state.isRunning || state.appState == .diskAbsent)
            Divider().padding(.vertical, 3)
            row("Esci", icon: "power") { state.onRequestQuit?() }
        }
    }

    private func row(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20, alignment: .center)
                Text(title)
                Spacer(minLength: 0)
            }
            .foregroundColor(Color(.labelColor))
        }
        .buttonStyle(.plain)
        .modifier(DimWhenDisabled())
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    // MARK: - Update banner

    @ViewBuilder
    private var updateBanner: some View {
        if let version = state.updateAvailable, state.dismissedUpdateVersion != version {
            HStack(spacing: 8) {
                Button { state.onRequestUpdate?() } label: {
                    HStack(spacing: 8) {
                        if state.isUpdating {
                            ProgressView().controlSize(.small)
                            Text(updatePhaseLabel).font(.subheadline).foregroundColor(.mlInfo)
                        } else {
                            Image(systemName: "arrow.down.circle.fill").foregroundColor(.mlInfo)
                            Text("Versione \(version) disponibile").font(.subheadline).foregroundColor(.mlInfo)
                            Spacer()
                            Text("Installa").font(.subheadline.weight(.semibold)).foregroundColor(.mlInfo)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(state.isUpdating)
                if !state.isUpdating {
                    Button { state.dismissedUpdateVersion = version } label: {
                        Image(systemName: "xmark").font(.caption).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ignora aggiornamento \(version)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.mlInfo.opacity(0.08))
        }
    }

    private var updatePhaseLabel: String {
        switch state.updatePhase {
        case .downloading: return "Scaricamento…"
        case .verifying: return "Verifica firma…"
        case .installing: return "Installazione…"
        case nil: return "Aggiornamento in corso…"
        }
    }

    // MARK: - Disk setup

    private var diskSetupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scegli il disco di backup").font(.subheadline.weight(.semibold))
            if volumes.isEmpty {
                Text("Nessun disco esterno collegato.").font(.caption).foregroundColor(.mlRosso)
            } else {
                ForEach(volumes, id: \.path) { vol in diskButton(for: vol) }
            }
        }
    }

    @ViewBuilder
    private func diskButton(for vol: URL) -> some View {
        let (free, total) = DiskDiagnostics.diskSpace(at: vol.path)
        Button { state.onSelectDisk?(vol) } label: {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive").foregroundColor(.mlInfo)
                Text(vol.lastPathComponent)
                Spacer()
                if total > 0 { Text(Fmt.formatBytes(free) + " liberi").font(.caption).foregroundColor(.secondary) }
            }
            .padding(7)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func diskSpaceColor(free: UInt64) -> Color {
        if free > 50 * 1_073_741_824 { return .secondary }
        if free > 10 * 1_073_741_824 { return .orange }
        return .mlRosso
    }

    private func refreshVolumes() {
        guard let vols = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) else { return }
        volumes = vols.filter {
            let p = $0.path
            return p != "/" && p != "/System/Volumes/Data" && $0.lastPathComponent != "Macintosh HD" && p.hasPrefix("/Volumes/")
        }
    }
}

private struct DimWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View { content.opacity(isEnabled ? 1 : 0.4) }
}
