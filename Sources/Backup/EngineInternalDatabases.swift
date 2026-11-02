import Foundation

/// Databases a browser engine (Chromium, Edge, Electron apps) keeps for its own telemetry and
/// tuning, inside a profile. They are not the user's data, and the running app holds them locked,
/// so `sqlite3 .backup` fails on them every time and makes the snapshot "incomplete"
/// (2026-11-02: Copilot's declarative_performance_observer.db). Only these known names, only
/// inside a Chromium/Electron profile (a profile folder next to `Local State`): any other database stays a real one, and a real one
/// that is locked is still an error.
enum EngineInternalDatabases {
    static let fileNames: Set<String> = [
        "declarative_performance_observer.db",
        "heavy_ad_intervention_opt_out.db",
        "load_statistics.db",
        "edgehubappusagesqlite.db",
        "persisted_state.db",
        "page_load_metrics.db",
        "browsermetrics.db",
    ]

    /// The path must be absolute and plain, sit in a profile folder, and the profile's parent
    /// must hold Chromium's `Local State` file: a folder that merely is called "Default" is not enough.
    static func isInternal(_ path: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              let name = components.last, fileNames.contains(name.lowercased()),
              let profile = components.dropLast().lastIndex(where: isProfileFolder), profile > 0 else { return false }
        let userData = "/" + components[..<profile].joined(separator: "/")
        return fileExists(userData + "/Local State")
    }

    /// Chromium names its profiles Default, Profile N, Guest Profile and System Profile.
    private static func isProfileFolder(_ name: String) -> Bool {
        if name == "Default" || name == "Guest Profile" || name == "System Profile" { return true }
        guard name.hasPrefix("Profile ") else { return false }
        let number = name.dropFirst("Profile ".count)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }
}
