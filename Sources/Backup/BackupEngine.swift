import Foundation
import Darwin

/// Knobs a test needs and the app does not: where "home" is, whether to run the slow
/// environment capture, git and database safety.
struct BackupRunOptions {
    var home: String = FileManager.default.homeDirectoryForCurrentUser.path
    var captureEnvironment = true
    var captureGit = true
    var captureDatabases = true
    var auditCoverage = true
    /// The coverage check at the end stops waiting after this long; tests shorten it.
    var coverageTimeLimit: TimeInterval = CoverageAuditor.timeLimit
    /// Tests replace the coverage walk to stand in for a folder that never answers.
    var coverageWalk: CoverageAuditor.Walk = CoverageAuditor.fullWalk
    var databaseEnvironment: [String: String]? = nil
    var now: () -> Date = { Date() }
    var environmentCapture: (URL) -> Void = EnvironmentSnapshot.capture
    var captureApplications = true
    var applicationRoots: [AppInventory.Root]? = nil
    var applicationCopyOptions = AppBundleCopy.Options()
    var applicationInstallers: [String: AppInstallers.Hint]? = nil
    /// Items `AutomaticCoverage` added to the settings just before this run (`~/` form).
    var automaticallyIncluded: [String] = []
}

/// Bounded hand-off between the scanner and the copy workers. Unlike a DispatchSemaphore it
/// can be opened for good on cancel without ending below its starting value (libdispatch
/// traps when such a semaphore is released, review R1).
final class QueueGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let limit: Int
    private var inFlight = 0
    private var isOpen = false

    init(limit: Int) { self.limit = limit }

    func acquire() {
        condition.lock()
        while inFlight >= limit && !isOpen { condition.wait() }
        inFlight += 1
        condition.unlock()
    }

    func release() {
        condition.lock()
        inFlight = max(0, inFlight - 1)
        condition.signal()
        condition.unlock()
    }

    /// Stop limiting: every waiting or future acquire returns at once.
    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

/// What a finished run was worth, for the caller (menu, CLI, notifications).
struct BackupRunResult {
    let snapshot: URL
    let manifest: SnapshotManifest
}

enum BackupEngine {
    static let STATUS_UPDATE_INTERVAL: Int = 500
    static let DISK_CHECK_INTERVAL: Int = 100
    static let MIN_FREE_SPACE: UInt64 = 1_073_741_824
    static let WORK_PRIORITY: TaskPriority = .background
    static let MAX_WORKERS = 4
    /// How many discovered files may wait for a copy worker. The walker blocks beyond
    /// this instead of dropping entries.
    static let QUEUE_LIMIT: Int = 4_096

    /// One token per run: a stale walker from a run that threw can never see the next
    /// run's flag reset and keep going (review M2).
    final class CancelToken: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func cancel() { lock.lock(); flag = true; lock.unlock() }
    }
    private static let currentLock = NSLock()
    nonisolated(unsafe) private static var current: CancelToken?

    static func stop() { currentLock.lock(); current?.cancel(); currentLock.unlock() }

    @discardableResult
    static func run(config: Config, statusWriter: StatusWriter = StatusWriter(),
                    options: BackupRunOptions = BackupRunOptions()) async throws -> BackupRunResult? {
        let token = CancelToken()
        currentLock.withLock { current = token }
        let destPath = config.destination.path
        let destURL = URL(fileURLWithPath: destPath)
        let home = options.home
        // What the settings gained by themselves is owed to a snapshot: remember it before any check
        // that can end the run (disk absent, store not open), and keep it until a snapshot records it.
        let carried = statusWriter.readPendingAdditions()
        let reportedAdditions = carried + options.automaticallyIncluded.filter { !carried.contains($0) }
        if !options.automaticallyIncluded.isEmpty {
            do { try statusWriter.writePendingAdditions(reportedAdditions) }
            catch { Log.error("Cannot remember the automatic additions: \(error.localizedDescription)") }
        }
        let excludeFilter = ExcludeFilter(patterns: config.exclude.patterns)
        let homePrefix = home.hasSuffix("/") ? home : home + "/"

        // Validate source paths: skip missing, block forbidden
        var allPaths: [String] = []
        var missing: [String] = []
        var sourceReasons: [String] = []
        for path in config.source.paths.map({ ConfigDiscovery.expand($0, home: home) }) {
            if WorktreePolicy.isTemporarySource(path, home: home) {
                Log.info("Skipping temporary linked worktree source: \(path)")
                continue
            }
            let contracted = ConfigDiscovery.contract(path)
            if ConfigDiscovery.isForbidden(contracted, allowCloudStorage: config.protection.includeCloudStorage) {
                Log.error("BLOCKED forbidden path: \(path)")
                throw BackupError.forbiddenPath(path)
            }
            let relative = path.hasPrefix(homePrefix)
                ? String(path.dropFirst(homePrefix.count)) : String(path.drop(while: { $0 == "/" }))
            if excludeFilter.isExcluded(relativePath: relative) {
                Log.info("Skipping excluded source: \(contracted)")
                continue
            }
            var metadata = stat()
            if stat(path, &metadata) == 0 {
                allPaths.append(path)
            } else {
                let code = errno
                if code == ENOENT {
                    missing.append(contracted)
                    Log.info("Skipping missing path: \(path)")
                    if path.hasPrefix("/Volumes/"), !isVolumeReallyMounted(path) {
                        sourceReasons.append("Il disco della sorgente \(contracted) non è collegato.")
                        Log.error("Source volume is not mounted: \(path)")
                    }
                } else {
                    let message = String(cString: strerror(code))
                    sourceReasons.append("La sorgente \(contracted) non è leggibile: \(message).")
                    Log.error("Cannot inspect source \(path): \(message)")
                }
            }
        }
        // Encrypted store: open it first (password from the Keychain) when its disk is there.
        try EncryptedStore.ensureOpen(config)
        guard isVolumeReallyMounted(destPath) else { throw BackupError.volumeNotMounted(destPath) }
        // An encrypted store can stay mounted after its disk is gone (scar 2026-10-11: the
        // unmount was refused, then the cable was pulled). Never write into or prune it.
        if let setup = config.encryption.setup,
           !(isVolumeReallyMounted(config.diskURL.path) && FileManager.default.fileExists(atPath: setup.container)) {
            throw BackupError.volumeNotMounted(config.diskURL.path)
        }
        // Security warning if backup disk is not encrypted
        if !DiskDiagnostics.checkEncryption(volume: destPath) {
            Log.warn("Backup disk is NOT encrypted -- sensitive data (SSH keys, tokens) at risk")
        }
        // Warn if iCloud Desktop & Documents is active (can cause bird evictions)
        if isiCloudDesktopActive() {
            Log.warn("iCloud Desktop & Documents sync is ACTIVE -- using bird-safe mode")
        }
        guard preflightWriteTest(at: destURL) else { throw BackupError.notWritable(destPath) }

        let operationLock = try DestinationLock(at: destURL)
        defer { withExtendedLifetime(operationLock) {} }
        let lockPath = destURL.appendingPathComponent("rustymacbackup.lock").path
        try acquireLock(at: lockPath)
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        let onBattery = IOPriority.isOnBattery()
        let previousIOPolicy = try IOPriority.beginBackup(onBattery: onBattery)
        defer {
            do { try IOPriority.setDiskPolicy(previousIOPolicy) }
            catch { Log.error("Cannot restore disk I/O priority: \(error.localizedDescription)") }
        }
        Log.info("Backup priorities: CPU=\(Task.currentPriority.rawValue), disk=\(IOPriority.backupPolicy(onBattery: onBattery, previous: previousIOPolicy)), workers=\(MAX_WORKERS)")
        // After the priorities: searching old snapshots walks a lot of folders and must be gentle.
        do {
            _ = try WorktreePolicy.cleanupLocked(at: destURL, home: home, cancelled: { token.isCancelled })
        } catch {
            Log.warn("Worktree cleanup deferred; backup will continue: \(error.localizedDescription)")
        }

        let previousComplete = SnapshotCatalog.latestComplete(at: destURL)
        // Without a verified snapshot yet (first 3.0 run), compare with the newest old one,
        // so a wiped Mac is recognised on day one too.
        let baselineFiles: Int64? = {
            guard previousComplete == nil, let latest = findLatestBackup(at: destURL) else { return nil }
            // A 3.0 snapshot already knows its size; only a pre-3.0 one is counted (once a
            // day at most, and never again after the first 3.0 snapshot).
            if let m = SnapshotManifest.read(from: latest) { return m.filesDiscovered }
            return countFiles(in: latest)
        }()

        // An encrypted store is sized as big as its disk: what counts is the free space of the
        // physical disk under it (the old unencrypted snapshots may still fill it), not only
        // the space inside the store (review 4.1 B2).
        func freeSpace() -> UInt64 { min(diskFreeSpace(at: destPath), diskFreeSpace(at: config.diskURL.path)) }
        if freeSpace() < MIN_FREE_SPACE {
            let _ = try RetentionManager.pruneLockedBackups(at: destURL, policy: config.retention, dryRun: false)
            if freeSpace() < MIN_FREE_SPACE {
                throw BackupError.insufficientSpace(freeSpace())
            }
        }

        let latestBackup = findLatestBackup(at: destURL)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let startTime = options.now()
        var timestamp = formatter.string(from: startTime)
        // Two runs in the same second (tests, a double click) must not collide.
        while FileManager.default.fileExists(atPath: destURL.appendingPathComponent(timestamp).path) {
            timestamp = formatter.string(from: Date(timeInterval: 1, since: formatter.date(from: timestamp)!))
        }
        let inProgressURL = destURL.appendingPathComponent("in-progress-\(timestamp)")
        try FileManager.default.createDirectory(at: inProgressURL, withIntermediateDirectories: true)

        // F-01: clean stale dirs only AFTER acquiring the lock
        cleanStaleInProgress(at: destURL)

        var status = statusWriter.read() ?? BackupStatusFile()
        status.state = "running"
        status.phase = "scanning"
        status.startedAt = ISO8601DateFormatter().string(from: startTime)
        status.autoIncluded = reportedAdditions
        status.filesDone = 0
        status.filesTotal = 0
        status.bytesCopied = 0
        status.errors = 0
        status.filesSkipped = 0
        status.bytesPerSec = 0
        status.etaSecs = 0
        status.scanFinished = false
        status.currentFile = "Avvio backup..."
        do { try statusWriter.write(status: status) } catch { Log.error("Status write failed at start: \(error)") }

        let sourceURLs = allPaths.map { URL(fileURLWithPath: $0) }
        // Always use HOME as basePath so snapshot preserves full relative paths:
        // ~/GitHub/MyRepo/file.swift → snapshot/GitHub/MyRepo/file.swift
        let homeBasePaths = Array(repeating: home, count: sourceURLs.count)

        // Use a class (heap ref) instead of UnsafeMutablePointer — ARC keeps it alive
        // for as long as the walkerTask closure references it, preventing use-after-free.
        final class Counters: @unchecked Sendable {
            private let lock = NSLock()
            private var discovered: Int64 = 0
            private var walkerDone = false
            private var traversalErrors: [(path: String, error: Error)] = []

            func discover() { lock.withLock { discovered += 1 } }
            func finish(completed: Bool) { lock.withLock { walkerDone = completed } }
            func recordError(path: String, error: Error) {
                lock.withLock { traversalErrors.append((path, error)) }
            }
            var snapshot: (discovered: Int64, walkerDone: Bool, traversalErrors: [(path: String, error: Error)]) {
                lock.withLock { (discovered: discovered, walkerDone: walkerDone, traversalErrors: traversalErrors) }
            }
        }
        let counters = Counters()

        // Scar 2026-10-06: this stream used `.bufferingNewest(256)`, which DROPS the oldest
        // waiting files whenever the walker runs ahead of the copy workers. Snapshots lost
        // up to two thirds of their files and were still named as good ones. The stream is
        // now unbounded and the walker waits on a semaphore instead: nothing is ever dropped,
        // and memory stays bounded by QUEUE_LIMIT.
        let (stream, continuation) = AsyncStream<FileEntry>.makeStream(bufferingPolicy: .unbounded)
        let slots = QueueGate(limit: QUEUE_LIMIT)

        let walkerTask = Task.detached(priority: WORK_PRIORITY) {
            FileScanner.walk(sources: sourceURLs, basePaths: homeBasePaths,
                           excludeFilter: excludeFilter,
                           onTraversalError: { path, error in
                               counters.recordError(path: path, error: error)
                           }) { entry in
                if token.isCancelled { return false }
                slots.acquire()
                if token.isCancelled { return false }
                counters.discover()
                continuation.yield(entry)
                return true
            }
            counters.finish(completed: !token.isCancelled)
            continuation.finish()
        }

        var stats = BackupStats()
        var errorList: [(path: String, error: Error)] = []
        var skipList: [(path: String, reason: String)] = []
        var processedCount: UInt64 = 0
        var completedCount: UInt64 = 0
        var vanishedCount = 0
        let VANISHED_THRESHOLD = 3
        let directories = BackupDirectories()

        let protectionGuard = RightsManagementGuard(config: config.protection)
        if protectionGuard.isActive {
            Log.info("Rights-managed documents excluded by preference -- local format inspection only")
        }

        // Helper: post-copy checks and stats merge (called from main task only — no data races)
        func handleResult(_ result: FileResult, entry: FileEntry) {
            completedCount += 1
            processResult(result, stats: &stats, errors: &errorList, skips: &skipList)
            let isShellFile = entry.relativePath.hasSuffix("shrc") || entry.relativePath.hasSuffix("profile")
                || entry.relativePath.hasSuffix("shenv") || entry.relativePath.hasSuffix("history")
            if result.savedFile && !isShellFile && !FileManager.default.fileExists(atPath: entry.absolutePath) {
                vanishedCount += 1
                Log.warn("Source file vanished after copy: \(entry.relativePath) (\(vanishedCount)/\(VANISHED_THRESHOLD))")
            }
        }

        var inFlight = 0
        do {
            try await withThrowingTaskGroup(of: (FileResult, FileEntry).self) { group in
                for await file in stream {
                    slots.release()
                    if token.isCancelled { break }
                    processedCount += 1

                    if processedCount % UInt64(DISK_CHECK_INTERVAL) == 0 {
                        guard FileManager.default.fileExists(atPath: inProgressURL.path) else {
                            throw BackupError.diskDisconnected
                        }
                    }

                    // Emergency stop: source files vanishing → bird eviction suspected
                    if vanishedCount >= VANISHED_THRESHOLD {
                        Log.error("EMERGENCY STOP: \(vanishedCount) source files vanished -- bird eviction suspected")
                        status.state = "error"
                        status.currentFile = "STOPPED: source files vanishing (iCloud eviction)"
                        try? statusWriter.write(status: status)
                        throw BackupError.sourceFilesVanishing
                    }

                    let destFile = inProgressURL.appendingPathComponent(file.relativePath).path
                    let prevFile = latestBackup.map { $0.appendingPathComponent(file.relativePath).path }

                    group.addTask(priority: WORK_PRIORITY) {
                        (await BackupEngine.processFile(entry: file, destFile: destFile,
                                                        prevFile: prevFile, protectionGuard: protectionGuard,
                                                        directories: directories), file)
                    }
                    inFlight += 1

                    if inFlight >= MAX_WORKERS {
                        if let (result, entry) = try await group.next() {
                            inFlight -= 1
                            handleResult(result, entry: entry)
                        }
                    }

                    if processedCount % UInt64(STATUS_UPDATE_INTERVAL) == 0 {
                        let counts = counters.snapshot
                        status.updateCopyProgress(discovered: UInt64(counts.discovered), completed: completedCount,
                                                  scanFinished: counts.walkerDone, bytesCopied: stats.bytesCopied,
                                                  elapsed: options.now().timeIntervalSince(startTime))
                        status.errors = UInt64(errorList.count)
                        status.filesSkipped = stats.filesSkipped
                        status.currentFile = file.relativePath
                        do { try statusWriter.write(status: status) }
                        catch { Log.error("Status write failed during backup: \(error)") }
                    }
                }

                for try await (result, entry) in group {
                    handleResult(result, entry: entry)
                }
            }
        } catch {
            // Stop the walker, release it if it waits for a slot, and wait for it to end:
            // nothing of this run may outlive it (review M1/M2).
            token.cancel()
            slots.open()
            await walkerTask.value
            throw error
        }

        // `for await` also ends silently when the Swift task is cancelled.
        if Task.isCancelled { token.cancel() }
        // A cancelled walker may be waiting for a slot: release it, then wait for it to end
        // so `walkerDone` and the traversal errors are final before they are judged.
        if token.isCancelled { slots.open() }
        await walkerTask.value

        let counts = counters.snapshot
        errorList.append(contentsOf: counts.traversalErrors)

        func abandonCancelledBackup() {
            do { try FileManager.default.removeItem(at: inProgressURL) }
            catch { Log.error("Cannot remove cancelled snapshot: \(error)") }
            status.state = "cancelled"
            status.phase = "cancelled"
            status.currentFile = "Backup annullato"
            do { try statusWriter.write(status: status) } catch { Log.error("Status write failed on cancel: \(error)") }
        }
        // F-02: Do NOT rename to final snapshot if cancelled — partial backup must not look valid.
        if token.isCancelled { abandonCancelledBackup(); return nil }

        // Git and database safety: written into the snapshot before it gets its final name.
        status.filesDone = completedCount
        status.filesTotal = UInt64(counts.discovered)
        status.scanFinished = true
        status.etaSecs = 0
        func reportFinalization(_ message: String) {
            status.beginFinalizationStep(message, at: options.now())
            do { try statusWriter.write(status: status) }
            catch { Log.error("Status write failed during finalization: \(error)") }
        }
        reportFinalization("Cerco i repository da proteggere…")
        let gitRecords = options.captureGit
            ? GitSafety.captureAll(sources: allPaths, excludeFilter: excludeFilter, home: home, into: inProgressURL,
                                   previousSnapshot: latestBackup,
                                   onProgress: { index, total in
                                       reportFinalization("Salvo i commit: repository \(index) di \(total)")
                                   })
            : []
        reportFinalization("Preparo le copie dei database…")
        let dbRecords = options.captureDatabases
            ? DatabaseDumps.captureAll(config: config.databases, home: home, into: inProgressURL,
                                     previousSnapshot: previousComplete?.url, now: options.now(),
                                     postgresEnvironment: options.databaseEnvironment,
                                     cancelled: { token.isCancelled || Task.isCancelled },
                                     onProgress: { index, total in
                                         reportFinalization("Salvo il database \(index) di \(total)")
                                     })
            : []

        if token.isCancelled || Task.isCancelled {
            abandonCancelledBackup()
            return nil
        }
        var applicationReport: AppCapture.Report?
        if options.captureApplications && config.applications.capture {
            var copyOptions = options.applicationCopyOptions
            let externallyCancelled = copyOptions.isCancelled
            copyOptions.isCancelled = { token.isCancelled || Task.isCancelled || externallyCancelled() }
            reportFinalization("Cerco le applicazioni da salvare…")
            applicationReport = AppCapture.capture(config: config, home: home,
                roots: options.applicationRoots ?? AppInventory.Root.standard(home: home),
                into: inProgressURL, previous: latestBackup, options: copyOptions,
                installers: options.applicationInstallers ?? AppInstallers.hints(),
                onProgress: { index, total in reportFinalization("Salvo l'applicazione \(index) di \(total)…") })
            sourceReasons.append(contentsOf: (applicationReport?.catalog.failures ?? []).map { "App non salvata: \($0)" })
        }
        if token.isCancelled || Task.isCancelled || applicationReport?.cancelled == true {
            abandonCancelledBackup()
            return nil
        }
        reportFinalization("Verifico e completo lo snapshot…")
        let traversalCount = counts.traversalErrors.count
        let copyErrors = errorList.count - traversalCount
        let shrink = SnapshotManifest.shrinkWarning(processed: Int64(processedCount),
                                                    previous: previousComplete?.manifest,
                                                    baselineFiles: baselineFiles)
        // Deleted sources stay recorded, not errors. Empty backups, unreadable sources and
        // an unexpectedly large drop in file count still fail the completeness checks.
        if allPaths.isEmpty { sourceReasons.append("Nessuna delle cartelle da salvare esiste su questo Mac.") }
        let (complete, reasons) = SnapshotManifest.evaluate(
            discovered: counts.discovered, processed: Int64(processedCount),
            walkerFinished: counts.walkerDone, errors: copyErrors, traversalErrors: traversalCount,
            gitFailures: gitRecords.compactMap { r in r.error.map { "\(r.relativePath) (\($0))" } },
            databaseFailures: dbRecords.compactMap { r in r.error.map { "\(r.source) (\($0))" } },
            shrinkWarning: shrink, otherReasons: sourceReasons)

        let manifest = SnapshotManifest(
            appVersion: appVersionString(), host: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            startedAt: ISO8601DateFormatter().string(from: startTime),
            finishedAt: ISO8601DateFormatter().string(from: options.now()),
            sources: allPaths.map { ConfigDiscovery.contract($0) }, missingSources: missing,
            filesDiscovered: counts.discovered, filesProcessed: Int64(processedCount),
            filesCopied: Int64(stats.filesCopied), filesHardlinked: Int64(stats.filesHardlinked),
            filesSkipped: Int64(stats.filesSkipped), bytesCopied: stats.bytesCopied,
            errorCount: copyErrors, traversalErrorCount: traversalCount,
            git: gitRecords, databases: dbRecords, shrinkWarning: shrink,
            complete: complete, incompleteReasons: reasons, applications: applicationReport?.summary,
            automaticallyIncluded: reportedAdditions.isEmpty ? nil : reportedAdditions)
        try manifest.write(to: inProgressURL)

        let finalURL = destURL.appendingPathComponent(timestamp)
        try FileManager.default.moveItem(at: inProgressURL, to: finalURL)
        // The snapshot is on disk with the additions in its manifest: nothing is owed any more.
        do { try statusWriter.writePendingAdditions([]) }
        catch { Log.error("Cannot clear the owed automatic additions: \(error.localizedDescription)") }
        if complete {
            Log.info("Snapshot \(timestamp) complete: \(processedCount) files")
        } else {
            Log.warn("Snapshot \(timestamp) INCOMPLETE: \(reasons.joined(separator: " | "))")
        }

        if options.captureEnvironment {
            reportFinalization("Registro l'ambiente di sviluppo…")
            // Run AFTER backup completes, in a non-interactive shell to avoid triggering kaku/dotfile managers
            Log.info("Capturing environment snapshot...")
            options.environmentCapture(finalURL)
            Log.info("Environment snapshot complete")
        }

        if !errorList.isEmpty || !skipList.isEmpty {
            // F-06: Use ErrorReporter for semantic keys (permission_denied, not_found, etc.)
            // Protection skips travel in the same report: a file absent from the backup must be
            // visible in exactly one place, whether it failed or was deliberately left out.
            try? statusWriter.writeErrors(
                errors: ErrorReporter.categorizeErrors(errorList, skips: skipList))
        }

        if !skipList.isEmpty {
            Log.info("\(skipList.count) file(s) excluded by protection preference -- see errors.json")
        }

        if options.auditCoverage {
            reportFinalization("Controllo la copertura del backup…")
            try? statusWriter.writeCoverage(CoverageAuditor.boundedReport(
                config: config, home: home, previous: statusWriter.readCoverage(), timeLimit: options.coverageTimeLimit,
                walk: options.coverageWalk, cancelled: { token.isCancelled || Task.isCancelled }))
        }

        let duration = options.now().timeIntervalSince(startTime)
        status.state = "idle"
        status.phase = "finalizing"
        status.filesDone = processedCount
        status.filesTotal = processedCount
        status.lastCompleted = ISO8601DateFormatter().string(from: options.now())
        status.lastDurationSecs = duration
        status.bytesPerSec = duration > 0 ? UInt64(Double(stats.bytesCopied) / duration) : 0
        status.etaSecs = 0
        status.currentFile = ""
        status.errors = UInt64(errorList.count)
        status.filesSkipped = stats.filesSkipped
        status.lastResult = complete ? "complete" : "incomplete"
        status.incompleteReasons = reasons
        status.lastSnapshot = timestamp
        status.applications = applicationReport?.summary
        if complete { status.lastCompleteAt = status.lastCompleted }
        else if status.lastCompleteAt == nil, let prev = previousComplete {
            status.lastCompleteAt = ISO8601DateFormatter().string(from: prev.timestamp)
        }
        do { try statusWriter.write(status: status) } catch { Log.error("Status write failed at completion: \(error)") }
        return BackupRunResult(snapshot: finalURL, manifest: manifest)
    }

    /// Bounded count of the files in a snapshot (old snapshots have no manifest).
    static func countFiles(in snapshot: URL, limit: Int64 = 3_000_000) -> Int64 {
        guard let e = FileManager.default.enumerator(at: snapshot, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: []) else { return 0 }
        var n: Int64 = 0
        for case let url as URL in e {
            if url.lastPathComponent == "_environment" || url.lastPathComponent == SnapshotManifest.directoryName {
                e.skipDescendants(); continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { n += 1 }
            if n >= limit { break }
        }
        return n
    }

    static func appVersionString() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
