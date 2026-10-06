import Foundation

/// A consistent copy of one database, stored under `_rustymacbackup/databases/`.
/// Database files are excluded from the plain file copy (`*.db`, `*.sqlite`): copying a live
/// SQLite file can produce a corrupt copy, and Postgres keeps its data outside the home.
/// Scar 2026-10-06: VirtualBPM's history.db and the gbrain database were simply not in any
/// snapshot.
struct DatabaseRecord: Codable, Equatable {
    var kind: String          // "sqlite" | "postgres"
    var source: String        // ~/path for sqlite, database name for postgres
    var file: String?         // path inside the snapshot, relative to its root
    var bytes: UInt64
    var error: String?
}

struct DatabaseConfig: Equatable {
    var sqlite: [String] = []
    var postgres: [String] = []
}

enum DatabaseDumps {
    static let directoryName = "databases"

    static var sqlite3: String? { Shell.find(["/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3"]) }

    /// pg_dump must not be older than the server: prefer the newest Homebrew keg.
    static var pgDump: String? {
        let fm = FileManager.default
        var candidates: [String] = []
        for root in ["/opt/homebrew/opt", "/usr/local/opt"] {
            let kegs = ((try? fm.contentsOfDirectory(atPath: root)) ?? [])
                .filter { $0.hasPrefix("postgresql@") }
                .sorted { (Int($0.dropFirst("postgresql@".count)) ?? 0) > (Int($1.dropFirst("postgresql@".count)) ?? 0) }
            candidates += kegs.map { "\(root)/\($0)/bin/pg_dump" }
        }
        candidates += ["/opt/homebrew/bin/pg_dump", "/usr/local/bin/pg_dump",
                       "/Applications/Postgres.app/Contents/Versions/latest/bin/pg_dump"]
        return Shell.find(candidates)
    }

    static func captureAll(config: DatabaseConfig, home: String, into snapshot: URL) -> [DatabaseRecord] {
        let root = snapshot.appendingPathComponent(SnapshotManifest.directoryName)
            .appendingPathComponent(directoryName)
        var records: [DatabaseRecord] = []
        for path in config.sqlite {
            records.append(captureSQLite(path: path, home: home, root: root, snapshot: snapshot))
        }
        for name in config.postgres {
            records.append(capturePostgres(database: name, root: root, snapshot: snapshot))
        }
        return records
    }

    static func captureSQLite(path: String, home: String, root: URL, snapshot: URL) -> DatabaseRecord {
        let expanded = ConfigDiscovery.expand(path)
        var record = DatabaseRecord(kind: "sqlite", source: path, file: nil, bytes: 0)
        guard FileManager.default.fileExists(atPath: expanded) else {
            // A database that does not exist yet is not a failure (the app creates it later).
            record.error = nil
            return record
        }
        guard let sqlite3 else { record.error = "sqlite3 non trovato"; return record }
        let rel = expanded.hasPrefix(home + "/") ? String(expanded.dropFirst(home.count + 1))
                                                  : URL(fileURLWithPath: expanded).lastPathComponent
        let target = root.appendingPathComponent("sqlite").appendingPathComponent(rel)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            record.error = error.localizedDescription
            return record
        }
        // `.backup` uses SQLite's online backup API: consistent even while the app writes.
        let escaped = target.path.replacingOccurrences(of: "'", with: "''")
        // No -readonly: a WAL database opened read-only cannot create its -shm file and fails
        // with "unable to open database file". `.backup` only reads the source anyway.
        let result = Shell.run(sqlite3, [expanded, ".timeout 10000", ".backup '\(escaped)'"],
                               timeout: 600)
        if result.ok, let size = fileSize(target) {
            record.file = relative(target, to: snapshot)
            record.bytes = size
        } else {
            record.error = String(result.stderr.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            if record.error?.isEmpty ?? true { record.error = "copia non riuscita" }
        }
        return record
    }

    static func capturePostgres(database: String, root: URL, snapshot: URL) -> DatabaseRecord {
        var record = DatabaseRecord(kind: "postgres", source: database, file: nil, bytes: 0)
        guard let pgDump else { record.error = "pg_dump non trovato"; return record }
        let target = root.appendingPathComponent("postgres").appendingPathComponent("\(database).dump")
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            record.error = error.localizedDescription
            return record
        }
        // Custom format: compressed, restorable table by table with pg_restore.
        let result = Shell.run(pgDump, ["-Fc", "--no-password", "-d", database, "-f", target.path],
                               timeout: 1800)
        if result.ok, let size = fileSize(target) {
            record.file = relative(target, to: snapshot)
            record.bytes = size
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } else {
            record.error = String(result.stderr.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            if record.error?.isEmpty ?? true { record.error = "dump non riuscito" }
        }
        return record
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64
    }

    private static func relative(_ url: URL, to base: URL) -> String {
        let b = base.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(b) ? String(p.dropFirst(b.count)) : p
    }
}
