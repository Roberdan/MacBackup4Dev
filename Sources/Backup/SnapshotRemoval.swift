import Foundation
import Darwin

/// Removes a whole snapshot tree that is no longer restorable: an interrupted
/// `in-progress-*` run or a snapshot already renamed `.deleting-*` by retention.
///
/// A plain `FileManager.removeItem` stops at the first entry macOS refuses to delete
/// (an "everyone deny delete" ACL, a user-immutable flag, a directory without write
/// permission) and leaves the rest behind forever (13 interrupted runs on 2026-11-01).
/// After a failure the tree is unlocked and removed again:
/// - directories are never shared between snapshots, so their ACL, user flags and owner
///   permissions are reset;
/// - a file or link is unlocked only when it has a single link: a file still linked from
///   another snapshot keeps its metadata, because changing it would change that snapshot.
enum SnapshotRemoval {
    /// Removes `root`; a missing root is not an error. Throws when anything is left.
    static func remove(_ root: URL) throws {
        var info = stat()
        guard lstat(root.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            try FileManager.default.removeItem(at: root)
            return
        } catch {
            Log.warn("Removal of \(root.lastPathComponent) refused (\(error.localizedDescription)); unlocking it")
        }
        unlock(root.path)
        try removeEverything(root.path)
    }

    struct Leftovers: LocalizedError {
        let count: Int
        let first: String
        var errorDescription: String? {
            "\(count) elementi non eliminabili (il primo: \(first)); sono condivisi con un backup buono o protetti dal sistema."
        }
    }

    /// Deletes bottom-up and keeps going past an entry that cannot go, so only that entry
    /// (and the folders holding it) remain; the leftovers are reported, never ignored.
    private static func removeEverything(_ root: String) throws {
        guard let stream = root.withCString({ pointer -> UnsafeMutablePointer<FTS>? in
            var paths: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: pointer), nil]
            return fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { fts_close(stream) }
        var failed: [String] = []
        while let entry = fts_read(stream) {
            let path = String(cString: entry.pointee.fts_path)
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                continue
            case FTS_DP:
                if rmdir(path) != 0, !failed.contains(where: { $0.hasPrefix(path + "/") }) { failed.append(path) }
            case FTS_DNR, FTS_ERR, FTS_NS:
                failed.append(path)
            default:
                if unlink(path) != 0 { failed.append(path) }
            }
        }
        if let first = failed.first {
            Log.error("Old snapshot not fully removed: \(failed.count) entries left, first \(first)")
            throw Leftovers(count: failed.count, first: first)
        }
    }

    /// Resets what blocks deletion, never following links out of the tree.
    static func unlock(_ root: String) {
        var info = stat()
        guard lstat(root, &info) == 0 else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            unlockDirectory(root, info)
        } else {
            unlockEntry(root, info)
            return
        }
        guard let stream = root.withCString({ pointer -> UnsafeMutablePointer<FTS>? in
            var paths: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: pointer), nil]
            return fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else { return }
        defer { fts_close(stream) }
        while let entry = fts_read(stream) {
            let path = String(cString: entry.pointee.fts_path)
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                // Preorder: unlock before fts reads the directory.
                if path != root, let stat = entry.pointee.fts_statp { unlockDirectory(path, stat.pointee) }
            case FTS_DNR:
                // Unreadable even after unlocking: removal will report it.
                Log.warn("Cannot read \(path) while removing an old snapshot")
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                if let stat = entry.pointee.fts_statp { unlockEntry(path, stat.pointee) }
            default:
                break
            }
        }
    }

    private static let userLocks = UInt32(UF_IMMUTABLE | UF_APPEND)

    private static func unlockDirectory(_ path: String, _ info: stat) {
        if info.st_flags & userLocks != 0 { _ = lchflags(path, info.st_flags & ~userLocks) }
        clearACL(path)
        let owner = mode_t(S_IRWXU)
        if info.st_mode & owner != owner { _ = chmod(path, (info.st_mode & 0o7777) | owner) }
    }

    private static func unlockEntry(_ path: String, _ info: stat) {
        // Shared with another snapshot: its metadata belongs to that snapshot too.
        guard info.st_nlink == 1 else { return }
        if info.st_flags & userLocks != 0 { _ = lchflags(path, info.st_flags & ~userLocks) }
        clearACL(path)
    }

    private static func clearACL(_ path: String) {
        guard let current = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return }
        acl_free(UnsafeMutableRawPointer(current))
        guard let empty = acl_init(0) else { return }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        _ = acl_set_link_np(path, ACL_TYPE_EXTENDED, empty)
    }
}
