import Foundation

/// 4.1: backups encrypted by the app, on a real encrypted disk image (nothing mocked).
struct EncryptionTests {
    let safety = SafetyTests()

    private func setup(_ root: URL) -> EncryptedStore.Setup {
        let id = String(UUID().uuidString.prefix(6)).lowercased()
        return EncryptedStore.Setup(container: root.appendingPathComponent("disk/\(EncryptedStore.imageName)").path,
                                    volume: "MB4DTest-\(id)")
    }

    func test_passwordRules() throws {
        try expectNotNil(EncryptedStore.passwordProblem("short", confirm: "short"), "too short refused")
        try expectNotNil(EncryptedStore.passwordProblem("una frase lunga", confirm: "una frase lungA"), "mismatch refused")
        try expectNil(EncryptedStore.passwordProblem("una frase lunga", confirm: "una frase lunga"), "a memorable phrase is fine")
        try expectNotNil(EncryptedStore.passwordProblem("una frase\nlunga!", confirm: "una frase\nlunga!"), "a newline is refused")
    }

    func test_storeEncryptsKeepsHardLinksAndRefusesWrongPassword() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let s = setup(box.root)
        try FileManager.default.createDirectory(atPath: (s.container as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        defer { EncryptedStore.close(s, force: true) }
        try EncryptedStore.create(s, password: "una frase lunga", sizeBytes: 512 * 1_048_576)
        try expect(!EncryptedStore.isOpen(s), "created closed")
        do { try EncryptedStore.open(s, password: "sbagliata!!"); try fail("wrong password must be refused") }
        catch EncryptedStore.StoreError.wrongPassword {} catch is TestFailure { throw TestFailure.failed("wrong password accepted") }
        try EncryptedStore.open(s, password: "una frase lunga")
        try expect(EncryptedStore.isOpen(s), "opened with the right password")
        try expect(DiskDiagnostics.checkEncryption(volume: s.mountPoint), "the volume reports itself encrypted")
        try "x".write(toFile: s.mountPoint + "/a", atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(atPath: s.mountPoint + "/a", toPath: s.mountPoint + "/b")
        let links = (try FileManager.default.attributesOfItem(atPath: s.mountPoint + "/a")[.referenceCount] as? Int) ?? 0
        try expectEqual(links, 2, "hard links work inside the store (snapshots need them)")
        try expect(EncryptedStore.close(s), "closes")
        try expect(!EncryptedStore.isOpen(s), "closed")
        let raw = Shell.run("/usr/bin/grep", ["-r", "-l", "una frase lunga", s.container], timeout: 30)
        try expect(raw.stdout.isEmpty, "the password is not stored in the image")
    }

    func test_realBackupIntoTheEncryptedStore() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let s = setup(box.root)
        try FileManager.default.createDirectory(atPath: (s.container as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        defer { EncryptedStore.close(s, force: true) }
        try EncryptedStore.create(s, password: "una frase lunga", sizeBytes: 5 * 1_073_741_824)
        try EncryptedStore.open(s, password: "una frase lunga")
        try FileManager.default.createDirectory(atPath: s.destination, withIntermediateDirectories: true)
        try safety.write("segreto", to: box.home + "/.ssh/id_test")
        try safety.write("cfg", to: box.home + "/.zshrc")
        var cfg = safety.config(box, sources: [".ssh", ".zshrc"])
        cfg.destination.path = s.destination
        cfg.encryption = EncryptionConfig(container: s.container, volume: s.volume)
        let result = try safety.runEngine(cfg, box)
        try expect(result.snapshot.path.hasPrefix(s.mountPoint), "snapshot written inside the encrypted store")
        try expect(SnapshotManifest.read(from: result.snapshot)?.complete == true, "complete snapshot")
        try expectEqual(try String(contentsOfFile: result.snapshot.path + "/.ssh/id_test", encoding: .utf8), "segreto",
                        "the credential is in the backup, readable only with the store open")
        try expectEqual(URL(fileURLWithPath: s.container).deletingLastPathComponent(), cfg.diskURL,
                        "the menu names and ejects the physical disk, not the store")
    }

    func test_keychainRoundTripAndEnsureOpen() throws {
        // Touches the login Keychain (a throwaway item, removed at the end): skipped on CI.
        guard ProcessInfo.processInfo.environment["CI"] == nil, !EncryptedStore.keychainLocked else { return }
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let s = setup(box.root)
        defer { EncryptedStore.deletePassword(for: s); EncryptedStore.close(s, force: true) }
        try FileManager.default.createDirectory(atPath: (s.container as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Review 4.1 B1: accents, spaces at both ends, quotes and backslashes come back as typed.
        let pw = "  perché sì, è così \"davvero\" \\ ok  "
        try EncryptedStore.create(s, password: pw, sizeBytes: 512 * 1_048_576)
        try EncryptedStore.savePassword(pw, for: s)
        try expectEqual(EncryptedStore.readPassword(for: s), pw, "the password survives the Keychain exactly")
        var cfg = safety.config(box, sources: [])
        cfg.encryption = EncryptionConfig(container: s.container, volume: s.volume)
        try EncryptedStore.ensureOpen(cfg)
        try expect(EncryptedStore.isOpen(s), "opened with the password from the Keychain, nobody typing")
    }

    func test_configKeepsTheEncryptionSection() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        var cfg = safety.config(box, sources: [])
        cfg.encryption = EncryptionConfig(container: "/Volumes/Disk/MacBackup4Dev.sparsebundle", volume: "MacBackup4Dev-ab12cd")
        cfg.destination.path = "/Volumes/MacBackup4Dev-ab12cd/MacBackup4Dev"
        let url = box.root.appendingPathComponent("c.toml")
        try cfg.save(to: url)
        let back = try Config.load(from: url)
        try expectEqual(back.encryption, cfg.encryption, "encryption saved and read back")
        try expectEqual(back.diskURL.path, "/Volumes/Disk", "the physical disk is the one holding the store")
    }

    /// Review 4.1 M4: the same disk set up again opens its existing store with the password.
    func test_existingStoreIsAdoptedNotRecreated() throws {
        // Uses the Keychain: skipped on CI and while it is locked (never pop a dialog).
        guard ProcessInfo.processInfo.environment["CI"] == nil, !EncryptedStore.keychainLocked else { return }
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let disk = box.root.appendingPathComponent("disk")
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        let first = try EncryptedStore.createStore(on: disk, password: "una frase lunga")
        defer { EncryptedStore.deletePassword(for: first); EncryptedStore.close(first, force: true) }
        try "x".write(toFile: first.destination + "/keep", atomically: true, encoding: .utf8)
        EncryptedStore.close(first)
        do { _ = try EncryptedStore.createOrAdopt(on: disk, password: "sbagliata!!!"); try fail("wrong password must not open") }
        catch EncryptedStore.StoreError.wrongPassword {} catch is TestFailure { throw TestFailure.failed("opened with a wrong password") }
        let again = try EncryptedStore.createOrAdopt(on: disk, password: "una frase lunga")
        try expectEqual(again, first, "the existing store is reused, not replaced")
        try expect(FileManager.default.fileExists(atPath: again.destination + "/keep"), "its content is still there")
    }

    /// Deleted snapshots give their space back to the disk after a compaction.
    func test_compactionGivesSpaceBack() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let s = setup(box.root)
        try FileManager.default.createDirectory(atPath: (s.container as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        defer { EncryptedStore.close(s, force: true); try? FileManager.default.removeItem(atPath: EncryptedStore.compactFlag(volume: s.volume)) }
        try EncryptedStore.create(s, password: "una frase lunga", sizeBytes: 5 * 1_073_741_824)
        try EncryptedStore.open(s, password: "una frase lunga")
        _ = Shell.run("/bin/dd", ["if=/dev/urandom", "of=\(s.mountPoint)/old-snapshot", "bs=1m", "count=300"], timeout: 120)
        try FileManager.default.removeItem(atPath: s.mountPoint + "/old-snapshot")
        EncryptedStore.markSpaceFreed(destination: URL(fileURLWithPath: s.mountPoint + "/MacBackup4Dev"))
        Thread.sleep(forTimeInterval: 20)   // APFS hands freed blocks back shortly after a delete
        let freed = try EncryptedStore.compact(s, password: "una frase lunga")
        try expect(freed > 100 * 1_048_576, "most of the 300 MB came back: \(freed)")
        try expect(EncryptedStore.isOpen(s), "open again after compacting")
        try expect(!EncryptedStore.compactionRunning, "no compaction lock left behind")
    }

    /// A store that vanished without being closed (disk pulled out) is checked when reopened.
    func test_pulledOutStoreIsCheckedOnReopen() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let s = setup(box.root)
        try FileManager.default.createDirectory(atPath: (s.container as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        defer { EncryptedStore.close(s, force: true); try? FileManager.default.removeItem(atPath: EncryptedStore.openMarker(s)) }
        try EncryptedStore.create(s, password: "una frase lunga", sizeBytes: 1_073_741_824)
        try EncryptedStore.open(s, password: "una frase lunga")
        try expect(FileManager.default.fileExists(atPath: EncryptedStore.openMarker(s)), "open store is marked")
        try expect(EncryptedStore.close(s), "clean close")
        try expect(!EncryptedStore.wasLeftOpen(s), "clean close clears the mark")
        try EncryptedStore.open(s, password: "una frase lunga")
        // Pulled out: unmounted behind our back, the mark stays.
        _ = Shell.run("/usr/sbin/diskutil", ["unmount", "force", s.mountPoint], timeout: 60)
        _ = Shell.run("/usr/sbin/diskutil", ["eject", s.mountPoint], timeout: 60)
        _ = Shell.run("/usr/bin/hdiutil", ["detach", "-force", s.mountPoint], timeout: 60)
        try expect(!EncryptedStore.isOpen(s), "gone")
        try expect(EncryptedStore.wasLeftOpen(s), "the mark tells it was not closed by us")
        try EncryptedStore.open(s, password: "una frase lunga")   // runs the volume check first
        try expect(EncryptedStore.isOpen(s), "checked and reopened")
        try expectNil(EncryptedStore.checkAndRepair(s), "a sound volume passes the check")
    }

    func test_freedSpaceIsFlaggedOnlyForStores() throws {
        let vol = "MacBackup4Dev-zz\(Int.random(in: 1000...9999))"
        defer { try? FileManager.default.removeItem(atPath: EncryptedStore.compactFlag(volume: vol)) }
        EncryptedStore.markSpaceFreed(destination: URL(fileURLWithPath: "/Volumes/RoberdanBCK/RustyMacBackup"))
        try expect(!FileManager.default.fileExists(atPath: EncryptedStore.compactFlag(volume: "RoberdanBCK")), "a plain disk is never flagged")
        EncryptedStore.markSpaceFreed(destination: URL(fileURLWithPath: "/Volumes/\(vol)/MacBackup4Dev"))
        try expect(EncryptedStore.needsCompaction(EncryptedStore.Setup(container: "/x", volume: vol)), "a store is flagged")
    }

    /// Review 2026-10-07: "Interrompi" never reached a scheduled backup. SIGTERM now stops it
    /// within seconds, closing the snapshot instead of hanging or dying mid-file.
    func test_sigtermStopsARunningBackupQuickly() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        for i in 0..<20000 { try safety.write(String(repeating: "x", count: 2048), to: box.home + "/data/d\(i % 100)/f\(i).txt") }
        let cfg = safety.config(box, sources: ["data"])
        let source = CLIHandler.stopOnSIGTERM()
        defer { source.cancel(); signal(SIGTERM, SIG_DFL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { raise(SIGTERM) }
        let started = Date()
        let outcome = Result { try safety.runEngine(cfg, box) }
        let seconds = Date().timeIntervalSince(started)
        try expect(seconds < 15, "stopped in \(Int(seconds)) s")
        switch outcome {
        case .success(let r):
            try expect(!r.manifest.complete, "stopped: never marked complete (\(r.manifest.filesProcessed) of 20000 copied)")
        case .failure(let e):
            try expect("\(e)".contains("cancel"), "stopped by the signal, not another error: \(e)")
        }
    }
}
