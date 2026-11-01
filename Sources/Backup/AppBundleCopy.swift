import Foundation
import Darwin
import CryptoKit
import Security

enum AppBundleCopy {
    struct NeedsInstaller: LocalizedError {
        var errorDescription: String?
    }

    struct Fingerprint: Codable, Hashable {
        var files: Int
        var bytes: UInt64
        var digest: String
    }

    struct Options {
        var isCancelled: () -> Bool = { Task.isCancelled }
        var copyFile: (String, String) throws -> Void = copyRegularFile
        var verifySignature: (URL) throws -> Bool = isSigned
        var reserveBytes: UInt64 = 100 * 1_048_576
        var availableBytes: (URL) throws -> UInt64 = { url in
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
            guard let bytes = attributes[.systemFreeSize] as? NSNumber else {
                throw AppInventory.failure("Spazio libero non leggibile.")
            }
            return bytes.uint64Value
        }
    }

    private struct Node {
        var relative: String
        var metadata: stat
        var target: String?
        var digest: String?
        var kind: mode_t { metadata.st_mode & S_IFMT }
        var stamp: String {
            "\(relative)|\(metadata.st_ino)|\(metadata.st_mode)|\(metadata.st_size)|"
                + "\(metadata.st_mtimespec.tv_sec):\(metadata.st_mtimespec.tv_nsec)|\(target ?? "")"
        }
    }

    private static func check(_ options: Options) throws {
        if options.isCancelled() { throw CancellationError() }
    }

    static func isSigned(_ app: URL) throws -> Bool {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        if status == errSecCSUnsigned { return false }
        guard status == errSecSuccess, let code else {
            throw AppInventory.failure("Firma dell'app non leggibile (\(status)).")
        }
        let result = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue:
            kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil)
        if result == errSecCSUnsigned { return false }
        guard result == errSecSuccess else {
            throw AppInventory.failure("Firma dell'app non valida (\(result)).")
        }
        return true
    }

    static func fingerprint(_ root: URL, options: Options = Options()) throws -> Fingerprint {
        let nodes = try scan(root, hashing: true, options: options)
        return fingerprint(nodes)
    }

    /// The main executable of a launcher can be a link to a program installed elsewhere (Claude
    /// Code's URL handler). Such a bundle holds nothing that could run on its own and macOS
    /// cannot verify its signature, so it is recreated by the program it belongs to.
    /// Links that stay inside the bundle are ordinary and are judged by the usual checks.
    static func externalMainExecutable(_ app: URL, info: [String: Any]) -> String? {
        guard let name = info["CFBundleExecutable"] as? String, AppInventory.safeComponent(name) else { return nil }
        let relative = "Contents/MacOS/" + name
        let executable = app.appendingPathComponent(relative)
        guard let metadata = try? AppInventory.metadata(executable) else { return nil }
        var target: String?
        if metadata.st_mode & S_IFMT == S_IFLNK {
            target = try? FileManager.default.destinationOfSymbolicLink(atPath: executable.path)
        }
        let escapes: Bool
        if target?.hasPrefix("/") == true {
            escapes = true
        } else if let root = try? resolvedPath(app), let resolved = try? resolvedPath(executable) {
            escapes = !resolved.hasPrefix(root + "/")
        } else {
            escapes = true
        }
        return escapes ? relative + (target.map { " → " + $0 } ?? "") : nil
    }

    static func notSelfContainedReason(_ link: String) -> String {
        "App non autonoma, ricreata dalla sua app: l'eseguibile principale è un collegamento esterno o interrotto (\(link))."
    }

    /// Classification comes before the signature check, which fails for such a launcher.
    static func requireSelfContainedExecutable(_ app: URL) throws {
        guard let info = try? AppInventory.info(app),
              let link = externalMainExecutable(app, info: info) else { return }
        throw NeedsInstaller(errorDescription: notSelfContainedReason(link))
    }

    /// An app unchanged since the previous snapshot (every entry with the same identity,
    /// change time, size and mode as when that snapshot verified its copy, and that copy still
    /// matching) is linked from
    /// that copy without reading its contents again or repeating the signature checks: on
    /// 2026-11-01 the full checks kept a backup on Outlook alone for over 40 minutes.
    /// Returns nil when anything differs or goes wrong; the caller then makes a full copy.
    static func reuseUnchanged(from source: URL, to destination: URL, previous: URL,
                               recorded: Fingerprint, recordedSource: String,
                               options: Options = Options()) throws -> Fingerprint? {
        try check(options)
        guard !AppInventory.exists(destination), AppInventory.exists(previous) else { return nil }
        let before: [Node]
        let old: [Node]
        do {
            before = try scan(source, hashing: false, options: options)
            old = try scan(previous, hashing: false, options: options)
        } catch is CancellationError { throw CancellationError() } catch { return nil }
        let files = before.filter { $0.kind == S_IFREG }
        // The change time moves with every write, even one that restores size and mtime.
        guard sourceStamp(before) == recordedSource, before.count == old.count, zip(before, old).allSatisfy(sameContent),
              files.count == recorded.files,
              files.reduce(UInt64(0), { $0 + UInt64($1.metadata.st_size) }) == recorded.bytes else { return nil }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        } catch { return nil }
        do {
            for node in before {
                try check(options)
                let to = node.relative.isEmpty ? destination : destination.appendingPathComponent(node.relative)
                switch node.kind {
                case S_IFDIR:
                    if !node.relative.isEmpty { try FileManager.default.createDirectory(at: to, withIntermediateDirectories: false) }
                case S_IFLNK:
                    guard let target = node.target else { throw AppInventory.failure("Collegamento non leggibile.") }
                    try copySymbolicLink(target: target, to: to, mode: node.metadata.st_mode)
                default:
                    try HardLinker.hardLink(from: previous.appendingPathComponent(node.relative).path, to: to.path)
                }
            }
            for node in before.reversed() where node.kind == S_IFDIR {
                let from = node.relative.isEmpty ? source : source.appendingPathComponent(node.relative)
                let to = node.relative.isEmpty ? destination : destination.appendingPathComponent(node.relative)
                // Metadata only; never request COPYFILE_CLONE.
                guard copyfile(from.path, to.path, nil, copyfile_flags_t(UInt32(0x07))) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
            let after = try scan(source, hashing: false, options: options)
            guard before.map(\.stamp) == after.map(\.stamp) else {
                throw AppInventory.failure("L'app è cambiata durante la copia.")
            }
            return recorded
        } catch {
            do { try removePartial(at: destination) }
            catch { Log.error("Cannot remove partial app \(destination.path): \(error)") }
            if error is CancellationError { throw error }
            Log.warn("Unchanged app not reused, copying it in full: \(source.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private static func sameContent(_ new: Node, _ old: Node) -> Bool {
        guard new.relative == old.relative, new.kind == old.kind, new.target == old.target,
              new.metadata.st_mode & 0o777 == old.metadata.st_mode & 0o777 else { return false }
        guard new.kind == S_IFREG else { return true }
        let a = Double(new.metadata.st_mtimespec.tv_sec) + Double(new.metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        let b = Double(old.metadata.st_mtimespec.tv_sec) + Double(old.metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        return new.metadata.st_size == old.metadata.st_size && abs(a - b) < 0.001
    }

    /// Identity of every entry of the source, change time included: recorded with a verified
    /// copy so the next backup can tell, without reading contents, that nothing changed.
    private static func sourceStamp(_ nodes: [Node]) -> String {
        var digest = SHA256()
        for node in nodes {
            let m = node.metadata
            let part = "\(node.stamp)|\(m.st_dev)|\(m.st_flags)|\(m.st_ctimespec.tv_sec):\(m.st_ctimespec.tv_nsec)\0"
            digest.update(data: Data(part.utf8))
        }
        return hex(digest.finalize())
    }

    @discardableResult
    static func copy(from source: URL, to destination: URL, previous: URL? = nil,
                     options: Options = Options()) throws -> Fingerprint {
        try copyRecordingSource(from: source, to: destination, previous: previous, options: options).fingerprint
    }

    /// A full, verified copy; also returns the source's stamp for `reuseUnchanged`.
    static func copyRecordingSource(from source: URL, to destination: URL, previous: URL? = nil,
                                    options: Options = Options()) throws -> (fingerprint: Fingerprint, source: String) {
        try check(options)
        guard !AppInventory.exists(destination) else { throw AppInventory.failure("La destinazione esiste già.") }
        try requireSelfContainedExecutable(source)
        let signed = try options.verifySignature(source)
        let before = try scan(source, hashing: true, options: options)
        let expected = fingerprint(before)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            var regularFiles = 0
            var spaceBudget: UInt64 = 0
            for node in before {
                try check(options)
                let from = node.relative.isEmpty ? source : source.appendingPathComponent(node.relative)
                let to = node.relative.isEmpty ? destination : destination.appendingPathComponent(node.relative)
                guard try AppInventory.metadata(from).st_mode & S_IFMT == node.kind else {
                    throw AppInventory.failure("L'app è cambiata durante la copia.")
                }
                switch node.kind {
                case S_IFDIR:
                    if !node.relative.isEmpty { try FileManager.default.createDirectory(at: to, withIntermediateDirectories: false) }
                case S_IFLNK:
                    guard let target = node.target else { throw AppInventory.failure("Collegamento non leggibile.") }
                    try copySymbolicLink(target: target, to: to, mode: node.metadata.st_mode)
                case S_IFREG:
                    if regularFiles % 100 == 0 || UInt64(node.metadata.st_size) >= spaceBudget {
                        let free = try options.availableBytes(destination)
                        guard free > options.reserveBytes, UInt64(node.metadata.st_size) < free - options.reserveBytes else {
                            throw AppInventory.failure("Spazio libero insufficiente per salvare l'app.")
                        }
                        spaceBudget = free - options.reserveBytes
                    }
                    regularFiles += 1
                    var linked = false
                    if let previous, !SelectiveRestore.crossesLink(node.relative, root: previous.path) {
                        let old = previous.appendingPathComponent(node.relative)
                        let time = Date(timeIntervalSince1970: Double(node.metadata.st_mtimespec.tv_sec)
                                        + Double(node.metadata.st_mtimespec.tv_nsec) / 1_000_000_000)
                        if HardLinker.shouldHardLink(sourcePath: from.path, sourceSize: UInt64(node.metadata.st_size),
                                                    sourceMtime: time, previousBackupPath: old.path),
                           try AppInventory.metadata(old).st_mode & 0o777 == node.metadata.st_mode & 0o777,
                           try fileDigest(old, options: options) == node.digest {
                            do { try HardLinker.hardLink(from: old.path, to: to.path); linked = true }
                            catch { Log.warn("App hard link failed; copying \(node.relative): \(error)") }
                        }
                    }
                    if !linked {
                        try options.copyFile(from.path, to.path)
                        spaceBudget -= UInt64(node.metadata.st_size)
                    }
                default: throw AppInventory.failure("L'app contiene un file di tipo non trasferibile.")
                }
            }
            for node in before.reversed() where node.kind == S_IFDIR {
                let from = node.relative.isEmpty ? source : source.appendingPathComponent(node.relative)
                let to = node.relative.isEmpty ? destination : destination.appendingPathComponent(node.relative)
                // Metadata only; like regular files, never request COPYFILE_CLONE.
                guard copyfile(from.path, to.path, nil, copyfile_flags_t(UInt32(0x07))) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
            let after = try scan(source, hashing: false, options: options)
            guard before.map(\.stamp) == after.map(\.stamp),
                  try fingerprint(destination, options: options) == expected else {
                throw AppInventory.failure("L'app è cambiata durante la copia o la copia non è integra.")
            }
            if signed {
                guard try options.verifySignature(destination) else { throw AppInventory.failure("La copia ha perso la firma.") }
            }
            return (expected, sourceStamp(after))
        } catch {
            do { try removePartial(at: destination) }
            catch { Log.error("Cannot remove partial app \(destination.path): \(error)") }
            throw error
        }
    }

    static func removePartial(at root: URL) throws {
        func prepare(_ descriptor: Int32, _ directory: URL) throws {
            var metadata = stat()
            // Files may be linked to older snapshots; only change the new directories.
            guard fstat(descriptor, &metadata) == 0,
                  fchmod(descriptor, metadata.st_mode | 0o700) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if child < 0 {
                    if errno == ENOTDIR || errno == ELOOP { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                defer { close(child) }
                try prepare(child, directory.appendingPathComponent(name))
            }
        }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        try prepare(descriptor, root)
        try FileManager.default.removeItem(at: root)
    }

    private static func copySymbolicLink(target: String, to destination: URL, mode: mode_t) throws {
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        // O_SYMLINK pins the link itself, so changing its mode never follows its target.
        let descriptor = open(destination.path, O_RDONLY | O_SYMLINK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard metadata.st_mode & S_IFMT == S_IFLNK else {
            throw AppInventory.failure("Il collegamento dell'app non è più un collegamento simbolico.")
        }
        guard fchmod(descriptor, mode & 0o777) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func copyRegularFile(from source: String, to destination: String) throws {
        let input = open(source, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(input) }
        var metadata = stat()
        guard fstat(input, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw AppInventory.failure("Il file dell'app non è più un file regolare.")
        }
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(output) }
        // The same safe DATA|XATTR|STAT|ACL flags as HardLinker, with pinned file descriptors.
        guard fcopyfile(input, output, nil, copyfile_flags_t(UInt32(0x0F))) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func scan(_ root: URL, hashing: Bool, options: Options) throws -> [Node] {
        guard try AppInventory.metadata(root).st_mode & S_IFMT == S_IFDIR else {
            throw AppInventory.failure("Il bundle non è una cartella normale.")
        }
        let realRoot = try resolvedPath(root)
        var nodes: [Node] = []
        func walk(_ url: URL, _ rel: String) throws {
            try check(options)
            let metadata = try AppInventory.metadata(url)
            let kind = metadata.st_mode & S_IFMT
            var node = Node(relative: rel, metadata: metadata)
            switch kind {
            case S_IFDIR:
                guard metadata.st_mode & 0o400 != 0 else { throw AppInventory.failure("Cartella dell'app non leggibile: \(rel)") }
                nodes.append(node)
                for child in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                    try walk(url.appendingPathComponent(child), rel.isEmpty ? child : rel + "/" + child)
                }
            case S_IFREG:
                guard metadata.st_size >= 0, metadata.st_mode & 0o400 != 0 else {
                    throw AppInventory.failure("File dell'app non leggibile: \(rel)")
                }
                if hashing { node.digest = try fileDigest(url, options: options) }
                nodes.append(node)
            case S_IFLNK:
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                let resolved: String
                do { resolved = try resolvedPath(url) }
                catch { throw NeedsInstaller(errorDescription: "Collegamento interrotto o circolare: \(rel). Usa l'installer.") }
                guard !target.hasPrefix("/"), !target.contains("\0"),
                      resolved.hasPrefix(realRoot + "/") else {
                    throw NeedsInstaller(errorDescription: "Collegamento fuori dall'app: \(rel). Usa l'installer.")
                }
                node.target = target
                nodes.append(node)
            default: throw AppInventory.failure("File speciale non trasferibile: \(rel)")
            }
        }
        try walk(root, "")
        return nodes
    }

    private static func fingerprint(_ nodes: [Node]) -> Fingerprint {
        var digest = SHA256()
        var files = 0
        var bytes: UInt64 = 0
        for node in nodes {
            let part = "\(node.relative)\0\(node.kind)\0\(node.metadata.st_mode & 0o777)\0"
                + (node.digest ?? node.target ?? "") + "\0"
            digest.update(data: Data(part.utf8))
            if node.kind == S_IFREG { files += 1; bytes += UInt64(node.metadata.st_size) }
        }
        return Fingerprint(files: files, bytes: bytes, digest: hex(digest.finalize()))
    }

    private static func fileDigest(_ url: URL, options: Options) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var digest = SHA256()
        while true {
            try check(options)
            guard let data = try file.read(upToCount: 1_048_576), !data.isEmpty else { break }
            digest.update(data: data)
        }
        return hex(digest.finalize())
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func resolvedPath(_ url: URL) throws -> String {
        guard let path = realpath(url.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(path) }
        return String(cString: path)
    }
}
