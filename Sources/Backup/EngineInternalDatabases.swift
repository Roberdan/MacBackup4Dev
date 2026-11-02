import Foundation

/// Databases a browser engine (Chromium, Edge, Electron apps) keeps for its own telemetry and
/// tuning, inside a profile. They are not the user's data, and the running app holds them locked,
/// so `sqlite3 .backup` fails on them every time and makes the snapshot "incomplete"
/// (2026-11-02: Copilot's declarative_performance_observer.db). Only these known names, only
/// inside a Chromium/Electron profile: any other database stays a real one, and a real one
/// that is locked is still an error.
enum EngineInternalDatabases {
    static let fileNames: Set<String> = [
        "declarative_performance_observer.db",
        "heavy_ad_intervention_opt_out.db",
        "load_statistics.db",
        "edgehubappusagesqlite.db",
        "edgehubappusagesqlite.db-journal",
        "persisted_state.db",
        "page_load_metrics.db",
        "browsermetrics.db",
    ]

    static func isInternal(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let name = components.last, fileNames.contains(name.lowercased()) else { return false }
        return components.dropLast().contains(where: isProfileFolder)
            || (components.contains("Application Support") && components.count > 3)
    }

    /// Chromium names its profiles Default, Profile N, Guest Profile and System Profile.
    private static func isProfileFolder(_ name: String) -> Bool {
        if name == "Default" || name == "Guest Profile" || name == "System Profile" { return true }
        guard name.hasPrefix("Profile ") else { return false }
        let number = name.dropFirst("Profile ".count)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }
}
