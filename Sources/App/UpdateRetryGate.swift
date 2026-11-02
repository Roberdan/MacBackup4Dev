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
