import Foundation

struct BackupStatusFile: Codable {
    var state: String
    var phase: String          // F-21: scanning | copying | linking | finalizing | cancelled
    var startedAt: String
    var lastCompleted: String
    var lastDurationSecs: Double
    var filesTotal: UInt64
    var filesDone: UInt64
    var bytesCopied: UInt64
    var bytesPerSec: UInt64
    var etaSecs: UInt64
    var errors: UInt64
    var filesSkipped: UInt64
    var currentFile: String
    // 3.0: what the last finished backup was worth. Optional so older status files decode.
    var lastResult: String?            // "complete" | "incomplete"
    var lastCompleteAt: String?        // ISO 8601 of the newest complete snapshot
    var incompleteReasons: [String]?
    var lastSnapshot: String?

    enum CodingKeys: String, CodingKey {
        case state
        case phase
        case startedAt = "started_at"
        case lastCompleted = "last_completed"
        case lastDurationSecs = "last_duration_secs"
        case filesTotal = "files_total"
        case filesDone = "files_done"
        case bytesCopied = "bytes_copied"
        case bytesPerSec = "bytes_per_sec"
        case etaSecs = "eta_secs"
        case errors
        case filesSkipped = "files_skipped"
        case currentFile = "current_file"
        case lastResult = "last_result"
        case lastCompleteAt = "last_complete_at"
        case incompleteReasons = "incomplete_reasons"
        case lastSnapshot = "last_snapshot"
    }

    init(state: String = "idle", phase: String = "",
         startedAt: String = "", lastCompleted: String = "",
         lastDurationSecs: Double = 0,
         filesTotal: UInt64 = 0, filesDone: UInt64 = 0,
         bytesCopied: UInt64 = 0, bytesPerSec: UInt64 = 0,
         etaSecs: UInt64 = 0, errors: UInt64 = 0,
         filesSkipped: UInt64 = 0, currentFile: String = "") {
        self.state = state; self.phase = phase; self.startedAt = startedAt
        self.lastCompleted = lastCompleted; self.lastDurationSecs = lastDurationSecs
        self.filesTotal = filesTotal; self.filesDone = filesDone
        self.bytesCopied = bytesCopied; self.bytesPerSec = bytesPerSec
        self.etaSecs = etaSecs; self.errors = errors
        self.filesSkipped = filesSkipped; self.currentFile = currentFile
    }
}

struct CoverageReport: Codable {
    var checkedAt: String
    var gaps: [CoverageGap]
}

struct BackupErrorFile: Codable {
    var total: Int
    var timestamp: String
    var categories: [String: ErrorCategoryInfo]
}

struct ErrorCategoryInfo: Codable {
    var count: Int
    var files: [String]
}

final class StatusWriter {
    private static let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    static let directory = "\(home)/.local/share/macbackup4dev"
    static let statusPath = "\(directory)/status.json"
    static let errorPath = "\(directory)/errors.json"
    static let coveragePath = "\(directory)/coverage.json"

    /// Tests point this somewhere else: a test must never overwrite the real status while
    /// a real backup is running.
    let statusPath: String
    let errorPath: String
    let coveragePath: String

    init(directory: String = StatusWriter.directory) {
        statusPath = "\(directory)/status.json"
        errorPath = "\(directory)/errors.json"
        coveragePath = "\(directory)/coverage.json"
    }

    func write(status: BackupStatusFile) throws {
        try writeJSON(status, to: URL(fileURLWithPath: statusPath))
    }

    func writeErrors(errors: BackupErrorFile) throws {
        try writeJSON(errors, to: URL(fileURLWithPath: errorPath))
    }

    func writeCoverage(_ report: CoverageReport) throws {
        try writeJSON(report, to: URL(fileURLWithPath: coveragePath))
    }

    func readCoverage() -> CoverageReport? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: coveragePath)) else { return nil }
        return try? JSONDecoder().decode(CoverageReport.self, from: data)
    }

    func read() -> BackupStatusFile? {
        let url = URL(fileURLWithPath: statusPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BackupStatusFile.self, from: data)
    }

    private func writeJSON<T: Encodable>(_ payload: T, to fileURL: URL) throws {
        let fileManager = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)

        // Atomic write: write to temp then replace in one operation
        try data.write(to: fileURL, options: [.atomic])
    }
}
