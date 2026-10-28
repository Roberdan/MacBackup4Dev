import Foundation
import CryptoKit
import Darwin

/// Every snapshot owns links to its entire input chain, not references to other snapshots.
enum PostgresBackup {
    static let kind = "postgres-cluster"
    static let relativeRoot = SnapshotManifest.directoryName + "/databases/postgres-native"
    static let relativeManifest = relativeRoot + "/chain.json"
    static let fullInterval: TimeInterval = 24 * 60 * 60
    static let maxIncrementals = 24

    struct Server: Codable, Equatable {
        var systemIdentifier: String
        var major: Int
        var timeline: Int
        var bootstrapRole: String
        var databases: [String]
        var connectable: [String]
        var settings: [String: Int]
        var summaries: String?
        var primary: Bool
        var tablespaces: Int
        var replication: Bool
    }

    struct Input: Codable, Equatable {
        var name: String
        var manifestSHA256: String
    }

    struct LogicalExport: Codable, Equatable {
        var database: String
        var file: String
    }

    struct Chain: Codable, Equatable {
        var formatVersion = 1
        var server: Server
        var fullAt: Date
        var capturedAt: Date
        var inputs: [Input]
        var logical: [LogicalExport]
        var fullReason: String?
    }

    struct Tools {
        let directory: String
        func path(_ name: String) -> String { directory + "/" + name }

        static func find(major: Int) throws -> Tools {
            let required = ["postgres", "psql", "pg_basebackup", "pg_combinebackup",
                            "pg_verifybackup", "pg_waldump", "pg_ctl", "pg_dump", "pg_restore"]
            for directory in DatabaseDumps.postgresBinDirectories {
                guard required.allSatisfy({ FileManager.default.isExecutableFile(atPath: directory + "/" + $0) }) else {
                    continue
                }
                let version = Shell.run(directory + "/postgres", ["--version"], timeout: 10)
                if version.ok, version.stdout.range(of: "\\b\(major)\\.[0-9]", options: .regularExpression) != nil {
                    return Tools(directory: directory)
                }
            }
            throw failure("Servono gli strumenti PostgreSQL \(major), della stessa versione del server.")
        }
    }

    static func failure(_ text: String) -> NSError {
        NSError(domain: "PostgresBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    static func validDatabaseName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("\0") && !name.contains("=")
            && !name.hasPrefix("postgres://") && !name.hasPrefix("postgresql://")
    }

    static func run(_ tool: String, _ arguments: [String],
                    environment: [String: String]?, timeout: TimeInterval = 120,
                    cancelled: () -> Bool = { false }) throws -> Shell.Result {
        let result = Shell.run(tool, arguments, timeout: timeout,
                               environment: environment, inheritEnvironment: environment == nil,
                               cancelled: cancelled)
        if cancelled() { throw BackupError.cancelled }
        guard result.ok else {
            throw failure("\(URL(fileURLWithPath: tool).lastPathComponent): \(result.failureReason)")
        }
        return result
    }

    private static func sql(_ text: String, database: String, psql: String,
                            environment: [String: String]?,
                            cancelled: () -> Bool = { false }) throws -> String {
        guard validDatabaseName(database) else { throw failure("Nome di database non supportato: \(database)") }
        return try run(psql, ["-X", "-At", "--no-password", "--set", "ON_ERROR_STOP=1",
                              "-d", database, "-c", text],
                       environment: environment, timeout: 30, cancelled: cancelled)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func inspect(databases: [String], psql: String, environment: [String: String]?,
                        cancelled: () -> Bool = { false }) throws -> Server {
        guard let database = databases.first, databases.allSatisfy(validDatabaseName),
              Set(databases).count == databases.count else {
            throw failure("Elenca tutti i database del cluster, senza duplicati o stringhe di connessione.")
        }
        let query = """
        SELECT json_build_object(
          'systemIdentifier', (SELECT system_identifier::text FROM pg_control_system()),
          'major', current_setting('server_version_num')::int / 10000,
          'timeline', (SELECT timeline_id FROM pg_control_checkpoint()),
          'bootstrapRole', (SELECT rolname FROM pg_roles WHERE oid = 10),
          'databases', (SELECT json_agg(datname ORDER BY datname) FROM pg_database WHERE NOT datistemplate),
          'connectable', (SELECT json_agg(datname ORDER BY datname) FROM pg_database WHERE datallowconn),
          'settings', json_build_object(
            'max_connections', current_setting('max_connections')::int,
            'max_worker_processes', current_setting('max_worker_processes')::int,
            'max_wal_senders', current_setting('max_wal_senders')::int,
            'max_prepared_transactions', current_setting('max_prepared_transactions')::int,
            'max_locks_per_transaction', current_setting('max_locks_per_transaction')::int),
          'summaries', current_setting('summarize_wal', true),
          'primary', NOT pg_is_in_recovery(),
          'tablespaces', (SELECT count(*) FROM pg_tablespace WHERE spcname NOT IN ('pg_default', 'pg_global')),
          'replication', (SELECT rolsuper OR rolreplication FROM pg_roles WHERE rolname = current_user)
        )::text
        """
        let text = try sql(query, database: database, psql: psql,
                           environment: environment, cancelled: cancelled)
        let server = try JSONDecoder().decode(Server.self, from: Data(text.utf8))
        guard server.major >= 17 else { throw failure("L'incrementale nativo richiede PostgreSQL 17 o successivo.") }
        guard server.primary else { throw failure("Il backup incrementale richiede il server primario, non una replica.") }
        guard server.summaries == "on" else {
            throw failure("PostgreSQL: summarize_wal deve essere on. L'app non modifica le impostazioni del server.")
        }
        guard server.replication, (server.settings["max_wal_senders"] ?? 0) > 0 else {
            throw failure("PostgreSQL: servono i permessi di replica e max_wal_senders maggiore di zero.")
        }
        guard Set(server.databases) == Set(databases) else {
            throw failure("Il backup fisico salva tutto il cluster. [databases] postgres deve elencare esattamente: "
                          + server.databases.joined(separator: ", "))
        }
        guard Set(server.databases).isSubset(of: Set(server.connectable)) else {
            throw failure("Un database del cluster non permette connessioni: non posso verificarlo o esportarlo.")
        }
        guard server.tablespaces == 0 else {
            throw failure("I tablespace personalizzati non sono supportati dal backup incrementale.")
        }
        for name in server.connectable {
            let unlogged = try sql("SELECT EXISTS (SELECT 1 FROM pg_class WHERE relpersistence = 'u')",
                                   database: name, psql: psql, environment: environment, cancelled: cancelled)
            guard unlogged == "f" else {
                throw failure("\(name): tabelle unlogged non supportate; usa gli export logici completi.")
            }
        }
        return server
    }

    static func metadata(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw failure("Non posso leggere \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        return value
    }

    static func walk(_ root: URL, file: (URL, stat) throws -> Void) throws {
        let value = try metadata(root)
        switch value.st_mode & S_IFMT {
        case S_IFREG: try file(root, value)
        case S_IFDIR:
            for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try walk(child, file: file)
            }
        default: throw failure("Link simbolico o file speciale non ammesso: \(root.lastPathComponent)")
        }
    }

    static func root(in snapshot: URL) throws -> URL {
        var result = snapshot
        for component in relativeRoot.split(separator: "/") {
            result.appendPathComponent(String(component))
            guard try metadata(result).st_mode & S_IFMT == S_IFDIR else {
                throw failure("Percorso PostgreSQL non sicuro nello snapshot.")
            }
        }
        return result
    }

    static func readChain(in snapshot: URL) throws -> Chain {
        let directory = try root(in: snapshot)
        let file = directory.appendingPathComponent("chain.json")
        guard try metadata(file).st_mode & S_IFMT == S_IFREG else {
            throw failure("Il manifesto PostgreSQL non e' un file regolare.")
        }
        let chain = try JSONDecoder().decode(Chain.self, from: Data(contentsOf: file))
        try validate(chain)
        return chain
    }

    static func validate(_ chain: Chain) throws {
        guard chain.formatVersion == 1, chain.server.major >= 17,
              !chain.server.systemIdentifier.isEmpty, !chain.server.bootstrapRole.isEmpty,
              !chain.server.databases.isEmpty, chain.server.databases.allSatisfy(validDatabaseName),
              Set(chain.server.databases).count == chain.server.databases.count,
              !chain.inputs.isEmpty, chain.inputs.count <= maxIncrementals + 1,
              chain.logical.count == chain.server.databases.count else {
            throw failure("Manifesto PostgreSQL non supportato o incompleto.")
        }
        for (index, input) in chain.inputs.enumerated() {
            guard input.name == partName(index), input.manifestSHA256.count == 64,
                  input.manifestSHA256.allSatisfy({ $0.isHexDigit }) else {
                throw failure("Ordine o percorso della catena PostgreSQL non valido.")
            }
        }
        guard Set(chain.logical.map(\.database)) == Set(chain.server.databases) else {
            throw failure("Elenco degli export logici non valido.")
        }
        for (index, export) in chain.logical.enumerated() {
            guard export.file == logicalName(index) else { throw failure("Percorso di export non valido.") }
        }
    }

    static func partName(_ index: Int) -> String { String(format: "part-%04d", index) }
    static func logicalName(_ index: Int) -> String { String(format: "logical-%04d.dump", index) }

    static func digest(_ url: URL) throws -> String {
        guard try metadata(url).st_mode & S_IFMT == S_IFREG else {
            throw failure("backup_manifest non e' un file regolare.")
        }
        return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

}
