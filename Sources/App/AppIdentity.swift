import Foundation

/// The app's names and places, in one spot. Renamed RustyMacBackup → MacBackup4Dev in 4.0.
///
/// What changed: app and CLI name, config and data folders, LaunchAgent label, GitHub repo,
/// release file names, the default folder on a new backup disk.
/// What did NOT change, on purpose:
/// - the bundle identifier: 3.x updates itself only to a build with the same identifier, and
///   macOS ties the notification permission to it;
/// - everything on the backup disk (`_rustymacbackup/`, `rustymacbackup.lock`, the snapshot
///   folder of an existing setup): old snapshots stay readable and a 3.x and a 4.x never run
///   a backup at the same time;
/// - `~/.rustybackup-pre-restore`: it holds the undo data of past restores.
enum AppIdentity {
    static let name = "MacBackup4Dev"
    static let legacyName = "RustyMacBackup"
    static let bundleID = "com.roberdan.rusty-mac-backup"
    static let repoSlug = "Roberdan/MacBackup4Dev"
    static let launchAgentLabel = "com.roberdan.macbackup4dev"
    static let legacyLaunchAgentLabel = "com.roberdan.rusty-mac-backup"
    /// Folder created on a backup disk for a new setup (an existing `RustyMacBackup` is reused).
    static let backupFolderName = "MacBackup4Dev"

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static var configDir: String { home + "/.config/macbackup4dev" }
    static var dataDir: String { home + "/.local/share/macbackup4dev" }
    static var legacyConfigDir: String { home + "/.config/rusty-mac-backup" }
    static var legacyDataDir: String { home + "/.local/share/rusty-mac-backup" }

    /// The folder to use on a backup volume: the existing 3.x one if there is one.
    static func backupFolder(on volume: URL) -> URL {
        let legacy = volume.appendingPathComponent(legacyName)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDir), isDir.boolValue { return legacy }
        return volume.appendingPathComponent(backupFolderName)
    }

    /// Moves the 3.x config and data folders to the new names and leaves a link at the old
    /// place, so a 3.x binary or an old LaunchAgent still finds them. Idempotent.
    @discardableResult
    static func migrateFolders(home: String = AppIdentity.home) -> [String] {
        var done: [String] = []
        let pairs = [(home + "/.config/rusty-mac-backup", home + "/.config/macbackup4dev"),
                     (home + "/.local/share/rusty-mac-backup", home + "/.local/share/macbackup4dev")]
        let fm = FileManager.default
        for (old, new) in pairs {
            let oldIsLink = (try? fm.destinationOfSymbolicLink(atPath: old)) != nil
            guard !oldIsLink, fm.fileExists(atPath: old), !fm.fileExists(atPath: new) else { continue }
            do {
                try fm.createDirectory(atPath: (new as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: old, toPath: new)
                try fm.createSymbolicLink(atPath: old, withDestinationPath: new)
                done.append("\(old) → \(new)")
            } catch {
                Log.error("Migration \(old) → \(new) failed: \(error.localizedDescription)")
            }
        }
        return done
    }
}
