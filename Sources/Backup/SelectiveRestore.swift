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
        "Servizi automatici": ["Library/LaunchAgents"],
        "Font": ["Library/Fonts"],
        "Python e strumenti": [".venvs", ".config/uv", ".cargo/config.toml", ".npmrc"],
        "RustyMacBackup": [".config/rusty-mac-backup"],
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

    /// The snapshot-relative files a topic covers inside one snapshot.
    static func files(of topic: RestoreTopic, in snapshot: URL) -> [String] {
        var out: [String] = []
        for pattern in topic.paths {
            for root in expand(pattern, in: snapshot) {
                out.append(contentsOf: SelectiveRestore.filesBelow(root, in: snapshot))
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
    enum Action: String { case create = "nuovo", replace = "sostituito", same = "uguale" }
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
    var bytes: UInt64 { items.filter { $0.action != .same }.reduce(0) { $0 + $1.size } }

    var summary: String {
        "\(toReplace) da sostituire, \(toCreate) nuovi, \(unchanged) già uguali, 0 da cancellare"
    }
}

/// Undo record v2: lists files the restore REPLACED (their old version is kept) and files it
/// CREATED (undo removes them). The old format only knew replacements, so an undo left
/// every newly restored file behind.
struct UndoManifest: Codable {
    var version = 2
    var destinationRoot: String
    var replaced: [String]
    var created: [String]
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

    /// Compare each file with what is at the destination today. Nothing is written.
    static func plan(snapshot: URL, paths: [String],
                     destinationRoot: String = FileManager.default.homeDirectoryForCurrentUser.path) -> RestorePlan {
        let fm = FileManager.default
        var files: [String] = []
        for p in paths {
            let rel = Topics.normalize(p)
            guard let first = rel.split(separator: "/").first.map(String.init),
                  !internalDirectories.contains(first) else { continue }
            files.append(contentsOf: filesBelow(rel, in: snapshot))
        }
        var items: [RestorePlanItem] = []
        for rel in Array(Set(files)).sorted() {
            let src = snapshot.appendingPathComponent(rel).path
            let dst = destinationRoot + "/" + rel
            let srcAttrs = try? fm.attributesOfItem(atPath: src)
            let size = srcAttrs?[.size] as? UInt64 ?? 0
            let action: RestorePlanItem.Action
            if let dstAttrs = try? fm.attributesOfItem(atPath: dst) {
                let same = (dstAttrs[.size] as? UInt64) == size
                    && fm.contentsEqual(atPath: src, andPath: dst)
                action = same ? .same : .replace
            } else {
                action = .create
            }
            items.append(RestorePlanItem(relativePath: rel, action: action, size: size))
        }
        return RestorePlan(snapshot: snapshot, destinationRoot: destinationRoot, items: items)
    }

    /// Apply a plan. Each file is written next to its target and renamed into place, so a
    /// half-written file never replaces a good one. Replaced files are kept for undo.
    static func apply(_ plan: RestorePlan, undoRoot: URL = RestoreEngine.preRestoreBaseURL) throws -> (result: RestoreResult, undoDir: URL?) {
        let fm = FileManager.default
        var result = RestoreResult()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        var undoDir = undoRoot.appendingPathComponent(stamp.string(from: Date()))
        var n = 1
        while fm.fileExists(atPath: undoDir.path) {
            undoDir = undoRoot.appendingPathComponent(stamp.string(from: Date()) + "-\(n)"); n += 1
        }
        var manifest = UndoManifest(destinationRoot: plan.destinationRoot, replaced: [], created: [])
        for item in plan.items where item.action != .same {
            let src = plan.snapshot.appendingPathComponent(item.relativePath)
            let dst = URL(fileURLWithPath: plan.destinationRoot + "/" + item.relativePath)
            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if item.action == .replace {
                    let keep = undoDir.appendingPathComponent(item.relativePath)
                    try fm.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: dst, to: keep)
                }
                let temp = dst.deletingLastPathComponent()
                    .appendingPathComponent(".rmb-restore-\(UUID().uuidString)")
                try HardLinker.copyFile(from: src.path, to: temp.path)
                if item.action == .replace {
                    _ = try fm.replaceItemAt(dst, withItemAt: temp)
                    manifest.replaced.append(item.relativePath)
                    result.overwritten += 1
                } else {
                    try fm.moveItem(at: temp, to: dst)
                    manifest.created.append(item.relativePath)
                }
                result.restored += 1
            } catch {
                Log.error("Restore failed for \(item.relativePath): \(error.localizedDescription)")
                result.failed += 1
            }
        }
        guard !manifest.replaced.isEmpty || !manifest.created.isEmpty else { return (result, nil) }
        try fm.createDirectory(at: undoDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: undoDir.appendingPathComponent("undo.json"), options: .atomic)
        result.backedUpTo = undoDir.path
        return (result, undoDir)
    }

    /// Undo exactly what `apply` did: put replaced files back, remove created ones.
    /// `only` limits the undo to some files (per-file undo).
    static func undo(_ undoDir: URL, only: Set<String>? = nil) throws -> RestoreResult {
        let fm = FileManager.default
        let data = try Data(contentsOf: undoDir.appendingPathComponent("undo.json"))
        var manifest = try JSONDecoder().decode(UndoManifest.self, from: data)
        var result = RestoreResult()
        for rel in manifest.created where only?.contains(rel) ?? true {
            let dst = manifest.destinationRoot + "/" + rel
            do { try fm.removeItem(atPath: dst); result.restored += 1 } catch { result.failed += 1 }
        }
        for rel in manifest.replaced where only?.contains(rel) ?? true {
            let keep = undoDir.appendingPathComponent(rel)
            let dst = URL(fileURLWithPath: manifest.destinationRoot + "/" + rel)
            do {
                if fm.fileExists(atPath: dst.path) {
                    _ = try fm.replaceItemAt(dst, withItemAt: keep)
                } else {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: keep, to: dst)
                }
                result.restored += 1
            } catch { result.failed += 1 }
        }
        if let only {
            manifest.created.removeAll { only.contains($0) }
            manifest.replaced.removeAll { only.contains($0) }
        } else {
            manifest.created = []; manifest.replaced = []
        }
        if manifest.created.isEmpty && manifest.replaced.isEmpty && result.failed == 0 {
            try? fm.removeItem(at: undoDir)
        } else {
            try JSONEncoder().encode(manifest).write(to: undoDir.appendingPathComponent("undo.json"), options: .atomic)
        }
        return result
    }
}
