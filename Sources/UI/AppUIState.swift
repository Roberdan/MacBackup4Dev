import Foundation

enum UpdatePhase {
    case downloading
    case verifying
    case installing
}

/// F-18: Shown in popover for 60s after restore completes.
struct RestoreResultSummary {
    let restored: Int
    let overwritten: Int
    let failed: Int
    let backedUpTo: String  // empty = no pre-restore backup was needed
}

/// Shared observable state consumed by all SwiftUI views.
/// All mutations must occur on the main thread (guaranteed by AppDelegate's dispatch patterns).
final class AppUIState: ObservableObject {
    @Published var appState: AppState = .idle
    @Published var status: BackupStatusFile?
    @Published var config: Config?
    @Published var scheduleLabel: String = "Off"   // human-readable current schedule
    @Published var schedule: ScheduleStatus?
    /// The disk is there and the encrypted volume is being opened (and checked, after an
    /// unclean removal): not "disk missing" (user report 2026-10-11).
    @Published var storeOpening = false
    @Published var onBattery = false
    var now: () -> Date = { Date() }

    /// When the next automatic backup starts, and what it needs to actually run.
    var nextBackupText: String? {
        guard let schedule else { return nil }
        guard schedule.installed else { return "Backup automatico disattivato" }
        guard let next = schedule.nextRun(after: now()) else {
            return schedule.intervalMinutes.map { "Backup automatico ogni \($0) min" }
        }
        let text = "Prossimo backup automatico: \(ProtectionSummary.dateLabel(next).replacingOccurrences(of: "oggi ", with: "oggi alle "))"
        if appState == .diskAbsent && !storeOpening { return text + ", se colleghi il disco" }
        if onBattery { return text + ", solo con l'alimentatore collegato (ora sei a batteria)" }
        return text
    }
    /// nil = no cleanup; otherwise the current phase, shown in place of the status line.
    @Published var cleanupPhase: CleanupPhase?
    var isCleaning: Bool { cleanupPhase != nil }
    @Published var ejection: EjectionFeedback?
    var isEjecting: Bool { ejection?.phase.isBusy == true }

    func dismissEjection() {
        guard !isEjecting else { return }
        ejection = nil
    }

    func reconcileEjection(diskMounted: Bool) {
        if ejection?.phase == .succeeded && diskMounted { ejection = nil }
        // A refusal is stale once the disk is gone (ejected another way): drop it, so the
        // encrypted store opens again normally when the disk comes back.
        if case .failed = ejection?.phase, !diskMounted { ejection = nil }
    }

    /// Non-nil when a newer version is available on GitHub.
    @Published var updateAvailable: String?
    /// True while downloading + installing an update.
    @Published var isUpdating: Bool = false
    /// Current update installation phase — nil when not updating.
    @Published var updatePhase: UpdatePhase?
    /// Non-nil when an update version was dismissed by user.
    @Published var dismissedUpdateVersion: String?
    /// Mirrors AutoUpdater.autoInstall for the footer label.
    @Published var autoInstallUpdates: Bool = true
    var onRequestUpdateMenu: (() -> Void)?
    var onRequestOnboarding: (() -> Void)?
    var onRequestEncryption: (() -> Void)?

    // MARK: - 3.0: protection and coverage (computed by AppDelegate, never while rendering)
    @Published var protection: ProtectionSummary?
    @Published var coverageGaps: [CoverageGap] = []
    var onAddCoverage: ((CoverageGap) -> Void)?
    var onIgnoreCoverage: ((CoverageGap) -> Void)?
    var onRequestAdvancedRestore: (() -> Void)?
    var onRequestShowSnapshot: (() -> Void)?
    var onRequestChooseSources: (() -> Void)?

    // MARK: - Restore result (F-18)
    @Published var restoreResult: RestoreResultSummary?

    // MARK: - Cached disk state (F-19) — updated by pollStatus(), not computed on render
    @Published var cachedHasBackups: Bool = false
    @Published var cachedBackupAccessible: Bool = false
    @Published var cachedCanUndo: Bool = false

    // MARK: - Action callbacks — set by AppDelegate before popover is shown

    var onRequestBackup: (() -> Void)?
    var onRequestRestore: (() -> Void)?
    var onRequestStop: (() -> Void)?
    var onRequestEject: (() -> Void)?
    var onRequestOpenFolder: (() -> Void)?
    var onRequestQuit: (() -> Void)?
    var onSelectDisk: ((URL) -> Void)?
    var onRequestUndoRestore: (() -> Void)?
    var onRequestUpdate: (() -> Void)?
    /// nil = disable, >0 = intervalMinutes, <0 = daily at abs(value):00
    var onSetSchedule: ((Int?) -> Void)?
    var onRequestScheduleMenu: (() -> Void)?
    var onRequestCleanupMenu: (() -> Void)?

    // MARK: - Computed helpers

    var isRunning: Bool { appState == .running || appState == .restoring || appState == .stopping }

    var canRefreshBackupProgress: Bool {
        appState == .running && !isCleaning && !isEjecting
    }

    var backupFileActivity: (name: String, directory: String, path: String)? {
        guard appState == .running, let status, status.state == "running",
              status.phase == "scanning" || status.phase == "copying",
              status.filesDone > 0, !status.currentFile.isEmpty else { return nil }
        let path = status.currentFile as NSString
        return (path.lastPathComponent, path.deletingLastPathComponent, status.currentFile)
    }

    var progressFraction: Double? {
        guard let status else { return nil }
        if appState == .running { return status.progressFraction }
        if appState == .restoring, status.filesTotal > 0 {
            return min(1, Double(status.filesDone) / Double(status.filesTotal))
        }
        return nil
    }

    var progressDetail: String {
        if appState == .restoring { return "Ripristino dei file" }
        if appState == .stopping { return "Chiusura in corso" }
        guard appState == .running else { return "" }
        return status?.progressDetail ?? ""
    }

    var backupHeadline: String {
        if appState == .running {
            return status?.phase == "finalizing" ? "Backup: fase finale" : "Backup in corso"
        }
        if status?.state == "cancelled" { return "Backup interrotto" }
        return protection?.level == .protected ? "Backup completato" : (protection?.headline ?? "Nessun backup")
    }

    var backupDetail: String {
        if appState == .running {
            let start = status.flatMap { ISO8601DateFormatter().date(from: $0.startedAt) }
                .map { "Avviato \(ProtectionSummary.dateLabel($0)). " } ?? ""
            return start + "Ancora in corso. Non scollegare il disco."
        }
        if status?.state == "cancelled" {
            return "L'ultimo tentativo è stato interrotto. Nessun backup in corso."
        }
        guard let protection, protection.level == .protected else { return protection?.detail ?? "" }
        var finished = protection.lastCompleteFinishedDate
        if let status, status.state == "idle", status.lastResult == "complete",
           let snapshot = protection.lastComplete, status.lastSnapshot == snapshot,
           let date = status.lastCompleteAt.flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            finished = date
        }
        let date = finished.map { "Terminato \(ProtectionSummary.dateLabel($0))" }
            ?? protection.lastCompleteDate.map { "Avviato \(ProtectionSummary.dateLabel($0))" }
            ?? ""
        return date.isEmpty ? "Nessun backup in corso." : "\(date). Nessun backup in corso."
    }

    // F-19: hasBackups and canUndo are now cached — no disk I/O on SwiftUI render
    var canOpenBackupFolder: Bool {
        config != nil && cachedBackupAccessible && appState != .diskAbsent && appState != .needsSetup
            && !storeOpening && !isCleaning && !isEjecting && ejection?.phase != .succeeded
    }

    var hasBackups: Bool { cachedHasBackups && canOpenBackupFolder }
    var canRestore: Bool { hasBackups && !isRunning }
    var canUndo: Bool { cachedCanUndo }
}

enum CleanupPhase {
    case reading, awaitingConfirmation, deleting

    var label: String {
        switch self {
        case .reading: return "Controllo vecchi backup…"
        case .awaitingConfirmation: return "Pulizia: in attesa di conferma"
        case .deleting: return "Eliminazione vecchi backup…"
        }
    }

    var showsProgress: Bool { self != .awaitingConfirmation }
}
