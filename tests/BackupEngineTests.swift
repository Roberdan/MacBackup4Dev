import Foundation

final class BackupEngineTests {
    func test_snapshotNaming() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = formatter.string(from: Date())
        try expectEqual(name.count, 17, "Snapshot name length should be 17")
        try expectNotNil(RetentionManager.parseBackupName(name), "Snapshot name should parse")
    }

    func test_inProgressPrefix() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "in-progress-\(formatter.string(from: Date()))"
        try expect(name.hasPrefix("in-progress-"), "in-progress prefix missing")
    }

    func test_statusFileFormat() throws {
        let status = BackupStatusFile()
        let data = try JSONEncoder().encode(status)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            try fail("Status JSON should decode to dictionary")
            return
        }
        for key in ["state", "started_at", "last_completed", "files_total", "files_done", "bytes_copied", "bytes_per_sec", "eta_secs", "errors", "current_file"] {
            try expectNotNil(json[key], "Missing key in status JSON: \(key)")
        }
    }

    func test_progressUnknownUntilScanFinishes() throws {
        var status = BackupStatusFile(state: "running")
        for done in [UInt64(10_000), 100_000, 151_000] {
            status.updateCopyProgress(discovered: done + 4096, completed: done,
                                      scanFinished: false, bytesCopied: 20_000_000, elapsed: 1200)
            try expectEqual(status.filesTotal, done + 4096, "only the actual discovered count")
            try expectEqual(status.filesDone, done, "only completed workers")
            try expectEqual(status.etaSecs, 0, "no countdown for an unknown total")
            try expectNil(status.progressFraction, "no near-complete percentage during discovery")
            try expectEqual(status.progressDetail, "Totale in calcolo", "UI explains unknown total")
        }
    }

    func test_progressKnownCountsHardlinksAndFinalization() throws {
        var status = BackupStatusFile(state: "running")
        status.updateCopyProgress(discovered: 200, completed: 100, scanFinished: true,
                                  bytesCopied: 0, elapsed: 20)
        try expectEqual(status.etaSecs, 20, "file throughput works even when every file is hardlinked")
        try expectEqual(status.progressFraction, 0.5, "known denominator gives real percentage")
        status.updateCopyProgress(discovered: 200, completed: 200, scanFinished: true,
                                  bytesCopied: 0, elapsed: 40)
        try expectEqual(status.etaSecs, 0, "no remaining copies")
        try expectEqual(status.progressFraction, 0.99, "100% is reserved for completion")
        status.phase = "finalizing"; status.etaSecs = 42
        try expectNil(status.progressFraction, "Git and database capture is not a finished backup")
        try expectEqual(status.progressDetail, "Verifica finale", "stale copy ETA is not displayed")
    }

    func test_oldStatusDoesNotDisplayInventedEta() throws {
        let original = BackupStatusFile(state: "running", phase: "copying", filesTotal: 156_000,
                                        filesDone: 151_000, etaSecs: 42)
        let decoded = try JSONDecoder().decode(BackupStatusFile.self, from: JSONEncoder().encode(original))
        try expectNil(decoded.scanFinished, "older files remain readable")
        try expectNil(decoded.progressFraction, "unknown old denominator must not appear as 96%")
        try expectEqual(decoded.progressDetail, "Totale in calcolo", "old 42-second countdown is suppressed")
    }

    func test_restoreAndStoppingProgressRemainAccurate() throws {
        let state = AppUIState()
        state.status = BackupStatusFile(state: "running", phase: "copying", filesTotal: 10, filesDone: 5, etaSecs: 42)
        state.appState = .restoring
        try expectEqual(state.progressFraction, 0.5, "restore has a known total, independent of backup scan")
        try expectEqual(state.progressDetail, "Ripristino dei file", "restore does not inherit a backup ETA")
        state.appState = .stopping
        try expectNil(state.progressFraction, "cancellation has no completion estimate")
        try expectEqual(state.progressDetail, "Chiusura in corso", "stop remains distinct")
    }
}
