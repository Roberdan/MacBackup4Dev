import Foundation

enum CleanupAge: Int, CaseIterable {
    case oneMonth = 1
    case sixMonths = 6
    case oneYear = 12

    var label: String {
        switch self {
        case .oneMonth: return "1 mese"
        case .sixMonths: return "6 mesi"
        case .oneYear: return "1 anno"
        }
    }

    func cutoff(from now: Date, calendar: Calendar = .current) -> Date {
        // All cases are fixed, valid calendar-month offsets.
        calendar.date(byAdding: .month, value: -rawValue, to: now)!
    }
}

struct CleanupResult {
    let deleted: [String]
    /// Measured free-space gain on the volume; shared hard-linked data frees nothing.
    let freedBytes: UInt64
    let freeAfterBytes: UInt64
}

/// Holds the destination lock from preview until cancellation or execution.
final class SnapshotCleanup {
    let destination: URL
    let cutoff: Date
    let candidates: [BackupEntry]
    let latest: BackupEntry?
    private let lock: DestinationLock
    private let snapshotNames: Set<String>?

    convenience init(at destination: URL, age: CleanupAge, now: Date = Date()) throws {
        try self.init(at: destination, cutoff: age.cutoff(from: now))
    }

    init(at destination: URL, cutoff: Date, snapshotNames: Set<String>? = nil) throws {
        try RetentionManager.validateDestination(destination)
        let lock = try DestinationLock(at: destination)
        let backups = try RetentionManager.readBackups(at: destination)
        self.destination = destination
        self.cutoff = cutoff
        self.latest = backups.first
        let protected = RetentionManager.protectedNames(backups, fillWithUnverified: false)
        let eligible = backups.dropFirst().filter { $0.timestamp < cutoff && !protected.contains($0.name) }
        if let snapshotNames {
            guard !snapshotNames.isEmpty, snapshotNames.isSubset(of: Set(eligible.map(\.name))) else {
                throw NSError(domain: "SnapshotCleanup", code: 3, userInfo: [
                    NSLocalizedDescriptionKey:
                        "I backup scelti devono esistere, essere più vecchi del limite e non essere protetti."
                ])
            }
        }
        self.candidates = eligible.filter { snapshotNames?.contains($0.name) ?? true }
        self.snapshotNames = snapshotNames
        self.lock = lock
    }

    var freeBytes: UInt64 { BackupEngine.diskFreeSpace(at: destination.path) }

    func execute() throws -> CleanupResult {
        try withExtendedLifetime(lock) {
            try RetentionManager.validateDestination(destination)
            let current = try RetentionManager.readBackups(at: destination)
            let protected = RetentionManager.protectedNames(current, fillWithUnverified: false)
            let eligible = current.dropFirst().filter {
                $0.timestamp < cutoff && !protected.contains($0.name)
                    && (snapshotNames?.contains($0.name) ?? true)
            }.map(\.name)
            guard eligible == candidates.map(\.name) else {
                throw NSError(domain: "SnapshotCleanup", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "I backup sono cambiati. Ripeti l'anteprima prima di eliminare."
                ])
            }
            let before = freeBytes
            let deleted = try RetentionManager.deleteBackups(candidates, at: destination)
            let after = freeBytes
            return CleanupResult(deleted: deleted, freedBytes: after > before ? after - before : 0,
                                 freeAfterBytes: after)
        }
    }
}
