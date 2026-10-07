import Foundation
import Darwin

/// A persistent inode avoids the unlink/recreate race between backup and cleanup.
final class DestinationLock {
    private let descriptor: Int32

    init(at destination: URL) throws {
        var fd = try Self.lock(destination.appendingPathComponent(".rustymacbackup-operation.lock"))
        if fd == nil {
            // Some filesystems (e.g. network shares) reject flock; still serialize this Mac's app and CLI.
            let local = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/macbackup4dev/locks")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            let key = destination.standardized.path.replacingOccurrences(of: "/", with: "_")
            fd = try Self.lock(local.appendingPathComponent("\(key).lock"))
        }
        guard let fd else { throw POSIXError(.ENOTSUP) }
        // Respect a backup started by an older app, which only has the PID marker.
        let marker = destination.appendingPathComponent("rustymacbackup.lock")
        do {
            if FileManager.default.fileExists(atPath: marker.path) {
                let content = try String(contentsOf: marker, encoding: .utf8)
                if let first = content.split(separator: "\n").first,
                   let pid = Int32(first), pid > 0,
                   kill(pid, 0) == 0 || errno == EPERM {
                    throw BackupError.lockExists
                }
            }
        } catch {
            close(fd)
            throw error
        }
        descriptor = fd
    }

    /// Returns nil only when the filesystem does not support flock.
    private static func lock(_ url: URL) throws -> Int32? {
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw BackupError.lockExists }
            if code == ENOTSUP || code == EOPNOTSUPP { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return fd
    }

    deinit { close(descriptor) }
}
