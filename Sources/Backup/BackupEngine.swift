import Foundation

enum BackupEngine {
    static let STATUS_UPDATE_INTERVAL: Int = 500
    static let DISK_CHECK_INTERVAL: Int = 100
    static let MIN_FREE_SPACE: UInt64 = 1_073_741_824

    private static var shouldCancel = false

    static func stop() { shouldCancel = true }

    static func run(config: Config, statusWriter: StatusWriter = StatusWriter()) async throws {
        shouldCancel = false
        let destPath = config.destination.path
        let destURL = URL(fileURLWithPath: destPath)

        // Validate source paths: skip missing, block forbidden
        var allPaths: [String] = []
        for path in config.source.allExpandedPaths() {
            let contracted = ConfigDiscovery.contract(path)
            if ConfigDiscovery.isForbidden(contracted, allowCloudStorage: config.protection.includeCloudStorage) {
                Log.error("BLOCKED forbidden path: \(path)")
                throw BackupError.forbiddenPath(path)
            }
            if FileManager.default.fileExists(atPath: path) {
                allPaths.append(path)
            } else {
                Log.info("Skipping missing path: \(path)")
            }
        }
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

        if diskFreeSpace(at: destPath) < MIN_FREE_SPACE {
            let _ = try RetentionManager.pruneLockedBackups(at: destURL, policy: config.retention, dryRun: false)
            if diskFreeSpace(at: destPath) < MIN_FREE_SPACE {
                throw BackupError.insufficientSpace(diskFreeSpace(at: destPath))
            }
        }

        let latestBackup = findLatestBackup(at: destURL)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let inProgressURL = destURL.appendingPathComponent("in-progress-\(timestamp)")
        try FileManager.default.createDirectory(at: inProgressURL, withIntermediateDirectories: true)

        // F-01: clean stale dirs only AFTER acquiring the lock
        cleanStaleInProgress(at: destURL)

        let startTime = Date()
        var status = BackupStatusFile()
        status.state = "running"
        status.phase = "scanning"
        status.startedAt = ISO8601DateFormatter().string(from: startTime)
        status.currentFile = "Avvio backup..."
        do { try statusWriter.write(status: status) } catch { Log.error("Status write failed at start: \(error)") }

        let excludeFilter = ExcludeFilter(patterns: config.exclude.patterns)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
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

        let (stream, continuation) = AsyncStream<FileEntry>.makeStream(bufferingPolicy: .bufferingNewest(256))

        let walkerTask = Task.detached(priority: .utility) {
            FileScanner.walk(sources: sourceURLs, basePaths: homeBasePaths,
                           excludeFilter: excludeFilter,
                           onTraversalError: { path, error in
                               counters.traversalErrors.append((path: path, error: error))
                           }) { entry in
                if shouldCancel { return false }
                counters.discovered += 1
                continuation.yield(entry)
                return true
            }
            counters.walkerDone = true
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

        // Parallel file processing with bounded TaskGroup (spec: 8 workers).
        // processFile is safe to parallelize: each call uses a unique destFile path,
        // createDirectory(withIntermediateDirectories:true) is safe for concurrent calls,
        // HardLinker uses COPYFILE_ALL (no COPYFILE_CLONE — see HardLinker.swift note).
        // All shared state (stats, errorList, vanishedCount) is mutated in the main task only.
        var inFlight = 0
        try await withThrowingTaskGroup(of: (FileResult, FileEntry).self) { group in
            for await file in stream {
                if shouldCancel { break }
                processedCount += 1

                // Disk check (every N files, in main task — safe)
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

                // Drain oldest result when worker pool is full (backpressure)
                if inFlight >= maxWorkers {
                    if let (result, entry) = try await group.next() {
                        inFlight -= 1
                        handleResult(result, entry: entry)
                    }
                }

                // Status update (uses current stream position as "current file")
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

            // Drain remaining in-flight tasks after stream ends
            for try await (result, entry) in group {
                handleResult(result, entry: entry)
            }
        }

        walkerTask.cancel()

        // F-08: Merge traversal errors (e.g. permission denied on subtrees) into error list
        errorList.append(contentsOf: counters.traversalErrors)

        // F-02: Do NOT rename to final snapshot if cancelled — partial backup must not look valid.
        if shouldCancel {
            try? FileManager.default.removeItem(at: inProgressURL)
            status.state = "cancelled"
            status.phase = "cancelled"
            status.currentFile = "Backup annullato"
            do { try statusWriter.write(status: status) } catch { Log.error("Status write failed on cancel: \(error)") }
            return
        }

        let finalURL = destURL.appendingPathComponent(timestamp)
        try FileManager.default.moveItem(at: inProgressURL, to: finalURL)

        // Capture portable environment snapshot (Brewfile, app list, restore script, app binary)
        // Run AFTER backup completes, in a non-interactive shell to avoid triggering kaku/dotfile managers
        Log.info("Capturing environment snapshot...")
        EnvironmentSnapshot.capture(to: finalURL)
        Log.info("Environment snapshot complete")

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

        let totalFiles = processedCount
        let duration = Date().timeIntervalSince(startTime)
        status.state = "idle"
        status.phase = "finalizing"
        status.filesDone = totalFiles
        status.filesTotal = totalFiles
        status.lastCompleted = ISO8601DateFormatter().string(from: Date())
        status.lastDurationSecs = duration
        status.bytesPerSec = duration > 0 ? UInt64(Double(stats.bytesCopied) / duration) : 0
        status.etaSecs = 0
        status.currentFile = ""
        status.errors = UInt64(errorList.count)
        status.filesSkipped = stats.filesSkipped
        do { try statusWriter.write(status: status) } catch { Log.error("Status write failed at completion: \(error)") }
    }
}
