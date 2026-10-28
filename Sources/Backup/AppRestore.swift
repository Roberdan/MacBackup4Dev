import Foundation
import AppKit
import Darwin

enum AppRestore {
    static let journalName = "undo-apps.json"

    struct Outcome {
        var installed: Bool
        var message: String
    }

    struct Report {
        var installed = 0
        var skipped = 0
        var failures: [String] = []
        var undoDirectory: URL?
    }

    private struct JournalEntry: Codable {
        var application: AppInventory.Entry
        var device: dev_t
        var inode: ino_t
    }

    private struct Journal: Codable {
        var entries: [JournalEntry]
    }

    static func installedIDs(_ entries: [AppInventory.Entry], roots: [AppInventory.Root],
                             home: String) -> Set<String> {
        let installed = AppInventory.discover(roots: roots, home: home)
        let identifiers = Set(installed.entries.map(\.bundleID).filter { !$0.isEmpty })
        return Set(entries.filter { !$0.bundleID.isEmpty && identifiers.contains($0.bundleID) }.map(\.id))
    }

    static func isRunning(_ identifier: String) -> Bool {
        !identifier.isEmpty && !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
    }

    static func run(snapshot: URL, selected: Set<String>, home: String, roots: [AppInventory.Root]? = nil,
                    dryRun: Bool, running: (String) -> Bool = isRunning,
                    sink: (String) -> Void = { _ in }) throws -> Report {
        guard let catalog = try AppCapture.read(from: snapshot) else {
            throw AppInventory.failure("Questo snapshot non contiene un archivio delle applicazioni.")
        }
        let chosen = catalog.entries.filter { selected.contains($0.id) }
        guard Set(chosen.map(\.id)) == selected, chosen.allSatisfy({ $0.state == .saved }) else {
            throw AppInventory.failure("La selezione contiene applicazioni sconosciute o non salvate.")
        }
        let destinations = roots ?? AppInventory.Root.standard(home: home)
        var report = Report()
        var journal = Journal(entries: [])
        let undo = URL(fileURLWithPath: home + "/.rustybackup-pre-restore/apps-" + UUID().uuidString)
        if !dryRun && !chosen.isEmpty {
            guard !SelectiveRestore.crossesLink(".rustybackup-pre-restore/" + undo.lastPathComponent + "/" + journalName,
                                                root: home) else {
                throw AppInventory.failure("La cartella per annullare il ripristino attraversa un collegamento.")
            }
            try FileManager.default.createDirectory(at: undo, withIntermediateDirectories: true)
        }
        for entry in chosen {
            sink("  \(entry.name): \(entry.dataDetail)")
            if dryRun {
                sink("  ripristinerei \(entry.name) dal backup, senza avviarla")
                continue
            }
            do {
                let result = try restore(entry, snapshot: snapshot, roots: destinations, home: home, running: running) { staging in
                    // Record the intended addition before rename: a crash cannot leave an
                    // installed app untracked; identity excludes an identical raced app.
                    let metadata = try AppInventory.metadata(staging)
                    var pending = journal
                    pending.entries.append(JournalEntry(application: entry, device: metadata.st_dev, inode: metadata.st_ino))
                    try JSONEncoder().encode(pending).write(to: undo.appendingPathComponent(journalName), options: .atomic)
                    journal = pending
                }
                if result.installed { report.installed += 1 } else { report.skipped += 1 }
                sink("  \(entry.name): \(result.message)")
            } catch {
                report.failures.append("\(entry.name): \(error.localizedDescription)")
                sink("  \(entry.name): NON ripristinata: \(error.localizedDescription)")
            }
        }
        if !journal.entries.isEmpty { report.undoDirectory = undo }
        else if !dryRun && !chosen.isEmpty { try FileManager.default.removeItem(at: undo) }
        return report
    }

    static func restore(_ entry: AppInventory.Entry, snapshot: URL, roots: [AppInventory.Root], home: String,
                        running: (String) -> Bool = isRunning,
                        beforeInstall: (URL) throws -> Void = { _ in }) throws -> Outcome {
        guard entry.state == .saved, AppInventory.validRelativePath(entry.relativePath),
              AppInventory.safeComponent(entry.bundleID), let fingerprint = entry.fingerprint,
              let root = roots.first(where: { $0.kind == entry.root }) else {
            throw AppInventory.failure("Applicazione o destinazione non valida.")
        }
        if running(entry.bundleID) {
            return Outcome(installed: false, message: "in esecuzione, lasciata intatta")
        }
        if installedIDs([entry], roots: roots, home: home).contains(entry.id) {
            return Outcome(installed: false, message: "già installata, lasciata intatta")
        }
        let target = root.url.appendingPathComponent(entry.relativePath)
        guard !AppInventory.exists(target) else {
            throw AppInventory.failure("La destinazione è occupata: non verrà sovrascritta.")
        }
        let rel = AppCapture.directoryName + "/" + entry.storagePath
        let source = snapshot.appendingPathComponent(rel)
        guard !SelectiveRestore.crossesLink(rel, root: snapshot.path),
              try AppInventory.metadata(source).st_mode & S_IFMT == S_IFDIR else {
            throw AppInventory.failure("L'archivio dell'app attraversa un collegamento o non è una cartella.")
        }
        let info = try AppInventory.info(source)
        guard info["CFBundleIdentifier"] as? String == entry.bundleID,
              (info["CFBundleShortVersionString"] as? String ?? "") == entry.version,
              (info["CFBundleVersion"] as? String ?? "") == entry.build,
              try AppBundleCopy.fingerprint(source) == fingerprint else {
            throw AppInventory.failure("L'app nel backup non corrisponde al catalogo.")
        }
        if entry.signed {
            guard try AppBundleCopy.isSigned(source) else {
                throw AppInventory.failure("La firma dell'app nel backup è mancante.")
            }
        }
        try prepareParent(entry, root: root)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".mb4d-app-" + UUID().uuidString + ".app")
        defer {
            if AppInventory.exists(staging) {
                do { try AppBundleCopy.removePartial(at: staging) }
                catch { Log.error("Cannot remove app staging \(staging.path): \(error)") }
            }
        }
        guard try AppBundleCopy.copy(from: source, to: staging) == fingerprint else {
            throw AppInventory.failure("La copia dell'app non è integra.")
        }
        try beforeInstall(staging)
        guard renamex_np(staging.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Installazione non eseguita: la destinazione è cambiata o non è scrivibile."])
        }
        return Outcome(installed: true, message: "copia ripristinata e verificata; app non avviata")
    }

    private static func prepareParent(_ entry: AppInventory.Entry, root: AppInventory.Root) throws {
        let fm = FileManager.default
        if !AppInventory.exists(root.url) {
            try fm.createDirectory(at: root.url, withIntermediateDirectories: true)
        }
        guard try AppInventory.metadata(root.url).st_mode & S_IFMT == S_IFDIR,
              !SelectiveRestore.crossesLink(entry.relativePath, root: root.url.path) else {
            throw AppInventory.failure("La destinazione attraversa un collegamento.")
        }
        let parent = root.url.appendingPathComponent(entry.relativePath).deletingLastPathComponent()
        if !AppInventory.exists(parent) { try fm.createDirectory(at: parent, withIntermediateDirectories: false) }
        guard try AppInventory.metadata(parent).st_mode & S_IFMT == S_IFDIR,
              fm.isWritableFile(atPath: parent.path) else {
            throw AppInventory.failure("La cartella delle applicazioni non è scrivibile; servono i permessi del Mac.")
        }
    }

    static func undo(_ directory: URL, home: String, roots: [AppInventory.Root]? = nil,
                     running: (String) -> Bool = isRunning) throws -> String {
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: directory.appendingPathComponent(journalName)))
        let destinations = roots ?? AppInventory.Root.standard(home: home)
        let movedRoot = URL(fileURLWithPath: NewMacRestore.movedAsideRoot(home: home) + "/Applicazioni/" + UUID().uuidString)
        guard !SelectiveRestore.crossesLink(String(movedRoot.path.dropFirst(home.count + 1)) + "/app",
                                            root: home) else {
            throw AppInventory.failure("La cartella delle copie conservate attraversa un collegamento.")
        }
        var moved = 0
        var kept = 0
        for recorded in journal.entries {
            let entry = recorded.application
            guard AppInventory.validRelativePath(entry.relativePath),
                  let root = destinations.first(where: { $0.kind == entry.root }), let fingerprint = entry.fingerprint else {
                throw AppInventory.failure("Registro di annullamento delle app non valido.")
            }
            let app = root.url.appendingPathComponent(entry.relativePath)
            guard AppInventory.exists(app) else { continue }
            guard !SelectiveRestore.crossesLink(entry.relativePath, root: root.url.path) else {
                throw AppInventory.failure("L'app ripristinata attraversa un collegamento.")
            }
            let metadata = try AppInventory.metadata(app)
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw AppInventory.failure("L'app ripristinata non è una cartella normale.")
            }
            if metadata.st_dev != recorded.device || metadata.st_ino != recorded.inode || running(entry.bundleID) {
                kept += 1
                continue
            }
            if try AppBundleCopy.fingerprint(app) != fingerprint {
                kept += 1
                continue
            }
            let saved = movedRoot.appendingPathComponent(entry.storagePath)
            try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard renamex_np(app.path, saved.path, UInt32(RENAME_EXCL)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            moved += 1
        }
        return "\(moved) app spostate tra le copie conservate; \(kept) cambiate o in uso, lasciate intatte."
    }
}
