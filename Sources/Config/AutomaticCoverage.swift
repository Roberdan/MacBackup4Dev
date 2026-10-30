import Foundation

enum AutomaticCoverage {
    /// Reload immediately before discovery: never save the app's launch-time configuration.
    static func prepare(from url: URL = Config.defaultPath, selectedPaths: [String]? = nil,
                        includeRightsManagedFiles: Bool? = nil,
                        home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> Config {
        let initialBytes = try Data(contentsOf: url)
        let original = try Config.load(from: url)
        var config = try Config.forBackup(from: url, selectedPaths: selectedPaths,
                                          includeRightsManagedFiles: includeRightsManagedFiles)
        let candidates = config.coverage.autoInclude || selectedPaths != nil
            ? discover(config: config, home: home) : []
        func expanded(_ path: String) -> String { ConfigDiscovery.expand(path, home: home) }
        func contains(_ parent: String, _ path: String) -> Bool {
            path == parent || path.hasPrefix(parent + "/")
        }
        var changed = selectedPaths != nil || includeRightsManagedFiles != nil

        if let selectedPaths {
            let selected = selectedPaths.map(expanded)
            // An unchecked item stays unchecked on future scheduled runs too.
            let declined = original.source.paths + candidates.filter { $0.kind == .folder }.map(\.path)
            config.coverage.ignore.removeAll { ignored in
                selected.contains { contains($0, expanded(ignored)) }
            }
            for path in declined where !selected.contains(where: { contains($0, expanded(path)) }) {
                if !config.coverage.ignore.contains(path) { config.coverage.ignore.append(path) }
            }
        } else if config.coverage.autoInclude {
            var sources = config.source.paths.map(expanded)
            var databases = Set(config.databases.sqlite.map(expanded))
            let ignored = config.coverage.ignore.map(expanded)
            for candidate in candidates {
                let path = expanded(candidate.path)
                guard !ignored.contains(where: { contains($0, path) || contains(path, $0) }) else { continue }
                switch candidate.kind {
                case .folder:
                    // A selected child is not permission to broaden its parent.
                    guard !sources.contains(where: { contains($0, path) || contains(path, $0) }) else { continue }
                    config.source.paths.append(candidate.path)
                    sources.append(path)
                case .database:
                    guard databases.insert(path).inserted else { continue }
                    config.databases.sqlite.append(candidate.path)
                }
                changed = true
                Log.info("Automatically included in backup: \(candidate.path)")
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
        return config
    }

    static func discover(config: Config, home: String) -> [CoverageGap] {
        let filter = ExcludeFilter(patterns: config.exclude.patterns)
        let databaseFilter = ExcludeFilter(patterns: config.exclude.patterns.filter { !sqliteFileExcludePatterns.contains($0) })
        let privateRoots = [".config/secrets", ".roberdan-os", ".gbrain", ".copilot",
                            ".codex", ".gemini", ".pi", ".claude/projects"]
        let scan = DevEnvironment.scan(home: home, includingInventory: false)
        let proposed = scan.allItems.filter { !$0.sensitive && $0.proposed }.flatMap(\.paths)
        let gaps = CoverageAuditor.audit(config: config, home: home, measuringSizes: false)
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
