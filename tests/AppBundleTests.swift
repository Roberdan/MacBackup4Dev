import Foundation
import Darwin

struct AppBundleTests {
    func test_frameworkLinksAndSignaturesSurvive() throws {
        let f = try AppTestFixture(); defer { f.cleanup() }
        let source = try f.app()
        let framework = source.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
        try f.write("framework resource", framework.path + "/Versions/A/Resources/data")
        try FileManager.default.createSymbolicLink(atPath: framework.path + "/Versions/Current", withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework.path + "/Resources", withDestinationPath: "Versions/Current/Resources")
        let result = try f.backup()
        try expect(result.manifest.complete, "portable Shoji-shaped app captured: \(result.manifest.incompleteReasons)")
        let saved = result.snapshot.appendingPathComponent("_apps/system/Shoji.app")
        try expectEqual(try AppBundleCopy.fingerprint(saved), try AppBundleCopy.fingerprint(source), "entire app, not just its name")
        try expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: saved.path + "/Contents/Frameworks/Sparkle.framework/Versions/Current"),
                        "A", "framework link kept relative")
        try expectEqual(try AppInventory.metadata(saved.appendingPathComponent("Contents/MacOS/Shoji")).st_mode & 0o777,
                        0o755, "executable mode kept")
        let entry = try AppCapture.read(from: result.snapshot)!.entries[0]
        _ = try AppRestore.restore(entry, snapshot: result.snapshot, roots: f.restoreRoots, home: f.restoreHome, running: { _ in false })
        try expectEqual(try AppBundleCopy.fingerprint(f.restoreRoots[0].url.appendingPathComponent("Shoji.app")),
                        try AppBundleCopy.fingerprint(source), "framework links survive a full restore too")

        let signed = try f.app("Signed.app", identifier: "com.example.signed", signed: true)
        let target = f.box.root.appendingPathComponent("signed-copy.app")
        try AppBundleCopy.copy(from: signed, to: target)
        try expect(try AppBundleCopy.isSigned(target), "ad-hoc signature remains valid")
    }

    func test_newAppsAndDedupNeverChangeSources() throws {
        let f = try AppTestFixture(); defer { f.cleanup() }
        let app = try f.app()
        let executable = app.appendingPathComponent("Contents/MacOS/Shoji")
        let original = try AppInventory.metadata(executable)
        let digest = try AppBundleCopy.fingerprint(app)
        let first = try f.backup()
        try f.app("Dev/Second.app", identifier: "com.example.second")
        try f.app("Home.app", identifier: "com.example.home", root: .user)
        let second = try f.backup()
        let entries = try AppCapture.read(from: second.snapshot)!.entries
        try expectEqual(entries.filter { $0.state == .saved }.count, 3, "new system, grouped and home apps discovered without editing config")
        let relative = "_apps/system/Shoji.app/Contents/MacOS/Shoji"
        let old = try AppInventory.metadata(first.snapshot.appendingPathComponent(relative))
        let new = try AppInventory.metadata(second.snapshot.appendingPathComponent(relative))
        try expectEqual(old.st_ino, new.st_ino, "unchanged app files deduplicated")
        try expect(original.st_ino != new.st_ino, "snapshot never hardlinks to a live source")
        try expectEqual(try AppInventory.metadata(executable).st_ino, original.st_ino, "source not moved")
        try expectEqual(try AppBundleCopy.fingerprint(app), digest, "source contents and modes unchanged")
        try expectEqual(second.manifest.filesProcessed, 1, "app counts do not affect shrink guard")

        try f.write("#!/bin/sh\nexit 1\n", executable.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970:
            Double(original.st_mtimespec.tv_sec) + Double(original.st_mtimespec.tv_nsec) / 1_000_000_000)],
                                              ofItemAtPath: executable.path)
        let third = try f.backup()
        let changed = try AppInventory.metadata(third.snapshot.appendingPathComponent(relative))
        try expect(changed.st_ino != new.st_ino, "same-size content change with preserved mtime must not reuse stale app")
        try expectEqual(try String(contentsOf: first.snapshot.appendingPathComponent(relative), encoding: .utf8),
                        "#!/bin/sh\nexit 0\n", "older snapshot remains immutable")
    }

    func test_nonPortableAppsAreExplicitAndLinksAreNotFollowed() throws {
        let f = try AppTestFixture(); defer { f.cleanup() }
        let external = f.box.root.appendingPathComponent("external")
        try f.write("do not copy", external.path + "/secret")
        let app = try f.app()
        try FileManager.default.createSymbolicLink(atPath: app.path + "/Contents/Outside", withDestinationPath: external.path)
        try FileManager.default.createSymbolicLink(atPath: f.roots[0].url.path + "/Linked.app", withDestinationPath: app.path)
        try FileManager.default.createSymbolicLink(atPath: f.roots[0].url.path + "/Group", withDestinationPath: external.path)
        let installer = try f.app("Installer.app", identifier: "com.example.installer")
        try f.write("helper", installer.path + "/Contents/Library/LaunchServices/helper")
        let store = try f.app("Store.app", identifier: "com.example.store")
        try f.write("receipt", store.path + "/Contents/_MASReceipt/receipt")
        let result = try f.backup()
        let entries = try AppCapture.read(from: result.snapshot)!.entries
        try expect(result.manifest.complete, "unsupported apps are reported, not promised as portable")
        try expectEqual(entries.filter { $0.state == .installer }.count, 4, "external link, app link, system helper and App Store are explicit")
        try expect(entries.allSatisfy { !$0.reason.isEmpty }, "each skipped app has a recovery reason")
        try expect(!FileManager.default.fileExists(atPath: result.snapshot.path + "/_apps/system/Shoji.app"), "no broken partial app kept")
        try expect(!entries.contains { $0.relativePath.hasPrefix("Group/") }, "linked grouping folder not traversed")
        try expectEqual(try String(contentsOf: external.appendingPathComponent("secret"), encoding: .utf8), "do not copy", "external source untouched")
    }

    func test_copyMutationSpaceAndCancellationFailHonestly() throws {
        for scenario in ["copy", "mutation", "space", "cancel"] {
            let f = try AppTestFixture(); defer { f.cleanup() }
            let source = try f.app()
            let first = try f.backup()
            if scenario != "space" {
                try f.write("#!/bin/sh\nexit 1\n", source.path + "/Contents/MacOS/Shoji")
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path + "/Contents/MacOS/Shoji")
            }
            let result = try f.run { options in
                if scenario == "space" {
                    options.applicationCopyOptions.availableBytes = { _ in 1 }
                } else {
                    options.applicationCopyOptions.copyFile = { from, to in
                        if scenario == "copy" { throw AppInventory.failure("injected copy failure") }
                        try AppBundleCopy.copyRegularFile(from: from, to: to)
                        if scenario == "mutation" { try f.write("updated", source.path + "/Contents/new-file") }
                        if scenario == "cancel" { BackupEngine.stop() }
                    }
                }
            }
            if scenario == "cancel" {
                try expectNil(result, "cancelled app capture cannot publish a snapshot")
                try expectEqual(StatusWriter(directory: f.box.state).read()?.state, "cancelled", "cancelled status")
            } else {
                try expectNotNil(result, "failed run is recorded as incomplete")
                try expect(result?.manifest.complete == false, "app failure makes snapshot incomplete: \(scenario)")
                try expect(result?.manifest.incompleteReasons.contains { $0.contains("Shoji") } == true, "names the app failure")
                let expected = ["copy": "injected copy failure", "mutation": "cambiata", "space": "Spazio"][scenario]!
                try expect(result?.manifest.incompleteReasons.contains { $0.contains(expected) } == true,
                           "exercises the intended failure, not another error: \(scenario)")
            }
            try expectEqual(SnapshotCatalog.latestComplete(at: URL(fileURLWithPath: f.box.dest))?.name,
                            first.snapshot.lastPathComponent, "last complete snapshot remains protected")
            let folders = try FileManager.default.contentsOfDirectory(atPath: f.box.dest)
            try expect(!folders.contains { $0.hasPrefix("in-progress-") }, "no abandoned in-progress app backup")
        }
    }

    func test_appDataIsAnExplicitChoiceAndConfigPersists() throws {
        let f = try AppTestFixture(); defer { f.cleanup() }
        try f.app()
        let preference = "Library/Preferences/com.example.shoji.plist"
        try f.write("settings", f.box.home + "/" + preference)
        try f.write("private data", f.box.home + "/Library/Application Support/Shoji/data")
        let first = try f.backup()
        let entry = try AppCapture.read(from: first.snapshot)!.entries[0]
        try expect(entry.data.contains { $0.relativePath == preference && $0.state == .notSelected }, "missing preferences reported")
        try expect(!FileManager.default.fileExists(atPath: first.snapshot.path + "/" + preference), "no automatic credential-bearing data capture")
        let candidates = AppInventory.dataCandidates(home: f.box.home, roots: f.roots)
        try expect(candidates.allSatisfy(\.sensitive), "data never included by picker Select All")

        var config = f.config
        config.source.paths.append(f.box.home + "/" + preference)
        config.applications.excludeBundleIDs = ["com.example.other"]
        let configURL = f.box.root.appendingPathComponent("config.toml")
        try config.save(to: configURL)
        let reloaded = try Config.load(from: configURL)
        try expectEqual(reloaded.applications, config.applications, "app choices survive normal config saves")
        let second = try f.backup(config: reloaded)
        try expectEqual(try String(contentsOf: second.snapshot.appendingPathComponent(preference), encoding: .utf8), "settings", "selected settings actually saved")
        try expect(try AppCapture.read(from: second.snapshot)!.entries[0].data.contains {
            $0.relativePath == preference && $0.state == .selected
        }, "catalog records actual source selection")
        config.applications.capture = false
        let disabled = try f.backup(config: config)
        try expect(try AppCapture.read(from: disabled.snapshot) == nil, "capture can be explicitly disabled")
    }
}
