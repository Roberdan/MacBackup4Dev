import Foundation
import Darwin

final class PostgresBackupTests {
    private func fixtureChain() -> PostgresBackup.Chain {
        let server = PostgresBackup.Server(
            systemIdentifier: "123", major: 17, timeline: 1, bootstrapRole: "backup_fixture",
            databases: ["postgres", "sample"], connectable: ["postgres", "sample", "template1"],
            settings: ["max_connections": 20, "max_worker_processes": 8, "max_wal_senders": 5,
                       "max_prepared_transactions": 0, "max_locks_per_transaction": 64],
            summaries: "on", primary: true, tablespaces: 0, replication: true)
        return PostgresBackup.Chain(
            server: server, fullAt: Date(), capturedAt: Date(),
            inputs: [.init(name: "part-0000", manifestSHA256: String(repeating: "0", count: 64))],
            logical: [.init(database: "postgres", file: "logical-0000.dump"),
                      .init(database: "sample", file: "logical-0001.dump")])
    }

    private func refuses(_ body: () throws -> Void, _ message: String) throws {
        var refused = false
        do { try body() } catch { refused = true }
        try expect(refused, message)
    }

    func test_metadataAndLegacyRecords() throws {
        let original = fixtureChain()
        try PostgresBackup.validate(original)
        var bad = original
        bad.inputs[0].name = "../outside"
        try refuses({ try PostgresBackup.validate(bad) }, "parent traversal is rejected")
        bad = original
        bad.inputs = []
        try refuses({ try PostgresBackup.validate(bad) }, "an empty chain is not a backup")
        bad = original
        bad.inputs[0].manifestSHA256 = "not-a-digest"
        try refuses({ try PostgresBackup.validate(bad) }, "invalid manifest digest is rejected")
        bad = original
        bad.logical[0].file = "/tmp/outside"
        try refuses({ try PostgresBackup.validate(bad) }, "absolute logical archive paths are rejected")
        bad = original
        bad.server.databases.append("postgres")
        try refuses({ try PostgresBackup.validate(bad) }, "duplicate databases are rejected")
        bad = original
        bad.formatVersion = 2
        try refuses({ try PostgresBackup.validate(bad) }, "unknown metadata versions are rejected")
        let old = Data(#"{"kind":"postgres","source":"sample","file":"sample.dump","bytes":20}"#.utf8)
        let decoded = try JSONDecoder().decode(DatabaseRecord.self, from: old)
        try expectNil(decoded.databaseNames, "old manifests remain readable")
        try expectEqual(decoded.savedDatabaseCount, 1, "old database count stays unchanged")
        let cluster = DatabaseRecord(kind: PostgresBackup.kind, source: "cluster", file: "chain.json",
                                     bytes: 1, databaseNames: ["postgres", "sample"])
        try expectEqual(cluster.savedDatabaseCount, 2, "cluster records count actual databases")
        try expect(CLIHandler.commandNeedsConfig("export-database"), "new recovery command uses the selected config")
        for name in ["", "dbname=sample password=hidden", "postgresql://server/sample", "\0"] {
            try expect(!PostgresBackup.validDatabaseName(name), "connection strings must not become database names")
        }
    }

    func test_symlinkMetadataAndCancellation() throws {
        let box = try SafetyTests().makeSandbox()
        defer { SafetyTests().cleanup(box) }
        let destination = box.root.appendingPathComponent("backup")
        let snapshot = destination.appendingPathComponent("snapshot")
        let outside = box.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent(SnapshotManifest.directoryName),
                                                   withDestinationURL: outside)
        try refuses({ _ = try PostgresBackup.readChain(in: snapshot) }, "metadata ancestors cannot escape by symlink")
        let alias = box.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
        var unsafeTargetRefused = false
        do {
            try PostgresBackup.exportDatabase("postgres", snapshot: snapshot,
                                              to: alias.appendingPathComponent("snapshot/export.dump"))
        } catch {
            unsafeTargetRefused = error.localizedDescription.contains("fuori dalla destinazione")
        }
        try expect(unsafeTargetRefused, "an output alias into any backup directory is rejected before reading inputs")
        let lock = try DestinationLock(at: destination)
        var busy = false
        do {
            try PostgresBackup.exportDatabase("postgres", snapshot: snapshot,
                                              to: box.root.appendingPathComponent("export.dump"))
        } catch BackupError.lockExists { busy = true }
        withExtendedLifetime(lock) {}
        try expect(busy, "database export respects the shared backup and retention lock")
        let start = Date()
        let cancelled = Shell.run("/bin/sleep", ["20"], timeout: 30,
                                  cancelled: { Date().timeIntervalSince(start) > 0.1 })
        try expectEqual(cancelled.status, -3, "cancel has an explicit non-success status")
        try expect(Date().timeIntervalSince(start) < 3, "cancel does not wait for the timeout")
        let failed = DatabaseRecord(kind: PostgresBackup.kind, source: "cluster", file: nil,
                                    bytes: 0, error: "fixture failure")
        let result = NewMacRestore.restoreDatabase(failed, snapshot: snapshot, home: box.home, dryRun: false)
        try expect(result.failed, "failed database recovery cannot look successful")
    }

    func test_integratedRoundtripRetentionAndCLI() throws {
        let source = try Cluster()
        let publisher = try Cluster()
        defer { cleanup([source, publisher]) }
        let box = try SafetyTests().makeSandbox()
        defer { SafetyTests().cleanup(box) }
        try source.sql("CREATE DATABASE sample")
        try source.sql("CREATE DATABASE sidecar")
        try source.sql("""
            CREATE TABLE items(id integer PRIMARY KEY, value text NOT NULL);
            INSERT INTO items SELECT i, repeat(md5(i::text), 8) FROM generate_series(1,30000) i
            """, database: "sample")
        try publisher.sql("CREATE TABLE published(id integer PRIMARY KEY); CREATE PUBLICATION fixture_pub FOR TABLE published")
        let connection = "host=\(publisher.root.appendingPathComponent("s").path) port=5432 user=backup_fixture dbname=postgres"
        try source.sql("""
            CREATE SUBSCRIPTION fixture_sub CONNECTION '\(connection)' PUBLICATION fixture_pub
            WITH (connect=false, enabled=false, create_slot=false)
            """, database: "sample")
        try source.sql("ALTER SUBSCRIPTION fixture_sub ENABLE", database: "sample")
        let config = try config(box, databases: ["postgres", "sample", "sidecar"])
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let first = try complete(config, box: box, cluster: source, now: now)
        let firstChain = try PostgresBackup.readChain(in: first.snapshot)
        try expectEqual(firstChain.inputs.count, 1, "first native capture has one full input")
        let original = first.snapshot.appendingPathComponent(PostgresBackup.relativeRoot)
            .appendingPathComponent("part-0000/PG_VERSION")
        let originalInode = try inode(original)
        try source.sql("UPDATE items SET value='changed' WHERE id=1; DELETE FROM items WHERE id=2; "
                       + "INSERT INTO items VALUES(30001,'new')", database: "sample")
        let fingerprint = try source.sql("SELECT md5(string_agg(id::text || value, '' ORDER BY id)) FROM items",
                                         database: "sample")
        let second = try complete(config, box: box, cluster: source, now: now.addingTimeInterval(3600))
        let secondChain = try PostgresBackup.readChain(in: second.snapshot)
        try expectEqual(secondChain.inputs.count, 2, "second native capture adds only an incremental input")
        try expect(second.manifest.databases[0].bytes < first.manifest.databases[0].bytes,
                   "incremental writes fewer bytes than the full baseline")
        try expectEqual(try inode(second.snapshot.appendingPathComponent(PostgresBackup.relativeRoot)
            .appendingPathComponent("part-0000/PG_VERSION")), originalInode, "parent inputs are actual hardlinks")
        var newest = second
        for hour in 2...4 {
            newest = try complete(config, box: box, cluster: source, now: now.addingTimeInterval(Double(hour) * 3600))
        }
        let fresh = try complete(config, box: box, cluster: source, now: now.addingTimeInterval(25 * 3600))
        try expectEqual(try PostgresBackup.readChain(in: fresh.snapshot).inputs.count, 1, "daily full resets the chain")
        let pruned = try RetentionManager.pruneBackups(at: URL(fileURLWithPath: box.dest),
                                                      policy: config.retention, dryRun: false)
        try expect(pruned.contains(first.snapshot.lastPathComponent), "original full snapshot was really pruned")
        try expect(pruned.contains(second.snapshot.lastPathComponent), "original incremental snapshot was really pruned")
        try expectEqual(try inode(newest.snapshot.appendingPathComponent(PostgresBackup.relativeRoot)
            .appendingPathComponent("part-0000/PG_VERSION")), originalInode, "latest snapshot is independent of pruned parents")

        // These files are intentionally ignored by pg_verifybackup: recovery must replace them.
        let input = newest.snapshot.appendingPathComponent(PostgresBackup.relativeRoot).appendingPathComponent("part-0000")
        try "shared_preload_libraries = 'not_a_real_library'\nmax_logical_replication_workers = 3\n"
            .write(to: input.appendingPathComponent("postgresql.auto.conf"), atomically: true, encoding: .utf8)
        try "".write(to: input.appendingPathComponent("standby.signal"), atomically: true, encoding: .utf8)
        try source.stop()
        let newestChain = try PostgresBackup.readChain(in: newest.snapshot)
        let directory = newest.snapshot.appendingPathComponent(PostgresBackup.relativeRoot)
        try PostgresBackup.verify(newestChain, at: directory, tools: source.tools)
        let socket = try PostgresBackup.withRecoveredCluster(chain: newestChain, directory: directory,
                                                            tools: source.tools) { environment in
            let query = "SELECT current_setting('listen_addresses') = '' AND "
                + "current_setting('max_logical_replication_workers')::int = 0 AND current_setting('archive_mode') = 'off'"
            let observed = Shell.run(source.tools.path("psql"), ["-X", "-At", "--no-password", "-c", query],
                                     environment: environment, inheritEnvironment: false)
            try expect(observed.ok && observed.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "t",
                       "private recovery empirically disables TCP, subscriptions and archiving")
            guard let socket = environment["PGHOST"] else { throw TestFailure.failed("private socket missing") }
            let privateVersion = URL(fileURLWithPath: socket).deletingLastPathComponent()
                .appendingPathComponent("data/PG_VERSION")
            try expect(try inode(privateVersion) != originalInode, "recovery copies rather than links saved inputs")
            return socket
        }
        try expect(!FileManager.default.fileExists(atPath: socket), "private recovery removes its own scratch")
        let configPath = box.root.appendingPathComponent("config.toml")
        try config.save(to: configPath)
        let archive = box.root.appendingPathComponent("selected.dump")
        let preview = Shell.run(CommandLine.arguments[0],
                                ["--postgres-cli-worker", "-c", configPath.path, "export-database", "sample",
                                 "--snapshot", newest.snapshot.lastPathComponent, "--to", archive.path],
                                timeout: 60, environment: source.environment, inheritEnvironment: false)
        try expect(preview.ok, "CLI preview: \(preview.failureReason)")
        try expect(!FileManager.default.fileExists(atPath: archive.path), "preview does not reconstruct or export")
        let exported = Shell.run(CommandLine.arguments[0],
                                 ["--postgres-cli-worker", "-c", configPath.path, "export-database", "sample",
                                  "--snapshot", newest.snapshot.lastPathComponent, "--to", archive.path, "--yes"],
                                 timeout: 180, environment: source.environment, inheritEnvironment: false)
        try expect(exported.ok, "live CLI export after parent prune and source stop: \(exported.failureReason)")
        let archiveBytes = try Data(contentsOf: archive)
        try refuses({ try PostgresBackup.exportDatabase("sample", snapshot: newest.snapshot, to: archive) },
                    "export never overwrites an existing file")
        try expectEqual(try Data(contentsOf: archive), archiveBytes, "existing archive is unchanged")
        let target = try Cluster()
        defer { cleanup([target]) }
        let report = NewMacRestore.run(snapshot: newest.snapshot, steps: [.databases], home: box.home,
                                       databaseEnvironment: target.environment)
        try expect(report.failures.isEmpty, "missing-only New Mac recovery: \(report.failures)")
        try expectEqual(try target.sql("SELECT md5(string_agg(id::text || value, '' ORDER BY id)) FROM items",
                                      database: "sample"), fingerprint, "restored data matches the latest captured state")
        try target.sql("UPDATE items SET value='local-change' WHERE id=1", database: "sample")
        let repeated = NewMacRestore.run(snapshot: newest.snapshot, steps: [.databases], home: box.home,
                                         databaseEnvironment: target.environment)
        try expect(repeated.failures.isEmpty, "existing databases are skipped without errors")
        try expectEqual(try target.sql("SELECT value FROM items WHERE id=1", database: "sample"),
                        "local-change", "repeat restore never overwrites an existing database")
        let publisherLog = try String(contentsOf: publisher.log, encoding: .utf8)
        try expect(!publisherLog.contains("application_name=fixture_sub"),
                   "the private recovered server never starts logical subscription connections")
        print("  PostgreSQL synthetic bytes: full=\(first.manifest.databases[0].bytes), incremental=\(second.manifest.databases[0].bytes)")
    }

    func test_preflightAndCancellationAreSafe() throws {
        let source = try Cluster()
        defer { cleanup([source]) }
        let box = try SafetyTests().makeSandbox()
        defer { SafetyTests().cleanup(box) }
        try source.sql("CREATE DATABASE sample")
        var config = try config(box, databases: ["postgres"])
        let now = Date(timeIntervalSince1970: 1_900_100_000)
        let unlisted = try run(config, box: box, cluster: source, now: now)
        try expect(unlisted?.manifest.complete == false, "an unlisted database cannot be silently captured")
        config.databases.postgres = ["postgres", "sample"]
        try source.sql("CREATE UNLOGGED TABLE transient_data(id integer)", database: "sample")
        let unlogged = try run(config, box: box, cluster: source, now: now.addingTimeInterval(3600))
        try expect(unlogged?.manifest.complete == false, "unlogged data cannot be silently lost")
        try source.sql("DROP TABLE transient_data", database: "sample")
        let tablespace = source.root.appendingPathComponent("tablespace")
        try FileManager.default.createDirectory(at: tablespace, withIntermediateDirectories: false)
        try source.sql("CREATE TABLESPACE fixture_ts LOCATION '\(tablespace.path)'")
        let unsupported = try run(config, box: box, cluster: source, now: now.addingTimeInterval(7200))
        try expect(unsupported?.manifest.complete == false, "custom tablespaces fail before any basebackup")
        try source.sql("DROP TABLESPACE fixture_ts")
        let before = RetentionManager.listBackups(at: URL(fileURLWithPath: box.dest)).count
        let cancelled = try run(config, box: box, cluster: source, now: now.addingTimeInterval(10800),
                                stopDuringDatabases: true)
        try expectNil(cancelled, "cancellation during database finalization never publishes a snapshot")
        try expectEqual(RetentionManager.listBackups(at: URL(fileURLWithPath: box.dest)).count, before,
                        "cancellation never renames a partial native snapshot")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: box.dest)
        try expect(!remaining.contains(where: { $0.hasPrefix("in-progress-") }), "cancel cleans only its own in-progress data")
        _ = try complete(config, box: box, cluster: source, now: now.addingTimeInterval(14400))
        try source.sql("ALTER SYSTEM SET summarize_wal = off")
        try source.stop()
        try source.start()
        let disabled = try run(config, box: box, cluster: source, now: now.addingTimeInterval(18000))
        try expect(disabled?.manifest.complete == false, "disabled summaries do not silently become hourly full backups")
    }

    func test_corruptionRefusedAndFullFallback() throws {
        let source = try Cluster()
        defer { cleanup([source]) }
        let box = try SafetyTests().makeSandbox()
        defer { SafetyTests().cleanup(box) }
        try source.sql("CREATE TABLE verified_data(id integer); INSERT INTO verified_data VALUES(1)")
        let relation = try source.sql("SELECT pg_relation_filepath('verified_data')")
        let config = try config(box, databases: ["postgres"])
        let now = Date(timeIntervalSince1970: 1_900_200_000)
        let first = try complete(config, box: box, cluster: source, now: now)
        let directory = first.snapshot.appendingPathComponent(PostgresBackup.relativeRoot)
        let savedRelation = directory.appendingPathComponent("part-0000").appendingPathComponent(relation)
        var bytes = try Data(contentsOf: savedRelation)
        try expect(bytes.count > 100, "synthetic table has a physical data page")
        bytes[100] ^= 1
        try bytes.write(to: savedRelation)
        var verificationRefused = false
        do {
            try PostgresBackup.verify(PostgresBackup.readChain(in: first.snapshot), at: directory, tools: source.tools)
        } catch { verificationRefused = error.localizedDescription.contains("pg_verifybackup") }
        try expect(verificationRefused, "native input verification catches damaged data before any combination")
        let output = box.root.appendingPathComponent("must-not-exist.dump")
        try refuses({ try PostgresBackup.exportDatabase("postgres", snapshot: first.snapshot, to: output) },
                    "a corrupt input is refused before combination")
        try expect(!FileManager.default.fileExists(atPath: output.path), "corruption produces no success-shaped export")
        let second = try complete(config, box: box, cluster: source, now: now.addingTimeInterval(3600))
        let repaired = try PostgresBackup.readChain(in: second.snapshot)
        try expectEqual(repaired.inputs.count, 1, "bad parents force a fresh verified full, not endless incomplete runs")
        try expect(repaired.fullReason?.contains("catena precedente") == true, "full fallback explains the parent failure")
        let summaries = source.data.appendingPathComponent("pg_wal/summaries")
        let files = try FileManager.default.contentsOfDirectory(at: summaries, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".summary") }
        try expect(!files.isEmpty, "synthetic WAL summaries exist for the incremental-failure test")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: summaries.path)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: summaries.path) }
            catch { print("Synthetic summary permission cleanup failed: \(error)"); exit(1) }
        }
        let fallback = try complete(config, box: box, cluster: source, now: now.addingTimeInterval(7200))
        let fallbackChain = try PostgresBackup.readChain(in: fallback.snapshot)
        try expectEqual(fallbackChain.inputs.count, 1, "a failed incremental gets one verified fresh-full attempt")
        try expect(fallbackChain.fullReason?.contains("incrementale") == true, "the native failure is not hidden")
    }
}
