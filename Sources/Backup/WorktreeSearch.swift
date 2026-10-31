import Foundation

/// Finding the saved checkouts of linked worktrees inside old snapshots.
extension WorktreePolicy {
    /// Snapshots made before 4.3.0 can hold saved checkouts of linked worktrees; the scanner
    /// has refused them ever since, so later snapshots are never searched.
    static let firstVersionWithoutCopies = "4.3.0"
    /// Seconds a backup may spend searching old snapshots for marked copies. A search that runs
    /// out of time stops between two folders and goes on from there at the next backup.
    static let scanBudget: TimeInterval = 30

    /// Where an unfinished search of one snapshot stands: `pending` are the folders still to enter
    /// ("" is the snapshot itself), `found` the marked copies met so far (snapshot-relative paths).
    struct Search: Codable, Equatable {
        var found: [String] = []
        var pending: [String] = [""]
    }

    enum SearchOutcome: Equatable {
        case finished([String])
        case unfinished(Search)
    }

    static func mayHoldCopies(_ manifest: SnapshotManifest) -> Bool {
        AutoUpdater.isNewer(firstVersionWithoutCopies, than: manifest.appVersion)
    }

    /// Top-level folders of a snapshot that are not the user's files (the app's own data, other volumes).
    private static let reservedTopLevel: Set<String> = [SnapshotManifest.directoryName, "_environment", "Volumes"]

    /// Remembered paths come from a file: only plain paths inside the snapshot are ever acted on.
    static func isSafeRelative(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        return !relative.isEmpty && !relative.hasPrefix("/") && !relative.contains("\0")
            && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
            && !reservedTopLevel.contains(String(parts[0]))
    }

    /// Looks for saved checkouts of linked worktrees, found by their marker wherever they sit in a
    /// snapshot. Stops between two folders when time, `maxFolders` or `cancelled` say so, handing
    /// back where it stands. Repository stores, links, the app's own folders and other volumes are
    /// not entered. What `prior` says is read from a file, so it is checked like any other path.
    static func search(_ snapshot: URL, from prior: Search? = nil, until deadline: Date = .distantFuture,
                       maxFolders: Int = .max, cancelled: () -> Bool = { false }) -> SearchOutcome {
        var found = (prior?.found ?? []).filter(isSafeRelative)
        var pending = prior.map { $0.pending.filter { $0.isEmpty || isSafeRelative($0) } } ?? [""]
        var visited = 0
        while let relative = pending.popLast() {
            let directory = relative.isEmpty ? snapshot : snapshot.appendingPathComponent(relative)
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                Log.warn("Worktree search skipped an unreadable folder \(directory.path): \(error.localizedDescription)")
                children = []
            }
            if !relative.isEmpty, children.contains(where: { $0.lastPathComponent == ".git" }),
               gitDirectory(of: directory) != nil {
                found.append(relative)
            } else {
                for child in children {
                    let name = child.lastPathComponent
                    if name == ".git" || (relative.isEmpty && reservedTopLevel.contains(name)) { continue }
                    guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                          values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    pending.append(relative.isEmpty ? name : relative + "/" + name)
                }
            }
            visited += 1
            // At least one folder per call, so every call makes progress.
            if !pending.isEmpty, visited >= maxFolders || cancelled() || Date() >= deadline {
                return .unfinished(Search(found: found.sorted(), pending: pending))
            }
        }
        return .finished(found.sorted())
    }
}
