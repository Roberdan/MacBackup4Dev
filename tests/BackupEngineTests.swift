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
        try expect(state.canRefreshBackupProgress, "active backup permits visible progress updates")
        try expectNil(state.backupFileActivity, "startup text is not a file")
        status.filesDone = 500
        status.currentFile = "Documents/Progetto molto lungo/relazione.txt"
        state.status = status
        try expectEqual(state.backupFileActivity?.name, "relazione.txt", "filename is separate from its folder")
        try expectEqual(state.backupFileActivity?.directory, "Documents/Progetto molto lungo",
                        "folder remains available without obscuring the filename")
        try expectEqual(state.backupFileActivity?.path, status.currentFile, "full path is retained for help")
        status.phase = "copying"; status.currentFile = ".zshrc"
        state.status = status
        try expectEqual(state.backupFileActivity?.name, ".zshrc", "root-level dotfile names remain intact")
        try expectEqual(state.backupFileActivity?.directory, "", "root-level files have no invented folder")
        state.cleanupPhase = .reading
        try expect(!state.canRefreshBackupProgress, "cleanup prevents extra progress reads")
        state.cleanupPhase = nil
        state.ejection = EjectionFeedback(disk: URL(fileURLWithPath: "/Volumes/Backup demo"), phase: .closingStore)
        try expect(!state.canRefreshBackupProgress, "ejection prevents extra progress reads")
        state.ejection = nil
        state.appState = .restoring
        try expect(!state.canRefreshBackupProgress, "backup polling cannot overwrite restore progress")
        try expectNil(state.backupFileActivity, "restore is not presented as backup file activity")
        state.appState = .running
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
        try expectNil(state.backupFileActivity, "finalization text is not a filename")
        try expectEqual(state.backupHeadline, "Backup: fase finale", "finalization is distinct from copying")
        try expect(state.backupDetail.contains("Non scollegare il disco"), "finalization is not safe completion")
        try expect(!state.backupDetail.contains("Terminato"), "no premature completion")

        state.appState = .idle
        status.state = "idle"; status.lastResult = "complete"
        try expectNil(status.finalizationStepDate, "terminal metadata cannot keep the activity timer running")
        status.lastSnapshot = "snapshot"; status.lastCompleteAt = iso.string(from: finish)
        state.status = status
        try expect(!state.canRefreshBackupProgress, "idle stops extra progress reads")
        try expectNil(state.backupFileActivity, "idle cannot keep an old filename active")
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

    func test_backupActionsRequireAccessibleDisk() throws {
        let state = AppUIState()
        state.config = Config(source: SourceConfig(paths: []),
                              destination: DestinationConfig(path: "/Volumes/Backup demo/MacBackup4Dev"),
                              exclude: ExcludeConfig(patterns: []), retention: RetentionConfig())
        state.cachedHasBackups = true
        state.cachedCanUndo = true
        try expect(!state.canOpenBackupFolder && !state.canRestore, "cached history cannot enable an inaccessible disk")
        state.cachedBackupAccessible = true
        try expect(state.canOpenBackupFolder && state.canRestore, "mounted backup enables browsing and recovery")
        for mode in [AppState.diskAbsent, .needsSetup] {
            state.appState = mode
            try expect(!state.canOpenBackupFolder && !state.canRestore, "disconnected/setup state overrides stale cache")
        }
        state.appState = .idle
        state.storeOpening = true
        try expect(!state.canOpenBackupFolder && !state.canRestore, "opening the encrypted store is not readiness")
        state.storeOpening = false
        state.cleanupPhase = .reading
        try expect(!state.canOpenBackupFolder && !state.canRestore, "cleanup blocks backup access")
        state.cleanupPhase = nil
        for phase in [EjectionPhase.closingStore, .ejecting, .succeeded] {
            state.ejection = EjectionFeedback(disk: state.config!.diskURL, phase: phase)
            try expect(!state.canOpenBackupFolder && !state.canRestore, "eject and successful removal block stale access")
        }
        state.ejection = nil
        for mode in [AppState.running, .restoring, .stopping] {
            state.appState = mode
            try expect(state.canOpenBackupFolder, "read-only browsing remains available during a mounted operation")
            try expect(!state.canRestore, "recovery cannot start during another operation")
        }
        state.appState = .error
        try expect(state.canRestore, "a failed latest backup does not hide retained history")
        state.cachedBackupAccessible = false
        try expect(state.canUndo, "undo is local and remains available without the backup disk")
        state.cachedBackupAccessible = true
        state.cachedHasBackups = false
        try expect(state.canOpenBackupFolder && !state.canRestore, "an empty mounted destination can be browsed but not restored")
        state.config = nil
        try expect(!state.canOpenBackupFolder && !state.canRestore, "missing configuration cannot enable backup access")
    }
}
