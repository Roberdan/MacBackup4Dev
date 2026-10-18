import Foundation
import Darwin

final class BackupOptimizationTests {
    func test_backgroundPolicyNeverRaisesExistingPriority() throws {
        try expectEqual(BackupEngine.WORK_PRIORITY, .background, "All backup callers share background priority")
        try expectEqual(BackupEngine.MAX_WORKERS, 4, "Copy concurrency is bounded conservatively")
        for previous in [IOPOL_DEFAULT, IOPOL_STANDARD, IOPOL_UTILITY] {
            try expectEqual(IOPriority.backupPolicy(onBattery: false, previous: previous), IOPOL_UTILITY,
                            "AC does not mean foreground I/O")
        }
        for previous in [IOPOL_PASSIVE, IOPOL_THROTTLE] {
            try expectEqual(IOPriority.backupPolicy(onBattery: false, previous: previous), previous,
                            "Keep stricter scheduled priority")
        }
        try expectEqual(IOPriority.backupPolicy(onBattery: true, previous: IOPOL_DEFAULT), IOPOL_THROTTLE,
                        "Battery keeps throttling")
    }

    func test_diskPolicyUsesSDKAndRestores() throws {
        let previous = try IOPriority.beginBackup(onBattery: false)
        var failure: Error?
        do {
            try expectEqual(getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS),
                            IOPriority.backupPolicy(onBattery: false, previous: previous),
                            "Real process policy uses the disk constant")
        } catch { failure = error }
        try IOPriority.setDiskPolicy(previous)
        try expectEqual(getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS), previous,
                        "Previous process policy restored")
        if let failure { throw failure }
    }

    func test_directoryPreparationIsConcurrentAndRunScoped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = BackupDirectories()
        let path = root.appendingPathComponent("snapshot/nested").path
        let failures = ResultBox<[Error]>()
        failures.value = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do { try directories.prepare(path) }
            catch { lock.withLock { failures.value?.append(error) } }
        }
        try expectEqual(failures.value?.count, 0, "Concurrent directory preparation succeeds")
        try FileManager.default.removeItem(atPath: path)
        let nextRun = BackupDirectories()
        try nextRun.prepare(path)
        try expect(FileManager.default.fileExists(atPath: path), "A new run never trusts an old directory cache")
    }

    func test_directoryFailuresAreNotCached() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        try "file".write(to: parent, atomically: true, encoding: .utf8)
        let directories = BackupDirectories()
        let path = parent.appendingPathComponent("child").path
        var refused = false
        do { try directories.prepare(path) }
        catch { refused = true }
        try expect(refused, "File-directory conflict is reported")
        try FileManager.default.removeItem(at: parent)
        try directories.prepare(path)
        try expect(FileManager.default.fileExists(atPath: path), "A failed preparation never poisons the cache")
    }

    func test_copyRecreatesRemovedCachedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try "keep this".write(to: source, atomically: true, encoding: .utf8)
        let parent = root.appendingPathComponent("snapshot/nested")
        let directories = BackupDirectories()
        try directories.prepare(parent.path)
        try FileManager.default.removeItem(at: parent)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let size = attributes[.size] as? UInt64, let mtime = attributes[.modificationDate] as? Date else {
            throw TestFailure.failed("Source metadata missing")
        }
        let result = ResultBox<FileResult>()
        let done = DispatchSemaphore(value: 0)
        let destination = parent.appendingPathComponent("saved.txt")
        Task {
            result.value = await BackupEngine.processFile(
                entry: FileEntry(relativePath: "source.txt", absolutePath: source.path, size: size, mtime: mtime),
                destFile: destination.path, prevFile: nil, directories: directories)
            done.signal()
        }
        try expect(done.wait(timeout: .now() + 10) == .success, "Copy finishes without deadlock")
        guard case .copied = result.value else { throw TestFailure.failed("Removed directory must be recreated") }
        try expectEqual(try String(contentsOf: destination, encoding: .utf8), "keep this", "Copy preserves data")
        try expectEqual(try String(contentsOf: source, encoding: .utf8), "keep this", "Source is never modified")
    }

    func test_failedCopiesNeverTriggerPostSaveDisappearanceGuard() throws {
        let box = try SafetyTests().makeSandbox()
        defer { SafetyTests().cleanup(box) }
        let result = ResultBox<FileResult>()
        let done = DispatchSemaphore(value: 0)
        Task {
            result.value = await BackupEngine.processFile(
                entry: FileEntry(relativePath: "deleted.txt", absolutePath: box.home + "/deleted.txt",
                                 size: 1, mtime: Date()),
                destFile: box.dest + "/deleted.txt", prevFile: nil)
            done.signal()
        }
        try expect(done.wait(timeout: .now() + 10) == .success, "failed copy finishes")
        guard let failure = result.value, case .error = failure else {
            throw TestFailure.failed("a file deleted before copy remains a reported error")
        }
        try expect(!failure.savedFile, "a failed copy is not a source lost after a successful save")
        var stats = BackupStats()
        var errors: [(path: String, error: Error)] = []
        var skips: [(path: String, reason: String)] = []
        BackupEngine.processResult(failure, stats: &stats, errors: &errors, skips: &skips)
        try expectEqual(errors.count, 1, "real copy failures remain visible and prevent completeness")
        try expect(FileResult.copied(bytes: 1).savedFile, "successful copies retain the disappearance guard")
        try expect(FileResult.hardlinked.savedFile, "successful hard links retain the disappearance guard")
        try expect(!FileResult.skipped(path: "cache", reason: "excluded").savedFile, "skips never claim a saved file")
    }

    func test_previousMetadataRejectsSymlinksAndKeepsTolerance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = root.appendingPathComponent("previous")
        try "hello".write(to: previous, atomically: true, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: previous.path)
        guard let mtime = attributes[.modificationDate] as? Date else {
            throw TestFailure.failed("Previous metadata missing")
        }
        for (delta, matches) in [(0.0, true), (0.0005, true), (-0.0005, true), (0.002, false), (-0.002, false)] {
            try expectEqual(HardLinker.shouldHardLink(sourcePath: "", sourceSize: 5,
                            sourceMtime: mtime.addingTimeInterval(delta), previousBackupPath: previous.path),
                            matches, "Metadata keeps millisecond tolerance")
        }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: previous)
        try expect(!HardLinker.shouldHardLink(sourcePath: "", sourceSize: 5, sourceMtime: mtime,
                                             previousBackupPath: link.path), "Never reuse a symlink as a regular file")
        try expect(!HardLinker.shouldHardLink(sourcePath: "", sourceSize: 5, sourceMtime: mtime,
                                             previousBackupPath: root.path), "Never reuse a directory as a file")
    }
}
