import AppKit

/// Debug-only: `MacBackup4Dev relaunch-test` exercises the real post-update relaunch:
/// starts a new instance of the installed app through LaunchServices exactly like
/// AutoUpdater.relaunch, then exits. Afterwards exactly one menu-bar instance must run.
extension CLIHandler {
    @MainActor
    static func relaunchTest() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let app = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/Applications/\(AppIdentity.name).app")
        let me = ProcessInfo.processInfo.processIdentifier
        let before = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleID)
            .map(\.processIdentifier).filter { $0 != me }
        print("prima: \(before)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        var done = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { launched, error in
            print(error.map { "errore: \($0.localizedDescription)" } ?? "avviata: pid \(launched?.processIdentifier ?? 0)")
            done = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        RunLoop.main.run(until: Date().addingTimeInterval(8))
        let after = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleID)
            .filter { !$0.isTerminated }.map(\.processIdentifier).filter { $0 != me }
        print("dopo: \(after) → \(after.count == 1 ? (before.contains(after[0]) ? "OK: una sola copia (la vecchia era al lavoro)" : "OK: una sola copia, quella nuova") : "DA CONTROLLARE: \(after.count) copie")")
    }
}
