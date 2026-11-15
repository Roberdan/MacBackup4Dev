import Foundation

struct PruneOptions {
    var age: CleanupAge?
    var days: Int?
    var snapshotNames: Set<String> = []
    var confirmed = false

    func cutoff(from now: Date) -> Date? {
        if let days { return now.addingTimeInterval(-TimeInterval(days) * 86_400) }
        return age?.cutoff(from: now)
    }

    static func parse(_ arguments: [String]) throws -> PruneOptions {
        var options = PruneOptions()
        var dryRun = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--older-than":
                index += 1
                guard options.age == nil, options.days == nil, index < arguments.count else { throw invalidArguments() }
                switch arguments[index] {
                case "7d": options.days = 7
                case "1m": options.age = .oneMonth
                case "6m": options.age = .sixMonths
                case "1y": options.age = .oneYear
                default: throw invalidArguments()
                }
            case "--yes": options.confirmed = true
            case "--dry-run": dryRun = true
            case "--snapshot":
                index += 1
                guard index < arguments.count,
                      RetentionManager.parseBackupName(arguments[index]) != nil,
                      options.snapshotNames.insert(arguments[index]).inserted else { throw invalidArguments() }
            default: throw invalidArguments()
            }
            index += 1
        }
        guard !(dryRun && options.confirmed) else { throw invalidArguments() }
        guard options.snapshotNames.isEmpty || options.age != nil || options.days != nil else {
            throw invalidArguments()
        }
        return options
    }

    private static func invalidArguments() -> NSError {
        NSError(domain: AppIdentity.name, code: 1, userInfo: [
            NSLocalizedDescriptionKey:
                "Usage: prune [--older-than 7d|1m|6m|1y] [--snapshot NAME ...] [--dry-run | --yes]"
        ])
    }
}
