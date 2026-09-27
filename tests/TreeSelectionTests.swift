import Foundation

final class TreeSelectionTests {
    func test_protectionToggleIsIndependentAndConfirmed() throws {
        try MainActor.assumeIsolated {
            let model = TreeSelectionModel(mode: .backup)
            // Use a deterministic list after discovery; no real backup or config writes.
            model.categories = [CategoryInfo(name: "Test", items: [
                ItemInfo(paths: ["~/test"], label: "Test", sensitive: false, isConflict: false)
            ])]
            model.checkedPaths = []
            try expect(!model.includeRightsManagedFiles, "protection toggle must start off")
            model.selectAll()
            try expect(!model.includeRightsManagedFiles, "Tutti must not opt into protected files")
            try expectEqual(model.selectedPaths, ["~/test"], "Tutti must still select paths")
            model.includeRightsManagedFiles = true
            model.selectNone()
            try expect(model.includeRightsManagedFiles, "Nessuno must not change the protection preference")
            model.toggleCategory(model.categories[0])
            try expect(model.includeRightsManagedFiles, "category selection must not change the toggle")
            var confirmed = false
            model.onConfirmBackup = { paths, includeProtected in
                confirmed = paths == ["~/test"] && includeProtected
            }
            model.confirmBackup()
            try expect(confirmed, "confirmation must deliver both selected paths and protection preference")
            let reopened = TreeSelectionModel(mode: .backup, includeRightsManagedFiles: true)
            try expect(reopened.includeRightsManagedFiles, "reopened selector must reflect saved opt-in")
            reopened.selectAll()
            try expect(reopened.includeRightsManagedFiles, "Tutti must also preserve opt-in")
        }
    }

    func test_addCustomPathRejectsForbiddenPaths() throws {
        try MainActor.assumeIsolated {
            let model = TreeSelectionModel(mode: .backup)
            model.categories = []
            let before = model.categories.count
            // The "Aggiungi percorso" picker (NSOpenPanel) lets the user browse anywhere on
            // disk, including OneDrive/CloudStorage -- addCustomPath is the last line of
            // defense that must reject it before it ever appears checked in the tree.
            try expect(!model.addCustomPath("~/Library/CloudStorage/OneDrive-Microsoft/FY27"),
                       "OneDrive path must be rejected")
            try expect(!model.addCustomPath("~/Library/Mail"),
                       "any forbidden path must be rejected, not just CloudStorage")
            try expectEqual(model.categories.count, before, "rejected paths add no category/row")
            try expect(model.addCustomPath("~/Desktop/SomeFolder"), "an ordinary path must still be accepted")
            try expect(model.checkedPaths.contains("~/Desktop/SomeFolder"), "accepted path must be checked")
        }
    }
}
