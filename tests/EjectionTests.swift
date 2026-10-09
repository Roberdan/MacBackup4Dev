import Foundation

struct EjectionTests {
    private let disk = URL(fileURLWithPath: "/Volumes/Test-ejection")
    private let store = EncryptedStore.Setup(container: "/Volumes/Test-ejection/test.sparsebundle", volume: "Test-store")

    func test_plainDiskProgressAndSuccess() throws {
        var events: [EjectionPhase] = []
        var commands: [[String]] = []
        let result = DiskEjection.run(disk: disk, store: nil,
                                     closeStore: { _, _ in fatalError("No encrypted store") },
                                     isStoreOpen: { _ in fatalError("No encrypted store") },
                                     diskutil: { commands.append($0); return true },
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
                                     diskutil: { _ in calls.append("eject"); return true },
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
                                         diskutil: { _ in ejected = true; return true },
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
                                     diskutil: { commands.append($0); return $0.first == "unmount" },
                                     processesUsing: { _ in "mds, wdavdaemon" },
                                     isMounted: { _ in false }, progress: { _ in })
        try expect(result == .succeeded && forcedClose, "Only known read-only scanners permit force-close")
        try expect(commands == [["eject", disk.path], ["unmount", "force", disk.path]], "Safe fallback is preserved")
    }

    func test_failureAndMountedSuccessStayUnsafe() throws {
        for holders in ["Finder, Terminal", ""] {
            var commands = 0
            let result = DiskEjection.run(disk: disk, store: nil,
                                         diskutil: { _ in commands += 1; return false },
                                         processesUsing: { _ in holders },
                                         isMounted: { _ in true }, progress: { _ in })
            guard case .failed(let reason) = result else { throw TestFailure.failed("Failed command cannot confirm success") }
            try expect(commands == 1, "Writers or unknown holders cannot trigger force-unmount")
            try expect(holders.isEmpty || reason.contains(holders), "Failure identifies known holders")
        }
        let stillMounted = DiskEjection.run(disk: disk, store: nil, diskutil: { _ in true },
                                            processesUsing: { _ in "" }, isMounted: { _ in true }, progress: { _ in })
        guard case .failed = stillMounted else { throw TestFailure.failed("Exit zero alone is not safe-to-unplug proof") }
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
        }, isMounted: { _ in true })
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
        }, isMounted: { _ in true })
        try expectEqual(commands, ["/usr/bin/hdiutil", "/usr/sbin/diskutil"], "Existing explicit-force fallback is preserved")
        try expectEqual(result, .failed("Unmount denied"), "The last attempted command supplies the reason")
        let noReason = EncryptedStore.closeReporting(store, runCommand: { _, _, _ in
            Shell.Result(status: 73, stdout: "", stderr: "")
        }, isMounted: { _ in true })
        try expectEqual(noReason, .failed("macOS non ha indicato il motivo (codice 73)."), "An empty error reports the exit code, not an invented owner")
        let longReason = EncryptedStore.closeReporting(store, runCommand: { _, _, _ in
            Shell.Result(status: 1, stdout: "", stderr: String(repeating: "x", count: 600) + " useful final reason")
        }, isMounted: { _ in true })
        guard case .failed(let detail) = longReason else { throw TestFailure.failed("The long failure must remain a failure") }
        try expectEqual(detail.count, 300, "Visible command errors are bounded")
        try expect(detail.hasSuffix("useful final reason"), "The final reason is not lost when bounding the output")
    }
}
