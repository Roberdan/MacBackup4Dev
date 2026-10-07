import Foundation

enum SpaceLevel {
    case verde
    case warning
    case rosso
}

enum DiskDiagnostics {
    static func preflightWriteTest(at url: URL) -> Bool {
        let probe = url.appendingPathComponent(".rustymacbackup-probe-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try "probe".write(to: probe, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// True when the volume holding `path` is encrypted (FileVault / APFS encryption).
    /// Asked to the file system for the volume itself: the old check ran `diskutil info` on
    /// the backup folder (not a disk, so it always failed) and looked for "FileVault: Yes"
    /// with one space, while diskutil aligns columns: an encrypted disk was reported as
    /// "NOT encrypted" at every backup (found 2026-10-07).
    static func checkEncryption(volume path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsEncryptedKey])
        return values?.volumeIsEncrypted ?? false
    }


    static func diskSpace(at path: String) -> (free: UInt64, total: UInt64) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber,
              let total = attrs[.systemSize] as? NSNumber
        else { return (0, 0) }
        return (free.uint64Value, total.uint64Value)
    }

    static func spaceColorLevel(free: UInt64) -> SpaceLevel {
        let gb50: UInt64 = 50 * 1_073_741_824
        let gb10: UInt64 = 10 * 1_073_741_824
        if free > gb50 { return .verde }
        if free > gb10 { return .warning }
        return .rosso
    }
}
