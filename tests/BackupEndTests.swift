import Foundation
import Darwin

/// 2026-11-01: a scheduled backup copied everything, then waited 35 minutes in the coverage
/// check (open() on a folder that was only in iCloud) with 972 pipes still open.
final class BackupEndTests {
    private let safety = SafetyTests()

    /// Open descriptors of this process, and how many of them are pipes.
    static func openDescriptors() -> (all: Int, pipes: Int) {
        var all = 0, pipes = 0
        for fd in 0..<getdtablesize() {
            var info = stat()
            guard fstat(fd, &info) == 0 else { continue }
            all += 1
            if info.st_mode & S_IFMT == S_IFIFO { pipes += 1 }
        }
        return (all, pipes)
    }

    /// A pipe closed right after its reader stopped is released a moment later, on another
    /// thread: wait for the count to come back down instead of reading it once.
    static func descriptors(within seconds: TimeInterval = 3,
                            until settled: ((all: Int, pipes: Int)) -> Bool) -> (all: Int, pipes: Int) {
        let deadline = Date().addingTimeInterval(seconds)
        var count = openDescriptors()
        while !settled(count) && Date() < deadline {
            usleep(20_000)
            count = openDescriptors()
        }
        return count
    }

    /// Runs the real engine in the sandbox and gives up waiting after `seconds`.
    func run(_ cfg: Config, _ box: SafetyTests.Sandbox, within seconds: TimeInterval = 120,
             configure: (inout BackupRunOptions) -> Void = { _ in }) throws -> BackupRunResult {
        guard let finished = try runAllowingStop(cfg, box, within: seconds, configure: configure) else {
            throw TestFailure.failed("backup cancelled")
        }
        return finished
    }

    /// The same, for a backup the test stops: nil when the engine abandoned it.
    func runAllowingStop(_ cfg: Config, _ box: SafetyTests.Sandbox, within seconds: TimeInterval = 120,
                         configure: (inout BackupRunOptions) -> Void = { _ in }) throws -> BackupRunResult? {
        var options = BackupRunOptions(home: box.home, captureEnvironment: false, captureGit: false,
                                       captureDatabases: false, auditCoverage: false, captureApplications: false)
        configure(&options)
        let runOptions = options
        let result = ResultBox<Result<BackupRunResult?, Error>>()
        let done = DispatchSemaphore(value: 0)
        Task {
            do { result.value = .success(try await BackupEngine.run(config: cfg,
                statusWriter: StatusWriter(directory: box.state), options: runOptions)) }
            catch { result.value = .failure(error) }
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else {
            throw TestFailure.failed("the backup was still running after \(Int(seconds)) s")
        }
        return try result.value!.get()
    }

    /// Every git, sqlite3 or brew run left its two output pipes open until the backup ended:
    /// the finalization of 2026-11-01 held 972 of them while it waited in the coverage check.
    func test_aBackupLeavesNoOpenDescriptorBehind() throws {
        guard let sqlite = DatabaseDumps.sqlite3, Shell.git != nil else {
            throw TestFailure.failed("git and sqlite3 are needed to exercise the backup's own commands")
        }
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let repository = box.home + "/project"
        try safety.write("one", to: repository + "/a.txt")
        _ = try safety.git(["init", "-q"], repository)
        _ = try safety.git(["add", "."], repository)
        _ = try safety.git(["commit", "-q", "-m", "one"], repository)
        let database = box.home + "/app/runtime/history.db"
        try FileManager.default.createDirectory(atPath: box.home + "/app/runtime", withIntermediateDirectories: true)
        let made = Shell.run(sqlite, [database, "create table t(x); insert into t values (1);"])
        try expect(made.ok, "sqlite fixture: \(made.stderr)")
        var cfg = safety.config(box, sources: ["project", "app"])
        cfg.databases.sqlite = [database]
        let during = ResultBox<(all: Int, pipes: Int)>()
        func backup(baseline: Int) throws -> BackupRunResult {
            try run(cfg, box) { options in
                options.captureGit = true
                options.captureDatabases = true
                options.auditCoverage = true
                options.captureEnvironment = true
                // Runs inside the backup's finalization, after its git and sqlite3 commands.
                options.environmentCapture = { _ in during.value = Self.descriptors { $0.pipes <= baseline } }
            }
        }
        // The first run opens what a process keeps for good (log, dispatch); the second adds nothing.
        let first = try backup(baseline: Int.max)
        try expect(first.manifest.git.contains { $0.error == nil }, "the repository was saved: \(first.manifest.git)")
        usleep(300_000)
        let before = Self.openDescriptors()
        let second = try backup(baseline: before.pipes)
        try expect(second.manifest.databases.contains { $0.error == nil }, "the database was saved: \(second.manifest.databases)")
        try expectEqual(during.value?.pipes ?? -1, before.pipes, "pipes still open while the backup finishes")
        let after = Self.descriptors { $0.all <= before.all }
        try expectEqual(after.all, before.all, "open descriptors after a backup (pipes before \(before.pipes), after \(after.pipes))")
        try expectEqual(after.pipes, before.pipes, "open pipes after a backup")
    }

    /// 2026-11-01: the check waited 35 minutes in open() after a complete copy; the status said
    /// "in progress", Restore was disabled and the next scheduled backup would have found it running.
    func test_aCoverageCheckThatNeverAnswersDoesNotHoldTheBackup() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        try safety.write("x", to: box.home + "/project/a.txt")
        // The previous check listed a database outside the folders saved now: it stays in the report but is
        // never saved on that word alone (only a check of the saved folders decides what a backup adds).
        try safety.write("data", to: box.home + "/app/runtime/history.db")
        let cfg = safety.config(box, sources: ["project"])
        let writer = StatusWriter(directory: box.state)
        let known = CoverageGap(kind: .database, path: "~/app/runtime/history.db",
                                lastModified: "2026-10-31T23:00:00Z", approximateBytes: 4096)
        try writer.writeCoverage(CoverageReport(checkedAt: "2026-11-01T00:00:00Z", gaps: [known]))
        let walking = DispatchSemaphore(value: 0)
        let answer = DispatchSemaphore(value: 0)
        defer { answer.signal() }   // let the stuck walk end with the test
        let started = Date()
        let result = try run(cfg, box, within: 20) { options in
            options.auditCoverage = true
            options.captureDatabases = true
            options.coverageTimeLimit = 1
            options.coverageWalk = { _, _, findings in
                findings.add(CoverageGap(kind: .folder, path: "~/Found", lastModified: "2026-11-01T10:00:00Z",
                                         approximateBytes: 1))
                walking.signal()
                _ = answer.wait(timeout: .now() + 30)   // a folder that never answers
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        try expect(walking.wait(timeout: .now()) == .success, "the coverage check started")
        try expect(elapsed < 15, "the backup ended \(Int(elapsed)) s after a check that never answered")
        guard let status = writer.read() else { throw TestFailure.failed("no status written") }
        try expectEqual(status.state, "idle", "the backup is over")
        try expectEqual(status.lastSnapshot, result.snapshot.lastPathComponent, "the new snapshot is recorded")
        try expect(result.manifest.complete, "the copy itself was complete")
        try expectEqual(status.lastResult, "complete", "last result")
        try expectEqual(status.lastCompleteAt, status.lastCompleted, "the new snapshot is the newest complete one")
        try expect(!FileManager.default.fileExists(atPath: box.dest + "/rustymacbackup.lock"),
                   "the destination is free for the next backup")
        guard let report = writer.readCoverage() else { throw TestFailure.failed("no coverage report") }
        try expectEqual(report.complete, false, "the report says the check is incomplete")
        try expect(report.incompleteReason?.contains("tempo scaduto") == true, "and why: \(report.incompleteReason ?? "nil")")
        let paths = Set(report.gaps.map(\.path))
        try expect(paths.contains("~/Found"), "what the check found before it stopped answering is kept: \(paths)")
        try expect(paths.contains(known.path), "what the previous check found is not lost: \(paths)")
        try expect(result.manifest.databases.isEmpty && report.addedByBackup == nil,
                   "and a database it listed outside the saved folders is not saved: \(result.manifest.databases.map(\.source))")
    }

    /// The check never downloads what is only in the cloud: it switches downloads off on the
    /// thread that walks, and leaves cloud-only folders and files out, counted as not checked.
    func test_theCoverageCheckNeverDownloadsWhatIsOnlyInTheCloud() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        for path in ["project/app/runtime/history.db", "project/cloud/runtime/remote.db", "project/cloud.db",
                     "Local/notes.md", "Local/cloud/notes.md", "Remote/notes.md", "GitHub/local/a.txt",
                     "GitHub/remote/a.txt"] {
            try safety.write("data", to: box.home + "/" + path)
        }
        let cfg = safety.config(box, sources: ["project"])
        let cloudOnly = ["/project/cloud", "/project/cloud.db", "/Local/cloud", "/Remote", "/GitHub/remote"]
        let policies = ResultBox<[Int32]>()
        let lock = NSLock()
        func findings() -> CoverageAuditor.Findings {
            CoverageAuditor.Findings { path in
                let policy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
                lock.withLock { policies.value = (policies.value ?? []) + [policy] }
                return cloudOnly.contains { path.hasSuffix($0) }
            }
        }
        let own = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        let audit = findings()
        let paths = Set(CoverageAuditor.audit(config: cfg, home: box.home, findings: audit).map(\.path))
        try expect(paths.contains("~/project/app/runtime/history.db"), "a database in an ordinary folder is found: \(paths)")
        try expect(paths.contains("~/Local") && paths.contains("~/GitHub/local"), "ordinary folders are found: \(paths)")
        for skipped in ["remote.db", "cloud.db", "~/Remote", "~/GitHub/remote"] {
            try expect(!paths.contains { $0.hasSuffix(skipped) }, "\(skipped) is only in the cloud and never opened: \(paths)")
        }
        try expectEqual(audit.found.unchecked, cloudOnly.count, "what was left out is counted as not checked")
        // The preparation before a backup calls the database walk on its own.
        let preparation = findings()
        let databases = CoverageAuditor.uncopiedDatabases(config: cfg, sources: [box.home + "/project"], home: box.home,
                                                          cutoff: Date().addingTimeInterval(-86_400), findings: preparation)
        try expectEqual(databases.map(\.path), ["~/project/app/runtime/history.db"], "the database walk skips the cloud too")
        try expectEqual(preparation.found.unchecked, 2, "the database walk counts what it left out")
        let seen = policies.value ?? []
        try expect(!seen.isEmpty && seen.allSatisfy { $0 == IOPOL_MATERIALIZE_DATALESS_FILES_OFF },
                   "downloads are off on the walking thread every time (\(seen))")
        try expectEqual(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD), own,
                        "the thread gets its own setting back")
        try expect(!CoverageAuditor.isCloudOnly(box.home + "/project/app"), "an ordinary folder is not cloud-only")
        // Past the time limit a walk still running ends at its next entry instead of going on.
        let stopped = CoverageAuditor.Findings()
        stopped.stop()
        try expect(CoverageAuditor.audit(config: cfg, home: box.home, findings: stopped).isEmpty,
                   "a stopped check walks no further")
    }

    /// "Interrompi" during the check (SIGTERM for a scheduled backup) used to wait for the walk. The check
    /// now runs before the databases are saved, so a stop there ends the backup at once like a stop during
    /// the copy: the unfinished snapshot is not kept (F-02: without its databases it must not look valid).
    func test_stoppingTheBackupDuringTheCheckEndsItAtOnce() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        try safety.write("x", to: box.home + "/project/a.txt")
        let cfg = safety.config(box, sources: ["project"])
        let answer = DispatchSemaphore(value: 0)
        defer { answer.signal() }
        let started = Date()
        let result = try runAllowingStop(cfg, box, within: 20) { options in
            options.auditCoverage = true
            options.coverageTimeLimit = 60
            options.coverageWalk = { _, _, _ in
                BackupEngine.stop()
                _ = answer.wait(timeout: .now() + 30)
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        try expect(elapsed < 15, "the backup ended \(Int(elapsed)) s after being stopped during the check")
        try expect(result == nil, "the stopped backup is abandoned")
        let writer = StatusWriter(directory: box.state)
        try expectEqual(writer.read()?.state, "cancelled", "the status says so")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: box.dest)) ?? []
        try expect(!left.contains { $0.hasPrefix("20") || $0.hasPrefix("in-progress-") || $0 == "rustymacbackup.lock" },
                   "no snapshot, no unfinished copy and no lock are left: \(left)")
        try expectEqual(writer.readCoverage()?.complete, false, "the check is marked incomplete")
        try expect(writer.readCoverage()?.incompleteReason?.contains("fermato") == true,
                   "because the backup was stopped: \(writer.readCoverage()?.incompleteReason ?? "nil")")
    }

    /// A command that cannot even start must not leave its pipes behind either.
    func test_aCommandThatCannotStartLeavesNoPipe() throws {
        let before = Self.openDescriptors()
        for _ in 0..<3 {
            let result = Shell.run("/nonexistent/macbackup4dev-tool", [], stdin: "secret")
            try expect(!result.ok, "the command cannot start")
        }
        let after = Self.descriptors { $0.pipes <= before.pipes }
        try expectEqual(after.pipes, before.pipes, "open pipes after commands that could not start")
    }
}
