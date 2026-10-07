import Foundation

/// Backups encrypted by the app, whatever the disk (4.1). Snapshots live inside an encrypted
/// APFS disk image (`MacBackup4Dev.sparsebundle`, AES-256) on the backup disk: without the
/// password nothing in it can be read. The image grows with its content (a 2 TB image starts
/// at ~24 MB) and keeps hard links, so snapshots work exactly as on a plain disk.
///
/// The password is chosen by the user and kept in the login Keychain: on a new Mac the user
/// types it, and it is the only way in. It is stored and read through
/// `/usr/bin/security` (trusted in the item's access list), not by the app itself: the app is
/// ad-hoc signed and its signature changes at every update, which would make macOS ask for
/// the Keychain password after each update — and block the scheduled backup, which runs with
/// nobody at the screen.
enum EncryptedStore {
    static let imageName = "\(AppIdentity.name).sparsebundle"
    static let keychainService = "\(AppIdentity.name) backup"

    struct Setup: Equatable {
        /// Path of the image on the backup disk.
        let container: String
        /// Name of the volume inside it (unique: the mount point is /Volumes/<volume>).
        let volume: String
        var mountPoint: String { "/Volumes/" + volume }
        /// Where snapshots go once the image is open.
        var destination: String { mountPoint + "/" + AppIdentity.backupFolderName }
    }

    enum StoreError: LocalizedError {
        case tool(String)
        case wrongPassword
        case noPassword(String)
        case containerMissing(String)
        var errorDescription: String? {
            switch self {
            case .tool(let s): return "Contenitore cifrato: \(s)"
            case .wrongPassword: return "Password sbagliata"
            case .noPassword(let v): return "Manca la password del contenitore \(v) nel Portachiavi"
            case .containerMissing(let p): return "Contenitore cifrato non trovato: \(p) (disco collegato?)"
            }
        }
    }

    // MARK: - Password

    /// The user chooses the password (one they can remember, decided 2026-10-07): at least
    /// `minimumPasswordLength` characters. A short phrase is easier to remember than a key.
    static let minimumPasswordLength = 10

    /// nil when acceptable, otherwise why not (Italian, shown under the field).
    static func passwordProblem(_ password: String, confirm: String) -> String? {
        if password.count < minimumPasswordLength { return "Almeno \(minimumPasswordLength) caratteri: va bene una frase che ricordi." }
        if password != confirm { return "Le due password non coincidono." }
        return nil
    }

    // MARK: - Image tool (diskutil image on recent macOS, hdiutil before)

    static let hasDiskutilImage: Bool = Shell.run("/usr/sbin/diskutil", ["image", "--help"], timeout: 15).ok

    /// Creates the encrypted image (not opened). `sizeBytes`: its maximum size.
    static func create(_ setup: Setup, password: String, sizeBytes: Int64) throws {
        let r: Shell.Result
        if hasDiskutilImage {
            r = Shell.run("/usr/sbin/diskutil", ["image", "create", "blank", "--encrypt", "--stdinpass",
                                                 "--size", String(sizeBytes), "--volumeName", setup.volume,
                                                 "--fs", "APFS", setup.container],
                          timeout: 300, stdin: password)
        } else {
            r = Shell.run("/usr/bin/hdiutil", ["create", "-size", "\(sizeBytes / 1_048_576)m", "-type", "SPARSEBUNDLE",
                                               "-fs", "APFS", "-encryption", "AES-256", "-stdinpass",
                                               "-volname", setup.volume, setup.container],
                          timeout: 300, stdin: password)
        }
        guard r.ok, FileManager.default.fileExists(atPath: setup.container) else {
            throw StoreError.tool("creazione non riuscita: \(r.stderr.suffix(200))")
        }
    }

    static func isOpen(_ setup: Setup) -> Bool {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return vols.contains { $0.path == setup.mountPoint }
    }

    /// Opens the image (hidden from the Finder). Throws `.wrongPassword` when refused.
    static func open(_ setup: Setup, password: String) throws {
        guard !isOpen(setup) else { return }
        guard FileManager.default.fileExists(atPath: setup.container) else { throw StoreError.containerMissing(setup.container) }
        let r: Shell.Result
        if hasDiskutilImage {
            r = Shell.run("/usr/sbin/diskutil", ["image", "attach", "--stdinpass", "--nobrowse", setup.container],
                          timeout: 120, stdin: password)
        } else {
            r = Shell.run("/usr/bin/hdiutil", ["attach", "-stdinpass", "-nobrowse", "-noautoopen", setup.container],
                          timeout: 120, stdin: password)
        }
        guard r.ok else {
            let text = (r.stderr + r.stdout).lowercased()
            if text.contains("authentication") || text.contains("passphrase") || text.contains("password") { throw StoreError.wrongPassword }
            throw StoreError.tool("apertura non riuscita: \(r.stderr.suffix(200))")
        }
        guard isOpen(setup) else { throw StoreError.tool("aperto, ma non montato in \(setup.mountPoint)") }
    }

    /// Closes the image (before ejecting its disk).
    @discardableResult
    static func close(_ setup: Setup, force: Bool = false) -> Bool {
        guard isOpen(setup) else { return true }
        var args = ["eject", setup.mountPoint]
        if force { args = ["unmount", "force", setup.mountPoint] }
        let r = Shell.run("/usr/sbin/diskutil", args, timeout: 60)
        if force && r.ok { _ = Shell.run("/usr/sbin/diskutil", ["eject", setup.mountPoint], timeout: 60) }
        return r.ok || !isOpen(setup)
    }

    // MARK: - Keychain (through /usr/bin/security, see the type comment)

    /// Saves the password; the command goes to `security` on stdin, so it never appears in
    /// the process list.
    static func savePassword(_ password: String, for setup: Setup) throws {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let command = "add-generic-password -U -a \(q(setup.volume)) -s \(q(keychainService)) -l \(q(keychainService + " (" + setup.volume + ")")) "
            + "-T /usr/bin/security -w \(q(password))\n"
        let r = Shell.run("/usr/bin/security", ["-i"], timeout: 30, stdin: command)
        guard r.ok, readPassword(for: setup) == password else {
            throw StoreError.tool("password non salvata nel Portachiavi: \(r.stderr.suffix(160))")
        }
    }

    static func readPassword(for setup: Setup) -> String? {
        let r = Shell.run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-a", setup.volume, "-w"], timeout: 30)
        let pw = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !pw.isEmpty ? pw : nil
    }

    static func deletePassword(for setup: Setup) {
        _ = Shell.run("/usr/bin/security", ["delete-generic-password", "-s", keychainService, "-a", setup.volume], timeout: 30)
    }

    // MARK: - What the rest of the app calls

    /// Before anything reads or writes the backup: opens the image when its disk is there.
    /// No-op for an unencrypted setup. Throws when the disk is attached but the image cannot
    /// be opened (missing password, wrong password).
    static func ensureOpen(_ config: Config?) throws {
        guard let setup = config?.encryption.setup, !isOpen(setup) else { return }
        guard FileManager.default.fileExists(atPath: setup.container) else { return }   // disk not attached
        guard let password = readPassword(for: setup) else { throw StoreError.noPassword(setup.volume) }
        try open(setup, password: password)
    }

    /// Creates a new encrypted store on `volume` (a backup disk) with the user's password,
    /// saves the password in the Keychain and opens the store.
    static func createStore(on volume: URL, password: String) throws -> Setup {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
        let setup = Setup(container: volume.appendingPathComponent(imageName).path, volume: "\(AppIdentity.name)-\(id)")
        guard !FileManager.default.fileExists(atPath: setup.container) else {
            throw StoreError.tool("esiste già \(setup.container): aprilo con la sua password")
        }
        let total = (try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity ?? 0
        let size = max(Int64(total), 100 * 1_073_741_824)   // grows on demand up to the disk size
        try create(setup, password: password, sizeBytes: size)
        writeVolumeMarker(setup)
        try savePassword(password, for: setup)
        try open(setup, password: password)
        try FileManager.default.createDirectory(atPath: setup.destination, withIntermediateDirectories: true)
        return setup
    }

    /// On a new Mac: opens an existing image with the password typed by the user and
    /// remembers it in this Mac's Keychain.
    static func adopt(container: String, volume: String, password: String) throws -> Setup {
        let setup = Setup(container: container, volume: volume)
        try open(setup, password: password)
        try savePassword(password, for: setup)
        return setup
    }

    /// The volume name inside an image, read without opening it (from its Info.plist is not
    /// enough for sparsebundles): the app stores it next to the image on creation.
    static func volumeName(ofContainer path: String) -> String? {
        let marker = URL(fileURLWithPath: path).deletingPathExtension().path + ".volume"
        return (try? String(contentsOfFile: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func writeVolumeMarker(_ setup: Setup) {
        let marker = URL(fileURLWithPath: setup.container).deletingPathExtension().path + ".volume"
        try? setup.volume.write(toFile: marker, atomically: true, encoding: .utf8)
    }
}
