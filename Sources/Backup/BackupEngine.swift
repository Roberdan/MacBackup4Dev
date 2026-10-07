import Foundation

/// Knobs a test needs and the app does not: where "home" is, whether to run the slow
/// environment capture, git and database safety.
struct BackupRunOptions {
    var home: String = FileManager.default.homeDirectoryForCurrentUser.path
    var captureEnvironment = true
    var captureGit = true
    var captureDatabases = true
    var auditCoverage = true
    var now: () -> Date = { Date() }
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
        currentLock.lock(); current = token; currentLock.unlock()
        let destPath = config.destination.path
        let destURL = URL(fileURLWithPath: destPath)
        let home = options.home

        // Validate source paths: skip missing, block forbidden
        var allPaths: [String] = []
        var missing: [String] = []
        for path in config.source.allExpandedPaths() {
            let contracted = ConfigDiscovery.contract(path)
            if ConfigDiscovery.isForbidden(contracted, allowCloudStorage: config.protection.includeCloudStorage) {
                Log.error("BLOCKED forbidden path: \(path)")
                throw BackupError.forbiddenPath(path)
            }
            if FileManager.default.fileExists(atPath: path) {
                allPaths.append(path)
            } else {
                missing.append(contracted)
                Log.info("Skipping missing path: \(path)")
            }
        }
        // Encrypted store: open it first (password from the Keychain) when its disk is there.
        try EncryptedStore.ensureOpen(config)
        guard isVolumeReallyMounted(destPath) else { throw BackupError.volumeNotMounted(destPath) }
        // Security warning if backup disk is not encrypted
        if !DiskDiagnostics.checkEncryption(volume: destPath) {
            Log.warn("Backup disk is NOT encrypted -- sensitive data (SSH keys, tokens) at risk")
        }
        // Warn if iCloud Desktop & Documents is active (can cause bird evictions)
        if isiCloudDesktopActive() {
            Log.warn("iCloud Desktop & Documents sync is ACTIVE -- using bird-safe mode")
        }
        // Throttle I/O on battery; use default priority on AC power
        let onBattery = IOPriority.isOnBattery()
        IOPriority.setIOPriority(throttle: onBattery)
        Log.info("I/O priority: \(onBattery ? "throttled (battery)" : "full speed (AC)")")
        guard preflightWriteTest(at: destURL) else { throw BackupError.notWritable(destPath) }

        let operationLock = try DestinationLock(at: destURL)
        defer { withExtendedLifetime(operationLock) {} }
        let lockPath = destURL.appendingPathComponent("rustymacbackup.lock").path
        try acquireLock(at: lockPath)
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

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

        if diskFreeSpace(at: destPath) < MIN_FREE_SPACE {
            let _ = try RetentionManager.pruneLockedBackups(at: destURL, policy: config.retention, dryRun: false)
            if diskFreeSpace(at: destPath) < MIN_FREE_SPACE {
                throw BackupError.insufficientSpace(diskFreeSpace(at: destPath))
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
        status.filesDone = 0
        status.filesTotal = 0
        status.bytesCopied = 0
        status.errors = 0
        status.currentFile = "Avvio backup..."
        do { try statusWriter.write(status: status) } catch { Log.error("Status write failed at start: \(error)") }

        let excludeFilter = ExcludeFilter(patterns: config.exclude.patterns)
        let sourceURLs = allPaths.map { URL(fileURLWithPath: $0) }
        // Always use HOME as basePath so snapshot preserves full relative paths:
        // ~/GitHub/MyRepo/file.swift → snapshot/GitHub/MyRepo/file.swift
        let homeBasePaths = Array(repeating: home, count: sourceURLs.count)

        // Use a class (heap ref) instead of UnsafeMutablePointer — ARC keeps it alive
        // for as long as the walkerTask closure references it, preventing use-after-free.
        final class Counters: @unchecked Sendable {
            var discovered: Int64 = 0
            var walkerDone: Bool = false
            var traversalErrors: [(path: String, error: Error)] = []
        }
        let counters = Counters()

        // Scar 2026-10-06: this stream used `.bufferingNewest(256)`, which DROPS the oldest
        // waiting files whenever the walker runs ahead of the copy workers. Snapshots lost
        // up to two thirds of their files and were still named as good ones. The stream is
        // now unbounded and the walker waits on a semaphore instead: nothing is ever dropped,
        // and memory stays bounded by QUEUE_LIMIT.
        let (stream, continuation) = AsyncStream<FileEntry>.makeStream(bufferingPolicy: .unbounded)
        let slots = QueueGate(limit: QUEUE_LIMIT)

        let walkerTask = Task.detached(priority: .utility) {
            FileScanner.walk(sources: sourceURLs, basePaths: homeBasePaths,
                           excludeFilter: excludeFilter,
                           onTraversalError: { path, error in
                               counters.traversalErrors.append((path: path, error: error))
                           }) { entry in
                if token.isCancelled { return false }
                slots.acquire()
                if token.isCancelled { return false }
                counters.discovered += 1
                continuation.yield(entry)
                return true
            }
            counters.walkerDone = !token.isCancelled
            continuation.finish()
        }

        var stats = BackupStats()
        var errorList: [(path: String, error: Error)] = []
        var skipList: [(path: String, reason: String)] = []
        var processedCount: UInt64 = 0
        var vanishedCount = 0
        let VANISHED_THRESHOLD = 3
        let maxWorkers = 8  // per spec: TaskGroup concurrency limit

        let protectionGuard = RightsManagementGuard(config: config.protection)
        if protectionGuard.isActive {
            Log.info("Rights-managed documents excluded by preference -- local format inspection only")
        }

        // Helper: post-copy checks and stats merge (called from main task only — no data races)
        func handleResult(_ result: FileResult, entry: FileEntry) {
            processResult(result, stats: &stats, errors: &errorList, skips: &skipList)
            let isShellFile = entry.relativePath.hasSuffix("shrc") || entry.relativePath.hasSuffix("profile")
                || entry.relativePath.hasSuffix("shenv") || entry.relativePath.hasSuffix("history")
            if !isShellFile && !FileManager.default.fileExists(atPath: entry.absolutePath) {
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

                    group.addTask {
                        (await BackupEngine.processFile(entry: file, destFile: destFile,
                                                        prevFile: prevFile, protectionGuard: protectionGuard), file)
                    }
                    inFlight += 1

                    if inFlight >= maxWorkers {
                        if let (result, entry) = try await group.next() {
                            inFlight -= 1
                            handleResult(result, entry: entry)
                        }
                    }

                    if processedCount % UInt64(STATUS_UPDATE_INTERVAL) == 0 {
                        let elapsed = Date().timeIntervalSince(startTime)
                        let discovered = UInt64(counters.discovered)
                        let done = processedCount
                        status.filesDone = done
                        status.filesTotal = counters.walkerDone ? discovered : discovered + 5000
                        status.bytesCopied = stats.bytesCopied
                        status.bytesPerSec = elapsed > 0 ? UInt64(Double(stats.bytesCopied) / elapsed) : 0
                        if status.bytesPerSec > 0 && done > 0 {
                            let remaining = status.filesTotal > done ? status.filesTotal - done : 0
                            let avgBytesPerFile = stats.bytesCopied / done
                            status.etaSecs = UInt64(remaining * avgBytesPerFile / status.bytesPerSec)
                        }
                        status.errors = UInt64(errorList.count)
                        status.filesSkipped = stats.filesSkipped
                        status.currentFile = file.relativePath
                        status.phase = stats.bytesCopied > 0 ? "copying" : "scanning"
                        try? statusWriter.write(status: status)
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

        errorList.append(contentsOf: counters.traversalErrors)

        // F-02: Do NOT rename to final snapshot if cancelled — partial backup must not look valid.
        if token.isCancelled {
            try? FileManager.default.removeItem(at: inProgressURL)
            status.state = "cancelled"
            status.phase = "cancelled"
            status.currentFile = "Backup annullato"
            do { try statusWriter.write(status: status) } catch { Log.error("Status write failed on cancel: \(error)") }
            return nil
        }

        // Git and database safety: written into the snapshot before it gets its final name.
        status.phase = "finalizing"
        status.currentFile = "Salvo i commit non pubblicati e i database…"
        try? statusWriter.write(status: status)
        let gitRecords = options.captureGit
            ? GitSafety.captureAll(sources: allPaths, excludeFilter: excludeFilter, home: home, into: inProgressURL,
                                   previousSnapshot: latestBackup)
            : []
        let dbRecords = options.captureDatabases
            ? DatabaseDumps.captureAll(config: config.databases, home: home, into: inProgressURL)
            : []

        let traversalCount = counters.traversalErrors.count
        let copyErrors = errorList.count - traversalCount
        let shrink = SnapshotManifest.shrinkWarning(processed: Int64(processedCount),
                                                    previous: previousComplete?.manifest,
                                                    baselineFiles: baselineFiles)
        // A folder that was in the last complete snapshot and is gone now is not a normal
        // day either (an unmounted volume, a moved project): say it (review H3).
        var sourceReasons: [String] = []
        if allPaths.isEmpty { sourceReasons.append("Nessuna delle cartelle da salvare esiste su questo Mac.") }
        if let previous = previousComplete?.manifest {
            for gone in missing where previous.sources.contains(gone) {
                sourceReasons.append("La cartella \(gone) non esiste più, ma era nell'ultimo backup completo. "
                    + "Se non ti serve più, toglila dalle cartelle da salvare.")
            }
        }
        let (complete, reasons) = SnapshotManifest.evaluate(
            discovered: counters.discovered, processed: Int64(processedCount),
            walkerFinished: counters.walkerDone, errors: copyErrors, traversalErrors: traversalCount,
            gitFailures: gitRecords.compactMap { r in r.error.map { "\(r.relativePath) (\($0))" } },
            databaseFailures: dbRecords.compactMap { r in r.error.map { "\(r.source) (\($0))" } },
            shrinkWarning: shrink, otherReasons: sourceReasons)

        let manifest = SnapshotManifest(
            appVersion: appVersionString(), host: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            startedAt: ISO8601DateFormatter().string(from: startTime),
            finishedAt: ISO8601DateFormatter().string(from: options.now()),
            sources: allPaths.map { ConfigDiscovery.contract($0) }, missingSources: missing,
            filesDiscovered: counters.discovered, filesProcessed: Int64(processedCount),
            filesCopied: Int64(stats.filesCopied), filesHardlinked: Int64(stats.filesHardlinked),
            filesSkipped: Int64(stats.filesSkipped), bytesCopied: stats.bytesCopied,
            errorCount: copyErrors, traversalErrorCount: traversalCount,
            git: gitRecords, databases: dbRecords, shrinkWarning: shrink,
            complete: complete, incompleteReasons: reasons)
        try manifest.write(to: inProgressURL)

        let finalURL = destURL.appendingPathComponent(timestamp)
        try FileManager.default.moveItem(at: inProgressURL, to: finalURL)
        if complete {
            Log.info("Snapshot \(timestamp) complete: \(processedCount) files")
        } else {
            Log.warn("Snapshot \(timestamp) INCOMPLETE: \(reasons.joined(separator: " | "))")
        }

        if options.captureEnvironment {
            // Run AFTER backup completes, in a non-interactive shell to avoid triggering kaku/dotfile managers
            Log.info("Capturing environment snapshot...")
            EnvironmentSnapshot.capture(to: finalURL)
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
            let gaps = CoverageAuditor.audit(config: config, home: home)
            try? statusWriter.writeCoverage(CoverageReport(
                checkedAt: ISO8601DateFormatter().string(from: Date()), gaps: gaps))
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
