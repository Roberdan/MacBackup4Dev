import SwiftUI

// MARK: - Look (3.1): a dark, deep panel lit by the state colour, one big ring that answers
// "am I protected?", glass cards, a gradient primary action and tiles for the rest.

private enum Look {
    static let backgroundTop = Color(red: 0.09, green: 0.10, blue: 0.19)
    static let backgroundBottom = Color(red: 0.13, green: 0.09, blue: 0.22)
    static let glass = Color.white.opacity(0.07)
    static let glassStroke = Color.white.opacity(0.10)
    static let text = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.40)
    static let green = Color(red: 0.20, green: 0.84, blue: 0.52)
    static let gold = Color(red: 1.00, green: 0.76, blue: 0.20)
    static let orange = Color(red: 1.00, green: 0.56, blue: 0.22)
    static let red = Color(red: 1.00, green: 0.33, blue: 0.36)
    static let blue = Color(red: 0.38, green: 0.62, blue: 1.00)
    static let violet = Color(red: 0.62, green: 0.48, blue: 1.00)
}

/// SwiftUI content of the menu bar popover.
/// First line answers "am I protected, and since when?" counting only COMPLETE snapshots;
/// then the problems, each with the button that fixes it; then the actions.
/// Observes AppUIState via @EnvironmentObject; all actions go through state callbacks.
struct PopoverView: View {
    @EnvironmentObject var state: AppUIState
    @State private var volumes: [URL] = []
    @State private var showAllIssues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            updateBanner
            if state.appState == .needsSetup {
                diskSetupSection
            } else {
                heroCard
                if let phase = state.cleanupPhase { cleanupRow(phase) }
                if state.appState == .error { errorCard }
                if let result = state.restoreResult { restoreResultCard(result) }
                issuesList
                if let p = state.protection, state.appState != .diskAbsent { timeline(p) }
            }
            primaryActions.disabled(state.isCleaning)
            tiles.disabled(state.isCleaning)
            footer
        }
        .padding(18)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(background)
        .environment(\.colorScheme, .dark)
        .onAppear { if state.appState == .needsSetup { refreshVolumes() } }
        .onChange(of: state.appState) { _, newState in
            if newState == .needsSetup { refreshVolumes() }
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Look.backgroundTop, Look.backgroundBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [levelColor.opacity(0.35), .clear], center: .topLeading,
                           startRadius: 10, endRadius: 320)
            RadialGradient(colors: [Look.violet.opacity(0.18), .clear], center: .bottomTrailing,
                           startRadius: 10, endRadius: 300)
        }
    }

    // MARK: - Header

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Look.violet, Look.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                Image(systemName: "externaldrive.fill.badge.timemachine")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(AppIdentity.name).font(.system(size: 14, weight: .semibold)).foregroundColor(Look.text)
                Text("v\(appVersion)").font(.system(size: 10)).foregroundColor(Look.tertiaryText)
            }
            Spacer()
            if let c = state.config { diskPill(c) }
        }
    }

    @ViewBuilder
    private func diskPill(_ config: Config) -> some View {
        let (free, total) = DiskDiagnostics.diskSpace(at: config.diskURL.path)
        let vol = config.diskURL.lastPathComponent
        HStack(spacing: 5) {
            Image(systemName: total > 0 ? "externaldrive.fill" : "externaldrive.badge.xmark")
                .font(.system(size: 10))
            Text(total > 0 ? "\(vol) · \(Fmt.formatBytes(free))" : "\(vol) assente")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(total > 0 ? (free < 10 * 1_073_741_824 ? Look.orange : Look.secondaryText) : Look.red)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Look.glass))
        .overlay(Capsule().stroke(Look.glassStroke, lineWidth: 1))
    }

    // MARK: - Hero: one ring, one sentence

    private var heroLevel: ProtectionSummary.Level {
        switch state.appState {
        case .error, .diskAbsent: return state.protection?.level == .protected ? .attention : (state.protection?.level ?? .unprotected)
        default: return state.protection?.level ?? .unprotected
        }
    }

    private var levelColor: Color {
        if state.appState == .running || state.appState == .restoring || state.appState == .stopping { return Look.gold }
        switch heroLevel {
        case .protected: return Look.green
        case .attention: return Look.orange
        case .unprotected: return Look.red
        }
    }

    private var heroHeadline: String {
        switch state.appState {
        case .running: return "Backup in corso"
        case .stopping: return "Interrompo il backup…"
        case .restoring: return "Ripristino in corso"
        case .diskAbsent: return "Disco di backup non collegato"
        case .error: return "L'ultimo backup non è riuscito"
        default: return state.protection?.headline ?? "Nessun backup"
        }
    }

    private var heroDetail: String {
        switch state.appState {
        case .diskAbsent:
            let last = state.protection?.lastCompleteDate.map { "Ultimo completo \(ProtectionSummary.ago(Date().timeIntervalSince($0))). " } ?? ""
            return last + "Collegalo: riparte da solo all'orario previsto."
        case .error, .running, .stopping, .restoring:
            return state.protection?.lastCompleteDate.map { "Ultimo completo: \(ProtectionSummary.dateLabel($0))" } ?? ""
        default:
            return state.protection?.detail ?? ""
        }
    }

    private var progress: Double? {
        state.progressFraction
    }

    private var ringSymbol: String {
        switch state.appState {
        case .running, .stopping: return "arrow.up"
        case .restoring: return "arrow.down"
        case .diskAbsent: return "externaldrive.badge.xmark"
        case .error: return "xmark"
        default:
            switch heroLevel {
            case .protected: return "checkmark.shield.fill"
            case .attention: return "exclamationmark"
            case .unprotected: return "shield.slash"
            }
        }
    }

    private var ring: some View {
        let value = progress ?? (state.isRunning ? 0 : (heroLevel == .protected ? 1 : 0.28))
        return ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 9)
            Circle()
                .trim(from: 0, to: value)
                .stroke(AngularGradient(colors: [levelColor.opacity(0.55), levelColor], center: .center),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: levelColor.opacity(0.6), radius: 8)
            if let progress {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(Look.text)
                    .monospacedDigit()
            } else {
                Image(systemName: ringSymbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(levelColor)
            }
        }
        .frame(width: 78, height: 78)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heroHeadline)
        .accessibilityValue(progress.map { "\(Int($0 * 100))%" } ?? (state.isRunning ? state.progressDetail : heroDetail))
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                ring
                VStack(alignment: .leading, spacing: 5) {
                    Text(heroHeadline)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(Look.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if !heroDetail.isEmpty {
                        Text(heroDetail)
                            .font(.system(size: 12))
                            .foregroundColor(Look.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            if state.isRunning, let s = state.status {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(Fmt.formatFileCount(s.filesDone)) file elaborati").monospacedDigit()
                        Spacer()
                        Text(state.progressDetail)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Look.secondaryText)
                    if !s.currentFile.isEmpty {
                        Text(s.currentFile).font(.system(size: 10)).foregroundColor(Look.tertiaryText)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            } else if let p = state.protection, p.level == .protected, state.appState == .idle {
                HStack(spacing: 6) {
                    if let n = p.filesInLastComplete { stat("doc.on.doc.fill", "\(Fmt.formatFileCount(UInt64(n))) file") }
                    stat("arrow.triangle.branch", "\(p.reposWithSavedCommits) repo")
                    stat("cylinder.split.1x2.fill", "\(p.databasesSaved) database")
                }
            }
        }
        .padding(16)
        .background(glassCard(radius: 18))
    }

    private func stat(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(levelColor)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(Look.text)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private func glassCard(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Look.glass)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Look.glassStroke, lineWidth: 1))
    }

    // MARK: - Issues

    private struct Issue: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let detail: String
        let primary: (String, () -> Void)?
        let secondary: (String, () -> Void)?
    }

    private var issues: [Issue] {
        var out: [Issue] = []
        if let p = state.protection, p.latestIsIncomplete, state.appState == .idle || state.appState == .stale {
            out.append(Issue(id: "incomplete", icon: "exclamationmark.triangle.fill", tint: Look.orange,
                             title: "Ultimo backup incompleto",
                             detail: p.latestReasons.prefix(2).joined(separator: " "),
                             primary: ("Riprova", { state.onRequestBackup?() }), secondary: nil))
        }
        if let config = state.config, config.encryption.setup == nil, state.appState != .needsSetup {
            out.append(Issue(id: "encrypt", icon: "lock.open.fill", tint: Look.orange,
                             title: "Backup non cifrati",
                             detail: "Chi ha il disco può leggerli. Cifrali: poi potrai salvare anche le credenziali.",
                             primary: ("Cifra", { state.onRequestEncryption?() }), secondary: nil))
        }
        for gap in state.coverageGaps {
            out.append(Issue(id: "gap-\(gap.path)",
                             icon: gap.kind == .database ? "cylinder.split.1x2" : "folder.badge.questionmark",
                             tint: Look.blue,
                             title: gap.kind == .database ? "Database non copiato" : "Cartella non salvata",
                             detail: gap.path,
                             primary: ("Aggiungi", { state.onAddCoverage?(gap) }),
                             secondary: ("Ignora", { state.onIgnoreCoverage?(gap) })))
        }
        return out
    }

    @ViewBuilder
    private var issuesList: some View {
        let all = issues
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(showAllIssues ? all : Array(all.prefix(3))) { issue in
                    HStack(alignment: .center, spacing: 10) {
                        iconTile(issue.icon, issue.tint, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title).font(.system(size: 12, weight: .semibold)).foregroundColor(Look.text)
                            Text(issue.detail).font(.system(size: 11)).foregroundColor(Look.secondaryText)
                                .lineLimit(2).truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        if let s = issue.secondary {
                            Button(s.0, action: s.1).buttonStyle(.plain)
                                .font(.system(size: 11)).foregroundColor(Look.secondaryText)
                        }
                        if let p = issue.primary {
                            Button(action: p.1) {
                                Text(p.0).font(.system(size: 11, weight: .semibold)).foregroundColor(.black)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(issue.tint))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(glassCard(radius: 12))
                }
                if all.count > 3 {
                    Button(showAllIssues ? "Mostra meno" : "Altri \(all.count - 3) avvisi") { showAllIssues.toggle() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Look.secondaryText)
                }
            }
        }
    }

    private func iconTile(_ icon: String, _ tint: Color, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: icon).font(.system(size: size * 0.45, weight: .semibold)).foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }

    // MARK: - Timeline (last 14 days)

    private func timeline(_ p: ProtectionSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Ultimi 14 giorni").font(.system(size: 11, weight: .medium)).foregroundColor(Look.secondaryText)
                Spacer()
                Text("\(p.days.filter { $0 == .complete }.count)/14").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Look.tertiaryText).monospacedDigit()
            }
            HStack(spacing: 4) {
                ForEach(Array(p.days.enumerated()), id: \.offset) { _, day in
                    Capsule()
                        .fill(day == .complete ? Look.green : day == .incomplete ? Look.orange : Color.white.opacity(0.08))
                        .frame(height: 18)
                        .shadow(color: day == .complete ? Look.green.opacity(0.45) : .clear, radius: 4)
                }
            }
            .accessibilityLabel("\(p.days.filter { $0 == .complete }.count) giorni con un backup completo su 14")
        }
    }

    // MARK: - Cleanup, error, restore result

    private func cleanupRow(_ phase: CleanupPhase) -> some View {
        HStack(spacing: 8) {
            if phase.showsProgress { ProgressView().controlSize(.small) }
            Text(phase.label).font(.system(size: 12)).foregroundColor(Look.text)
        }
    }

    @ViewBuilder
    private var errorCard: some View {
        if let errors = loadErrors(), let top = topErrorCategory(errors) {
            HStack(alignment: .top, spacing: 10) {
                iconTile("xmark.octagon.fill", Look.red, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ErrorReporter.localizedTitle(for: top)).font(.system(size: 12, weight: .semibold)).foregroundColor(Look.text)
                    Text(ErrorReporter.suggestedAction(for: top)).font(.system(size: 11)).foregroundColor(Look.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("Mostra log") { NSWorkspace.shared.open(ErrorReporter.logURL) }
                        Button("Riprova") { state.onRequestBackup?() }
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundColor(Look.blue)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(glassCard(radius: 12))
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
        HStack(spacing: 10) {
            iconTile("checkmark", Look.green, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ripristino completato").font(.system(size: 12, weight: .semibold)).foregroundColor(Look.text)
                Text("\(result.restored) ripristinati · \(result.overwritten) sostituiti · \(result.failed) non riusciti")
                    .font(.system(size: 11)).foregroundColor(Look.secondaryText)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(glassCard(radius: 12))
    }

    // MARK: - Actions

    private func gradientButton(_ title: String, icon: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 13, weight: .bold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.black.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)))
            .shadow(color: colors.last!.opacity(0.45), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
    }

    private func glassButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(Look.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Capsule().fill(Look.glass))
            .overlay(Capsule().stroke(Look.glassStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var primaryActions: some View {
        HStack(spacing: 10) {
            switch state.appState {
            case .running:
                gradientButton("Interrompi", icon: "stop.fill", colors: [Look.red.opacity(0.85), Look.red]) { state.onRequestStop?() }
            case .stopping, .restoring:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            case .needsSetup, .diskAbsent:
                glassButton("Ripristina…", icon: "clock.arrow.circlepath") { state.onRequestRestore?() }
                    .disabled(!state.hasBackups).opacity(state.hasBackups ? 1 : 0.4)
            default:
                gradientButton("Esegui ora", icon: "arrow.up.circle.fill", colors: [Look.gold, Look.orange]) { state.onRequestBackup?() }
                glassButton("Ripristina…", icon: "clock.arrow.circlepath") { state.onRequestRestore?() }
                    .disabled(!state.hasBackups).opacity(state.hasBackups ? 1 : 0.4)
            }
        }
    }

    private struct Tile: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let enabled: Bool
        let action: () -> Void
    }

    private var tileItems: [Tile] {
        var out: [Tile] = [
            Tile(id: "Scegli cartelle", icon: "checklist", tint: Look.violet,
                 enabled: !state.isRunning && state.config != nil, action: { state.onRequestChooseSources?() }),
            Tile(id: "Pianificazione\n\(state.scheduleLabel)", icon: "clock.fill", tint: Look.blue,
                 enabled: state.onRequestScheduleMenu != nil, action: { state.onRequestScheduleMenu?() }),
            Tile(id: "Libera spazio", icon: "trash.fill", tint: Look.orange,
                 enabled: !state.isRunning && state.config != nil && state.appState != .diskAbsent,
                 action: { state.onRequestCleanupMenu?() }),
            Tile(id: "Apri cartella", icon: "folder.fill", tint: Look.green, enabled: true,
                 action: { state.onRequestOpenFolder?() }),
            Tile(id: "Espelli disco", icon: "eject.fill", tint: Color.gray, enabled: !state.isRunning && state.appState != .diskAbsent,
                 action: { state.onRequestEject?() }),
        ]
        if state.canUndo {
            out.insert(Tile(id: "Annulla ripristino", icon: "arrow.uturn.backward", tint: Look.red, enabled: true,
                            action: { state.onRequestUndoRestore?() }), at: 0)
        }
        return out
    }

    private var tiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(tileItems) { tile in
                Button(action: tile.action) {
                    VStack(spacing: 6) {
                        iconTile(tile.icon, tile.tint, size: 28)
                        Text(tile.id).font(.system(size: 10, weight: .medium)).foregroundColor(Look.text)
                            .multilineTextAlignment(.center).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 66)
                    .background(glassCard(radius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!tile.enabled)
                .opacity(tile.enabled ? 1 : 0.35)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { state.onRequestUpdateMenu?() } label: {
                HStack(spacing: 4) {
                    Image(systemName: state.autoInstallUpdates ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                    Text("v\(AutoUpdater.currentVersion) · " + (state.autoInstallUpdates ? "aggiornamenti automatici" : "aggiornamenti manuali"))
                }
                .font(.system(size: 10)).foregroundColor(Look.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Aggiornamenti")
            Spacer()
            Button { state.onRequestQuit?() } label: {
                HStack(spacing: 4) { Image(systemName: "power"); Text("Esci") }
                    .font(.system(size: 11, weight: .medium)).foregroundColor(Look.secondaryText)
            }
            .buttonStyle(.plain)
            .disabled(state.isCleaning)
        }
    }

    // MARK: - Update banner

    @ViewBuilder
    private var updateBanner: some View {
        if let version = state.updateAvailable, state.dismissedUpdateVersion != version {
            HStack(spacing: 10) {
                iconTile("arrow.down.circle.fill", Look.blue, size: 26)
                Button { state.onRequestUpdate?() } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.isUpdating ? updatePhaseLabel : "Versione \(version) disponibile")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(Look.text)
                        if !state.isUpdating {
                            Text("Installa").font(.system(size: 11)).foregroundColor(Look.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(state.isUpdating)
                Spacer()
                if state.isUpdating { ProgressView().controlSize(.small) } else {
                    Button { state.dismissedUpdateVersion = version } label: {
                        Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(Look.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ignora aggiornamento \(version)")
                }
            }
            .padding(10)
            .background(glassCard(radius: 12))
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Benvenuto").font(.system(size: 15, weight: .bold)).foregroundColor(Look.text)
            Text("Trovo da solo il tuo ambiente di sviluppo e ti faccio scegliere cosa salvare. Su un Mac nuovo, lo rimetto com'era da un backup.")
                .font(.system(size: 12)).foregroundColor(Look.secondaryText).fixedSize(horizontal: false, vertical: true)
            Button { state.onRequestOnboarding?() } label: {
                Text("Inizia").font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Look.blue))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
        }
    }


    @ViewBuilder
    private func diskButton(for vol: URL) -> some View {
        let (free, total) = DiskDiagnostics.diskSpace(at: vol.path)
        Button { state.onSelectDisk?(vol) } label: {
            HStack(spacing: 10) {
                iconTile("externaldrive.fill", Look.blue, size: 28)
                Text(vol.lastPathComponent).foregroundColor(Look.text)
                Spacer()
                if total > 0 { Text(Fmt.formatBytes(free) + " liberi").font(.system(size: 11)).foregroundColor(Look.secondaryText) }
            }
            .padding(10)
            .background(glassCard(radius: 12))
        }
        .buttonStyle(.plain)
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
