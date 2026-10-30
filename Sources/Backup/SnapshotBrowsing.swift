import Foundation
import Darwin

/// Read-only walking of one snapshot, one folder at a time, for the restore browser.
/// Nothing here follows a symbolic link stored in a snapshot (a link may point anywhere on
/// the Mac or the disk) and nothing exposes the snapshot's own metadata folders.
enum SnapshotBrowsing {
    struct Entry: Equatable, Identifiable {
        enum Kind { case file, directory, link }
        let name: String
        let relativePath: String
        let kind: Kind
        let size: UInt64
        let modified: Date
        var id: String { relativePath }
    }

    /// The snapshots a person may browse: only those whose manifest says `complete: true`,
    /// newest first. `SnapshotCatalog` stays the single source of truth.
    static func browsableSnapshots(at destination: URL) -> [SnapshotInfo] {
        SnapshotCatalog.list(at: destination).filter { $0.state == .complete }
    }

    /// A clean home-relative path ("" is the snapshot root), or nil for anything unsafe.
    static func normalized(_ path: String) -> String? {
        let comps = path.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
        if comps.isEmpty { return "" }
        guard !comps.contains("..") else { return nil }
        let joined = comps.joined(separator: "/")
        return SelectiveRestore.safeRelative(joined)
    }

    private static func lstatInfo(_ path: String) -> (kind: Entry.Kind, size: UInt64, modified: Date)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let kind: Entry.Kind
        switch st.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .link
        default: return nil   // sockets, devices, pipes are never listed
        }
        let t = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000
        return (kind, UInt64(max(0, st.st_size)), Date(timeIntervalSince1970: t))
    }

    /// True when `relative` is a real directory inside `snapshot`, with no link on the way.
    static func isRealDirectory(_ relative: String, in snapshot: URL) -> Bool {
        var current = snapshot.path
        if !relative.isEmpty {
            for comp in relative.split(separator: "/") {
                current += "/" + comp
                guard lstatInfo(current)?.kind == .directory else { return false }
            }
        }
        return true
    }

    /// Folders first, then files, by name. Throws `fileNoSuchFile` when the folder does not
    /// exist in this snapshot (it may exist at another date) and for any unsafe path.
    static func list(snapshot: URL, directory: String) throws -> [Entry] {
        guard let dir = normalized(directory), isRealDirectory(dir, in: snapshot) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: directory])
        }
        let base = dir.isEmpty ? snapshot.path : snapshot.path + "/" + dir
        let names = try FileManager.default.contentsOfDirectory(atPath: base)
        var out: [Entry] = []
        for name in names {
            if dir.isEmpty, SelectiveRestore.internalDirectories.contains(name) { continue }
            if SelectiveRestore.junkNames.contains(name) { continue }
            guard let info = lstatInfo(base + "/" + name) else { continue }
            out.append(Entry(name: name, relativePath: dir.isEmpty ? name : dir + "/" + name,
                             kind: info.kind, size: info.size, modified: info.modified))
        }
        return out.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// What exists at `relative` in this snapshot, without following links.
    static func entry(snapshot: URL, relative: String) -> Entry? {
        guard let rel = normalized(relative), !rel.isEmpty,
              isRealDirectory((rel as NSString).deletingLastPathComponent, in: snapshot),
              let info = lstatInfo(snapshot.path + "/" + rel) else { return nil }
        return Entry(name: (rel as NSString).lastPathComponent, relativePath: rel,
                     kind: info.kind, size: info.size, modified: info.modified)
    }

    /// Regular files to restore for a file or a folder (recursive). Links, special files,
    /// internal metadata, Finder litter and anything that starts at login are left out;
    /// `skippedLoginSensitive` counts the latter so the preview can say so.
    static func restorableFiles(snapshot: URL, relative: String) -> (files: [String], skippedLoginSensitive: Int) {
        guard let rel = normalized(relative), !rel.isEmpty,
              let top = entry(snapshot: snapshot, relative: rel) else { return ([], 0) }
        var files: [String] = []
        var skipped = 0
        func visit(_ relPath: String, _ kind: Entry.Kind) {
            switch kind {
            case .file:
                if SelectiveRestore.junkNames.contains((relPath as NSString).lastPathComponent) { return }
                if NewMacRestore.isLoginSensitive(relPath) { skipped += 1 } else { files.append(relPath) }
            case .directory:
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: snapshot.path + "/" + relPath) else { return }
                for name in names {
                    guard let info = lstatInfo(snapshot.path + "/" + relPath + "/" + name) else { continue }
                    visit(relPath + "/" + name, info.kind)
                }
            case .link:
                return
            }
        }
        visit(top.relativePath, top.kind)
        return (files.sorted(), skipped)
    }
}
