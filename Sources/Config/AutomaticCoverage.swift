import Foundation

enum AutomaticCoverage {
    /// What a preparation did to the configuration: `added` lists, in `~/` form, the items
    /// included by themselves (folders and databases), for the menu and the snapshot.
    struct Preparation {
        var config: Config
        var added: [String]
    }

    /// Reload immediately before discovery: never save the app's launch-time configuration.
    static func prepare(from url: URL = Config.defaultPath, selectedPaths: [String]? = nil,
                        includeRightsManagedFiles: Bool? = nil,
                        home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> Config {
        try prepareReporting(from: url, selectedPaths: selectedPaths,
                             includeRightsManagedFiles: includeRightsManagedFiles, home: home).config
    }

    static func prepareReporting(from url: URL = Config.defaultPath, selectedPaths: [String]? = nil,
                                 includeRightsManagedFiles: Bool? = nil,
                                 home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                 knownDatabaseGaps: [CoverageGap]? = nil) throws -> Preparation {
        let initialBytes = try Data(contentsOf: url)
        let original = try Config.load(from: url)
        var config = try Config.forBackup(from: url, selectedPaths: selectedPaths,
                                          includeRightsManagedFiles: includeRightsManagedFiles)
        let candidates = config.coverage.autoInclude || selectedPaths != nil
            ? discover(config: config, home: home, databaseGaps: knownDatabaseGaps) : []
        func expanded(_ path: String) -> String { ConfigDiscovery.expand(path, home: home) }
        func contains(_ parent: String, _ path: String) -> Bool {
            path == parent || path.hasPrefix(parent + "/")
        }
        var changed = selectedPaths != nil || includeRightsManagedFiles != nil
        var included: [String] = []

        if let selectedPaths {
            let selected = selectedPaths.map(expanded)
            // An unchecked item stays unchecked on future scheduled runs too.
            let declined = original.source.paths + candidates.filter { $0.kind == .folder }.map(\.path)
            // A folder is never rejected while the user chose something inside it: that is a
            // partial selection, and rejecting the folder would also block its new projects.
            func holdsChoice(_ path: String) -> Bool { selected.contains { contains(expanded(path), $0) } }
            config.coverage.ignore.removeAll { ignored in
                selected.contains { contains($0, expanded(ignored)) } || holdsChoice(ignored)
            }
            for path in declined where !selected.contains(where: { contains($0, expanded(path)) }) && !holdsChoice(path) {
                if !config.coverage.ignore.contains(path) { config.coverage.ignore.append(path) }
            }
        } else if config.coverage.autoInclude {
            for addition in plan(config: config, candidates: candidates, home: home) {
                switch addition.kind {
                case .folder: config.source.paths.append(addition.path)
                case .database: config.databases.sqlite.append(addition.path)
                }
                included.append(addition.path)
                changed = true
                Log.info("Automatically included in backup: \(addition.path)")
            }
        }
        if changed {
            let added = config.source.paths.filter { !original.source.paths.contains($0) }
            let exclusions = ConfigDiscovery.dataExclusions(forSources: added, home: home)
            config.exclude.patterns += exclusions.filter { !config.exclude.patterns.contains($0) }
            guard try Data(contentsOf: url) == initialBytes else {
                throw NSError(domain: "AutomaticCoverage", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Le impostazioni sono cambiate durante il rilevamento. Riprova il backup."
                ])
            }
            try config.save(to: url)
        }
        return Preparation(config: config, added: included)
    }

    /// Which candidates an automatic preparation adds to this configuration. Pure: the menu
    /// previews it and the next backup applies it, so both always agree.
    static func plan(config: Config, candidates: [CoverageGap], home: String) -> [CoverageGap] {
        func expanded(_ path: String) -> String { ConfigDiscovery.expand(path, home: home) }
        func contains(_ parent: String, _ path: String) -> Bool {
            path == parent || path.hasPrefix(parent + "/")
        }
        var sources = config.source.paths.map(expanded)
        var databases = Set(config.databases.sqlite.map(expanded))
        let ignored = config.coverage.ignore.map(expanded)
        var additions: [CoverageGap] = []
        for candidate in candidates {
            let path = expanded(candidate.path)
            guard !ignored.contains(where: { contains($0, path) || contains(path, $0) }) else { continue }
            switch candidate.kind {
            case .folder:
                // A selected child is not permission to broaden its parent.
                guard !sources.contains(where: { contains($0, path) || contains(path, $0) }) else { continue }
                sources.append(path)
            case .database:
                guard databases.insert(path).inserted else { continue }
            }
            additions.append(candidate)
        }
        return additions
    }

    /// What the next backup would add by itself, from the settings as saved now. Read-only:
    /// nothing is saved and no inclusion is logged until a backup actually runs.
    /// Without `knownDatabaseGaps` this is the full discovery a backup runs (slow on a large
    /// configuration); the menu passes the databases the last audit found instead of walking
    /// every source again, so databases that appeared since may only show up at the backup.
    static func pending(config: Config, home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                        knownDatabaseGaps: [CoverageGap]? = nil) -> [CoverageGap] {
        guard config.coverage.autoInclude else { return [] }
        let candidates = discover(config: config, home: home, databaseGaps: knownDatabaseGaps?.filter { $0.kind == .database })
        return plan(config: config, candidates: candidates, home: home)
    }

    /// The one path every backup takes, from the menu or from the schedule: prepare the settings,
    /// then run with the automatic additions recorded in the status and in the snapshot.
    /// The databases of folders already saved come from the last backup's audit, like the menu's
    /// preview: walking every source again before each backup took minutes. Folders and what is
    /// inside a newly added one are still looked for right now. Without an audit (first backup,
    /// or after a reset) the sources are walked once, as before.
    static func prepareAndRun(from url: URL = Config.defaultPath, selectedPaths: [String]? = nil,
                              includeRightsManagedFiles: Bool? = nil,
                              statusWriter: StatusWriter = StatusWriter(),
                              options: BackupRunOptions = BackupRunOptions(),
                              onPrepared: (Config) async -> Void = { _ in }) async throws -> BackupRunResult? {
        let preparation = try prepareReporting(from: url, selectedPaths: selectedPaths,
                                               includeRightsManagedFiles: includeRightsManagedFiles, home: options.home,
                                               knownDatabaseGaps: statusWriter.readCoverage()?.gaps)
        await onPrepared(preparation.config)
        var runOptions = options
        runOptions.automaticallyIncluded = preparation.added
        return try await BackupEngine.run(config: preparation.config, statusWriter: statusWriter, options: runOptions)
    }

    /// `databaseGaps` replaces the walk over every source for uncopied databases, which takes
    /// minutes on a large configuration: the menu and every backup pass what the last backup's
    /// audit found, and `stillThere` keeps only what is still a plain, recent database.
    static func discover(config: Config, home: String, databaseGaps knownGaps: [CoverageGap]? = nil) -> [CoverageGap] {
        // The walk finds databases inside the saved folders only: so does what the last audit found.
        let savedFolders = config.source.paths.map { ConfigDiscovery.expand($0, home: home) }
        let databaseGaps = knownGaps.map { stillThere($0, home: home).filter { gap in
            let path = ConfigDiscovery.expand(gap.path, home: home)
            return savedFolders.contains { path.hasPrefix($0 + "/") }
        } }
        let filter = ExcludeFilter(patterns: config.exclude.patterns)
        let databaseFilter = ExcludeFilter(patterns: config.exclude.patterns.filter { !sqliteFileExcludePatterns.contains($0) })
        let privateRoots = [".config/secrets", ".roberdan-os", ".gbrain", ".copilot",
                            ".codex", ".gemini", ".pi", ".claude/projects"]
        let scan = DevEnvironment.scan(home: home, includingInventory: false)
        let proposed = scan.allItems.filter { !$0.sensitive && $0.proposed }.flatMap(\.paths)
        let gaps = CoverageAuditor.audit(config: config, home: home, measuringSizes: false,
                                         includingDatabases: databaseGaps == nil) + (databaseGaps ?? [])
        var seen = Set<String>()
        let folders = proposed.map {
            CoverageGap(kind: .folder, path: $0, lastModified: "", approximateBytes: 0)
        }
        func eligible(_ candidate: CoverageGap) -> Bool {
            let path = ConfigDiscovery.expand(candidate.path, home: home)
            guard path.hasPrefix(home + "/"), seen.insert(path).inserted else { return false }
            let relative = String(path.dropFirst(home.count + 1))
            guard !ConfigDiscovery.isForbidden(candidate.path, home: home),
                  !privateRoots.contains(where: {
                      relative == $0 || relative.hasPrefix($0 + "/") || $0.hasPrefix(relative + "/")
                  }),
                  !(candidate.kind == .database ? databaseFilter : filter).isExcluded(relativePath: relative),
                  !relative.split(separator: "/").contains(where: { DevEnvironment.looksSecret(String($0)) }),
                  !WorktreePolicy.isTemporarySource(path, home: home),
                  !hasLinkedAncestor(path, home: home) else { return false }
            if candidate.kind == .folder {
                // Generic hidden folders must use discovery's sensitive classification.
                if relative.hasPrefix("."), !proposed.contains(candidate.path) { return false }
                if holdsCredentials(path) { return false }
            }
            return true
        }
        let found = (folders + gaps).filter(eligible)
        let sources = config.source.paths.map { ConfigDiscovery.expand($0, home: home) }
        let newSources = found.filter { $0.kind == .folder }.map { ConfigDiscovery.expand($0.path, home: home) }
            .filter { path in !sources.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") } }
        let additionalDatabases = CoverageAuditor.uncopiedDatabases(config: config, sources: newSources, home: home,
            cutoff: Date().addingTimeInterval(-30 * 86_400))
        return found + additionalDatabases.filter(eligible)
    }

    /// What the last audit listed may be gone, replaced by a link, emptied or untouched for a month
    /// by now: only a plain database with a size the audit accepts and a recent change is kept.
    /// Same rule as the walk, so a backup adds exactly what a fresh walk would have found there.
    static func stillThere(_ gaps: [CoverageGap], home: String, now: Date = Date()) -> [CoverageGap] {
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        return gaps.filter { gap in
            guard gap.kind == .database else { return false }
            let url = URL(fileURLWithPath: ConfigDiscovery.expand(gap.path, home: home))
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                                 .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size < 2_147_483_648,
                  let modified = values.contentModificationDate, modified > cutoff else { return false }
            return true
        }
    }

    private static func hasLinkedAncestor(_ path: String, home: String) -> Bool {
        var url = URL(fileURLWithPath: path)
        while url.path.hasPrefix(home + "/") {
            do {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { return true }
            } catch {
                Log.warn("Automatic inclusion skipped: cannot inspect \(url.path): \(error.localizedDescription)")
                return true
            }
            url.deleteLastPathComponent()
        }
        return false
    }

    private static func holdsCredentials(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if DevEnvironment.tokenBearingConfigDirs.contains(name) { return true }
        let children: [String]
        do {
            guard try URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                return false
            }
            children = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            Log.warn("Automatic inclusion skipped: cannot inspect \(path): \(error.localizedDescription)")
            return true
        }
        return children.contains {
            let lower = $0.lowercased()
            return DevEnvironment.looksSecret(lower)
                || ["auth.json", "hosts.yml", "oauth_creds.json", "id_rsa", "id_ed25519"].contains(lower)
        }
    }
}
