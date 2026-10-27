import Foundation
import Darwin

extension PostgresBackup {
    private static func quotedSetting(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func withRecoveredCluster<T>(chain: Chain, directory: URL, tools: Tools,
                                       body: ([String: String]) throws -> T) throws -> T {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: "/private/tmp/mbpg-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let data = work.appendingPathComponent("data")
        let sockets = work.appendingPathComponent("s")
        var outcome: Result<T, Error>
        do {
            var required: UInt64 = 64 * 1024 * 1024
            for input in chain.inputs {
                try walk(directory.appendingPathComponent(input.name)) { _, value in
                    required += UInt64(max(0, value.st_size))
                }
            }
            let attributes = try fm.attributesOfFileSystem(forPath: work.path)
            guard let free = attributes[.systemFreeSize] as? NSNumber, free.uint64Value >= required else {
                throw failure("Spazio insufficiente per ricostruire il cluster PostgreSQL nella cartella temporanea.")
            }
            _ = try run(tools.path("pg_combinebackup"),
                        ["--copy", "--output", data.path] + chain.inputs.map { directory.appendingPathComponent($0.name).path },
                        environment: nil, timeout: 1800)
            _ = try run(tools.path("pg_verifybackup"), [data.path], environment: nil, timeout: 1800)
            try fm.createDirectory(at: sockets, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var settings = [
                "listen_addresses = ''", "port = 5432",
                "unix_socket_directories = \(quotedSetting(sockets.path))",
                "unix_socket_permissions = 0700", "ssl = off", "shared_preload_libraries = ''",
                "archive_mode = off", "archive_command = ''", "restore_command = ''",
                "primary_conninfo = ''", "max_logical_replication_workers = 0",
                "logging_collector = off", "shared_buffers = '16MB'"
            ]
            for key in ["max_connections", "max_worker_processes", "max_wal_senders",
                        "max_prepared_transactions", "max_locks_per_transaction"] {
                guard let value = chain.server.settings[key], value >= 0 else {
                    throw failure("Impostazioni minime di ripristino mancanti.")
                }
                settings.append("\(key) = \(value)")
            }
            try (settings.joined(separator: "\n") + "\n").write(
                to: data.appendingPathComponent("postgresql.conf"), atomically: true, encoding: .utf8)
            for name in ["postgresql.auto.conf", "pg_ident.conf"] {
                try "".write(to: data.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            try "local all all trust\n".write(to: data.appendingPathComponent("pg_hba.conf"),
                                             atomically: true, encoding: .utf8)
            for signal in ["standby.signal", "recovery.signal"] {
                let file = data.appendingPathComponent(signal)
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            }
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PG") }
            environment["PGHOST"] = sockets.path
            environment["PGPORT"] = "5432"
            environment["PGUSER"] = chain.server.bootstrapRole
            environment["PGDATABASE"] = chain.server.databases[0]
            environment["PGCONNECT_TIMEOUT"] = "10"
            environment["LC_ALL"] = "C"
            let started = Shell.run(tools.path("pg_ctl"), ["-D", data.path, "-l", work.appendingPathComponent("server.log").path,
                                                          "-w", "-t", "30", "start"],
                                    timeout: 40, environment: environment, inheritEnvironment: false)
            guard started.ok else {
                let log = (try? String(contentsOf: work.appendingPathComponent("server.log"), encoding: .utf8)) ?? ""
                throw failure("Avvio della copia privata fallito: \(started.failureReason) \(String(log.suffix(300)))")
            }
            outcome = .success(try body(environment))
        } catch {
            outcome = .failure(error)
        }
        if fm.fileExists(atPath: data.appendingPathComponent("postmaster.pid").path) {
            var stopped = Shell.run(tools.path("pg_ctl"), ["-D", data.path, "-m", "fast", "-w", "-t", "30", "stop"], timeout: 40)
            if !stopped.ok {
                stopped = Shell.run(tools.path("pg_ctl"), ["-D", data.path, "-m", "immediate", "-w", "-t", "10", "stop"], timeout: 20)
            }
            guard stopped.ok else {
                throw failure("Non posso fermare la copia privata: \(stopped.failureReason). Dati conservati in \(work.path)")
            }
        }
        do { try fm.removeItem(at: work) }
        catch { throw failure("Pulizia della copia privata fallita (\(work.path)): \(error.localizedDescription)") }
        return try outcome.get()
    }

    /// Produces a new logical archive, never writes to the original database or snapshot.
    static func exportDatabase(_ database: String, snapshot: URL, to target: URL) throws {
        let snapshot = snapshot.resolvingSymlinksInPath().standardizedFileURL
        let destination = snapshot.deletingLastPathComponent()
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let target = parent.appendingPathComponent(target.lastPathComponent).standardizedFileURL
        let outputError = failure("L'export richiede un nuovo file fuori dalla destinazione di backup; non sovrascrivo file esistenti.")
        guard !FileManager.default.fileExists(atPath: target.path) else { throw outputError }
        let protected = try metadata(destination)
        var ancestor = parent
        while true {
            var value = stat()
            if lstat(ancestor.path, &value) == 0 {
                guard value.st_dev != protected.st_dev || value.st_ino != protected.st_ino else { throw outputError }
            } else if errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let next = ancestor.deletingLastPathComponent()
            if next.path == ancestor.path { break }
            ancestor = next
        }
        let operationLock = try DestinationLock(at: destination)
        defer { withExtendedLifetime(operationLock) {} }
        let chain = try readChain(in: snapshot)
        guard chain.server.databases.contains(database) else { throw failure("Database non presente nel cluster salvato.") }
        let directory = try root(in: snapshot)
        let tools = try Tools.find(major: chain.server.major)
        try verify(chain, at: directory, tools: tools)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".mbpg-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let staged = staging.appendingPathComponent("database.dump")
        do {
            try withRecoveredCluster(chain: chain, directory: directory, tools: tools) { environment in
                let result = Shell.run(tools.path("pg_dump"), ["-Fc", "--no-password", "-d", database, "-f", staged.path],
                                       timeout: 1800, environment: environment, inheritEnvironment: false)
                guard result.ok else { throw failure("Export dalla copia privata fallito: \(result.failureReason)") }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            // link(2) publishes without an overwrite race; the staged archive is closed.
            try FileManager.default.linkItem(at: staged, to: target)
            try FileManager.default.removeItem(at: staging)
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) {
                do { try FileManager.default.removeItem(at: staging) }
                catch { throw failure("Pulizia dell'export fallita: \(error.localizedDescription)") }
            }
            throw error
        }
    }

    static func withDatabaseExport<T>(_ database: String, snapshot: URL,
                                      body: (URL) throws -> T) throws -> T {
        let directory = URL(fileURLWithPath: "/private/tmp/mbpg-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var outcome: Result<T, Error>
        do {
            let file = directory.appendingPathComponent("database.dump")
            try exportDatabase(database, snapshot: snapshot, to: file)
            outcome = .success(try body(file))
        } catch { outcome = .failure(error) }
        do { try FileManager.default.removeItem(at: directory) }
        catch { throw failure("Pulizia dell'export temporaneo fallita (\(directory.path)): \(error.localizedDescription)") }
        return try outcome.get()
    }
}
