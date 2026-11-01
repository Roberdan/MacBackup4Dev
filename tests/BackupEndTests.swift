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
        guard let finished = try result.value!.get() else { throw TestFailure.failed("backup cancelled") }
        return finished
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
}
