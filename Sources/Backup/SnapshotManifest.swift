import Foundation

/// Written into every snapshot at `_rustymacbackup/manifest.json` before the snapshot is
/// renamed to its final name. It is the only thing that says whether a snapshot is safe to
/// restore from: a snapshot without one predates 3.0 and is shown as "non verificato".
///
/// Scar 2026-10-06: a snapshot holding a third of the files was named like a good one, the
/// restore picked it by default and a whole day went into putting the Mac back together.
struct SnapshotManifest: Codable, Equatable {
    var formatVersion: Int = 1
    var appVersion: String
    var host: String
    var startedAt: String
    var finishedAt: String
    var sources: [String]
    var missingSources: [String]
    var filesDiscovered: Int64
    var filesProcessed: Int64
    var filesCopied: Int64
    var filesHardlinked: Int64
    var filesSkipped: Int64
    var bytesCopied: UInt64
    var errorCount: Int
    var traversalErrorCount: Int
    var git: [GitRepoRecord]
    var databases: [DatabaseRecord]
    /// Set when the home holds far fewer files than the last complete snapshot: a freshly
    /// reinstalled or emptied Mac. Such a snapshot is never the default and never a reason
    /// to prune anything.
    var shrinkWarning: String?
    var complete: Bool
    var incompleteReasons: [String]

    static let directoryName = "_rustymacbackup"
    static let fileName = "manifest.json"

    static func url(in snapshot: URL) -> URL {
        snapshot.appendingPathComponent(directoryName).appendingPathComponent(fileName)
    }

    static func read(from snapshot: URL) -> SnapshotManifest? {
        guard let data = try? Data(contentsOf: url(in: snapshot)) else { return nil }
        return try? JSONDecoder().decode(SnapshotManifest.self, from: data)
    }

    func write(to snapshot: URL) throws {
        let target = Self.url(in: snapshot)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: target, options: .atomic)
    }

    /// Decide completeness from the counts. Kept pure so the rule is testable on its own.
    static func evaluate(discovered: Int64, processed: Int64, walkerFinished: Bool,
                         errors: Int, traversalErrors: Int, gitFailures: [String],
                         databaseFailures: [String], shrinkWarning: String?) -> (Bool, [String]) {
        var reasons: [String] = []
        if !walkerFinished {
            reasons.append("La scansione delle cartelle non è arrivata in fondo.")
        }
        if processed < discovered {
            reasons.append("\(discovered - processed) file trovati ma non copiati.")
        }
        if errors > 0 {
            reasons.append("\(errors) file non copiati per errore (dettagli in errors.json).")
        }
        if traversalErrors > 0 {
            reasons.append("\(traversalErrors) cartelle non leggibili.")
        }
        for failure in gitFailures {
            reasons.append("Commit non pubblicati non salvati: \(failure).")
        }
        for failure in databaseFailures {
            reasons.append("Database non salvato: \(failure).")
        }
        if let shrink = shrinkWarning {
            reasons.append(shrink)
        }
        return (reasons.isEmpty, reasons)
    }

    /// A home with less than 30% of the files of the last complete snapshot is not a normal
    /// day: it is a new Mac, a wiped home or a broken mount. Small trees are ignored.
    static func shrinkWarning(processed: Int64, previous: SnapshotManifest?) -> String? {
        guard let previous, previous.complete, previous.filesProcessed >= 1_000 else { return nil }
        guard Double(processed) < Double(previous.filesProcessed) * 0.3 else { return nil }
        return "Questo Mac ha molti meno file dell'ultimo backup completo "
            + "(\(processed) contro \(previous.filesProcessed)): sembra nuovo o svuotato. "
            + "Lo snapshot non sostituisce quello completo."
    }
}

enum SnapshotState: String, Codable {
    case complete
    case incomplete
    /// Created before 3.0: no manifest, so nobody checked whether it is whole.
    case unverified

    var label: String {
        switch self {
        case .complete: return "completo"
        case .incomplete: return "incompleto"
        case .unverified: return "non verificato"
        }
    }
}

struct SnapshotInfo {
    let name: String
    let url: URL
    let timestamp: Date
    let manifest: SnapshotManifest?

    var state: SnapshotState {
        guard let manifest else { return .unverified }
        return manifest.complete ? .complete : .incomplete
    }
}

/// Every snapshot at a destination with its state. The single place that answers "which
/// snapshot is good": restore defaults, retention protection and the menu all ask here.
enum SnapshotCatalog {
    static func list(at destination: URL) -> [SnapshotInfo] {
        RetentionManager.listBackups(at: destination).map {
            SnapshotInfo(name: $0.name, url: $0.url, timestamp: $0.timestamp,
                         manifest: SnapshotManifest.read(from: $0.url))
        }
    }

    static func latestComplete(at destination: URL) -> SnapshotInfo? {
        list(at: destination).first { $0.state == .complete }
    }

    /// The snapshot a restore should offer first: the newest complete one; without any, the
    /// newest unverified one (pre-3.0 history). An incomplete snapshot is never the default.
    static func defaultForRestore(at destination: URL) -> SnapshotInfo? {
        let all = list(at: destination)
        return all.first { $0.state == .complete } ?? all.first { $0.state == .unverified }
    }
}
