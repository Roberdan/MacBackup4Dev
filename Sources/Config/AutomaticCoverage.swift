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

    /// `alreadyRecorded`: databases the last backup saved by itself and recorded in its snapshot. They
    /// enter the settings like any addition but are not announced a second time.
    static func prepareReporting(from url: URL = Config.defaultPath, selectedPaths: [String]? = nil,
                                 includeRightsManagedFiles: Bool? = nil,
                                 home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                 knownDatabaseGaps: [CoverageGap]? = nil,
                                 alreadyRecorded: [String] = []) throws -> Preparation {
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
            let recorded = Set(alreadyRecorded.map(expanded))
            for addition in plan(config: config, candidates: candidates, home: home) {
                switch addition.kind {
                case .folder: config.source.paths.append(addition.path)
                case .database: config.databases.sqlite.append(addition.path)
                }
                changed = true
                if addition.kind == .database && recorded.contains(expanded(addition.path)) {
                    Log.info("Added to the settings, already saved by the last backup: \(addition.path)")
                } else {
                    included.append(addition.path)
                    Log.info("Automatically included in backup: \(addition.path)")
                }
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
    /// Without `knownDatabaseGaps` this walks every saved folder for databases (slow on a large
    /// configuration); the menu passes the databases the last check found instead, so databases
    /// that appeared since show up when the next backup's own check finds and saves them.
    static func pending(config: Config, home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                        knownDatabaseGaps: [CoverageGap]? = nil) -> [CoverageGap] {
        guard config.coverage.autoInclude else { return [] }
        let candidates = discover(config: config, home: home, databaseGaps: knownDatabaseGaps?.filter { $0.kind == .database })
        return plan(config: config, candidates: candidates, home: home)
    }

    /// The one path every backup takes, from the menu or from the schedule: prepare the settings,
    /// then run with the automatic additions recorded in the status and in the snapshot.
    /// The preparation never walks the saved folders for databases (it took minutes before each
    /// backup): the backup's own check does, once, right before the databases are saved, and saves
    /// what it finds in the same run. Its file (`coverage.json`) brings those databases here, into
    /// the settings. Folders and what is inside a newly added one are still looked for right now.
    static func prepareAndRun(from url: URL = Config.defaultPath, selectedPaths: [String]? = nil,
                              includeRightsManagedFiles: Bool? = nil,
                              statusWriter: StatusWriter = StatusWriter(),
                              options: BackupRunOptions = BackupRunOptions(),
                              onPrepared: (Config) async -> Void = { _ in }) async throws -> BackupRunResult? {
        let lastCheck = statusWriter.readCoverage()
        let savedByLastBackup = lastCheck?.addedByBackup ?? []
        let preparation = try prepareReporting(from: url, selectedPaths: selectedPaths,
                                               includeRightsManagedFiles: includeRightsManagedFiles, home: options.home,
                                               knownDatabaseGaps: (lastCheck?.gaps ?? []) + savedByLastBackup,
                                               alreadyRecorded: savedByLastBackup.map(\.path))
        await onPrepared(preparation.config)
        var runOptions = options
        runOptions.automaticallyIncluded = preparation.added
        return try await BackupEngine.run(config: preparation.config, statusWriter: statusWriter, options: runOptions)
    }

    /// `databaseGaps` replaces the walk over every source for uncopied databases, which takes
    /// minutes on a large configuration: the menu and every backup pass what the last backup's
    /// check found, and `knownDatabases` keeps only what is still a plain, recent database there.
    static func discover(config: Config, home: String, databaseGaps knownGaps: [CoverageGap]? = nil) -> [CoverageGap] {
        let databaseGaps = knownGaps.map { knownDatabases($0, config: config, home: home) }
        let admission = Admission(config: config, home: home)
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
            guard path.hasPrefix(home + "/"), seen.insert(path).inserted, admission.admits(candidate) else { return false }
            if candidate.kind == .folder {
                let relative = path.dropFirst(home.count + 1)
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

    /// Private agent data: never added by itself, whatever folder holds it.
    static let privateRoots = [".config/secrets", ".roberdan-os", ".gbrain", ".copilot",
                               ".codex", ".gemini", ".pi", ".claude/projects"]

    /// The rule every item must pass to enter the backup by itself, the same for the preparation
    /// and for the backup's own check: under the home, not forbidden, not private agent data, not
    /// excluded (the database file patterns aside, for a database), no part that looks like a
    /// secret, not a temporary worktree, not reached through a link. Folders have two more rules
    /// of their own in `discover`. Built once per configuration: the filters are not free.
    struct Admission {
        let home: String
        private let filter: ExcludeFilter
        private let databaseFilter: ExcludeFilter

        init(config: Config, home: String) {
            self.home = home
            filter = ExcludeFilter(patterns: config.exclude.patterns)
            databaseFilter = ExcludeFilter(patterns: config.exclude.patterns.filter { !sqliteFileExcludePatterns.contains($0) })
        }

        func admits(_ candidate: CoverageGap) -> Bool {
            let path = ConfigDiscovery.expand(candidate.path, home: home)
            guard path.hasPrefix(home + "/") else { return false }
            let relative = String(path.dropFirst(home.count + 1))
            return !ConfigDiscovery.isForbidden(candidate.path, home: home)
                && !AutomaticCoverage.privateRoots.contains(where: {
                    relative == $0 || relative.hasPrefix($0 + "/") || $0.hasPrefix(relative + "/")
                })
                && !(candidate.kind == .database ? databaseFilter : filter).isExcluded(relativePath: relative)
                && !relative.split(separator: "/").contains(where: { DevEnvironment.looksSecret(String($0)) })
                && !WorktreePolicy.isTemporarySource(path, home: home)
                && !AutomaticCoverage.hasLinkedAncestor(path, home: home)
        }
    }

    /// Databases named by a check's file that may still be added: still plain recent databases
    /// (`stillThere`), inside a folder these settings save (the check only walks those).
    static func knownDatabases(_ gaps: [CoverageGap], config: Config, home: String) -> [CoverageGap] {
        let savedFolders = config.source.paths.map { ConfigDiscovery.expand($0, home: home) }
        return stillThere(gaps, home: home).filter { gap in
            let path = ConfigDiscovery.expand(gap.path, home: home)
            return savedFolders.contains { path.hasPrefix($0 + "/") }
        }
    }

    /// What the backup saves by itself from what its own check found: exactly the databases the
    /// next preparation would add to these settings (Roberto, 2026-11-01). Database files are left
    /// out of the plain copy, so leaving them to that preparation kept them out of one more
    /// snapshot. The settings are not touched during the backup: the next preparation writes these
    /// in from the check's file. Nothing when automatic additions are switched off.
    static func databasesToSave(found: [CoverageGap], config: Config, home: String) -> [CoverageGap] {
        guard config.coverage.autoInclude else { return [] }
        let admission = Admission(config: config, home: home)
        let candidates = knownDatabases(found, config: config, home: home).filter(admission.admits)
        return plan(config: config, candidates: candidates, home: home)
    }

    /// What the last audit listed may be gone, replaced by a link, emptied or untouched for a month
    /// by now: only a plain database with a size the audit accepts and a recent change is kept.
    /// Same rule as the walk, so a backup adds exactly what a fresh walk would have found there.
    /// The path comes out of a file: only an absolute one with no `.`, `..` or empty part is
    /// trusted, so the later string checks (saved folder, private roots) mean what they say.
    static func stillThere(_ gaps: [CoverageGap], home: String, now: Date = Date()) -> [CoverageGap] {
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        return gaps.filter { gap in
            guard gap.kind == .database else { return false }
            let path = ConfigDiscovery.expand(gap.path, home: home)
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.hasPrefix("/"),
                  !parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                                 .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size < 2_147_483_648,
                  let modified = values.contentModificationDate, modified > cutoff else { return false }
            return true
        }
    }

    /// True when the path or one of its folders under `home` is a link, or cannot be inspected, or
    /// cannot be climbed (a `..` part never shortens it: the loop used to turn there for ever).
    static func hasLinkedAncestor(_ path: String, home: String) -> Bool {
        var url = URL(fileURLWithPath: path)
        while url.path.hasPrefix(home + "/") {
            do {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { return true }
            } catch {
                Log.warn("Automatic inclusion skipped: cannot inspect \(url.path): \(error.localizedDescription)")
                return true
            }
            let parent = url.deletingLastPathComponent()
            guard parent.path.count < url.path.count else { return true }
            url = parent
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
