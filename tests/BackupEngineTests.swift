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

    func test_terminalStatusNeverClaimsWorkInProgress() throws {
        let state = AppUIState()
        state.appState = .idle
        for terminal in ["idle", "cancelled", "error"] {
            let status = BackupStatusFile(state: terminal, phase: "finalizing", etaSecs: 42)
            state.status = status
            try expectEqual(status.progressDetail, "", "terminal metadata is not an active phase")
            try expectEqual(state.progressDetail, "", "idle UI never inherits an old active phase")
            try expectNil(state.progressFraction, "idle UI has no running percentage")
        }
    }

    func test_backupActivityAndFinishTimeAreExplicit() throws {
        let start = Date(timeIntervalSince1970: 1_791_705_600)
        let finish = start.addingTimeInterval(699)
        let iso = ISO8601DateFormatter()
        let state = AppUIState()
        state.protection = ProtectionSummary(
            level: .protected, headline: "Protetto", detail: "", lastComplete: "snapshot",
            lastCompleteDate: start, latestIsIncomplete: false, latestReasons: [],
            looksLikeNewMac: false, days: [], reposWithSavedCommits: 0, databasesSaved: 0,
            lastCompleteFinishedDate: finish.addingTimeInterval(-180))
        var status = BackupStatusFile(state: "running", phase: "scanning",
                                      startedAt: iso.string(from: start))
        state.appState = .running
        state.status = status
        try expectEqual(state.backupHeadline, "Backup in corso", "discovery is active")
        try expect(state.backupDetail.contains("Avviato \(ProtectionSummary.dateLabel(start))"), "start is named as start")
        try expect(state.backupDetail.contains("Ancora in corso"), "activity is explicit")
        status.phase = "finalizing"
        status.beginFinalizationStep("Salvo il database 1 di 2", at: finish)
        try expectEqual(status.currentFile, "Salvo il database 1 di 2", "actual step is displayed")
        try expectEqual(status.finalizationStepDate, finish, "step timer uses actual start")
        try expectNil(status.progressFraction, "finalization has no invented percentage")
        let roundTrip = try JSONDecoder().decode(BackupStatusFile.self, from: JSONEncoder().encode(status))
        try expectEqual(roundTrip.finalizationStepDate, finish, "step timestamp survives status polling")
        var dbProgress: [(Int, Int)] = []
        _ = DatabaseDumps.captureAll(config: DatabaseConfig(sqlite: ["/nonexistent-mb4d-test.sqlite"]),
                                    home: "/nonexistent-mb4d-test-home",
                                    into: URL(fileURLWithPath: "/nonexistent-mb4d-test-snapshot"),
                                    onProgress: { dbProgress.append(($0, $1)) })
        try expectEqual(dbProgress.map { $0.0 }, [1], "database step reports actual index")
        try expectEqual(dbProgress.map { $0.1 }, [1], "database step reports configured total")
        state.status = status
        try expectEqual(state.backupHeadline, "Backup: fase finale", "finalization is distinct from copying")
        try expect(state.backupDetail.contains("Non scollegare il disco"), "finalization is not safe completion")
        try expect(!state.backupDetail.contains("Terminato"), "no premature completion")

        state.appState = .idle
        status.state = "idle"; status.lastResult = "complete"
        try expectNil(status.finalizationStepDate, "terminal metadata cannot keep the activity timer running")
        status.lastSnapshot = "snapshot"; status.lastCompleteAt = iso.string(from: finish)
        state.status = status
        try expectEqual(state.backupHeadline, "Backup completato", "idle and manifest complete")
        try expect(state.backupDetail.contains("Terminato \(ProtectionSummary.dateLabel(finish))"), "matching operation uses actual finish")
        try expect(state.backupDetail.contains("Nessun backup in corso"), "idle is explicit")
        status.state = "cancelled"
        state.status = status
        try expectEqual(state.backupHeadline, "Backup interrotto", "previous protection cannot hide cancellation")
        try expect(state.backupDetail.contains("ultimo tentativo è stato interrotto"), "retained successful history is not this attempt")
        try expect(!state.backupDetail.contains("Terminato"), "cancelled attempt never claims completion")
        status.state = "idle"
        status.lastSnapshot = "another-snapshot"
        state.status = status
        let manifestFinish = finish.addingTimeInterval(-180)
        try expect(state.backupDetail.contains("Terminato \(ProtectionSummary.dateLabel(manifestFinish))"), "unrelated status cannot override manifest")
        state.protection?.lastCompleteFinishedDate = nil
        try expect(state.backupDetail.contains("Avviato \(ProtectionSummary.dateLabel(start))"), "legacy fallback never calls start the finish")
        try expect(!state.backupDetail.contains("Terminato"), "unknown finish remains unknown")
        state.protection?.level = .attention
        state.protection?.headline = "Ultimo backup incompleto"
        try expectEqual(state.backupHeadline, "Ultimo backup incompleto", "attention is not changed into success")
    }
}
