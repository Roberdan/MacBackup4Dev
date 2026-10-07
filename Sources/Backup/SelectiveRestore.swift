import Foundation

// MARK: - Topics

/// A named group of home-relative paths restored together ("tutto Warp").
/// Built-in topics cover the tools this app backs up by default; `[topics]` in config.toml
/// adds new ones or replaces a built-in one with the same name. Paths may end with `*`.
struct RestoreTopic: Equatable {
    let name: String
    let paths: [String]   // home-relative, no leading ~/
}

enum Topics {
    static let builtIn: [String: [String]] = [
        "Warp": [".warp", "Library/Preferences/dev.warp.*", "Library/Application Support/dev.warp.*",
                 "Library/Fonts"],
        "Terminale e shell": [".zshrc", ".zshenv", ".zprofile", ".zsh_history", ".zfunc", ".bashrc",
                              ".bash_profile", ".config/oh-my-posh", ".config/atuin", ".config/zsh",
                              ".config/starship.toml", ".tmux.conf", ".tmux", ".terminfo",
                              ".config/ghostty", ".config/btop"],
        "Claude Code": [".claude", ".claude.json"],
        "Copilot": [".copilot", ".config/github-copilot", ".local/bin/copilot"],
        "Git e SSH": [".gitconfig", ".gitconfig-*", ".config/git", ".ssh/config", ".ssh/known_hosts",
                      ".config/gh"],
        "Editor": [".config/zed", "Library/Application Support/Code/User", ".vscode"],
        "Font": ["Library/Fonts"],
        "Python e strumenti": [".venvs", ".config/uv", ".cargo/config.toml", ".npmrc"],
        "MacBackup4Dev": [".config/macbackup4dev", ".config/rusty-mac-backup"],
    ]

    static func all(config: Config?) -> [RestoreTopic] {
        var merged = builtIn
        for (name, paths) in config?.topics ?? [:] {
            merged[name] = paths.map(normalize)
        }
        return merged.keys.sorted().map { RestoreTopic(name: $0, paths: merged[$0] ?? []) }
    }

    static func normalize(_ path: String) -> String {
        var p = path
        if p.hasPrefix("~/") { p.removeFirst(2) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p.hasPrefix(home + "/") { p = String(p.dropFirst(home.count + 1)) }
        return p
    }

    /// The snapshot-relative files a topic covers inside one snapshot. Never anything that
    /// starts at login (LaunchAgents, login items, system preferences of the old Mac): those
    /// come back only through "Nuovo Mac" → Servizi automatici, one explicit toggle each.
    static func files(of topic: RestoreTopic, in snapshot: URL) -> [String] {
        var out: [String] = []
        for pattern in topic.paths {
            for root in expand(pattern, in: snapshot) {
                out.append(contentsOf: SelectiveRestore.filesBelow(root, in: snapshot)
                    .filter { !NewMacRestore.isLoginSensitive($0) })
            }
        }
        return Array(Set(out)).sorted()
    }

    /// Resolve a trailing `*` in the last component against the snapshot.
    static func expand(_ pattern: String, in snapshot: URL) -> [String] {
        guard pattern.hasSuffix("*") else { return [pattern] }
        let parent = (pattern as NSString).deletingLastPathComponent
        let prefix = String((pattern as NSString).lastPathComponent.dropLast())
        let dir = parent.isEmpty ? snapshot : snapshot.appendingPathComponent(parent)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.map { parent.isEmpty ? $0 : parent + "/" + $0 }
    }
}

// MARK: - Versions of one file

struct FileVersion: Equatable {
    let snapshot: String
    let state: SnapshotState
    let size: UInt64
    let modified: Date
}

enum FileVersions {
    /// Every distinct version of `relativePath` across the snapshots, newest first.
    /// Hard-linked copies (same inode) and identical size+mtime are the same version.
    static func list(relativePath: String, at destination: URL) -> [FileVersion] {
        var out: [FileVersion] = []
        var lastKey: String?
        for snap in SnapshotCatalog.list(at: destination) {
            let path = snap.url.appendingPathComponent(relativePath).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular else { continue }
            let size = attrs[.size] as? UInt64 ?? 0
            let mtime = attrs[.modificationDate] as? Date ?? .distantPast
            let key = "\(size)-\(Int(mtime.timeIntervalSince1970))"
            if key == lastKey { continue }
            lastKey = key
            out.append(FileVersion(snapshot: snap.name, state: snap.state, size: size, modified: mtime))
        }
        return out
    }

    /// Files in a snapshot whose path contains `query` (case-insensitive), for "cerca un file".
    static func search(_ query: String, in snapshot: URL, limit: Int = 200) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty, let e = FileManager.default.enumerator(atPath: snapshot.path) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            if rel.hasPrefix(SnapshotManifest.directoryName) || rel.hasPrefix("_environment") {
                e.skipDescendants(); continue
            }
            if rel.lowercased().contains(q) {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: snapshot.appendingPathComponent(rel).path, isDirectory: &isDir)
                if !isDir.boolValue { out.append(rel); if out.count >= limit { break } }
            }
        }
        return out
    }
}

// MARK: - Selective restore with preview and per-file undo

struct RestorePlanItem: Equatable {
    enum Action: String {
        case create = "nuovo", replace = "sostituito", same = "uguale"
        /// The target is a symbolic link (e.g. ~/.claude/agents/*.md → roberdan-os): left alone.
        case keepLink = "collegamento, lasciato"
        /// A folder (or file) of another type is where the file would go: left alone.
        case conflict = "tipo diverso, lasciato"
    }
    let relativePath: String
    let action: Action
    let size: UInt64
}

struct RestorePlan {
    let snapshot: URL
    let destinationRoot: String
    let items: [RestorePlanItem]

    var toCreate: Int { items.filter { $0.action == .create }.count }
    var toReplace: Int { items.filter { $0.action == .replace }.count }
    var unchanged: Int { items.filter { $0.action == .same }.count }
    var links: Int { items.filter { $0.action == .keepLink }.count }
    var conflicts: Int { items.filter { $0.action == .conflict }.count }
    var bytes: UInt64 { items.filter { $0.action == .create || $0.action == .replace }.reduce(0) { $0 + $1.size } }

    var summary: String {
        "\(toReplace) da sostituire, \(toCreate) nuovi, \(unchanged) già uguali, 0 da cancellare"
            + (links > 0 ? ", \(links) collegamenti lasciati come sono" : "")
            + (conflicts > 0 ? ", \(conflicts) lasciati perché lì c'è una cartella" : "")
    }
}

/// Undo record v3: what the restore REPLACED (old version kept), what it CREATED, and the
/// size and modification time of what it wrote. Undo touches a file only if it is still
/// exactly what the restore wrote: a week of edits after a restore is never thrown away
/// (review H1). Earlier versions only knew replacements, so an undo left created files behind.
struct UndoManifest: Codable {
    struct Stamp: Codable, Equatable {
        var size: UInt64
        var mtime: Double
    }
    var version = 3
    var destinationRoot: String
    var replaced: [String]
    var created: [String]
    var written: [String: Stamp]? = [:]
}

struct UndoOutcome {
    var restored = 0
    var failed = 0
    /// Changed after the restore: left as they are.
    var keptBecauseChanged: [String] = []
}

enum SelectiveRestore {
    static let internalDirectories: Set<String> = [SnapshotManifest.directoryName, "_environment"]
    /// Finder litter: never worth restoring, never worth replacing a local one.
    static let junkNames: Set<String> = [".DS_Store", ".localized"]

    static func filesBelow(_ relative: String, in snapshot: URL) -> [String] {
        let fm = FileManager.default
        let root = snapshot.appendingPathComponent(relative)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return junkNames.contains(root.lastPathComponent) ? [] : [relative] }
        guard let e = fm.enumerator(atPath: root.path) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            var d: ObjCBool = false
            fm.fileExists(atPath: root.appendingPathComponent(rel).path, isDirectory: &d)
            if !d.boolValue, !junkNames.contains((rel as NSString).lastPathComponent) { out.append(relative + "/" + rel) }
        }
        return out
    }

    /// Normalise a requested path: no "..", no ".", no absolute path, nothing internal.
    static func safeRelative(_ path: String) -> String? {
        let comps = Topics.normalize(path).split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
        guard !comps.isEmpty, !comps.contains(".."), !path.hasPrefix("/") || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path),
              !internalDirectories.contains(comps[0]) else { return nil }
        return comps.joined(separator: "/")
    }

    /// True when any folder between the destination root and the file is a symbolic link:
    /// writing there would go somewhere else entirely.
    static func crossesLink(_ rel: String, root: String) -> Bool {
        let fm = FileManager.default
        var current = root
        for comp in rel.split(separator: "/").dropLast() {
            current += "/" + comp
            if (try? fm.destinationOfSymbolicLink(atPath: current)) != nil { return true }
        }
        return false
    }

    /// Compare each file with what is at the destination today. Nothing is written.
    static func plan(snapshot: URL, paths: [String],
                     destinationRoot: String = FileManager.default.homeDirectoryForCurrentUser.path) -> RestorePlan {
        let fm = FileManager.default
        var files: [String] = []
        for p in paths {
            guard let rel = safeRelative(p) else { continue }
            files.append(contentsOf: filesBelow(rel, in: snapshot))
        }
        var items: [RestorePlanItem] = []
        for rel in Array(Set(files)).sorted() {
            let src = snapshot.appendingPathComponent(rel).path
            let dst = destinationRoot + "/" + rel
            let size = (try? fm.attributesOfItem(atPath: src))?[.size] as? UInt64 ?? 0
            let action: RestorePlanItem.Action
            var isDir: ObjCBool = false
            if (try? fm.destinationOfSymbolicLink(atPath: dst)) != nil || crossesLink(rel, root: destinationRoot) {
                action = .keepLink
            } else if fm.fileExists(atPath: dst, isDirectory: &isDir) {
                if isDir.boolValue {
                    action = .conflict
                } else {
                    let same = (try? fm.attributesOfItem(atPath: dst))?[.size] as? UInt64 == size
                        && fm.contentsEqual(atPath: src, andPath: dst)
                    action = same ? .same : .replace
                }
            } else {
                action = .create
            }
            items.append(RestorePlanItem(relativePath: rel, action: action, size: size))
        }
        return RestorePlan(snapshot: snapshot, destinationRoot: destinationRoot, items: items)
    }

    static func stamp(_ path: String) -> UndoManifest.Stamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return UndoManifest.Stamp(size: a[.size] as? UInt64 ?? 0,
                                  mtime: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }

    private static func writeManifest(_ manifest: UndoManifest, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("undo.json"), options: .atomic)
    }

    /// Apply a plan. Each file is written next to its target and renamed into place, so a
    /// half-written file never replaces a good one. Replaced files are kept for undo, and
    /// the undo record is saved as the restore goes, not only at the end.
    static func apply(_ plan: RestorePlan, undoRoot: URL = RestoreEngine.preRestoreBaseURL) throws -> (result: RestoreResult, undoDir: URL?) {
        let fm = FileManager.default
        var result = RestoreResult()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var undoDir = undoRoot.appendingPathComponent(formatter.string(from: Date()))
        var n = 1
        while fm.fileExists(atPath: undoDir.path) {
            undoDir = undoRoot.appendingPathComponent(formatter.string(from: Date()) + "-\(n)"); n += 1
        }
        var manifest = UndoManifest(destinationRoot: plan.destinationRoot, replaced: [], created: [])
        var sinceSave = 0
        for item in plan.items where item.action == .create || item.action == .replace {
            let src = plan.snapshot.appendingPathComponent(item.relativePath)
            let dst = URL(fileURLWithPath: plan.destinationRoot + "/" + item.relativePath)
            let temp = dst.deletingLastPathComponent().appendingPathComponent(".rmb-restore-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if item.action == .replace {
                    let keep = undoDir.appendingPathComponent(item.relativePath)
                    try fm.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: dst, to: keep)
                }
                try HardLinker.copyFile(from: src.path, to: temp.path)
                if item.action == .replace {
                    _ = try fm.replaceItemAt(dst, withItemAt: temp)
                    manifest.replaced.append(item.relativePath)
                    result.overwritten += 1
                } else {
                    try fm.moveItem(at: temp, to: dst)   // fails if something appeared there meanwhile
                    manifest.created.append(item.relativePath)
                }
                manifest.written?[item.relativePath] = stamp(dst.path)
                result.restored += 1
            } catch {
                try? fm.removeItem(at: temp)
                Log.error("Restore failed for \(item.relativePath): \(error.localizedDescription)")
                result.failed += 1
            }
            sinceSave += 1
            if sinceSave >= 100 { try? writeManifest(manifest, to: undoDir); sinceSave = 0 }
        }
        guard !manifest.replaced.isEmpty || !manifest.created.isEmpty else {
            try? fm.removeItem(at: undoDir)
            return (result, nil)
        }
        try writeManifest(manifest, to: undoDir)
        result.backedUpTo = undoDir.path
        return (result, undoDir)
    }

    /// Undo exactly what `apply` did: put replaced files back, remove created ones, but only
    /// where the file is still what the restore wrote. `only` limits the undo to some files.
    @discardableResult
    static func undo(_ undoDir: URL, only: Set<String>? = nil) throws -> RestoreResult {
        let outcome = try undoDetailed(undoDir, only: only)
        var r = RestoreResult()
        r.restored = outcome.restored
        r.failed = outcome.failed + outcome.keptBecauseChanged.count
        return r
    }

    static func undoDetailed(_ undoDir: URL, only: Set<String>? = nil) throws -> UndoOutcome {
        let fm = FileManager.default
        let data = try Data(contentsOf: undoDir.appendingPathComponent("undo.json"))
        var manifest = try JSONDecoder().decode(UndoManifest.self, from: data)
        var outcome = UndoOutcome()
        var done = Set<String>()
        func unchanged(_ rel: String, _ path: String) -> Bool {
            guard let written = manifest.written?[rel] else { return true }   // older record
            guard let now = stamp(path) else { return true }                  // already gone
            return now.size == written.size && abs(now.mtime - written.mtime) < 0.001
        }
        for rel in manifest.created where only?.contains(rel) ?? true {
            let dst = manifest.destinationRoot + "/" + rel
            guard fm.fileExists(atPath: dst) else { done.insert(rel); continue }
            guard unchanged(rel, dst) else { outcome.keptBecauseChanged.append(rel); continue }
            do { try fm.removeItem(atPath: dst); outcome.restored += 1; done.insert(rel) } catch { outcome.failed += 1 }
        }
        for rel in manifest.replaced where only?.contains(rel) ?? true {
            let keep = undoDir.appendingPathComponent(rel)
            let dst = URL(fileURLWithPath: manifest.destinationRoot + "/" + rel)
            guard unchanged(rel, dst.path) else { outcome.keptBecauseChanged.append(rel); continue }
            do {
                if fm.fileExists(atPath: dst.path) {
                    _ = try fm.replaceItemAt(dst, withItemAt: keep)
                } else {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: keep, to: dst)
                }
                outcome.restored += 1
                done.insert(rel)
            } catch { outcome.failed += 1 }
        }
        // Only what succeeded leaves the record: a failure can be retried (review M3).
        manifest.created.removeAll { done.contains($0) }
        manifest.replaced.removeAll { done.contains($0) }
        for rel in done { manifest.written?[rel] = nil }
        if manifest.created.isEmpty && manifest.replaced.isEmpty {
            try? fm.removeItem(at: undoDir)
        } else {
            try writeManifest(manifest, to: undoDir)
        }
        return outcome
    }
}
