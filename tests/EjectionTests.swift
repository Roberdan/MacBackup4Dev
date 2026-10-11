import Foundation

struct EjectionTests {
    private let disk = URL(fileURLWithPath: "/Volumes/Test-ejection")
    private let store = EncryptedStore.Setup(container: "/Volumes/Test-ejection/test.sparsebundle", volume: "Test-store")
    private let success = Shell.Result(status: 0, stdout: "", stderr: "")
    private let failure = Shell.Result(status: 1, stdout: "", stderr: "Resource busy")

    func test_plainDiskProgressAndSuccess() throws {
        var events: [EjectionPhase] = []
        var commands: [[String]] = []
        let result = DiskEjection.run(disk: disk, store: nil,
                                     closeStore: { _, _ in fatalError("No encrypted store") },
                                     isStoreOpen: { _ in fatalError("No encrypted store") },
                                     diskutil: { commands.append($0); return success },
                                     processesUsing: { _ in fatalError("No holders needed") },
                                     isMounted: { _ in false },
                                     progress: { events.append($0) })
        try expect(result == .succeeded, "A detached disk confirms success")
        try expect(events == [.ejecting], "Progress starts before ejecting")
        try expect(commands == [["eject", disk.path]], "Only the configured physical disk is ejected")
    }

    func test_encryptedStoreClosesFirst() throws {
        var calls: [String] = []
        let result = DiskEjection.run(disk: disk, store: store,
                                     closeStore: { _, force in calls.append(force ? "force-close" : "close"); return .closed },
                                     isStoreOpen: { _ in false },
                                     diskutil: { _ in calls.append("eject"); return success },
                                     processesUsing: { _ in "" },
                                     isMounted: { _ in false },
                                     progress: { calls.append($0 == .closingStore ? "closing" : "ejecting") })
        try expect(result == .succeeded, "Encrypted store ejection completes")
        try expect(calls == ["closing", "close", "ejecting", "eject"], "Close precedes physical disk ejection")
    }

    func test_busyStoreNeverEjects() throws {
        for holders in ["Terminal", ""] {
            var forced = false
            var ejected = false
            let result = DiskEjection.run(disk: disk, store: store,
                                         closeStore: { _, force in forced = forced || force; return .failed("hdiutil: detach failed - Resource busy") },
                                         isStoreOpen: { _ in true },
                                         diskutil: { _ in ejected = true; return success },
                                         processesUsing: { _ in holders },
                                         isMounted: { _ in true }, progress: { _ in })
            guard case .failed(let reason) = result else { throw TestFailure.failed("Busy store must fail") }
            try expect(!forced && !ejected, "Unknown holders and writers must never be forced")
            try expect(reason.contains("volume cifrato") && reason.contains("Resource busy"), "The real close error reaches the feedback")
            try expect(!reason.contains("quando ha finito"), "A close failure must not imply a running backup")
            try expect(reason.contains("Non scollegare"), "A failed close never permits unplugging")
            try expect(holders.isEmpty ? reason.contains("Nessun processo identificato") : reason.contains(holders),
                       "Unknown owners are distinguished from observed process names")
        }
    }

    func test_indexersOnlyAllowFallback() throws {
        var forcedClose = false
        var commands: [[String]] = []
        let result = DiskEjection.run(disk: disk, store: store,
                                     closeStore: { _, force in forcedClose = forcedClose || force; return force ? .closed : .failed("Resource busy") },
                                     isStoreOpen: { _ in false },
                                     diskutil: { commands.append($0); return $0.first == "unmount" ? success : failure },
                                     processesUsing: { _ in "mds, wdavdaemon" },
                                     isMounted: { _ in false }, progress: { _ in })
        try expect(result == .succeeded && forcedClose, "Only known read-only scanners permit force-close")
        try expect(commands == [["eject", disk.path], ["unmount", "force", disk.path]], "Safe fallback is preserved")
    }

    func test_failureAndMountedSuccessStayUnsafe() throws {
        for holders in ["Finder, Terminal", ""] {
            var commands = 0
            let result = DiskEjection.run(disk: disk, store: nil,
                                         diskutil: { _ in commands += 1; return failure },
                                         processesUsing: { _ in holders },
                                         isMounted: { _ in true }, progress: { _ in })
            guard case .failed(let reason) = result else { throw TestFailure.failed("Failed command cannot confirm success") }
            try expect(commands == 1, "Writers or unknown holders cannot trigger force-unmount")
            try expect(holders.isEmpty || reason.contains(holders), "Failure identifies known holders")
            try expect(reason.contains("Resource busy") && reason.contains("Non scollegare"),
                       "Physical failure preserves the error and does not permit unplugging")
        }
        let stillMounted = DiskEjection.run(disk: disk, store: nil, diskutil: { _ in success },
                                            processesUsing: { _ in "" }, isMounted: { _ in true }, progress: { _ in })
        guard case .failed(let reason) = stillMounted else { throw TestFailure.failed("Exit zero alone is not safe-to-unplug proof") }
        try expect(reason.contains("ancora montato") && reason.contains("Non scollegare"),
                   "Unconfirmed unmount is reported explicitly, not as a command failure")
    }

    func test_physicalFailurePreservesSystemError() throws {
        for holders in ["", "Finder"] {
            let result = DiskEjection.run(
                disk: disk, store: nil,
                diskutil: { _ in Shell.Result(status: 16, stdout: "Ejection progress", stderr: "Actual macOS refusal\n") },
                processesUsing: { _ in holders }, isMounted: { _ in true }, progress: { _ in })
            guard case .failed(let reason) = result else { throw TestFailure.failed("Eject must fail") }
            try expect(reason.contains("Actual macOS refusal") && !reason.contains("Ejection progress"),
                       "Stderr takes priority over progress output")
            try expect(!reason.contains("Chiudi le finestre del Finder"), "Do not guess Finder is the cause")
            try expect(holders.isEmpty ? reason.contains("Nessun processo identificato") : reason.contains(holders),
                       "Observed holders are distinguished from an inconclusive lookup")
        }
    }

    func test_physicalFailureUsesStdoutAndExitCode() throws {
        for output in ["Volume could not be unmounted by process 12345", ""] {
            let result = DiskEjection.run(
                disk: disk, store: nil,
                diskutil: { _ in Shell.Result(status: 73, stdout: output, stderr: " \n") },
                processesUsing: { _ in "" }, isMounted: { _ in true }, progress: { _ in })
            guard case .failed(let reason) = result else { throw TestFailure.failed("Eject must fail") }
            try expect(output.isEmpty ? reason.contains("codice 73") : reason.contains(output),
                       "diskutil failures on stdout and empty-output exit codes remain visible")
        }
        let long = Shell.Result(status: 1, stdout: "", stderr: String(repeating: "x", count: 600) + " last refusal")
        try expectEqual(long.failureReason.count, 300, "Shared command errors are bounded")
        try expect(long.failureReason.hasSuffix("last refusal"), "Bounding keeps the useful final reason")
    }

    func test_physicalFallbackKeepsLastError() throws {
        var commands: [[String]] = []
        let result = DiskEjection.run(
            disk: disk, store: nil,
            diskutil: { args in
                commands.append(args)
                return Shell.Result(status: 1, stdout: "", stderr: args.first == "eject" ? "First refusal" : "Last refusal")
            }, processesUsing: { _ in "mds" }, isMounted: { _ in true }, progress: { _ in })
        guard case .failed(let reason) = result else { throw TestFailure.failed("Fallback must fail") }
        try expectEqual(commands, [["eject", disk.path], ["unmount", "force", disk.path]], "Existing indexer-only policy is unchanged")
        try expect(reason.contains("Last refusal") && !reason.contains("First refusal"),
                   "The last attempted physical command supplies the reason")
    }

    func test_physicalCommandCapturesOutputAndDeadline() throws {
        var seen: ([String], TimeInterval)?
        var executableUsed = ""
        let result = DiskEjection.runDiskutil(["eject", disk.path], runCommand: { executable, args, timeout in
            executableUsed = executable
            seen = (args, timeout)
            return Shell.Result(status: -2, stdout: "progress", stderr: "timeout dopo 120s")
        })
        try expectEqual(executableUsed, "/usr/sbin/diskutil", "Only the native diskutil is invoked")
        try expectEqual(seen?.0, ["eject", disk.path], "The configured target is preserved")
        try expectEqual(seen?.1, 120, "Physical commands no longer wait without a deadline")
        try expectEqual(result.status, -2, "Timeout remains a failure")
        try expectEqual(result.stdout, "progress", "Output is captured instead of discarded")
        try expectEqual(result.stderr, "timeout dopo 120s", "The captured error is preserved")
    }

    func test_feedbackLifecycle() throws {
        let state = AppUIState()
        state.ejection = EjectionFeedback(disk: disk, phase: .ejecting)
        try expect(state.isEjecting, "In-progress state blocks duplicate/conflicting UI actions")
        state.dismissEjection()
        state.reconcileEjection(diskMounted: true)
        try expect(state.isEjecting, "Busy state cannot be dismissed or cleared by mount polling")
        state.ejection?.phase = .succeeded
        state.reconcileEjection(diskMounted: false)
        try expect(!state.isEjecting && state.ejection != nil, "Confirmation persists while disk is absent")
        try expect(state.ejection?.detail.contains("Puoi scollegare") == true, "Success explicitly says unplugging is safe")
        state.reconcileEjection(diskMounted: true)
        try expect(state.ejection == nil, "Reconnection clears stale safe-to-unplug confirmation")
        state.ejection = EjectionFeedback(disk: disk, phase: .failed("Occupato"))
        state.reconcileEjection(diskMounted: true)
        try expect(state.ejection != nil, "Polling does not hide failure or retry")
        state.dismissEjection()
        try expect(state.ejection == nil, "A finished result can be dismissed")
    }

    func test_closeReportingPreservesCommandFailure() throws {
        var commands: [String] = []
        var arguments: [[String]] = []
        var timeouts: [TimeInterval] = []
        let result = EncryptedStore.closeReporting(store, runCommand: { executable, args, timeout in
            commands.append(executable)
            arguments.append(args)
            timeouts.append(timeout)
            return Shell.Result(status: 16, stdout: "", stderr: "hdiutil: detach failed - Resource busy\n")
        }, isMounted: { _ in true }, imageDevice: { _ in nil })
        try expectEqual(commands, ["/usr/bin/hdiutil"], "A normal failure must not try forced unmount")
        try expectEqual(arguments, [["detach", store.mountPoint]], "Normal close does not force")
        try expectEqual(timeouts, [120], "The existing close deadline is preserved")
        try expectEqual(result, .failed("hdiutil: detach failed - Resource busy"), "The system error is retained, not replaced by a guessed backup state")
    }

    func test_closeReportingKeepsFallbackErrorAndExitCode() throws {
        var commands: [String] = []
        let result = EncryptedStore.closeReporting(store, force: true, runCommand: { executable, _, _ in
            commands.append(executable)
            return Shell.Result(status: 1, stdout: "", stderr: executable == "/usr/bin/hdiutil" ? "First failure" : "Unmount denied")
        }, isMounted: { _ in true }, imageDevice: { _ in "/dev/disk12" })
        try expectEqual(commands, ["/usr/bin/hdiutil", "/usr/sbin/diskutil"], "Existing explicit-force fallback is preserved")
        try expectEqual(result, .failed("Unmount denied"), "The last attempted command supplies the reason")
        let noReason = EncryptedStore.closeReporting(store, runCommand: { _, _, _ in
            Shell.Result(status: 73, stdout: "", stderr: "")
        }, isMounted: { _ in true })
        try expectEqual(noReason, .failed("macOS non ha indicato il motivo (codice 73)."), "An empty error reports the exit code, not an invented owner")
        let outputReason = EncryptedStore.closeReporting(store, runCommand: { _, _, _ in
            Shell.Result(status: 1, stdout: "Actual close refusal on stdout", stderr: "")
        }, isMounted: { _ in true })
        try expectEqual(outputReason, .failed("Actual close refusal on stdout"), "Shared error reporting also retains close failures on stdout")
        let longReason = EncryptedStore.closeReporting(store, runCommand: { _, _, _ in
            Shell.Result(status: 1, stdout: "", stderr: String(repeating: "x", count: 600) + " useful final reason")
        }, isMounted: { _ in true })
        guard case .failed(let detail) = longReason else { throw TestFailure.failed("The long failure must remain a failure") }
        try expectEqual(detail.count, 300, "Visible command errors are bounded")
        try expect(detail.hasSuffix("useful final reason"), "The final reason is not lost when bounding the output")
    }

    func test_normalCloseEjectsTheExactImageDevice() throws {
        var calls: [[String]] = []
        var timeouts: [TimeInterval] = []
        let refusal = "Unmount of disk12 failed: at least one volume could not be unmounted\n"
            + "Unmount was dissented by PID 14647 (/Applications/Microsoft Defender.app/Contents/MacOS/dlp_agent.app/Contents/MacOS/dlp_agent)"
        let result = EncryptedStore.closeReporting(store, runCommand: { executable, args, timeout in
            calls.append([executable] + args); timeouts.append(timeout)
            return Shell.Result(status: 1, stdout: "", stderr: refusal)
        }, isMounted: { _ in true }, imageDevice: { _ in "/dev/disk12" })
        try expectEqual(calls, [["/usr/sbin/diskutil", "eject", "/dev/disk12"]], "Normal close ejects the image's own device, never forced")
        try expectEqual(timeouts, [120], "Same close deadline")
        guard case .failed(let reason) = result else { throw TestFailure.failed("A refusal is not a close") }
        try expect(reason.contains("dissented by PID 14647"), "The system's dissent survives in the reason")
        var forced: [[String]] = []
        _ = EncryptedStore.closeReporting(store, force: true, runCommand: { executable, args, _ in
            forced.append([executable] + args); return Shell.Result(status: 0, stdout: "", stderr: "")
        }, isMounted: { _ in true }, imageDevice: { _ in "/dev/disk12" })
        try expectEqual(forced, [["/usr/bin/hdiutil", "detach", "-force", store.mountPoint]], "The explicit force path is unchanged")
        let closed = EncryptedStore.closeReporting(store, runCommand: { _, _, _ in Shell.Result(status: 0, stdout: "", stderr: "") },
                                                   isMounted: { _ in true }, imageDevice: { _ in "/dev/disk12" })
        try expectEqual(closed, .closed, "A successful eject closes")
    }

    func test_imageDeviceNeedsExactlyOneMatchingImage() throws {
        func info(_ images: [[String: Any]]) -> Data {
            (try? PropertyListSerialization.data(fromPropertyList: ["images": images], format: .xml, options: 0)) ?? Data()
        }
        func image(_ path: String, _ disk: Int, mount: String?) -> [String: Any] {
            var leaf: [String: Any] = ["dev-entry": "/dev/disk\(disk + 1)s1"]
            if let mount { leaf["mount-point"] = mount }
            return ["image-path": path, "system-entities": [
                ["dev-entry": "/dev/disk\(disk)", "content-hint": "GUID_partition_scheme"],
                ["dev-entry": "/dev/disk\(disk)s1"], ["dev-entry": "/dev/disk\(disk + 1)"], leaf]]
        }
        let other = image("/tmp/other/\(EncryptedStore.imageName)", 14, mount: "/Volumes/MB4DTest-x")
        let ours = image(store.container, 12, mount: store.mountPoint)
        try expectEqual(EncryptedStore.imageDevice(fromHdiutilInfo: info([other, ours]), setup: store), "/dev/disk12",
                        "The image's own whole device, not its APFS container nor another image")
        try expectNil(EncryptedStore.imageDevice(fromHdiutilInfo: info([other]), setup: store), "Not attached: no device")
        try expectNil(EncryptedStore.imageDevice(fromHdiutilInfo: info([image(store.container, 12, mount: "/Volumes/Else")]), setup: store),
                      "Same file mounted elsewhere is not this store")
        try expectNil(EncryptedStore.imageDevice(fromHdiutilInfo: info([ours, image(store.container, 16, mount: store.mountPoint)]), setup: store),
                      "Ambiguous: no device")
        try expectNil(EncryptedStore.imageDevice(fromHdiutilInfo: Data("not a plist".utf8), setup: store), "Unreadable: no device")
    }

    func test_dissenterIsNamedFromTheSystemMessage() throws {
        let line = "Unmount was dissented by PID 14647 (/Applications/Microsoft Defender.app/Contents/MacOS/dlp_agent.app/Contents/MacOS/dlp_agent)"
        try expectEqual(DiskEjection.dissenter(in: line), "Microsoft Defender (dlp_agent, PID 14647)", "App and executable named")
        try expectEqual(DiskEjection.dissenter(in: "Unmount was dissented by PID 77 (/usr/sbin/someprog)"), "someprog (PID 77)", "Plain executable")
        try expectEqual(DiskEjection.dissenter(in: "Unmount was dissented by PID 9"), "PID 9", "No path: only the PID")
        try expectNil(DiskEjection.dissenter(in: "Resource busy"), "No dissent: nothing invented")
        let result = DiskEjection.run(disk: disk, store: store,
                                     closeStore: { _, _ in .failed(line) }, isStoreOpen: { _ in true },
                                     diskutil: { _ in fatalError("Never eject while the store is open") },
                                     processesUsing: { _ in "" }, isMounted: { _ in true }, progress: { _ in })
        guard case .failed(let reason) = result else { throw TestFailure.failed("Refusal must fail") }
        try expect(reason.contains("Lo sta usando: Microsoft Defender (dlp_agent, PID 14647)."), "The refusing process is named")
        try expect(!reason.contains("Nessun processo identificato"), "No contradiction with the named process")
        try expect(reason.contains("Non scollegare il disco"), "Still unsafe to unplug")
    }

    func test_failureIsDroppedOnlyWhenTheDiskIsGone() throws {
        let state = AppUIState()
        state.ejection = EjectionFeedback(disk: disk, phase: .failed("Occupato"))
        state.reconcileEjection(diskMounted: true)
        try expect(state.ejection != nil, "A refusal stays while the disk is there")
        state.reconcileEjection(diskMounted: false)
        try expect(state.ejection == nil, "Disk gone: the refusal is stale")
        state.ejection = EjectionFeedback(disk: disk, phase: .closingStore)
        state.reconcileEjection(diskMounted: false)
        try expect(state.ejection?.phase == .closingStore, "A running ejection is never dropped")
    }
}
