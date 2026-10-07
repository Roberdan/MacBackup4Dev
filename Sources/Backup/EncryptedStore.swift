import Foundation
import Security

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
        case keychainLocked
        var errorDescription: String? {
            switch self {
            case .tool(let s): return "Contenitore cifrato: \(s)"
            case .wrongPassword: return "Password sbagliata"
            case .noPassword(let v): return "Manca la password del contenitore \(v) nel Portachiavi"
            case .containerMissing(let p): return "Contenitore cifrato non trovato: \(p) (disco collegato?)"
            case .keychainLocked: return "Il Portachiavi è bloccato: sbloccalo (password del Mac) e riprovo da solo"
            }
        }
    }

    // MARK: - Password

    /// The user chooses the password (one they can remember, decided 2026-10-07): at least
    /// `minimumPasswordLength` characters. A short phrase is easier to remember than a key.
    static let minimumPasswordLength = 10

    /// nil when acceptable, otherwise why not (Italian, shown under the field).
    static func passwordProblem(_ password: String, confirm: String) -> String? {
        if password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "Niente a capo o tabulazioni nella password."
        }
        if password.count < minimumPasswordLength { return "Almeno \(minimumPasswordLength) caratteri: va bene una frase che ricordi." }
        if password != confirm { return "Le due password non coincidono." }
        return nil
    }

    // MARK: - Image tool (diskutil image on recent macOS, hdiutil before)

    static let hasDiskutilImage: Bool = Shell.run("/usr/sbin/diskutil", ["image", "--help"], timeout: 15).ok

    /// Creates the encrypted image (not opened). `sizeBytes`: its maximum size.
    static func create(_ setup: Setup, password: String, sizeBytes: Int64) throws {
        // diskutil image (newer macOS; APFS is its default) and hdiutil (always there) both
        // work; the options of `diskutil image` differ between macOS versions (macOS 14 has
        // no --fs), so a refused usage falls back to hdiutil (found on CI, 2026-10-07).
        var r = Shell.Result(status: -1, stdout: "", stderr: "")
        if hasDiskutilImage {
            r = Shell.run("/usr/sbin/diskutil", ["image", "create", "blank", "--encrypt", "--stdinpass",
                                                 "--size", String(sizeBytes), "--volumeName", setup.volume, setup.container],
                          timeout: 300, stdin: password)
        }
        if !r.ok || !FileManager.default.fileExists(atPath: setup.container) {
            try? FileManager.default.removeItem(atPath: setup.container)
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
        var r = Shell.Result(status: -1, stdout: "", stderr: "")
        if hasDiskutilImage {
            r = Shell.run("/usr/sbin/diskutil", ["image", "attach", "--stdinpass", "--nobrowse", setup.container],
                          timeout: 120, stdin: password)
        }
        // Older `diskutil image` without these options: hdiutil, which every macOS has.
        if !r.ok && !isOpen(setup) && (!hasDiskutilImage || (r.stderr + r.stdout).contains("--help")) {
            r = Shell.run("/usr/bin/hdiutil", ["attach", "-stdinpass", "-nobrowse", "-noautoopen", setup.container],
                          timeout: 120, stdin: password)
        }
        guard r.ok else {
            // Opened meanwhile by someone else (the app and the scheduled backup at once)?
            if isOpen(setup) { return }
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
    /// the process list. Stored base64-encoded: `security -w` prints a non-ASCII password
    /// ("perché sì") as hex and keeps spaces, so the text read back was not the one saved
    /// (review 4.1 B1). Base64 is plain ASCII and needs no quoting.
    static func savePassword(_ password: String, for setup: Setup) throws {
        guard !keychainLocked else { throw StoreError.keychainLocked }
        // Already there: never rewrite it (changing an existing item makes macOS ask for
        // confirmation in a window — the test hung on it, 2026-10-07).
        if readPassword(for: setup) == password { return }
        if readPassword(for: setup) != nil { deletePassword(for: setup) }
        let encoded = "b64:" + Data(password.utf8).base64EncodedString()
        let command = "add-generic-password -U -a \"\(setup.volume)\" -s \"\(keychainService)\" "
            + "-l \"\(keychainService) (\(setup.volume))\" -T /usr/bin/security -w \"\(encoded)\"\n"
        let r = Shell.run("/usr/bin/security", ["-i"], timeout: 30, stdin: command)
        guard r.ok, readPassword(for: setup) == password else {
            throw StoreError.tool("password non salvata nel Portachiavi (\(r.status))")
        }
    }

    /// True when the login Keychain is locked. Asked without any dialog: reading or writing
    /// a locked Keychain makes macOS show a password window and the command waits for it —
    /// at every scheduled backup, with nobody at the screen (seen 2026-10-07).
    static var keychainLocked: Bool {
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return true }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return true }
        return status & UInt32(kSecUnlockStateStatus) == 0
    }

    static func readPassword(for setup: Setup) -> String? {
        guard !keychainLocked else {
            Log.error("Keychain locked: the backup password cannot be read now")
            return nil
        }
        let r = Shell.run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-a", setup.volume, "-w"], timeout: 30)
        guard r.ok else {
            if r.stderr.lowercased().contains("interaction") { Log.error("Keychain locked: cannot read the backup password") }
            return nil
        }
        var value = r.stdout
        if value.hasSuffix("\n") { value.removeLast() }   // only the newline security adds
        guard value.hasPrefix("b64:"), let data = Data(base64Encoded: String(value.dropFirst(4))),
              let password = String(data: data, encoding: .utf8) else { return nil }
        return password
    }

    static func deletePassword(for setup: Setup) {
        guard !keychainLocked else { return }
        _ = Shell.run("/usr/bin/security", ["delete-generic-password", "-s", keychainService, "-a", setup.volume], timeout: 30)
    }

    // MARK: - What the rest of the app calls

    /// Before anything reads or writes the backup: opens the image when its disk is there.
    /// No-op for an unencrypted setup. Throws when the disk is attached but the image cannot
    /// be opened (missing password, wrong password).
    static func ensureOpen(_ config: Config?) throws {
        guard let setup = config?.encryption.setup, !isOpen(setup) else { return }
        guard FileManager.default.fileExists(atPath: setup.container) else { return }   // disk not attached
        guard !keychainLocked else { throw StoreError.keychainLocked }
        guard let password = readPassword(for: setup) else { throw StoreError.noPassword(setup.volume) }
        try open(setup, password: password)
    }

    /// The store on `volume`: created when there is none, or opened with `password` when the
    /// disk already holds one (the same disk set up again, or a new Mac). Review 4.1 M4.
    static func createOrAdopt(on volume: URL, password: String) throws -> Setup {
        let container = volume.appendingPathComponent(imageName).path
        if FileManager.default.fileExists(atPath: container) {
            guard let name = volumeName(ofContainer: container) else {
                throw StoreError.tool("su questo disco c'è già un backup cifrato, ma non trovo il suo nome (\(container))")
            }
            let setup = try adopt(container: container, volume: name, password: password)
            try FileManager.default.createDirectory(atPath: setup.destination, withIntermediateDirectories: true)
            return setup
        }
        return try createStore(on: volume, password: password)
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
        // Keychain first: an image whose password was not saved would be a locked box.
        try savePassword(password, for: setup)
        do {
            try create(setup, password: password, sizeBytes: size)
            try writeVolumeMarker(setup)
        } catch {
            deletePassword(for: setup)
            try? FileManager.default.removeItem(atPath: setup.container)
            throw error
        }
        try open(setup, password: password)
        try FileManager.default.createDirectory(atPath: setup.destination, withIntermediateDirectories: true)
        return setup
    }

    /// On a new Mac: opens an existing image with the password typed by the user and
    /// remembers it in this Mac's Keychain.
    static func adopt(container: String, volume: String, password: String) throws -> Setup {
        let setup = Setup(container: container, volume: volume)
        try open(setup, password: password)
        do { try savePassword(password, for: setup) } catch { close(setup); throw error }
        return setup
    }

    /// The volume name inside an image, read without opening it (from its Info.plist is not
    /// enough for sparsebundles): the app stores it next to the image on creation.
    static func volumeName(ofContainer path: String) -> String? {
        let marker = URL(fileURLWithPath: path).deletingPathExtension().path + ".volume"
        return (try? String(contentsOfFile: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func writeVolumeMarker(_ setup: Setup) throws {
        let marker = URL(fileURLWithPath: setup.container).deletingPathExtension().path + ".volume"
        try setup.volume.write(toFile: marker, atomically: true, encoding: .utf8)
    }
}
