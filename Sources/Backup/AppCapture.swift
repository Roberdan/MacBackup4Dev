import Foundation
import Darwin

enum AppCapture {
    static let directoryName = SnapshotManifest.directoryName + "/applications"

    struct Catalog: Codable {
        var formatVersion = 1
        var entries: [AppInventory.Entry]
        var failures: [String]
    }

    struct Summary: Codable, Equatable {
        var saved: Int
        var needsInstaller: Int
        var failed: Int
        var unselectedDataPaths: Int
        /// The rule `unselectedDataPaths` was counted by; absent in files written before 4.3.2.
        var dataCountRule: Int? = nil
    }

    /// Before 4.3.2 the count included data of excluded apps (this app itself) that the picker never
    /// offers, so the menu asked to choose what could not be chosen. A count made by that rule
    /// must not be trusted: it carries no number here.
    static let dataCountRule = 2

    struct Report {
        var catalog: Catalog
        var cancelled = false
        var summary: Summary {
            Summary(saved: catalog.entries.filter { $0.state == .saved }.count,
                    needsInstaller: catalog.entries.filter { $0.state == .installer }.count,
                    failed: catalog.failures.count,
                    unselectedDataPaths: AppCapture.dataToChoose(in: catalog.entries).count,
                    dataCountRule: AppCapture.dataCountRule)
        }
    }

    /// App data the user can still choose in the picker. Apps that are excluded (this app, macOS,
    /// the user's own exclusions) are not offered there, and data that is excluded or unreadable
    /// cannot be chosen: counting them made the menu ask for something impossible.
    static func dataToChoose(in entries: [AppInventory.Entry]) -> Set<String> {
        Set(entries.filter { $0.state != .excluded && !$0.bundleID.isEmpty }
            .flatMap(\.data).filter { $0.state == .notSelected }.map(\.relativePath))
    }

    static func catalogURL(in snapshot: URL) -> URL {
        snapshot.appendingPathComponent(directoryName + "/catalog.json")
    }

    /// A snapshot made within a day of the last application capture holds only this file, with
    /// the name of the complete snapshot that has the apps, instead of linking every app file
    /// again: on 2026-11-02 the copies were 248,000 of the 470,000 entries of each backup and
    /// half of its hour (Roberto, 2026-11-02: apps once a day).
    static let referenceName = directoryName + "/same-as"
    static let captureInterval: TimeInterval = 24 * 3600

    /// The name a snapshot's reference points to, if it has a well-formed one.
    static func referencedName(in snapshot: URL) -> String? {
        let url = snapshot.appendingPathComponent(referenceName)
        guard !SelectiveRestore.crossesLink(referenceName, root: snapshot.path),
              let metadata = try? AppInventory.metadata(url), metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size < 256,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RetentionManager.parseBackupName(name) != nil, name != snapshot.lastPathComponent else { return nil }
        return name
    }

    /// The snapshot holding the applications of `snapshot`: itself, or the complete snapshot
    /// its reference names, next to it. nil when there is none.
    static func holder(of snapshot: URL) -> URL? {
        if AppInventory.exists(catalogURL(in: snapshot)) { return snapshot }
        guard let name = referencedName(in: snapshot) else { return nil }
        let target = snapshot.deletingLastPathComponent().appendingPathComponent(name)
        guard (try? AppInventory.metadata(target).st_mode & S_IFMT) == S_IFDIR,
              AppInventory.exists(catalogURL(in: target)),
              SnapshotManifest.read(from: target)?.complete == true else { return nil }
        return target
    }

    /// Writes the reference of a new snapshot to the snapshot holding the apps.
    static func refer(_ snapshot: URL, to holder: URL) throws {
        let url = snapshot.appendingPathComponent(referenceName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (holder.lastPathComponent + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The catalog of the applications of `snapshot`, following its reference.
    static func read(from snapshot: URL) throws -> Catalog? {
        guard let holder = holder(of: snapshot) else {
            if referencedName(in: snapshot) != nil {
                throw AppInventory.failure("Le applicazioni di questo snapshot sono in un altro che non è più disponibile.")
            }
            return nil
        }
        return try readOwn(from: holder)
    }

    private static func readOwn(from snapshot: URL) throws -> Catalog? {
        let url = catalogURL(in: snapshot)
        do { _ = try AppInventory.metadata(url) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
        guard !SelectiveRestore.crossesLink(directoryName + "/catalog.json", root: snapshot.path),
              try AppInventory.metadata(url).st_mode & S_IFMT == S_IFREG else {
            throw AppInventory.failure("Il catalogo delle applicazioni non è un file regolare.")
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        guard catalog.formatVersion == 1, Set(catalog.entries.map(\.id)).count == catalog.entries.count,
              catalog.entries.allSatisfy({ AppInventory.validRelativePath($0.relativePath) }) else {
            throw AppInventory.failure("Catalogo delle applicazioni non valido o di una versione non supportata.")
        }
        return catalog
    }

    static func capture(config: Config, home: String, roots: [AppInventory.Root], into snapshot: URL,
                        previous: URL?, options: AppBundleCopy.Options = AppBundleCopy.Options(),
                        installers: [String: AppInstallers.Hint] = [:],
                        onProgress: (Int, Int) -> Void = { _, _ in }) -> Report {
        let discovery = AppInventory.discover(roots: roots, home: home, config: config)
        var report = Report(catalog: Catalog(entries: discovery.entries, failures: discovery.failures))
        let directory = snapshot.appendingPathComponent(directoryName)
        // Verified copies of the previous snapshot, reused when an app has not changed.
        var verified: [String: AppInventory.Entry] = [:]
        if let previous {
            do {
                for old in try read(from: previous)?.entries ?? [] where old.state == .saved && old.fingerprint != nil {
                    verified[old.id] = old
                }
            } catch { Log.warn("Previous app catalog unreadable, every app is copied in full: \(error.localizedDescription)") }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let total = report.catalog.entries.count
            for index in report.catalog.entries.indices {
                if options.isCancelled() { report.cancelled = true; return report }
                onProgress(index + 1, total)
                var entry = report.catalog.entries[index]
                if let root = roots.first(where: { $0.kind == entry.root }),
                   let hint = installers[root.url.appendingPathComponent(entry.relativePath).path] {
                    entry.packageID = hint.packageID
                    if entry.state == .pending && hint.requiresInstaller {
                        entry.state = .installer
                        entry.reason = "Homebrew: richiede l'installer di \(hint.packageID); usa la fase Programmi."
                    }
                    report.catalog.entries[index] = entry
                }
                guard entry.state == .pending else { continue }
                do {
                    guard let root = roots.first(where: { $0.kind == entry.root }) else {
                        throw AppInventory.failure("Cartella sorgente dell'app non disponibile.")
                    }
                    let source = root.url.appendingPathComponent(entry.relativePath)
                    let target = directory.appendingPathComponent(entry.storagePath)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try AppBundleCopy.requireSelfContainedExecutable(source)
                    if let previous, let old = verified[entry.id], let recorded = old.fingerprint,
                       let recordedSource = old.sourceStamp,
                       !SelectiveRestore.crossesLink(directoryName + "/" + entry.storagePath + "/Contents", root: previous.path),
                       old.bundleID == entry.bundleID, old.version == entry.version, old.build == entry.build,
                       let reused = try AppBundleCopy.reuseUnchanged(from: source, to: target,
                           previous: previous.appendingPathComponent(directoryName + "/" + entry.storagePath),
                           recorded: recorded, recordedSource: recordedSource, options: options) {
                        entry.signed = old.signed
                        entry.fingerprint = reused
                        entry.sourceStamp = recordedSource
                        entry.state = .saved
                        entry.reason = "Copia integra; l'app non viene avviata durante il ripristino."
                        report.catalog.entries[index] = entry
                        continue
                    }
                    entry.signed = try options.verifySignature(source)
                    let copied = try AppBundleCopy.copyRecordingSource(from: source, to: target,
                        previous: previous?.appendingPathComponent(directoryName + "/" + entry.storagePath), options: options)
                    entry.fingerprint = copied.fingerprint
                    entry.sourceStamp = copied.source
                    entry.state = .saved
                    entry.reason = "Copia integra; l'app non viene avviata durante il ripristino."
                } catch is CancellationError {
                    report.cancelled = true
                    return report
                } catch let error as AppBundleCopy.NeedsInstaller {
                    entry.state = .installer
                    entry.reason = error.localizedDescription
                } catch {
                    entry.state = .failed
                    entry.reason = error.localizedDescription
                    report.catalog.failures.append("\(entry.name): \(entry.reason)")
                    Log.error("App not saved: \(entry.name): \(entry.reason)")
                }
                report.catalog.entries[index] = entry
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report.catalog).write(to: catalogURL(in: snapshot), options: .atomic)
        } catch {
            let reason = "Catalogo delle applicazioni non salvato: \(error.localizedDescription)"
            report.catalog.failures.append(reason)
            Log.error(reason)
        }
        return report
    }
}
