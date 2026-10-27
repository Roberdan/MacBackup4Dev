import Foundation
import Darwin

extension PostgresBackup {
    private struct BackupIdentity: Decodable {
        var version: Int
        var systemIdentifier: UInt64
        enum CodingKeys: String, CodingKey {
            case version = "PostgreSQL-Backup-Manifest-Version"
            case systemIdentifier = "System-Identifier"
        }
    }

    private static func checkStorage(_ directory: URL) throws {
        try walk(directory) { file, _ in
            if file.lastPathComponent.range(of: "_init(?:\\.[0-9]+)?$", options: .regularExpression) != nil {
                throw failure("Il backup contiene una tabella unlogged: il suo contenuto non e' protetto.")
            }
        }
        let tablespaces = directory.appendingPathComponent("pg_tblspc")
        if FileManager.default.fileExists(atPath: tablespaces.path),
           !(try FileManager.default.contentsOfDirectory(atPath: tablespaces.path)).isEmpty {
            throw failure("Il backup contiene tablespace non supportati.")
        }
    }

    static func verify(_ chain: Chain, at directory: URL, tools: Tools,
                       cancelled: () -> Bool = { false }) throws {
        try validate(chain)
        for input in chain.inputs {
            try verifyInput(input, server: chain.server, at: directory, tools: tools, cancelled: cancelled)
        }
        try verifyRelationship(chain, at: directory, tools: tools, cancelled: cancelled)
    }

    private static func verifyInput(_ input: Input, server: Server, at directory: URL, tools: Tools,
                                    cancelled: () -> Bool) throws {
        if cancelled() { throw BackupError.cancelled }
        let part = directory.appendingPathComponent(input.name)
        try checkStorage(part)
        let manifest = part.appendingPathComponent("backup_manifest")
        guard try digest(manifest) == input.manifestSHA256 else {
            throw failure("Il manifesto di \(input.name) e' cambiato.")
        }
        let identity = try JSONDecoder().decode(BackupIdentity.self, from: Data(contentsOf: manifest))
        guard identity.version == 2, String(identity.systemIdentifier) == server.systemIdentifier else {
            throw failure("Il backup appartiene a un altro cluster PostgreSQL.")
        }
        _ = try run(tools.path("pg_verifybackup"), [part.path], environment: nil,
                    timeout: 1800, cancelled: cancelled)
    }

    private static func verifyRelationship(_ chain: Chain, at directory: URL, tools: Tools,
                                           cancelled: () -> Bool) throws {
        try validate(chain)
        _ = try run(tools.path("pg_combinebackup"),
                    ["--dry-run", "--output", directory.appendingPathComponent(".verify-" + UUID().uuidString).path]
                    + chain.inputs.map { directory.appendingPathComponent($0.name).path },
                    environment: nil, timeout: 120, cancelled: cancelled)
        for export in chain.logical {
            guard try metadata(directory.appendingPathComponent(export.file)).st_mode & S_IFMT == S_IFREG else {
                throw failure("Export logico mancante o non regolare.")
            }
        }
    }

    private static func linkTree(from source: URL, to target: URL,
                                 cancelled: () -> Bool) throws {
        if cancelled() { throw BackupError.cancelled }
        let value = try metadata(source)
        switch value.st_mode & S_IFMT {
        case S_IFDIR:
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try linkTree(from: child, to: target.appendingPathComponent(child.lastPathComponent), cancelled: cancelled)
            }
        case S_IFREG:
            try HardLinker.hardLink(from: source.path, to: target.path)
            let linked = try metadata(target)
            guard linked.st_dev == value.st_dev, linked.st_ino == value.st_ino,
                  linked.st_size == value.st_size,
                  linked.st_mtimespec.tv_sec == value.st_mtimespec.tv_sec,
                  linked.st_mtimespec.tv_nsec == value.st_mtimespec.tv_nsec else {
                throw failure("Il disco non ha creato un vero hard link.")
            }
        default: throw failure("Non posso riusare un link simbolico o un file speciale.")
        }
    }

    static func capture(databases: [String], into snapshot: URL, previousSnapshot: URL?,
                        now: Date, environment: [String: String]?,
                        cancelled: () -> Bool = { false }) throws -> DatabaseRecord {
        guard let pgDump = DatabaseDumps.pgDump else { throw failure("PostgreSQL non installato.") }
        let psql = URL(fileURLWithPath: pgDump).deletingLastPathComponent().appendingPathComponent("psql").path
        let server = try inspect(databases: databases, psql: psql, environment: environment, cancelled: cancelled)
        let tools = try Tools.find(major: server.major)
        let directory = snapshot.appendingPathComponent(relativeRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var chain = Chain(server: server, fullAt: now, capturedAt: now, inputs: [], logical: [], fullReason: nil)
        if let previousSnapshot,
           SnapshotManifest.read(from: previousSnapshot)?.databases.contains(where: { $0.kind == kind && $0.file != nil }) == true {
            do {
                let previous = try readChain(in: previousSnapshot)
                let age = now.timeIntervalSince(previous.fullAt)
                if previous.server == server, age >= 0, age < fullInterval,
                   previous.inputs.count <= maxIncrementals {
                    let previousRoot = try root(in: previousSnapshot)
                    try verify(previous, at: previousRoot, tools: tools, cancelled: cancelled)
                    for name in previous.inputs.map(\.name) + previous.logical.map(\.file) {
                        try linkTree(from: previousRoot.appendingPathComponent(name),
                                     to: directory.appendingPathComponent(name), cancelled: cancelled)
                    }
                    chain = previous
                    chain.capturedAt = now
                    chain.fullReason = nil
                } else {
                    chain.fullReason = "Nuova base: intervallo, limite della catena o identita' del server cambiata."
                }
            } catch {
                if cancelled() { throw BackupError.cancelled }
                chain.fullReason = "Nuova base: catena precedente non riutilizzabile (\(error.localizedDescription))."
                try FileManager.default.removeItem(at: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
        }
        if let reason = chain.fullReason { Log.warn(reason) }
        var part = directory.appendingPathComponent(partName(chain.inputs.count))
        func takeBackup(incremental: Bool) throws {
            // Fetch uses one process: cancellation cannot orphan a WAL-streaming child.
            var args = ["--pgdata", part.path, "--format=plain", "--wal-method=fetch",
                        "--checkpoint=fast", "--no-password"]
            if incremental, let last = chain.inputs.last {
                args += ["--incremental", directory.appendingPathComponent(last.name)
                    .appendingPathComponent("backup_manifest").path]
            }
            _ = try run(tools.path("pg_basebackup"), args, environment: environment,
                        timeout: 1800, cancelled: cancelled)
        }
        do {
            try takeBackup(incremental: !chain.inputs.isEmpty)
        } catch {
            if cancelled() { throw BackupError.cancelled }
            guard !chain.inputs.isEmpty else { throw error }
            let reason = "Nuova base: l'incrementale non e' disponibile (\(error.localizedDescription))."
            Log.warn(reason)
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            chain = Chain(server: server, fullAt: now, capturedAt: now, inputs: [], logical: [], fullReason: reason)
            part = directory.appendingPathComponent(partName(0))
            try takeBackup(incremental: false)
        }
        var newBytes: UInt64 = 0
        try walk(part) { _, value in newBytes += UInt64(max(0, value.st_size)) }
        chain.inputs.append(Input(name: part.lastPathComponent,
                                  manifestSHA256: try digest(part.appendingPathComponent("backup_manifest"))))
        if chain.inputs.count == 1 {
            for (index, database) in server.databases.enumerated() {
                let file = directory.appendingPathComponent(logicalName(index))
                _ = try run(tools.path("pg_dump"), ["-Fc", "--no-password", "-d", database, "-f", file.path],
                            environment: environment, timeout: 1800, cancelled: cancelled)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                newBytes += UInt64(max(0, try metadata(file).st_size))
                chain.logical.append(LogicalExport(database: database, file: file.lastPathComponent))
            }
        }
        let after = try inspect(databases: databases, psql: tools.path("psql"),
                                environment: environment, cancelled: cancelled)
        guard server == after else { throw failure("Il cluster e' cambiato durante il backup; snapshot non completo.") }
        // Parents were verified before linking and still use those same inodes.
        try verifyInput(chain.inputs[chain.inputs.count - 1], server: server,
                        at: directory, tools: tools, cancelled: cancelled)
        try verifyRelationship(chain, at: directory, tools: tools, cancelled: cancelled)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(chain)
        let manifest = directory.appendingPathComponent("chain.json")
        try data.write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        return DatabaseRecord(kind: kind, source: "PostgreSQL (cluster)", file: relativeManifest,
                              bytes: newBytes + UInt64(data.count), databaseNames: server.databases)
    }
}
