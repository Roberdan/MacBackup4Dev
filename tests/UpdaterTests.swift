import CryptoKit
import Foundation

/// 3.2: automatic updates accept only signed, newer, same-identity builds, and replacing the
/// app never leaves it half-written.
struct UpdaterTests {
    private func sandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rmb-upd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeBundle(at url: URL, id: String, version: String, marker: String, sign: Bool) throws {
        let macos = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try "#!/bin/sh\necho \(marker)\n".write(to: macos.appendingPathComponent("RustyMacBackup"), atomically: true, encoding: .utf8)
        _ = chmod(macos.appendingPathComponent("RustyMacBackup").path, 0o755)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version,
                                    "CFBundleExecutable": "RustyMacBackup", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        if sign {
            let r = Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path], timeout: 60)
            try expect(r.status == 0, "ad-hoc signing of the test bundle works: \(r.stderr)")
        }
    }

    func test_signatureAcceptsOnlyTheReleaseKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let archive = Data("RustyMacBackup-3.2.0.app.zip contents".utf8)
        let sig = try key.signature(for: archive).base64EncodedString()
        try expect(UpdateSignature.verify(archive, signatureBase64: sig + "\n", publicKeyBase64: pub), "valid signature accepted")
        var tampered = archive; tampered[0] ^= 0xFF
        try expect(!UpdateSignature.verify(tampered, signatureBase64: sig, publicKeyBase64: pub), "tampered archive rejected")
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        try expect(!UpdateSignature.verify(archive, signatureBase64: sig, publicKeyBase64: other), "another key rejected")
        try expect(!UpdateSignature.verify(archive, signatureBase64: "not-base64!", publicKeyBase64: pub), "garbage signature rejected")
        try expect(!UpdateSignature.verify(archive, signatureBase64: "", publicKeyBase64: pub), "empty signature rejected")
        try expect(!UpdateSignature.verify(archive, signatureBase64: sig), "a key that is not the release key is rejected by the app")
        try expect(Data(base64Encoded: UpdateSignature.publicKeyBase64)?.count == 32, "the app embeds a 32-byte Ed25519 public key")
    }

    func test_versionsNeverGoBack() throws {
        try expect(AutoUpdater.isNewer("3.2.0", than: "3.1.3"), "3.2.0 > 3.1.3")
        try expect(AutoUpdater.isNewer("3.10.0", than: "3.9.9"), "numeric, not alphabetical")
        try expect(!AutoUpdater.isNewer("3.1.3", than: "3.1.3"), "same version is not an update")
        try expect(!AutoUpdater.isNewer("3.1.0", than: "3.1.3"), "no downgrades")
    }

    func test_validateRejectsWrongBuilds() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good.app")
        try makeBundle(at: good, id: "com.roberdan.rusty-mac-backup", version: "3.2.0", marker: "new", sign: true)
        try AutoUpdater.validate(newApp: good, expectedVersion: "3.2.0", currentVersion: "3.1.3",
                                 currentBundleID: "com.roberdan.rusty-mac-backup")

        func rejects(_ what: String, _ body: () throws -> Void) throws {
            do { try body(); try fail("\(what) should be rejected") } catch is AutoUpdater.UpdateError {}
        }
        try rejects("older than the running app") {
            try AutoUpdater.validate(newApp: good, expectedVersion: "3.2.0", currentVersion: "3.3.0",
                                     currentBundleID: "com.roberdan.rusty-mac-backup")
        }
        try rejects("a build whose version is not the release's") {
            try AutoUpdater.validate(newApp: good, expectedVersion: "3.2.1", currentVersion: "3.1.3",
                                     currentBundleID: "com.roberdan.rusty-mac-backup")
        }
        try rejects("another app") {
            try AutoUpdater.validate(newApp: good, expectedVersion: "3.2.0", currentVersion: "3.1.3",
                                     currentBundleID: "com.example.other")
        }
        let unsigned = dir.appendingPathComponent("unsigned.app")
        try makeBundle(at: unsigned, id: "com.roberdan.rusty-mac-backup", version: "3.2.0", marker: "x", sign: false)
        try rejects("an unsigned bundle") {
            try AutoUpdater.validate(newApp: unsigned, expectedVersion: "3.2.0", currentVersion: "3.1.3",
                                     currentBundleID: "com.roberdan.rusty-mac-backup")
        }
    }

    func test_swapReplacesTheAppWholeAndLeavesNothingBehind() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let apps = dir.appendingPathComponent("Applications")
        let current = apps.appendingPathComponent("RustyMacBackup.app")
        try makeBundle(at: current, id: "x", version: "3.1.3", marker: "old", sign: false)
        try "only in old".write(to: current.appendingPathComponent("Contents/stale.txt"), atomically: true, encoding: .utf8)
        let newApp = dir.appendingPathComponent("download/RustyMacBackup.app")
        try makeBundle(at: newApp, id: "x", version: "3.2.0", marker: "new", sign: false)

        try expect(AutoUpdater.canReplaceInPlace(current), "an app owned by this user can be replaced")
        try AutoUpdater.swap(newApp: newApp, into: current)
        let script = try String(contentsOf: current.appendingPathComponent("Contents/MacOS/RustyMacBackup"), encoding: .utf8)
        try expect(script.contains("new"), "the new app is in place")
        try expect(!FileManager.default.fileExists(atPath: current.appendingPathComponent("Contents/stale.txt").path),
                   "nothing of the old app is mixed in")
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["RustyMacBackup.app"],
                        "no staged or old copy left in Applications")
    }

    func test_failedSwapKeepsTheOldApp() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let apps = dir.appendingPathComponent("Applications")
        let current = apps.appendingPathComponent("RustyMacBackup.app")
        try makeBundle(at: current, id: "x", version: "3.1.3", marker: "old", sign: false)
        do {
            try AutoUpdater.swap(newApp: dir.appendingPathComponent("missing.app"), into: current)
            try fail("swapping in a missing app must fail")
        } catch is TestFailure { throw TestFailure.failed("swap did not fail") } catch {}
        let script = try String(contentsOf: current.appendingPathComponent("Contents/MacOS/RustyMacBackup"), encoding: .utf8)
        try expect(script.contains("old"), "the old app is still there and intact")
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["RustyMacBackup.app"],
                        "no leftovers after a failed swap")
        try expect(!AutoUpdater.canReplaceInPlace(apps.appendingPathComponent("nope.app")), "a missing app is not replaceable")
    }

    /// 4.0 rename: a 3.x "RustyMacBackup.app" becomes "MacBackup4Dev.app", nothing left behind.
    func test_swapFromLegacyNameLeavesOnlyTheNewApp() throws {
        let dir = try sandbox(); defer { try? FileManager.default.removeItem(at: dir) }
        let apps = dir.appendingPathComponent("Applications")
        let legacy = apps.appendingPathComponent("RustyMacBackup.app")
        try makeBundle(at: legacy, id: "x", version: "3.3.0", marker: "old", sign: false)
        let newApp = dir.appendingPathComponent("download/MacBackup4Dev.app")
        try makeBundle(at: newApp, id: "x", version: "4.0.0", marker: "new", sign: false)
        let target = apps.appendingPathComponent("MacBackup4Dev.app")
        try AutoUpdater.swap(newApp: newApp, into: legacy, as: target)
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["MacBackup4Dev.app"],
                        "only the renamed app is left")
        let script = try String(contentsOf: target.appendingPathComponent("Contents/MacOS/RustyMacBackup"), encoding: .utf8)
        try expect(script.contains("new"), "it is the new build")
    }

    func test_foldersMoveAndOldPlacesStillWork() throws {
        let home = try sandbox().path; defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/.config/rusty-mac-backup", withIntermediateDirectories: true)
        try "x".write(toFile: home + "/.config/rusty-mac-backup/config.toml", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: home + "/.local/share/rusty-mac-backup", withIntermediateDirectories: true)
        try "s".write(toFile: home + "/.local/share/rusty-mac-backup/status.json", atomically: true, encoding: .utf8)

        let moved = AppIdentity.migrateFolders(home: home)
        try expectEqual(moved.count, 2, "both folders moved: \(moved)")
        try expectEqual(try String(contentsOfFile: home + "/.config/macbackup4dev/config.toml", encoding: .utf8), "x", "config at the new place")
        try expectEqual(try String(contentsOfFile: home + "/.config/rusty-mac-backup/config.toml", encoding: .utf8), "x",
                        "a 3.x binary still finds it through the link")
        try expect(AppIdentity.migrateFolders(home: home).isEmpty, "running it again does nothing")

        let volume = try sandbox(); defer { try? fm.removeItem(at: volume) }
        try expectEqual(AppIdentity.backupFolder(on: volume).lastPathComponent, "MacBackup4Dev", "new disk: new folder name")
        try fm.createDirectory(at: volume.appendingPathComponent("RustyMacBackup"), withIntermediateDirectories: true)
        try expectEqual(AppIdentity.backupFolder(on: volume).lastPathComponent, "RustyMacBackup", "existing 3.x folder reused")
    }
}
