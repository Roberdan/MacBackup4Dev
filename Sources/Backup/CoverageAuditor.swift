import Foundation

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

    static func audit(config: Config, home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                      days: Int = 30, now: Date = Date()) -> [CoverageGap] {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let sources = config.source.paths.map { ConfigDiscovery.expand($0) }
        let ignored = config.coverage.ignore.map { ConfigDiscovery.expand($0) }
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
            guard !protectedTopLevel.contains(name), !isNoise(name) else { continue }
            let full = home + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            if (try? URL(fileURLWithPath: full).resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            if projectContainers.contains(name) {
                for child in ((try? fm.contentsOfDirectory(atPath: full)) ?? []).sorted() where !child.hasPrefix(".") && !isNoise(child) {
                    let c = full + "/" + child
                    var d: ObjCBool = false
                    if fm.fileExists(atPath: c, isDirectory: &d), d.boolValue { candidates.append(c) }
                }
                continue
            }
            candidates.append(full)
        }

        var gaps: [CoverageGap] = []
        for path in candidates {
            let rel = relative(path)
            guard !covered(path), !containsSource(path), !isIgnored(path) else { continue }
            guard !ConfigDiscovery.isForbidden(path),
                  !ConfigDiscovery.isDeniedHidden(relative: rel),
                  !filter.isExcluded(relativePath: rel) else { continue }
            // A linked git worktree (".git" is a file) is temporary and its commits live in
            // the main repository, which the git safety net already bundles (2026-10-07: a
            // job's worktree was added, then deleted mid-backup).
            var gitIsDir: ObjCBool = false
            if fm.fileExists(atPath: path + "/.git", isDirectory: &gitIsDir), !gitIsDir.boolValue { continue }
            guard let newest = newestModification(in: path, filter: filter, home: home, after: cutoff) else { continue }
            gaps.append(CoverageGap(kind: .folder, path: ConfigDiscovery.contract(path),
                                    lastModified: ISO8601DateFormatter().string(from: newest),
                                    approximateBytes: ConfigDiscovery.approximateSize(atPath: path, limit: 50 * 1_073_741_824)))
        }
        gaps.append(contentsOf: uncopiedDatabases(config: config, sources: sources, home: home, cutoff: cutoff))
        return gaps
    }

    /// SQLite files inside backed-up folders, changed recently, that `*.db` keeps out of the
    /// file copy and that are not in `[databases] sqlite`. Caches stay quiet: only files
    /// that live next to project/runtime data and are smaller than 2 GB are reported.
    static func uncopiedDatabases(config: Config, sources: [String], home: String, cutoff: Date) -> [CoverageGap] {
        let fm = FileManager.default
        let listed = Set(config.databases.sqlite.map { ConfigDiscovery.expand($0) })
        let extensions: Set<String> = ["db", "sqlite", "sqlite3"]
        let noisy: [String] = ["cache", "caches", "node_modules", ".git", "logs", "tmp", "telemetry",
                               "embedding", "session", "history-cache", "webcache", "indexeddb"]
        var gaps: [CoverageGap] = []
        for source in sources {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue,
                  let walker = fm.enumerator(at: URL(fileURLWithPath: source),
                                             includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey],
                                             options: [.skipsPackageDescendants]) else { continue }
            var visited = 0
            for case let url as URL in walker {
                visited += 1
                if visited > 60_000 { break }
                let lower = url.path.lowercased()
                if noisy.contains(where: { lower.contains("/\($0)") }) {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { walker.skipDescendants() }
                    continue
                }
                guard extensions.contains(url.pathExtension.lowercased()), !listed.contains(url.path) else { continue }
                // Only project data: a database inside a tool's own hidden folder (~/.codex,
                // ~/.local/share/atuin, a browser profile) is that tool's state, not yours.
                let rel = url.path.hasPrefix(home + "/") ? String(url.path.dropFirst(home.count + 1)) : url.path
                let comps = rel.split(separator: "/").map(String.init)
                if comps.dropLast().contains(where: { $0.hasPrefix(".") || isNoise($0) }) { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink != true,
                      let modified = values?.contentModificationDate, modified > cutoff,
                      let size = values?.fileSize, size > 0, size < 2_147_483_648 else { continue }
                gaps.append(CoverageGap(kind: .database, path: ConfigDiscovery.contract(url.path),
                                        lastModified: ISO8601DateFormatter().string(from: modified),
                                        approximateBytes: Int64(size)))
            }
        }
        return gaps
    }

    /// Newest modification date after `cutoff` among the first entries of a tree, or nil.
    /// Bounded: a huge cold tree costs at most `limit` entries.
    static func newestModification(in path: String, filter: ExcludeFilter, home: String,
                                   after cutoff: Date, limit: Int = 20_000) -> Date? {
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]) else { return nil }
        var visited = 0
        var newest: Date?
        for case let url as URL in walker {
            visited += 1
            if visited > limit { break }
            let rel = url.path.hasPrefix(home + "/") ? String(url.path.dropFirst(home.count + 1)) : url.path
            if filter.isExcluded(relativePath: rel) || url.lastPathComponent == ".git" {
                walker.skipDescendants(); continue
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, values?.isDirectory != true,
                  let modified = values?.contentModificationDate, modified > cutoff else { continue }
            if newest == nil || modified > newest! { newest = modified }
            if visited > 2_000, newest != nil { break }
        }
        return newest
    }
}
