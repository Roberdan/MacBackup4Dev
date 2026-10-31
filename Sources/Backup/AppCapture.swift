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
    }

    struct Report {
        var catalog: Catalog
        var cancelled = false
        var summary: Summary {
            Summary(saved: catalog.entries.filter { $0.state == .saved }.count,
                    needsInstaller: catalog.entries.filter { $0.state == .installer }.count,
                    failed: catalog.failures.count,
                    unselectedDataPaths: AppCapture.dataToChoose(in: catalog.entries).count)
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

    static func read(from snapshot: URL) throws -> Catalog? {
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
                    entry.signed = try AppBundleCopy.isSigned(source)
                    entry.fingerprint = try AppBundleCopy.copy(from: source, to: target,
                        previous: previous?.appendingPathComponent(directoryName + "/" + entry.storagePath), options: options)
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
