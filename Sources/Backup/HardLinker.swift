import Foundation
import Darwin

enum HardLinker {
    /// Compare size + mtime to decide if file should be hard-linked from previous backup.
    static func shouldHardLink(sourcePath: String, sourceSize: UInt64, sourceMtime: Date,
                                previousBackupPath: String) -> Bool {
        var metadata = stat()
        guard lstat(previousBackupPath, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0 else {
            return false
        }
        let previousTime = Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        return sourceSize == UInt64(metadata.st_size) && abs(sourceMtime.timeIntervalSince1970 - previousTime) < 0.001
    }

    /// Create hard link from an existing backup file to the new destination.
    static func hardLink(from source: String, to destination: String) throws {
        try FileManager.default.linkItem(atPath: source, toPath: destination)
    }

    /// Copy file using Apple's copyfile() preserving all attributes.
    /// NOTE: COPYFILE_CLONE (1<<20) was REMOVING source files when copying
    /// across volumes (APFS -> ExFAT/HFS+). Use COPYFILE_ALL only.
    static func copyFile(from source: String, to destination: String) throws {
        // COPYFILE_ALL = DATA|XATTR|STAT|ACL = 0x0F (NO CLONE!)
        let flags = copyfile_flags_t(UInt32(0x0F))
        if Darwin.copyfile(source, destination, nil, flags) == 0 { return }
        let firstError = errno
        // macOS sometimes refuses to copy an ACL or a protected extended attribute
        // (com.apple.provenance) while the data itself is readable: seen on 2026-10-06 for six
        // Copilot plugin icons, every night. Save the data and dates rather than nothing.
        if firstError == EPERM || firstError == EACCES {
            unlink(destination)
            // COPYFILE_DATA | COPYFILE_STAT = 0x0A (still NO CLONE!)
            if Darwin.copyfile(source, destination, nil, copyfile_flags_t(UInt32(0x0A))) == 0 {
                Log.warn("Copied without extended attributes/ACL (system refused them): \(source)")
                return
            }
            unlink(destination)
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(firstError),
                      userInfo: [NSLocalizedDescriptionKey: "copyfile failed: \(String(cString: strerror(firstError)))"])
    }

    /// Preserve modification time on a copied file.
    static func preserveModificationTime(at path: String, mtime: Date) {
        try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
    }
}
