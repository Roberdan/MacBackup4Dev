import Foundation
import Darwin

/// Something that changed recently and that no snapshot would contain.
/// Scar 2026-10-06: ~/Obsidian (the whole vault), ~/actions-runners and the VirtualBPM
/// history database were in use every day and in no snapshot. The source list is a
/// whitelist on purpose (no Full Disk Access, MDM Macs); this audit is what keeps a
/// whitelist from silently going stale.
struct CoverageGap: Codable, Equatable {
    enum Kind: String, Codable { case folder, database }
    var kind: Kind
    var path: String          // ~/... form
    var lastModified: String  // ISO 8601
    var approximateBytes: Int64

    var message: String {
        switch kind {
        case .folder: return "\(path) è cambiata di recente e non viene salvata"
        case .database: return "Il database \(path) non viene copiato"
        }
    }
}

enum CoverageAuditor {
    /// Top-level home folders macOS protects (TCC) or that hold media/apps, never scanned.
    static let protectedTopLevel: Set<String> = [
        "Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
        "Applications", "Public", ".Trash",
    ]
    /// Never suggested (feedback 2026-10-07, after "Aggiungi" on every suggestion added
    /// credentials, a parked copy and browser-profile databases): folders holding secrets
    /// (backed up only by explicit choice), parked folders ("_name"), caches and profiles.
    static func isNoise(_ name: String) -> Bool {
        if name.hasPrefix("_") { return true }
        if ConfigDiscovery.secretBearingDotEntries.contains(name) { return true }
        return ConfigDiscovery.isDeniedName(name)
    }

    /// Folders whose children are projects: each child is judged on its own.
    static let projectContainers: [String] = ["GitHub", "Developer", "Projects", "Code", "src"]

    /// The check at the end of a backup gets at most this long. On the real configuration
    /// (171 sources) it takes about a minute (57 s and 73 s, 2026-10-31 and 11-01): ten minutes
    /// leave room for a slow or throttled disk, and a check that hangs (2026-11-01: 35 minutes
    /// in open()) no longer keeps the backup "in progress".
    static let timeLimit: TimeInterval = 600

    /// What a check found so far. The walks add to it as they go, so a check that runs out of
    /// time still reports what it found, and `stop()` ends a walk at its next entry.
    final class Findings: @unchecked Sendable {
        private let lock = NSLock()
        private var gaps: [CoverageGap] = []
        private var unchecked = 0
        private var stopped = false
        /// Tests stand in for the cloud: a real dataless folder cannot be made without iCloud.
        let isCloudOnly: (String) -> Bool

        init(isCloudOnly: @escaping (String) -> Bool = { CoverageAuditor.isCloudOnly($0) }) {
            self.isCloudOnly = isCloudOnly
        }

        func add(_ gap: CoverageGap) { lock.withLock { gaps.append(gap) } }
        /// A folder or file left out: only in the cloud, or it could not be opened.
        func skip() { lock.withLock { unchecked += 1 } }
        func stop() { lock.withLock { stopped = true } }
        var isStopped: Bool { lock.withLock { stopped } }
        var found: (gaps: [CoverageGap], unchecked: Int) { lock.withLock { (gaps, unchecked) } }
    }

    /// Only in the cloud (SF_DATALESS, iCloud Drive or another file provider): listing or
    /// reading it would download it. lstat reads the flag without downloading anything.
    static func isCloudOnly(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// Runs `body` without ever downloading a cloud-only file or folder (2026-11-01: the check
    /// waited 35 minutes in open() on an iCloud folder). The process downloads by default, as
    /// every Mac app does: this switches it off for the calling thread only, then restores it.
    static func withoutDownloads<T>(_ body: () -> T) -> T {
        let kind = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let previous = getiopolicy_np(kind, IOPOL_SCOPE_THREAD)
        guard setiopolicy_np(kind, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            Log.warn("Coverage check: cannot turn off cloud downloads (\(String(cString: strerror(errno)))); cloud-only folders are still skipped")
            return body()
        }
        defer { _ = setiopolicy_np(kind, IOPOL_SCOPE_THREAD, previous >= 0 ? previous : IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT) }
        return body()
    }

    /// What the check walks; tests replace it to stand in for a folder that never answers.
    typealias Walk = @Sendable (Config, String, Findings) -> Void
    static let fullWalk: Walk = { config, home, findings in _ = audit(config: config, home: home, findings: findings) }

    /// The check at the end of a backup, bounded. Past `timeLimit`, or when the backup is
    /// stopped, the backup goes on with what was found so far and the report says why it is
    /// incomplete, keeping what the previous check found and this one could not check again.
    /// The walk runs on a thread of its own: one stuck in the kernel is left behind instead of
    /// holding the backup, its status and its locks.
    static func boundedReport(config: Config, home: String, previous: CoverageReport?,
                              timeLimit: TimeInterval = timeLimit, walk: @escaping Walk = fullWalk,
                              cancelled: () -> Bool = { false }) -> CoverageReport {
        let findings = Findings()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            walk(config, home, findings)
            finished.signal()
        }
        thread.name = "Coverage check"
        thread.qualityOfService = .background
        thread.start()
        let deadline = Date().addingTimeInterval(timeLimit)
        var reason: String?
        while true {
            if cancelled() { reason = "Controllo interrotto: il backup è stato fermato"; break }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                reason = "Controllo interrotto dopo \(Int((timeLimit / 60).rounded(.up))) minuti: tempo scaduto"
                break
            }
            if finished.wait(timeout: .now() + min(remaining, 0.25)) == .success { break }
        }
        findings.stop()
        let (gaps, unchecked) = findings.found
        let checkedAt = ISO8601DateFormatter().string(from: Date())
        guard let reason else {
            return CoverageReport(checkedAt: checkedAt, gaps: gaps, complete: true, unchecked: unchecked)
        }
        Log.warn("Coverage check incomplete (\(reason)): \(gaps.count) found so far; the backup goes on")
        let fresh = Set(gaps.map { "\($0.kind.rawValue)|\($0.path)" })
        let carried = (previous?.gaps ?? []).filter { !fresh.contains("\($0.kind.rawValue)|\($0.path)") }
        return CoverageReport(checkedAt: checkedAt, gaps: gaps + carried, complete: false,
                              incompleteReason: reason, unchecked: unchecked)
    }

    static func audit(config: Config, home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                      days: Int = 30, now: Date = Date(), measuringSizes: Bool = true,
                      includingDatabases: Bool = true, findings: Findings = Findings()) -> [CoverageGap] {
        withoutDownloads {
            auditWalk(config: config, home: home, days: days, now: now, measuringSizes: measuringSizes,
                      includingDatabases: includingDatabases, findings: findings)
        }
    }

    private static func auditWalk(config: Config, home: String, days: Int, now: Date, measuringSizes: Bool,
                                  includingDatabases: Bool, findings: Findings) -> [CoverageGap] {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let sources = config.source.paths.map { ConfigDiscovery.expand($0, home: home) }
        let ignored = config.coverage.ignore.map { ConfigDiscovery.expand($0, home: home) }
        let filter = ExcludeFilter(patterns: config.exclude.patterns)

        func covered(_ path: String) -> Bool {
            sources.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        func containsSource(_ path: String) -> Bool {
            sources.contains { $0.hasPrefix(path + "/") }
        }
        func isIgnored(_ path: String) -> Bool {
            ignored.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        func relative(_ path: String) -> String {
            path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        }

        var candidates: [String] = []
        let top = (try? fm.contentsOfDirectory(atPath: home)) ?? []
        for name in top.sorted() {
            guard !protectedTopLevel.contains(name), !isNoise(name), !ConfigDiscovery.isCloudFolderName(name) else { continue }
            let full = home + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            if (try? URL(fileURLWithPath: full).resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            if findings.isCloudOnly(full) { findings.skip(); continue }
            if projectContainers.contains(name) {
                for child in ((try? fm.contentsOfDirectory(atPath: full)) ?? []).sorted() where !child.hasPrefix(".") && !isNoise(child) {
                    let c = full + "/" + child
                    var d: ObjCBool = false
                    guard fm.fileExists(atPath: c, isDirectory: &d), d.boolValue else { continue }
                    if findings.isCloudOnly(c) { findings.skip() } else { candidates.append(c) }
                }
                continue
            }
            candidates.append(full)
        }

        var gaps: [CoverageGap] = []
        for path in candidates {
            if findings.isStopped { return gaps }
            let rel = relative(path)
            guard !covered(path), !containsSource(path), !isIgnored(path) else { continue }
            guard !ConfigDiscovery.isForbidden(path, home: home),
                  !ConfigDiscovery.isDeniedHidden(relative: rel),
                  !filter.isExcluded(relativePath: rel) else { continue }
            // A linked git worktree (".git" is a file) is temporary and its commits live in
            // the main repository, which the git safety net already bundles (2026-10-07: a
            // job's worktree was added, then deleted mid-backup).
            var gitIsDir: ObjCBool = false
            if fm.fileExists(atPath: path + "/.git", isDirectory: &gitIsDir), !gitIsDir.boolValue { continue }
            guard let newest = newestModification(in: path, filter: filter, home: home, after: cutoff,
                                                   findings: findings) else { continue }
            let gap = CoverageGap(kind: .folder, path: ConfigDiscovery.contract(path, home: home),
                                  lastModified: ISO8601DateFormatter().string(from: newest),
                                  approximateBytes: measuringSizes
                                      ? ConfigDiscovery.approximateSize(atPath: path, limit: 50 * 1_073_741_824) : 0)
            findings.add(gap)
            gaps.append(gap)
        }
        // Walking every source for databases is what takes minutes on a large configuration.
        if includingDatabases && !findings.isStopped {
            gaps.append(contentsOf: uncopiedDatabases(config: config, sources: sources, home: home, cutoff: cutoff,
                                                      findings: findings))
        }
        return gaps
    }

    /// SQLite files inside backed-up folders, changed recently, that `*.db` keeps out of the
    /// file copy and that are not in `[databases] sqlite`. Caches stay quiet: only files
    /// that live next to project/runtime data and are smaller than 2 GB are reported.
    static func uncopiedDatabases(config: Config, sources: [String], home: String, cutoff: Date,
                                  findings: Findings = Findings()) -> [CoverageGap] {
        withoutDownloads {
            databaseWalk(config: config, sources: sources, home: home, cutoff: cutoff, findings: findings)
        }
    }

    private static func databaseWalk(config: Config, sources: [String], home: String, cutoff: Date,
                                     findings: Findings) -> [CoverageGap] {
        let fm = FileManager.default
        let resolvedHome = FileScanner.realPath(home)
        let listed = Set(config.databases.sqlite.map { FileScanner.realPath(ConfigDiscovery.expand($0, home: home)) })
        let filter = ExcludeFilter(patterns: config.exclude.patterns.filter { !sqliteFileExcludePatterns.contains($0) })
        let extensions: Set<String> = ["db", "sqlite", "sqlite3"]
        let noisy: [String] = ["cache", "caches", "node_modules", ".git", "logs", "tmp", "telemetry",
                               "embedding", "session", "history-cache", "webcache", "indexeddb"]
        var gaps: [CoverageGap] = []
        for source in sources {
            if findings.isStopped { break }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else { continue }
            if findings.isCloudOnly(source) { findings.skip(); continue }
            guard let walker = fm.enumerator(at: URL(fileURLWithPath: source),
                                             includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey,
                                                                          .isSymbolicLinkKey, .isDirectoryKey],
                                             options: [.skipsPackageDescendants],
                                             errorHandler: { _, _ in findings.skip(); return true }) else { continue }
            var visited = 0
            for case let url as URL in walker {
                if findings.isStopped { break }
                visited += 1
                if visited > 60_000 { break }
                let relative = url.path.hasPrefix(resolvedHome + "/")
                    ? String(url.path.dropFirst(resolvedHome.count + 1)) : url.path
                if filter.isExcluded(relativePath: relative) {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { walker.skipDescendants() }
                    continue
                }
                let lower = url.path.lowercased()
                if noisy.contains(where: { lower.contains("/\($0)") }) {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { walker.skipDescendants() }
                    continue
                }
                // Never opened: listing a folder that is only in the cloud would download it.
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true, findings.isCloudOnly(url.path) {
                    walker.skipDescendants()
                    findings.skip()
                    continue
                }
                guard extensions.contains(url.pathExtension.lowercased()), !listed.contains(url.path) else { continue }
                if findings.isCloudOnly(url.path) { findings.skip(); continue }
                // Only project data: a database inside a tool's own hidden folder (~/.codex,
                // ~/.local/share/atuin, a browser profile) is that tool's state, not yours.
                let rel = url.path.hasPrefix(resolvedHome + "/")
                    ? String(url.path.dropFirst(resolvedHome.count + 1)) : url.path
                let comps = rel.split(separator: "/").map(String.init)
                if comps.dropLast().contains(where: { $0.hasPrefix(".") || isNoise($0) }) { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink != true,
                      let modified = values?.contentModificationDate, modified > cutoff,
                      let size = values?.fileSize, size > 0, size < 2_147_483_648 else { continue }
                let gap = CoverageGap(kind: .database, path: ConfigDiscovery.contract(url.path, home: resolvedHome),
                                      lastModified: ISO8601DateFormatter().string(from: modified),
                                      approximateBytes: Int64(size))
                findings.add(gap)
                gaps.append(gap)
            }
        }
        return gaps
    }

    /// Newest modification date after `cutoff` among the first entries of a tree, or nil.
    /// Bounded: a huge cold tree costs at most `limit` entries.
    static func newestModification(in path: String, filter: ExcludeFilter, home: String,
                                   after cutoff: Date, limit: Int = 20_000, findings: Findings = Findings()) -> Date? {
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in findings.skip(); return true }) else { return nil }
        var visited = 0
        var newest: Date?
        for case let url as URL in walker {
            if findings.isStopped { break }
            visited += 1
            if visited > limit { break }
            let rel = url.path.hasPrefix(home + "/") ? String(url.path.dropFirst(home.count + 1)) : url.path
            if filter.isExcluded(relativePath: rel) || url.lastPathComponent == ".git" {
                walker.skipDescendants(); continue
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, findings.isCloudOnly(url.path) {
                walker.skipDescendants()
                findings.skip()
                continue
            }
            guard values?.isSymbolicLink != true, values?.isDirectory != true,
                  let modified = values?.contentModificationDate, modified > cutoff else { continue }
            if newest == nil || modified > newest! { newest = modified }
            if visited > 2_000, newest != nil { break }
        }
        return newest
    }
}
