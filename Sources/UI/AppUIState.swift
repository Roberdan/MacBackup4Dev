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
    /// nil = no cleanup; otherwise the current phase, shown in place of the status line.
    @Published var cleanupPhase: CleanupPhase?
    var isCleaning: Bool { cleanupPhase != nil }

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

    // F-19: hasBackups and canUndo are now cached — no disk I/O on SwiftUI render
    var hasBackups: Bool { cachedHasBackups }
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
