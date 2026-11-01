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
        let quarantine = "0081;00000000;MacBackup4DevTests;"
        try expect(Shell.run("/usr/bin/xattr", ["-w", "com.apple.quarantine", quarantine, source.path]).ok,
                   "synthetic app has quarantine metadata")
        let result = try f.backup()
        try expect(result.manifest.complete, "portable Shoji-shaped app captured: \(result.manifest.incompleteReasons)")
        let saved = result.snapshot.appendingPathComponent("_rustymacbackup/applications/system/Shoji.app")
        try expectEqual(try AppBundleCopy.fingerprint(saved), try AppBundleCopy.fingerprint(source), "entire app, not just its name")
        try expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: saved.path + "/Contents/Frameworks/Sparkle.framework/Versions/Current"),
                        "A", "framework link kept relative")
        try expectEqual(try AppInventory.metadata(saved.appendingPathComponent("Contents/MacOS/Shoji")).st_mode & 0o777,
                        0o755, "executable mode kept")
        let entry = try AppCapture.read(from: result.snapshot)!.entries[0]
        _ = try AppRestore.restore(entry, snapshot: result.snapshot, roots: f.restoreRoots, home: f.restoreHome, running: { _ in false })
        try expectEqual(try AppBundleCopy.fingerprint(f.restoreRoots[0].url.appendingPathComponent("Shoji.app")),
                        try AppBundleCopy.fingerprint(source), "framework links survive a full restore too")
        for app in [saved, f.restoreRoots[0].url.appendingPathComponent("Shoji.app")] {
            let attribute = Shell.run("/usr/bin/xattr", ["-p", "com.apple.quarantine", app.path])
            try expect(attribute.ok && attribute.stdout.components(separatedBy: ";").prefix(2)
                       == quarantine.components(separatedBy: ";").prefix(2),
                       "backup and restore preserve quarantine flags and timestamp; macOS normalizes the agent")
        }

        let signed = try f.app("Signed.app", identifier: "com.example.signed", signed: true)
        let target = f.box.root.appendingPathComponent("signed-copy.app")
        try AppBundleCopy.copy(from: signed, to: target)
        try expect(try AppBundleCopy.isSigned(target), "ad-hoc signature remains valid")
    }

    func test_symlinkPermissionsDoNotDependOnUmask() throws {
        let originalMask = umask(0o022)
        defer { umask(originalMask) }
        let f = try AppTestFixture(); defer { f.cleanup() }
        let source = try f.app(signed: true)
        let relative = "Contents/Resources/payload"
        let payload = source.appendingPathComponent(relative)
        let link = source.appendingPathComponent("Contents/Resources/current")
        try f.write("immutable resource", payload.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: payload.path)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "payload")
        let signing = Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", source.path])
        try expect(signing.ok, "signing the sandbox app with its internal link: \(signing.stderr)")
        let expected = try AppBundleCopy.fingerprint(source)
        let originalPayload = try AppInventory.metadata(payload)
        let originalLink = try AppInventory.metadata(link)
        try expectEqual(originalLink.st_mode & 0o777, 0o755, "fixture link starts with ordinary launch permissions")

        let first = f.box.root.appendingPathComponent("first-copy.app")
        try AppBundleCopy.copy(from: source, to: first)
        umask(0o077)
        let second = f.box.root.appendingPathComponent("restricted-copy.app")
        try AppBundleCopy.copy(from: source, to: second, previous: first)

        for saved in [first, second] {
            try expectEqual(try AppBundleCopy.fingerprint(saved), expected, "all app contents and modes survive either umask")
            try expect(try AppBundleCopy.isSigned(saved), "signature survives either umask")
            try expectEqual(try AppInventory.metadata(saved.appendingPathComponent("Contents/Resources/current")).st_mode & 0o777,
                            originalLink.st_mode & 0o777, "link permissions are independent of umask")
        }
        let oldPayload = try AppInventory.metadata(first.appendingPathComponent(relative))
        let newPayload = try AppInventory.metadata(second.appendingPathComponent(relative))
        try expectEqual(newPayload.st_ino, oldPayload.st_ino, "regular resource remains deduplicated")
        try expectEqual(newPayload.st_mode & 0o777, 0o640, "link metadata does not change its shared target")
        try expect(oldPayload.st_ino != originalPayload.st_ino, "resource is never linked to the live source")
        try expectEqual(try AppInventory.metadata(payload).st_ino, originalPayload.st_ino, "source resource is not replaced")
        try expectEqual(try AppInventory.metadata(link).st_ino, originalLink.st_ino, "source link is not replaced")
        try expectEqual(try AppBundleCopy.fingerprint(source), expected, "source contents and modes are unchanged")
    }

    /// 2026-11-01: every backup re-read and re-verified every app (Outlook: over 40 minutes).
    func test_unchangedAppIsReusedWithoutReadingOrVerifyingIt() throws {
        let f = try AppTestFixture(); defer { f.cleanup() }
        let app = try f.app(signed: true)
        let relative = "_rustymacbackup/applications/system/Shoji.app"
        final class Counter: @unchecked Sendable { var copies = 0; var signatures = 0 }
        let counter = Counter()
        let counting: (inout BackupRunOptions) -> Void = { options in
            options.applicationCopyOptions.copyFile = { from, to in
                counter.copies += 1
                try AppBundleCopy.copyRegularFile(from: from, to: to)
            }
            options.applicationCopyOptions.verifySignature = { url in
                counter.signatures += 1
                return try AppBundleCopy.isSigned(url)
            }
        }
        let first = try f.backup(configure: counting)
        try expect(counter.signatures > 0 && counter.copies > 0, "a new app gets the full copy and checks")
        try expect(try AppCapture.read(from: first.snapshot)!.entries[0].sourceStamp != nil,
                   "a verified copy records what its source was")

        counter.copies = 0; counter.signatures = 0
        let second = try f.backup(configure: counting)
        let entry = try AppCapture.read(from: second.snapshot)!.entries[0]
        try expect(second.manifest.complete, "reused app keeps the snapshot complete")
        try expectEqual(entry.state, .saved, "unchanged app is saved")
        try expect(entry.signed, "its signature result is carried over")
        try expectEqual(counter.signatures, 0, "an unchanged app is not verified again")
        try expectEqual(counter.copies, 0, "an unchanged app is not read and copied again")
        let saved = second.snapshot.appendingPathComponent(relative)
        try expectEqual(try AppBundleCopy.fingerprint(saved), try AppBundleCopy.fingerprint(app), "the reused copy is the whole app")
        try expect(try AppBundleCopy.isSigned(saved), "the reused copy is still a valid signed app")
        let executable = "/Contents/MacOS/Shoji"
        try expectEqual(try AppInventory.metadata(URL(fileURLWithPath: saved.path + executable)).st_ino,
                        try AppInventory.metadata(first.snapshot.appendingPathComponent(relative + executable)).st_ino,
                        "files are shared with the previous verified copy")

        counter.copies = 0; counter.signatures = 0
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let before = try AppInventory.metadata(plist)
        let text = try String(contentsOf: plist, encoding: .utf8)
        try text.replacingOccurrences(of: "1.2.2", with: "1.2.3").write(to: plist, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970:
            Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) / 1_000_000_000)], ofItemAtPath: plist.path)
        let third = try f.run(configure: counting)
        try expect(counter.signatures > 0, "a change with the same size and time still gets the full checks")
        try expect(third?.manifest.complete == false, "and the edited signed app is not passed off as the verified one")
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
        let relative = "_rustymacbackup/applications/system/Shoji.app/Contents/MacOS/Shoji"
        let old = try AppInventory.metadata(first.snapshot.appendingPathComponent(relative))
        let new = try AppInventory.metadata(second.snapshot.appendingPathComponent(relative))
        try expectEqual(old.st_ino, new.st_ino, "unchanged app files deduplicated")
        try expect(original.st_ino != new.st_ino, "snapshot never hardlinks to a live source")
        try expectEqual(try AppInventory.metadata(executable).st_ino, original.st_ino, "source not moved")
        try expectEqual(try AppBundleCopy.fingerprint(app), digest, "source contents and modes unchanged")
        try expectEqual(second.manifest.filesProcessed, 1, "app counts do not affect shrink guard")

        try f.write("#!/bin/sh\nexit 1\n", executable.path)
        try FileManager.default.setAttributes([.posixPermissions: Int(original.st_mode & 0o777),
            .modificationDate: Date(timeIntervalSince1970:
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
        try expect(!FileManager.default.fileExists(atPath: result.snapshot.path + "/_rustymacbackup/applications/system/Shoji.app"), "no broken partial app kept")
        try expect(!entries.contains { $0.relativePath.hasPrefix("Group/") }, "linked grouping folder not traversed")
        try expectEqual(try String(contentsOf: external.appendingPathComponent("secret"), encoding: .utf8), "do not copy", "external source untouched")
    }

    /// A launcher whose only executable is a link to a tool installed elsewhere (Claude Code's
    /// URL handler) cannot be copied or verified on its own: macOS rejects its signature.
    func test_externalMainExecutableIsListedAsNotSelfContainedNotAnError() throws {
        let f = try AppTestFixture(); defer { f.cleanup() }
        let fm = FileManager.default
        let tool = f.box.root.appendingPathComponent("external/tool").path
        try fm.createDirectory(atPath: (tool as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try AppBundleCopy.copyRegularFile(from: "/usr/bin/true", to: tool)
        let launcher = try f.app("Launcher.app", identifier: "com.example.launcher")
        let executable = launcher.path + "/Contents/MacOS/Shoji"
        try fm.removeItem(atPath: executable)
        try fm.createSymbolicLink(atPath: executable, withDestinationPath: tool)
        let dangling = try f.app("Dangling.app", identifier: "com.example.dangling")
        try fm.removeItem(atPath: dangling.path + "/Contents/MacOS/Shoji")
        try fm.createSymbolicLink(atPath: dangling.path + "/Contents/MacOS/Shoji",
                                  withDestinationPath: f.box.root.path + "/never-installed")
        try f.app("Ordinary.app", identifier: "com.example.ordinary")

        var refused = false
        do { try AppBundleCopy.copy(from: launcher, to: f.box.root.appendingPathComponent("direct.app")) }
        catch is AppBundleCopy.NeedsInstaller { refused = true }
        try expect(refused, "a direct copy classifies the external launcher instead of failing on its signature")
        try expect(!fm.fileExists(atPath: f.box.root.appendingPathComponent("direct.app").path), "no partial copy left")

        let result = try f.backup()
        try expect(result.manifest.complete, "an app that is recreated by its own program is not a backup error: \(result.manifest.incompleteReasons)")
        let catalog = try AppCapture.read(from: result.snapshot)!
        try expect(catalog.failures.isEmpty, "nothing is reported as a failure: \(catalog.failures)")
        for name in ["Launcher.app", "Dangling.app"] {
            guard let entry = catalog.entries.first(where: { $0.relativePath == name }) else {
                throw TestFailure.failed("\(name) must stay listed in the catalog")
            }
            try expectEqual(entry.state, .installer, "\(name) is classified, not copied")
            try expect(entry.reason.contains("non autonoma, ricreata dalla sua app"), "plain reason for \(name): \(entry.reason)")
            try expect(!fm.fileExists(atPath: result.snapshot.path + "/_rustymacbackup/applications/system/" + name),
                       "\(name) has no copy that could not run")
        }
        try expectEqual(catalog.entries.first { $0.relativePath == "Ordinary.app" }?.state, .saved,
                        "ordinary apps are still saved whole")
        try expectEqual(try fm.destinationOfSymbolicLink(atPath: executable), tool, "source link untouched")
    }

    /// Scar 2026-10-31: the menu kept asking to choose "1 path" with everything selected, because the
    /// count included data of apps the picker never offers (this app itself).
    func test_dataOfExcludedAppsIsNotARequestThePickerCannotMeet() throws {
        let f = try AppTestFixture(); defer { f.cleanup() }
        try f.app("Shoji.app", identifier: "com.example.shoji")
        try f.app("Itself.app", identifier: AppIdentity.bundleID)
        try f.app("Declined.app", identifier: "com.example.declined")
        for identifier in ["com.example.shoji", AppIdentity.bundleID, "com.example.declined"] {
            try f.write("settings", f.box.home + "/Library/Preferences/\(identifier).plist")
        }
        var config = f.config
        config.applications.excludeBundleIDs = ["com.example.declined"]
        let result = try f.backup(config: config)
        let catalog = try AppCapture.read(from: result.snapshot)!
        for identifier in [AppIdentity.bundleID, "com.example.declined"] {
            let entry = catalog.entries.first { $0.bundleID == identifier }
            try expectEqual(entry?.state, .excluded, "fixture: \(identifier) is excluded")
            try expect(entry?.data.contains { $0.state == .notSelected } == true, "fixture: it has unselected data")
        }
        let offered = Set(AppInventory.dataCandidates(home: f.box.home, roots: f.roots).flatMap(\.paths))
        try expect(offered.contains("~/Library/Preferences/com.example.shoji.plist"), "the picker offers the ordinary app's data")
        try expect(!offered.contains("~/Library/Preferences/\(AppIdentity.bundleID).plist"),
                   "the picker never offers this app's own data")
        try expectEqual(result.manifest.applications?.unselectedDataPaths, 1,
                        "only data that can still be chosen is asked for")
        try expectEqual(StatusWriter(directory: f.box.state).read()?.applications?.unselectedDataPaths, 1,
                        "the menu reads the same number")
    }

    func test_onlyDataThatCanStillBeChosenIsCounted() throws {
        func entry(_ id: String, _ state: AppInventory.Entry.State, _ data: [(String, AppInventory.DataPath.State)]) -> AppInventory.Entry {
            var entry = AppInventory.Entry(root: .system, relativePath: id + ".app", name: id)
            entry.bundleID = "com.example." + id
            entry.state = state
            entry.data = data.map { AppInventory.DataPath(relativePath: $0.0, state: $0.1) }
            return entry
        }
        let catalog = AppCapture.Catalog(entries: [
            entry("saved", .saved, [("a", .notSelected), ("b", .selected), ("c", .excluded), ("d", .unavailable)]),
            entry("excluded", .excluded, [("e", .notSelected)]),
            entry("installer", .installer, [("a", .notSelected), ("f", .notSelected)]),
        ], failures: [])
        try expectEqual(AppCapture.Report(catalog: catalog).summary.unselectedDataPaths, 2,
                        "a, f: not selected yet, from apps the picker offers, each path once")
    }

    /// The reclassification must not turn a broken signature of an ordinary app into a pass.
    func test_signatureChecksOfOrdinaryAppsStayStrict() throws {
        let f = try AppTestFixture(); defer { f.cleanup() }
        let fm = FileManager.default
        let signed = try f.app("Signed.app", identifier: "com.example.signed", signed: true)
        try f.write("sealed", signed.path + "/Contents/Resources/data.txt")
        let sealing = Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", signed.path])
        try expect(sealing.ok, "sealing the resource into the signature: \(sealing.stderr)")
        try f.write("changed after signing", signed.path + "/Contents/Resources/data.txt")
        var invalid = false
        do { _ = try AppBundleCopy.isSigned(signed) } catch { invalid = true }
        try expect(invalid, "the tampered fixture really has an invalid signature")
        let linked = try f.app("Linked.app", identifier: "com.example.linked")
        try f.write("#!/bin/sh\nexit 0\n", linked.path + "/Contents/Resources/real")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: linked.path + "/Contents/Resources/real")
        try fm.removeItem(atPath: linked.path + "/Contents/MacOS/Shoji")
        try fm.createSymbolicLink(atPath: linked.path + "/Contents/MacOS/Shoji", withDestinationPath: "../Resources/real")

        let result = try f.backup()
        try expect(!result.manifest.complete, "an app with a broken signature still stops the snapshot from being complete")
        try expect(result.manifest.incompleteReasons.contains { $0.contains("Firma dell'app non valida") },
                   "the broken signature is reported: \(result.manifest.incompleteReasons)")
        let catalog = try AppCapture.read(from: result.snapshot)!
        try expectEqual(catalog.entries.first { $0.relativePath == "Signed.app" }?.state, .failed, "tampered signed app fails")
        try expectEqual(catalog.entries.first { $0.relativePath == "Linked.app" }?.state, .saved,
                        "an executable that is a link inside the bundle remains a portable app")
        var rejected = false
        do { try AppBundleCopy.copy(from: signed, to: f.box.root.appendingPathComponent("tampered.app")) }
        catch is AppBundleCopy.NeedsInstaller { throw TestFailure.failed("a broken signature must not be reported as a launcher") }
        catch { rejected = true }
        try expect(rejected, "direct copies still reject an invalid signature")
    }

    func test_copyMutationSpaceAndCancellationFailHonestly() throws {
        for scenario in ["copy", "mutation", "space", "cancel"] {
            let f = try AppTestFixture(); defer { f.cleanup() }
            let source = try f.app()
            let first = try f.backup()
            // Changed for every scenario: an unchanged app is reused from the first copy and
            // needs neither space nor copying.
            try f.write("#!/bin/sh\nexit 1\n", source.path + "/Contents/MacOS/Shoji")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path + "/Contents/MacOS/Shoji")
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
        let additional = AppInventory.dataCandidates(home: f.box.home, roots: f.roots,
                                                     excluding: ["~/" + preference])
        try expect(!additional.flatMap(\.paths).contains("~/" + preference),
                   "known tool settings are not duplicated as sensitive app data")
        try expect(additional.flatMap(\.paths).contains("~/Library/Application Support/Shoji"),
                   "new app data still needs an explicit choice")

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
