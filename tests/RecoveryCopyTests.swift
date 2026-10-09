import Foundation

struct RecoveryCopyTests {
    private let safety = SafetyTests()

    static func runWorker(configPath: String, home: String, state: String) throws {
        Log.logURL = URL(fileURLWithPath: state).appendingPathComponent("worker.log")
        guard EnvironmentSnapshot.findAppBundle() != nil else {
            throw TestFailure.failed("Regression worker must run inside a real app bundle")
        }
        let config = try Config.load(from: URL(fileURLWithPath: configPath))
        try expect(!EnvironmentSnapshot.refreshRecoveryApp(onDisk: config.diskURL, isMounted: { _ in false }),
                   "A writable but unmounted directory must not receive a physical recovery copy")
        let options = BackupRunOptions(home: home, captureEnvironment: true, captureGit: false,
                                       captureDatabases: false, auditCoverage: false, environmentCapture: { _ in })
        let outcome = ResultBox<Result<BackupRunResult?, Error>>()
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                outcome.value = .success(try await BackupEngine.run(config: config,
                                                                   statusWriter: StatusWriter(directory: state),
                                                                   options: options))
            } catch { outcome.value = .failure(error) }
            done.signal()
        }
        done.wait()
        guard let result = try outcome.value?.get(), result.manifest.complete else {
            throw TestFailure.failed("Worker backup did not complete")
        }
    }

    private func bundle(_ app: URL, version: String, executable: URL? = nil) throws {
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": AppIdentity.bundleID, "CFBundleShortVersionString": version,
                     "CFBundleExecutable": AppIdentity.name]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if let executable {
            let macOS = contents.appendingPathComponent("MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: executable, to: macOS.appendingPathComponent(AppIdentity.name))
        }
    }

    private func version(_ app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    func test_backupFinishesWithoutRefreshingPhysicalDisk() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        try safety.write("protected", to: box.home + "/data/file")
        let config = safety.config(box, sources: ["data"])
        let configURL = box.root.appendingPathComponent("config.toml")
        try config.save(to: configURL)
        let recovery = box.root.appendingPathComponent("MacBackup4Dev.app")
        try bundle(recovery, version: "0.0.1")
        let worker = box.root.appendingPathComponent("worker/MacBackup4Dev.app")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        try bundle(worker, version: "9.0.0", executable: executable)
        for _ in 0..<2 {
            let result = Shell.run(worker.appendingPathComponent("Contents/MacOS/MacBackup4Dev").path,
                                   ["--environment-worker", configURL.path, box.home, box.state], timeout: 15)
            try expect(result.ok, "Real bundled backup worker exited promptly: \(result.stderr)")
            let status = StatusWriter(directory: box.state).read()
            try expectEqual(status?.state, "idle", "Backup completion is persisted")
            try expectEqual(status?.lastResult, "complete", "Protected files are complete")
            try expectEqual(version(recovery), "0.0.1", "Backup worker must not refresh the physical recovery app")
            try expect(!FileManager.default.fileExists(atPath: box.dest + "/rustymacbackup.lock"),
                       "PID marker is released before the next run")
            let lock = try DestinationLock(at: URL(fileURLWithPath: box.dest))
            withExtendedLifetime(lock) {}
        }
        try expectEqual(SnapshotCatalog.list(at: URL(fileURLWithPath: box.dest)).count, 2,
                        "Two consecutive jobs both produce complete snapshots")
    }

    func test_competingCopyDoesNotWaitOrTouchStaging() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let source = box.root.appendingPathComponent("installed/MacBackup4Dev.app")
        try bundle(source, version: "9.0.0")
        let disk = URL(fileURLWithPath: box.dest)
        var competitorCopied = false
        var competitorResult = true
        let result = EnvironmentSnapshot.refreshRecoveryApp(from: source, in: disk, copy: { source, staged in
            competitorResult = EnvironmentSnapshot.refreshRecoveryApp(from: source, in: disk, copy: { _, _ in
                competitorCopied = true
            })
            try FileManager.default.copyItem(at: source, to: staged)
        })
        try expect(result && !competitorResult && !competitorCopied, "Concurrent request must skip, never wait or erase another staging copy")
        try expectEqual(version(disk.appendingPathComponent("MacBackup4Dev.app")), "9.0.0", "The first copy remains intact")
        let names = try FileManager.default.contentsOfDirectory(atPath: disk.path)
        try expect(!names.contains { $0.contains("-new-") || $0.contains("-old-") }, "Owned staging copies are cleaned")
    }

    func test_timeoutPreservesExistingRecoveryApp() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let source = box.root.appendingPathComponent("installed/MacBackup4Dev.app")
        let disk = URL(fileURLWithPath: box.dest)
        let target = disk.appendingPathComponent("MacBackup4Dev.app")
        try bundle(source, version: "9.0.0")
        try bundle(target, version: "0.0.1")
        let sleeper = box.root.appendingPathComponent("slow-copy")
        try "#!/bin/sh\nexec /bin/sleep 5\n".write(to: sleeper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sleeper.path)
        let started = Date()
        var timedOut = false
        let result = EnvironmentSnapshot.refreshRecoveryApp(from: source, in: disk, copy: { source, staged in
            do { try EnvironmentSnapshot.copyAppBounded(from: source, to: staged, timeout: 0.1, executable: sleeper.path) }
            catch {
                timedOut = error.localizedDescription.contains("timeout")
                throw error
            }
        })
        try expect(!result && timedOut, "Timeout is reported, not disguised as success")
        try expect(Date().timeIntervalSince(started) < 3, "A stalled child must not hold the worker indefinitely")
        try expectEqual(version(target), "0.0.1", "A failed refresh preserves the usable old app")
        let names = try FileManager.default.contentsOfDirectory(atPath: disk.path)
        try expect(!names.contains { $0.contains("-new-") || $0.contains("-old-") }, "Timeout leaves no partial app")
    }

    func test_failedReplacementRestoresPreviousApp() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let source = box.root.appendingPathComponent("installed/MacBackup4Dev.app")
        let disk = URL(fileURLWithPath: box.dest)
        let target = disk.appendingPathComponent("MacBackup4Dev.app")
        try bundle(source, version: "9.0.0")
        try bundle(target, version: "0.0.1")
        var replacementAttempted = false
        let result = EnvironmentSnapshot.refreshRecoveryApp(from: source, in: disk,
            copy: { try FileManager.default.copyItem(at: $0, to: $1) },
            move: { from, to in
                if from.lastPathComponent.contains("-new-") {
                    replacementAttempted = true
                    throw POSIXError(.EACCES)
                }
                try FileManager.default.moveItem(at: from, to: to)
            })
        try expect(!result && replacementAttempted, "The replacement failure is reported")
        try expectEqual(version(target), "0.0.1", "Rollback restores the previous app to its original path")
        let names = try FileManager.default.contentsOfDirectory(atPath: disk.path)
        try expect(!names.contains { $0.contains("-new-") || $0.contains("-old-") }, "Rollback leaves no partial or displaced app")
    }
}
