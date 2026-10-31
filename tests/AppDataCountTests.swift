import Foundation

/// Scar 2026-10-31: after the update the menu kept asking "1 percorso non salvato / Scegli dati" with
/// everything selected, because the status file still held the count the old rule had made.
final class AppDataCountTests {
    private func menuState(_ f: AppTestFixture) -> AppUIState {
        let state = AppUIState()
        state.status = StatusWriter(directory: f.box.state).read()
        return state
    }

    func test_anOldCountOfOneWithNothingLeftToChooseIsNotShown() throws {
        let f = try AppTestFixture(); defer { f.cleanup() }
        try f.app("Itself.app", identifier: AppIdentity.bundleID)
        try f.write("settings", f.box.home + "/Library/Preferences/\(AppIdentity.bundleID).plist")
        let result = try f.backup()
        let catalog = try AppCapture.read(from: result.snapshot)!
        try expect(catalog.entries.first { $0.bundleID == AppIdentity.bundleID }?.data.contains { $0.state == .notSelected } == true,
                   "fixture: this app's own data is there, not selected")
        try expect(AppCapture.dataToChoose(in: catalog.entries).isEmpty, "fixture: nothing is left to choose")
        try expect(AppInventory.dataCandidates(home: f.box.home, roots: f.roots).flatMap(\.paths).isEmpty,
                   "fixture: the picker offers nothing either")

        // What the previous version left in the status file: the app's own data counted as "to choose".
        let writer = StatusWriter(directory: f.box.state)
        guard var old = writer.read() else { throw TestFailure.failed("the backup wrote a status") }
        old.applications = AppCapture.Summary(saved: 0, needsInstaller: 0, failed: 0, unselectedDataPaths: 1)
        try writer.write(status: old)
        let json = try String(contentsOfFile: writer.statusPath, encoding: .utf8)
        try expect(json.contains("unselectedDataPaths") && !json.contains("dataCountRule"), "fixture: the file has the old shape")
        let before = menuState(f)
        try expectEqual(before.status?.applications?.unselectedDataPaths, 1, "fixture: the old count is read back")
        try expectEqual(before.appDataToChoose, 0, "the menu does not ask for what cannot be chosen")

        _ = try f.backup()
        let after = menuState(f)
        try expectEqual(after.status?.applications?.dataCountRule, AppCapture.dataCountRule,
                        "the next backup counts again, by the current rule")
        try expectEqual(after.appDataToChoose, 0, "and it still has nothing to ask")
    }

    func test_dataThatCanReallyBeChosenIsStillAsked() throws {
        let f = try AppTestFixture(); defer { f.cleanup() }
        try f.app("Shoji.app", identifier: "com.example.shoji")
        try f.write("settings", f.box.home + "/Library/Preferences/com.example.shoji.plist")
        _ = try f.backup()
        let state = menuState(f)
        let offered = Set(AppInventory.dataCandidates(home: f.box.home, roots: f.roots).flatMap(\.paths))
        try expect(offered.contains("~/Library/Preferences/com.example.shoji.plist"), "fixture: the picker offers it")
        try expectEqual(state.appDataToChoose, offered.count, "the menu asks exactly for what the picker offers")
        try expectEqual(state.appDataToChoose, 1, "and that is the one path")
    }
}
