import Foundation

/// Only directories created successfully during this snapshot are cached.
final class BackupDirectories: @unchecked Sendable {
    private let lock = NSLock()
    private var prepared: Set<String> = []

    func prepare(_ path: String) throws {
        if lock.withLock({ prepared.contains(path) }) { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        lock.withLock { _ = prepared.insert(path) }
    }

    func invalidate(_ path: String) {
        lock.withLock { _ = prepared.remove(path) }
    }
}

struct BackupStats {
    var filesHardlinked: UInt64 = 0
    var filesCopied: UInt64 = 0
    var dirsCreated: UInt64 = 0
    var bytesCopied: UInt64 = 0
    var filesSkipped: UInt64 = 0
}

enum FileResult {
    case hardlinked
    case copied(bytes: UInt64)
    /// Deliberately not copied. A skip is a decision, not a failure, so it is kept apart from
    /// `.error` — but it still carries the path and the reason, because a file missing from
    /// the backup must always be explainable.
    case skipped(path: String, reason: String)
    case error(path: String, error: Error)
}

enum BackupError: LocalizedError {
    case sourceNotFound(String)
    case volumeNotMounted(String)
    case notWritable(String)
    case insufficientSpace(UInt64)
    case diskDisconnected
    case lockExists
    case cancelled
    case forbiddenPath(String)
    case sourceFilesVanishing

    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let p):    return "Cartella da salvare non trovata: \(p)"
        case .volumeNotMounted(let p):  return "Disco di backup non collegato: \(p)"
        case .notWritable(let p):       return "Non posso scrivere sul disco di backup: \(p)"
        case .insufficientSpace(let b): return "Spazio insufficiente sul disco di backup: \(b / 1_048_576) MB liberi"
        case .diskDisconnected:         return "Il disco di backup si è scollegato durante il backup"
        case .lockExists:               return "C'è già un backup in corso"
        case .cancelled:                return "Backup annullato"
        case .forbiddenPath(let p):     return "Cartella protetta dal sistema, non salvabile: \(p)"
        case .sourceFilesVanishing:     return "Backup fermato: i file stanno sparendo mentre li copio (probabile iCloud che libera spazio). Mi sono fermato per proteggere i tuoi dati."
        }
    }
}

extension BackupStatusFile {
    init() {
        state = "idle"
        phase = ""
        startedAt = ""
        lastCompleted = ""
        lastDurationSecs = 0
        filesTotal = 0
        filesDone = 0
        bytesCopied = 0
        bytesPerSec = 0
        etaSecs = 0
        errors = 0
        filesSkipped = 0
        currentFile = ""
    }
}
