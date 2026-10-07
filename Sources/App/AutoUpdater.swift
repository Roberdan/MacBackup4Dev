import Foundation
import AppKit

/// Automatic updates, modelled on Sparkle:
/// - checks GitHub at launch and every few hours (never more than once per `checkInterval`);
/// - accepts an update only if its archive carries a valid Ed25519 signature from the release
///   key (`UpdateSignature`), is a newer version than the running one (no downgrades), keeps
///   the same bundle identifier and passes `codesign --verify`;
/// - replaces the app with two renames in /Applications, rolling back if the second fails,
///   so the app is never left half-written; a running backup keeps its own copy open;
/// - installs only while nothing is running (backup, restore, cleanup), then relaunches;
/// - when the installed app is not writable (installed by an administrator), downloads the
///   signed .pkg and opens it in Installer instead: one password, after which updates are
///   automatic again (the pkg hands the app to the logged-in user).
enum AutoUpdater {
    static let repoSlug = "roberdan/RustyMacBackup"
    static let checkInterval: TimeInterval = 6 * 3600

    private static let autoInstallKey = "autoInstallUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let lastRunVersionKey = "lastRunVersion"

    /// Install updates without asking (default on). Checking stays on either way.
    static var autoInstall: Bool {
        get { UserDefaults.standard.object(forKey: autoInstallKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoInstallKey) }
    }

    static var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: lastCheckKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastCheckKey) }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Only the installed app updates itself: a build run from build/ or a scratch copy never does.
    static var isInstalledCopy: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications"
    }

    /// The version this app ran as last time, when it differs from now (= just updated).
    static func consumeUpdatedFrom() -> String? {
        let previous = UserDefaults.standard.string(forKey: lastRunVersionKey)
        UserDefaults.standard.set(currentVersion, forKey: lastRunVersionKey)
        guard let previous, previous != currentVersion, isNewer(currentVersion, than: previous) else { return nil }
        return previous
    }

    struct Release: Decodable {
        let tagName: String
        let draft: Bool?
        let prerelease: Bool?
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease
        }
    }

    // MARK: - Check

    /// Returns the latest published version if newer than the running bundle, else nil.
    static func checkForUpdate() async -> String? {
        let apiURL = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!
        var request = URLRequest(url: apiURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("RustyMacBackup/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let release = try JSONDecoder().decode(Release.self, from: data)
            lastCheck = Date()
            if release.draft == true || release.prerelease == true { return nil }
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            return isNewer(latest, than: currentVersion) ? latest : nil
        } catch {
            Log.info("Update check failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Download & verify

    /// Downloads `name` and its `.sig` from the release and verifies the signature.
    static func downloadSigned(_ name: String, version: String, into dir: URL) async throws -> URL {
        let base = "https://github.com/\(repoSlug)/releases/download/v\(version)/"
        let file = dir.appendingPathComponent(name)
        let (local, response) = try await URLSession.shared.download(from: URL(string: base + name)!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.downloadFailed(http.statusCode) }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: local, to: file)

        let (sigData, sigResponse) = try await URLSession.shared.data(from: URL(string: base + name + ".sig")!)
        guard (sigResponse as? HTTPURLResponse)?.statusCode == 200,
              let signature = String(data: sigData, encoding: .utf8) else { throw UpdateError.unsigned }
        guard UpdateSignature.verify(try Data(contentsOf: file), signatureBase64: signature) else {
            throw UpdateError.signatureInvalid
        }
        return file
    }

    /// Download, verify and unpack the new app. Returns the verified bundle in `dir`.
    static func prepare(version: String, in dir: URL,
                        onPhase: ((UpdatePhase) -> Void)? = nil) async throws -> URL {
        onPhase?(.downloading)
        Log.info("Downloading update \(version)…")
        let zip = try await downloadSigned("RustyMacBackup-\(version).app.zip", version: version, into: dir)

        onPhase?(.verifying)
        let unpack = Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path], timeout: 120)
        let newApp = dir.appendingPathComponent("RustyMacBackup.app")
        guard unpack.status == 0, FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError.badZip }
        try validate(newApp: newApp, expectedVersion: version,
                     currentVersion: currentVersion, currentBundleID: Bundle.main.bundleIdentifier)
        return newApp
    }

    /// Checks that do not need the network: code signature, identity, version.
    static func validate(newApp: URL, expectedVersion: String, currentVersion: String,
                         currentBundleID: String?) throws {
        let codesign = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path], timeout: 60)
        guard codesign.status == 0 else { throw UpdateError.codeSignatureInvalid }
        let bundle = Bundle(url: newApp)
        let newID = bundle?.bundleIdentifier
        if let newID, let currentBundleID, newID != currentBundleID {
            throw UpdateError.bundleIdentityMismatch(newID, currentBundleID)
        }
        let newVersion = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard newVersion == expectedVersion, isNewer(newVersion, than: currentVersion) else {
            throw UpdateError.versionMismatch(newVersion)
        }
    }

    // MARK: - Install

    /// True when this user can replace the app bundle without a password.
    static func canReplaceInPlace(_ app: URL = Bundle.main.bundleURL) -> Bool {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path),
              let owner = (try? fm.attributesOfItem(atPath: app.path))?[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value == getuid()
    }

    /// Replaces `current` with `newApp`: copy beside it, then two renames in the same folder.
    /// If the second rename fails the old app is put back. Processes running the old binary
    /// (a backup) keep running: a rename never touches open files.
    static func swap(newApp: URL, into current: URL) throws {
        let fm = FileManager.default
        let parent = current.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".RustyMacBackup-update.app")
        let old = parent.appendingPathComponent(".RustyMacBackup-old-\(UUID().uuidString.prefix(8)).app")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: newApp, to: staged)
        do {
            try fm.moveItem(at: current, to: old)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        do {
            try fm.moveItem(at: staged, to: current)
        } catch {
            try? fm.moveItem(at: old, to: current)
            try? fm.removeItem(at: staged)
            throw error
        }
        try? fm.removeItem(at: old)
    }

    /// Downloads, verifies and installs `version`, then relaunches the app.
    /// Throws `.needsInstaller(pkg)` when the app is not ours to replace: the caller opens it.
    static func install(version: String, onPhase: ((UpdatePhase) -> Void)? = nil) async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RustyMacBackup-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        guard canReplaceInPlace() else {
            onPhase?(.downloading)
            let pkg = try await downloadSigned("RustyMacBackup-\(version)-arm64.pkg", version: version,
                                               into: FileManager.default.homeDirectoryForCurrentUser
                                                   .appendingPathComponent("Downloads"))
            throw UpdateError.needsInstaller(pkg)
        }
        let newApp = try await prepare(version: version, in: dir, onPhase: onPhase)
        onPhase?(.installing)
        Log.info("Installing \(version) over \(Bundle.main.bundleURL.path)…")
        try swap(newApp: newApp, into: Bundle.main.bundleURL)
        Log.info("Update installed — relaunching")
        relaunch()
    }

    /// Starts the new copy once this process has exited, then quits.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app]
        try? p.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    // MARK: - Helpers

    static func isNewer(_ v1: String, than v2: String) -> Bool {
        let a = v1.split(separator: ".").compactMap { Int($0) }
        let b = v2.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    enum UpdateError: LocalizedError {
        /// The release itself is wrong (not a network hiccup): retrying the same version is pointless.
        var isPermanent: Bool {
            switch self {
            case .unsigned, .signatureInvalid, .codeSignatureInvalid, .bundleIdentityMismatch, .versionMismatch, .badZip: return true
            case .downloadFailed, .needsInstaller: return false
            }
        }

        case badZip
        case downloadFailed(Int)
        case unsigned
        case signatureInvalid
        case codeSignatureInvalid
        case bundleIdentityMismatch(String, String)
        case versionMismatch(String)
        case needsInstaller(URL)
        var errorDescription: String? {
            switch self {
            case .badZip: return "Il file di aggiornamento non è valido"
            case .downloadFailed(let code): return "Download fallito (HTTP \(code))"
            case .unsigned: return "L'aggiornamento non è firmato: non lo installo"
            case .signatureInvalid: return "La firma dell'aggiornamento non è valida: non lo installo"
            case .codeSignatureInvalid: return "L'app scaricata è danneggiata: non la installo"
            case .bundleIdentityMismatch(let new, let cur): return "App diversa (\(new) invece di \(cur)): non la installo"
            case .versionMismatch(let v): return "Versione inattesa nell'aggiornamento (\(v.isEmpty ? "?" : v)): non la installo"
            case .needsInstaller: return "Serve l'Installer di macOS"
            }
        }
    }
}
