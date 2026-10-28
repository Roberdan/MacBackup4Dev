import Foundation

/// Re-registers the existing launchd schedule after an app update: once per launch, only
/// while the app is idle, retried later while a backup is busy or the disk is offline.
/// Calling `run()` again after it finished, or while a retry is pending, does nothing.
@MainActor
final class ScheduleRegistrationRefresher {
    enum Outcome { case refreshed, deferred, notNeeded }

    static let retryDelay: TimeInterval = 300

    private let isBusy: () -> Bool
    private let refresh: () throws -> Outcome
    private let scheduleRetry: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    private let updateScheduleLabel: () -> Void
    private let reportFailure: (_ readable: String, _ error: Error) -> Void
    private let onFinished: () -> Void
    private var retryPending = false
    private(set) var finished = false

    init(isBusy: @escaping () -> Bool,
         refresh: @escaping () throws -> Outcome,
         scheduleRetry: @escaping (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void,
         updateScheduleLabel: @escaping () -> Void,
         reportFailure: @escaping (_ readable: String, _ error: Error) -> Void,
         onFinished: @escaping () -> Void) {
        self.isBusy = isBusy
        self.refresh = refresh
        self.scheduleRetry = scheduleRetry
        self.updateScheduleLabel = updateScheduleLabel
        self.reportFailure = reportFailure
        self.onFinished = onFinished
    }

    func run() {
        guard !finished, !retryPending else { return }
        guard !isBusy() else { return retryLater() }
        do {
            switch try refresh() {
            case .deferred: return retryLater()
            case .refreshed: updateScheduleLabel()
            case .notNeeded: break
            }
        } catch BackupError.lockExists {
            return retryLater()
        } catch {
            // The schedule may now be unloaded: show what launchd really has.
            updateScheduleLabel()
            reportFailure(ScheduleManager.registrationRefreshFailureMessage, error)
        }
        finished = true
        onFinished()
    }

    private func retryLater() {
        retryPending = true
        scheduleRetry(Self.retryDelay) { [weak self] in
            self?.retryPending = false
            self?.run()
        }
    }
}
