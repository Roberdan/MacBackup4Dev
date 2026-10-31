import Foundation
import Darwin

enum AppInventory {
    struct Root: Equatable {
        enum Kind: String, Codable { case system, user }
        var kind: Kind
        var url: URL

        static func standard(home: String) -> [Root] {
            [Root(kind: .system, url: URL(fileURLWithPath: "/Applications")),
             Root(kind: .user, url: URL(fileURLWithPath: home + "/Applications"))]
        }
    }

    struct DataPath: Codable, Hashable {
        enum State: String, Codable { case selected, notSelected, excluded, unavailable }
        var relativePath: String
        var state: State
    }

    struct Entry: Codable, Identifiable, Hashable {
        enum State: String, Codable { case pending, saved, installer, excluded, failed }
        var root: Root.Kind
        var relativePath: String
        var name: String
        var bundleID = ""
        var version = ""
        var build = ""
        var state: State = .pending
        var reason = ""
        var data: [DataPath] = []
        var warnings: [String] = []
        var fingerprint: AppBundleCopy.Fingerprint?
        var signed = false
        var packageID: String?

        var id: String { root.rawValue + ":" + relativePath }
        var storagePath: String { root.rawValue + "/" + relativePath }
        var dataDetail: String {
            let missing = data.filter { $0.state != .selected }
            if !missing.isEmpty {
                return "Dati non salvati: " + missing.map {
                    "~/" + $0.relativePath + ($0.state == .unavailable ? " (non leggibile)" : "")
                }.joined(separator: ", ")
            }
            return data.isEmpty ? "Nessun dato locale riconosciuto; controlla i dati dell'app."
                : "Dati selezionati nella copia dei file (con le esclusioni configurate)."
        }
    }

    struct Discovery {
        var entries: [Entry] = []
        var failures: [String] = []
    }

    static func validRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return (1...2).contains(parts.count) && parts.allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") && !$0.contains("\0")
        } && parts.last?.lowercased().hasSuffix(".app") == true
    }

    static func metadata(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        return value
    }

    static func exists(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0
    }

    static func info(_ app: URL) throws -> [String: Any] {
        let file = app.appendingPathComponent("Contents/Info.plist")
        guard !SelectiveRestore.crossesLink("Contents/Info.plist", root: app.path),
              try metadata(file).st_mode & S_IFMT == S_IFREG else {
            throw failure("Info.plist non è un file regolare.")
        }
        let data = try Data(contentsOf: file)
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw failure("Info.plist non valido.")
        }
        return value
    }

    static func failure(_ text: String) -> NSError {
        NSError(domain: "MacBackup4Dev.Applications", code: 1,
                userInfo: [NSLocalizedDescriptionKey: text])
    }

    static func discover(roots: [Root], home: String, config: Config? = nil) -> Discovery {
        var out = Discovery()
        let fm = FileManager.default
        for root in roots {
            do {
                let metadata: stat
                do { metadata = try self.metadata(root.url) }
                catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
                    if root.kind == .user { continue }
                    throw error
                }
                guard metadata.st_mode & S_IFMT == S_IFDIR else {
                    throw failure("La cartella delle applicazioni non è una cartella normale: \(root.url.path)")
                }
                var paths: [String] = []
                for name in try fm.contentsOfDirectory(atPath: root.url.path).sorted() where !name.hasPrefix(".") {
                    if name.lowercased().hasSuffix(".app") { paths.append(name); continue }
                    let group = root.url.appendingPathComponent(name)
                    guard try self.metadata(group).st_mode & S_IFMT == S_IFDIR else { continue }
                    for child in try fm.contentsOfDirectory(atPath: group.path).sorted()
                    where !child.hasPrefix(".") && child.lowercased().hasSuffix(".app") {
                        paths.append(name + "/" + child)
                    }
                }
                for path in paths {
                    var entry = Entry(root: root.kind, relativePath: path,
                                      name: String((path as NSString).lastPathComponent.dropLast(4)))
                    let app = root.url.appendingPathComponent(path)
                    do {
                        guard validRelativePath(path) else { throw failure("Percorso dell'app non valido.") }
                        guard try self.metadata(app).st_mode & S_IFMT == S_IFDIR else {
                            entry.state = .installer
                            entry.reason = "Collegamento o app non autonoma: serve l'installer originale."
                            out.entries.append(entry)
                            continue
                        }
                        let info = try self.info(app)
                        guard let identifier = info["CFBundleIdentifier"] as? String, safeComponent(identifier) else {
                            throw failure("Identificativo dell'app mancante o non valido.")
                        }
                        entry.bundleID = identifier
                        entry.name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? entry.name
                        entry.version = info["CFBundleShortVersionString"] as? String ?? ""
                        entry.build = info["CFBundleVersion"] as? String ?? ""
                        entry.data = dataPaths(bundleID: identifier, name: info["CFBundleName"] as? String,
                                               home: home, config: config)
                        if identifier == AppIdentity.bundleID {
                            entry.state = .excluded
                            entry.reason = "MacBackup4Dev è conservata separatamente in _environment."
                        } else if config?.applications.excludeBundleIDs.contains(identifier) == true {
                            entry.state = .excluded
                            entry.reason = "Esclusa dalla configurazione."
                        } else if fm.fileExists(atPath: app.path + "/Contents/_MASReceipt/receipt") {
                            entry.state = .installer
                            entry.reason = "App Store: reinstalla da Programmi o dall'App Store con il tuo account."
                        } else if identifier.hasPrefix("com.apple.") {
                            entry.state = .excluded
                            entry.reason = "Applicazione di macOS: non si trasferisce dal vecchio sistema."
                        } else if identifier.hasPrefix("com.google.Chrome.app.") {
                            entry.state = .installer
                            entry.reason = "App web collegata al browser: ricreala dal browser originale."
                        } else if ["LaunchServices", "LaunchDaemons", "SystemExtensions", "Extensions"].contains(where: {
                            fm.fileExists(atPath: app.path + "/Contents/Library/" + $0)
                        }) {
                            entry.state = .installer
                            entry.reason = "Contiene componenti di sistema: usa l'installer originale."
                        } else if let link = AppBundleCopy.externalMainExecutable(app, info: info) {
                            entry.state = .installer
                            entry.reason = AppBundleCopy.notSelfContainedReason(link)
                        } else {
                            entry.warnings.append("Accessi, licenze e permessi di macOS possono richiedere una nuova conferma.")
                        }
                    } catch {
                        entry.state = .failed
                        entry.reason = error.localizedDescription
                        out.failures.append("\(entry.name): \(entry.reason)")
                    }
                    out.entries.append(entry)
                }
            } catch {
                out.failures.append("\(root.url.path): \(error.localizedDescription)")
            }
        }
        return out
    }

    static func safeComponent(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && !name.contains("\0") && name.utf8.count < 256
    }

    static func dataPaths(bundleID: String, name: String?, home: String, config: Config?) -> [DataPath] {
        guard safeComponent(bundleID) else { return [] }
        var candidates = ["Library/Preferences/" + bundleID + ".plist",
                          "Library/Application Support/" + bundleID]
        if let name, safeComponent(name) { candidates.append("Library/Application Support/" + name) }
        let sources = (config?.source.paths ?? []).map { path in
            path.hasPrefix("~/") ? home + String(path.dropFirst()) : path
        }
        let filter = ExcludeFilter(patterns: config?.exclude.patterns ?? defaultExcludePatterns)
        return Array(Set(candidates)).sorted().compactMap { rel in
            // Only these ordinary paths are probed. Containers, group containers and
            // Keychain are never enumerated, even to measure coverage.
            guard !ConfigDiscovery.isForbidden("~/" + rel), !NewMacRestore.isLoginSensitive(rel),
                  !SelectiveRestore.crossesLink(rel, root: home) else { return nil }
            let url = URL(fileURLWithPath: home + "/" + rel)
            let value: stat
            do { value = try metadata(url) }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
            catch {
                Log.warn("Cannot inspect application data \(url.path): \(error)")
                return DataPath(relativePath: rel, state: .unavailable)
            }
            guard [S_IFREG, S_IFDIR].contains(value.st_mode & S_IFMT) else { return nil }
            let selected = sources.contains { url.path == $0 || url.path.hasPrefix($0 + "/") }
            let state: DataPath.State = filter.isExcluded(relativePath: rel) ? .excluded
                : selected ? .selected : .notSelected
            return DataPath(relativePath: rel, state: state)
        }
    }

    static func dataCandidates(home: String = NSHomeDirectory(), roots: [Root]? = nil,
                               excluding knownPaths: Set<String> = []) -> [DiscoveredConfig] {
        let result = discover(roots: roots ?? Root.standard(home: home), home: home)
        for failure in result.failures { Log.warn("Application data discovery: \(failure)") }
        var represented = knownPaths
        return result.entries.filter { !$0.bundleID.isEmpty && $0.state != .excluded }.compactMap { entry in
            // Known tool settings keep their existing picker entry and sensitivity.
            let paths = entry.data.map { "~/" + $0.relativePath }.filter { represented.insert($0).inserted }
            guard !paths.isEmpty else { return nil }
            return DiscoveredConfig(category: "Dati delle applicazioni", label: entry.name,
                                    paths: paths, sensitive: true)
        }
    }
}
