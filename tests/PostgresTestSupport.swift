import Foundation
import Darwin

extension PostgresBackupTests {
    final class Cluster {
        let root: URL
        let tools: PostgresBackup.Tools
        let environment: [String: String]
        var data: URL { root.appendingPathComponent("data") }
        var log: URL { root.appendingPathComponent("server.log") }

        init() throws {
            tools = try PostgresBackup.Tools.find(major: 17)
            root = URL(fileURLWithPath: "/private/tmp/mbpg-test-" + UUID().uuidString)
            var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PG") }
            env["PGHOST"] = root.appendingPathComponent("s").path
            env["PGPORT"] = "5432"
            env["PGUSER"] = "backup_fixture"
            env["PGDATABASE"] = "postgres"
            env["PGCONNECT_TIMEOUT"] = "3"
            env["LC_ALL"] = "C"
            environment = env
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.createDirectory(at: root.appendingPathComponent("s"),
                                                        withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                let initialized = command("initdb", ["-D", data.path, "--username=backup_fixture",
                                                     "--auth-local=trust", "--auth-host=reject",
                                                     "--encoding=UTF8", "--locale=C", "--data-checksums"])
                try expect(initialized.ok, "synthetic initdb: \(initialized.failureReason)")
                let config = """
                listen_addresses = ''
                port = 5432
                unix_socket_directories = '\(root.appendingPathComponent("s").path)'
                unix_socket_permissions = 0700
                shared_buffers = '16MB'
                max_connections = 20
                max_wal_senders = 5
                max_replication_slots = 5
                wal_level = logical
                summarize_wal = on
                max_logical_replication_workers = 0
                log_connections = on
                """
                try (config + "\n").write(to: data.appendingPathComponent("postgresql.conf"),
                                         atomically: true, encoding: .utf8)
                try start()
            } catch {
                do { try cleanup() }
                catch { throw TestFailure.failed("synthetic setup cleanup failed: \(error)") }
                throw error
            }
        }

        func command(_ name: String, _ arguments: [String]) -> Shell.Result {
            Shell.run(tools.path(name), arguments, timeout: 60, environment: environment, inheritEnvironment: false)
        }

        func start() throws {
            let result = command("pg_ctl", ["-D", data.path, "-l", log.path, "-w", "-t", "20", "start"])
            try expect(result.ok, "synthetic start: \(result.failureReason)")
        }

        func stop() throws {
            if FileManager.default.fileExists(atPath: data.appendingPathComponent("postmaster.pid").path) {
                var result = command("pg_ctl", ["-D", data.path, "-m", "fast", "-w", "-t", "20", "stop"])
                if !result.ok {
                    result = command("pg_ctl", ["-D", data.path, "-m", "immediate", "-w", "-t", "10", "stop"])
                }
                try expect(result.ok, "synthetic stop failed; retained \(root.path): \(result.failureReason)")
            }
        }

        func cleanup() throws {
            try stop()
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }

        @discardableResult
        func sql(_ text: String, database: String = "postgres") throws -> String {
            let result = command("psql", ["-X", "-At", "--no-password", "--set", "ON_ERROR_STOP=1",
                                         "-d", database, "-c", text])
            try expect(result.ok, "synthetic SQL: \(result.failureReason)")
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func cleanup(_ clusters: [Cluster]) {
        for cluster in clusters {
            do { try cluster.cleanup() }
            catch {
                print("PostgreSQL test cleanup failed: \(error)")
                exit(1)
            }
        }
    }

    func config(_ box: SafetyTests.Sandbox, databases: [String]) throws -> Config {
        try SafetyTests().write("fixture", to: box.home + "/source/file.txt")
        var config = SafetyTests().config(box, sources: ["source"])
        config.databases.postgres = databases
        config.databases.postgresClusterIncremental = true
        config.retention = RetentionConfig(hourly: 0, daily: 0, weekly: 0, monthly: 1)
        return config
    }

    func run(_ config: Config, box: SafetyTests.Sandbox, cluster: Cluster,
             now: Date, stopDuringDatabases: Bool = false) throws -> BackupRunResult? {
        let result = ResultBox<Result<BackupRunResult?, Error>>()
        let done = DispatchSemaphore(value: 0)
        let options = BackupRunOptions(home: box.home, captureEnvironment: false, captureGit: false,
                                       captureDatabases: true, auditCoverage: false,
                                       databaseEnvironment: cluster.environment, now: { now })
        Task {
            do {
                result.value = .success(try await BackupEngine.run(
                    config: config, statusWriter: StatusWriter(directory: box.state), options: options))
            } catch { result.value = .failure(error) }
            done.signal()
        }
        if stopDuringDatabases {
            let deadline = Date().addingTimeInterval(20)
            var stopped = false
            while Date() < deadline {
                if StatusWriter(directory: box.state).read()?.currentFile.contains("Salvo il database") == true {
                    BackupEngine.stop()
                    stopped = true
                    break
                }
                usleep(10_000)
            }
            done.wait()
            try expect(stopped, "test must interrupt the database finalization, not some earlier phase")
        } else { done.wait() }
        return try result.value!.get()
    }

    func complete(_ config: Config, box: SafetyTests.Sandbox, cluster: Cluster,
                  now: Date) throws -> BackupRunResult {
        guard let result = try run(config, box: box, cluster: cluster, now: now) else {
            throw TestFailure.failed("synthetic backup was cancelled")
        }
        try expect(result.manifest.complete, "complete synthetic snapshot: \(result.manifest.incompleteReasons)")
        return result
    }

    func inode(_ url: URL) throws -> UInt64 {
        var metadata = stat()
        try expect(lstat(url.path, &metadata) == 0, "fixture inode exists")
        return UInt64(metadata.st_ino)
    }
}
