import Foundation

/// Retries a pending automatic update the moment the disk falls quiet. An update found during
/// a backup is put off, and the hourly tick alone kept finding the next backup running
/// (2026-11-02: hourly backups of 30–60 minutes kept 4.3.6 waiting until the app was restarted).
///
/// Fed at every status poll (30 s), it installs once on the step from busy to quiet: a backup
/// that completed or was stopped, a restore, a cleanup, a compaction. Never while busy, never
/// twice for the same quiet spell, so a failed download is not retried every poll.
/// The app's own update is not "busy" here: its failure must not count as a backup ending.
final class UpdateRetryGate {
    private var wasBusy = false
    private let install: (String) -> Void

    init(install: @escaping (String) -> Void) {
        self.install = install
    }

    func observe(busy: Bool, pending: String?, allowed: Bool, rejected: String?) {
        defer { wasBusy = busy }
        guard wasBusy, !busy, allowed, let pending, pending != rejected else { return }
        Log.info("Disk quiet again: installing pending update \(pending)")
        install(pending)
    }
}

/// Set (main thread) once the last check before replacing the app has passed: the relaunch
/// quits the app in seconds, so no window may start writing in between.
enum AppReplacement {
    static var inProgress = false
}

/// What keeps the disk or the user's files busy, for updates and compaction. The polled backup
/// state alone is not enough: it reads idle during an in-app restore (no lock file), and the
/// "Ripristina" window restores on its own.
struct DiskActivity {
    var polledBusy = false          // backup running/stopping, tree restore state
    var lockHolderAlive = false     // a backup in any process holds the destination lock
    var maintenance = false         // cleanup, ejection, recovery copy, compaction, store opening
    var restoresInFlight = 0        // tree restore and undo started by the app
    var restoreWindowBusy = false   // "Ripristina" window: file, folder, new-Mac stages, undo
    var setupWindowOpen = false     // encryption migration or first-launch adoption may be copying

    var isBusy: Bool {
        polledBusy || lockHolderAlive || maintenance || restoresInFlight > 0 || restoreWindowBusy || setupWindowOpen
    }
}
