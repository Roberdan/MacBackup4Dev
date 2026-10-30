import Foundation

/// The chronological restore browser, against real snapshot folders in a sandbox.
final class SnapshotBrowserTests {
    let safety = SafetyTests()
    let older = "2026-10-10_090000"
    let middle = "2026-10-11_090000"
    let newest = "2026-10-12_090000"

    private func wait(_ model: SnapshotBrowserModel) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if !model.busy { RunLoop.current.run(until: Date().addingTimeInterval(0.01)); if !model.busy { return } }
        }
        throw TestFailure.failed("browser model never became idle")
    }

    private func makeModel(_ box: SafetyTests.Sandbox, _ dest: URL) throws -> SnapshotBrowserModel {
        let model = SnapshotBrowserModel(destination: dest, home: box.home,
                                         undoRoot: box.root.appendingPathComponent("undo"))
        model.load()
        try wait(model)
        return model
    }

    func test_timeTravelKeepsFolderAndRestoresDeletedFile() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let dest = URL(fileURLWithPath: box.dest)
        for name in [older, middle, newest] { try safety.makeSnapshot(dest, name, complete: true) }
        try safety.makeSnapshot(dest, "2026-10-13_090000", complete: false)
        try safety.write("v1", to: dest.path + "/\(older)/Documents/work/notes.txt")
        try safety.write("gone", to: dest.path + "/\(older)/Documents/work/deleted.txt")
        try safety.write("v2", to: dest.path + "/\(middle)/Documents/work/notes.txt")
        try safety.write("v3", to: dest.path + "/\(newest)/Documents/work/notes.txt")

        let model = try makeModel(box, dest)
        try expectEqual(model.snapshots.map(\.name), [newest, middle, older], "only complete snapshots, newest first")
        try expectEqual(model.current?.name, newest, "an incomplete newest snapshot is never shown")
        try expect(!model.entries.contains { $0.name.hasPrefix("_") }, "internal snapshot metadata is not listed")
        try expect(model.entries.contains { $0.name == "Documents" }, "the root lists real content")

        model.open("Documents"); try wait(model)
        model.open("Documents/work"); try wait(model)
        try expectEqual(model.entries.map(\.name), ["notes.txt"], "the newest snapshot lacks the deleted file")
        model.goOlder(); try wait(model)
        model.goOlder(); try wait(model)
        try expectEqual(model.directory, "Documents/work", "the folder is kept when the date changes")
        try expectEqual(model.current?.name, older, "moved two snapshots back")
        try expectEqual(Set(model.entries.map(\.name)), ["notes.txt", "deleted.txt"], "the deleted file is there")
        try expectEqual(model.page?.motion, .older, "going back is a deeper-in-time move")

        model.select("Documents/work/deleted.txt")
        model.goNewer(); try wait(model)
        try expectNil(model.selected, "a selection that does not exist on that date is dropped")
        try expect(model.message.contains("non c'è"), "and the person is told: \(model.message)")
        model.goOlder(); try wait(model)
        model.select("Documents/work/deleted.txt")
        model.restoreToFolder = false
        model.preview(); try wait(model)
        try expectEqual(model.plan?.toCreate, 1, "preview says one new file")
        try expectEqual(model.plan?.destinationRoot, box.home, "the sandbox home is the destination")
        model.restore(); try wait(model)
        try expect(!model.messageIsError, "restore reports success: \(model.message)")
        try expectEqual(try String(contentsOfFile: box.home + "/Documents/work/deleted.txt", encoding: .utf8), "gone",
                        "the deleted file comes back with its contents")
        model.undo(); try wait(model)
        try expect(!FileManager.default.fileExists(atPath: box.home + "/Documents/work/deleted.txt"), "undo removes it")
    }

    func test_folderRestoreIsRecursiveAndUndoable() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let dest = URL(fileURLWithPath: box.dest)
        try safety.makeSnapshot(dest, older, complete: true)
        try safety.makeSnapshot(dest, newest, complete: true)
        try safety.write("old a", to: dest.path + "/\(older)/proj/a.txt")
        try safety.write("old deep", to: dest.path + "/\(older)/proj/sub/deep/b.txt")
        try safety.write("junk", to: dest.path + "/\(older)/proj/.DS_Store")
        try FileManager.default.createDirectory(atPath: dest.path + "/\(older)/proj/empty", withIntermediateDirectories: true)
        try safety.write("today", to: box.home + "/proj/a.txt")

        let model = try makeModel(box, dest)
        model.goOlder(); try wait(model)
        model.open("proj"); try wait(model)
        try expectEqual(model.target, "proj", "an open folder with nothing selected restores the folder")
        model.restoreToFolder = false
        model.preview(); try wait(model)
        try expectEqual(model.plan?.toReplace, 1, "the changed file is a replacement")
        try expectEqual(model.plan?.toCreate, 1, "the nested file is new; junk and empty folders add nothing")
        model.restore(); try wait(model)
        try expect(!model.messageIsError, "folder restore succeeds: \(model.message)")
        try expectEqual(try String(contentsOfFile: box.home + "/proj/a.txt", encoding: .utf8), "old a", "replaced")
        try expectEqual(try String(contentsOfFile: box.home + "/proj/sub/deep/b.txt", encoding: .utf8), "old deep", "nested")
        model.undo(); try wait(model)
        try expect(!model.messageIsError, "undo succeeds: \(model.message)")
        try expectEqual(try String(contentsOfFile: box.home + "/proj/a.txt", encoding: .utf8), "today", "undo puts the old file back")
        try expect(!FileManager.default.fileExists(atPath: box.home + "/proj/sub/deep/b.txt"), "undo removes created files")

        model.open("proj/empty"); try wait(model)
        try expect(model.entries.isEmpty, "an empty folder lists nothing")
        model.preview(); try wait(model)
        try expectEqual(model.plan?.items.count, 0, "nothing to restore from an empty folder")
        try expect(model.messageIsError, "and it is said plainly, not reported as success")
    }

    func test_linksAndTraversalNeverLeaveTheSnapshot() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let dest = URL(fileURLWithPath: box.dest)
        try safety.makeSnapshot(dest, newest, complete: true)
        let snap = dest.appendingPathComponent(newest)
        try safety.write("secret", to: box.root.path + "/outside/secret.txt")
        try safety.write("real", to: snap.path + "/Documents/real.txt")
        try safety.write("agent", to: snap.path + "/Library/LaunchAgents/x.plist")
        try FileManager.default.createSymbolicLink(atPath: snap.path + "/Documents/filelink",
                                                   withDestinationPath: box.root.path + "/outside/secret.txt")
        try FileManager.default.createSymbolicLink(atPath: snap.path + "/Documents/dirlink",
                                                   withDestinationPath: box.root.path + "/outside")

        let entries = try SnapshotBrowsing.list(snapshot: snap, directory: "Documents")
        try expectEqual(entries.first { $0.name == "dirlink" }?.kind, .link, "a folder link is not a folder")
        try expectEqual(entries.first { $0.name == "filelink" }?.kind, .link, "a file link is not a file")
        for bad in ["Documents/dirlink", "../outside", "Documents/../../outside", "_rustymacbackup", "_environment", "/etc"] {
            do { _ = try SnapshotBrowsing.list(snapshot: snap, directory: bad); throw TestFailure.failed("listed \(bad)") }
            catch is CocoaError { }
        }
        try expectEqual(SnapshotBrowsing.restorableFiles(snapshot: snap, relative: "Documents/dirlink").files, [], "no walking through a folder link")
        try expectEqual(SnapshotBrowsing.restorableFiles(snapshot: snap, relative: "Documents/dirlink/secret.txt").files, [], "no file behind a link")
        try expectEqual(SnapshotBrowsing.restorableFiles(snapshot: snap, relative: "Documents/filelink").files, [], "a file link is not restored")
        try expectEqual(SnapshotBrowsing.restorableFiles(snapshot: snap, relative: "Documents").files, ["Documents/real.txt"], "a folder restores only real files")
        try expectEqual(SnapshotBrowsing.restorableFiles(snapshot: snap, relative: "_rustymacbackup").files, [], "metadata is not restorable")
        let launch = SnapshotBrowsing.restorableFiles(snapshot: snap, relative: "Library")
        try expectEqual(launch.files, [], "login items are not restored")
        try expectEqual(launch.skippedLoginSensitive, 1, "and they are counted for the preview")

        let model = try makeModel(box, dest)
        model.open("Documents"); try wait(model)
        model.open("Documents/dirlink"); try wait(model)
        try expectEqual(model.directory, "Documents", "a folder link cannot be opened")
        model.select("Documents/filelink")
        try expectNil(model.selected, "a link cannot be selected for restore")
        model.restoreToFolder = false
        model.preview(); try wait(model)
        model.restore(); try wait(model)
        try expect(!FileManager.default.fileExists(atPath: box.home + "/Documents/dirlink"), "nothing came through the link")
        try expect(!FileManager.default.fileExists(atPath: box.home + "/Documents/filelink"), "no link target copied")
        try expectEqual(try String(contentsOfFile: box.home + "/Documents/real.txt", encoding: .utf8), "real", "real content restored")
    }

    func test_onlyIncompleteHistoryOffersNothing() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let dest = URL(fileURLWithPath: box.dest)
        try safety.makeSnapshot(dest, newest, complete: false)
        try safety.makeSnapshot(dest, older, complete: nil)
        let model = try makeModel(box, dest)
        try expect(model.loaded && model.snapshots.isEmpty, "incomplete and unverified snapshots are not browsable")
        try expectNil(model.current, "no current snapshot")
    }
}
