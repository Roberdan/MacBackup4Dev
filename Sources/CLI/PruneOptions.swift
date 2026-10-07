import Foundation

struct PruneOptions {
    var age: CleanupAge?
    var confirmed = false

    static func parse(_ arguments: [String]) throws -> PruneOptions {
        var options = PruneOptions()
        var dryRun = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--older-than":
                index += 1
                guard options.age == nil, index < arguments.count else { throw invalidArguments() }
                switch arguments[index] {
                case "1m": options.age = .oneMonth
                case "6m": options.age = .sixMonths
                case "1y": options.age = .oneYear
                default: throw invalidArguments()
                }
            case "--yes": options.confirmed = true
            case "--dry-run": dryRun = true
            default: throw invalidArguments()
            }
            index += 1
        }
        guard !(dryRun && options.confirmed) else { throw invalidArguments() }
        return options
    }

    private static func invalidArguments() -> NSError {
        NSError(domain: AppIdentity.name, code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Usage: prune [--older-than 1m|6m|1y] [--dry-run | --yes]"
        ])
    }
}
