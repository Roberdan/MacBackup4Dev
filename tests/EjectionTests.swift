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
                                     closeStore: { _, force in calls.append(force ? "force-close" : "close"); return true },
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
                                         closeStore: { _, force in forced = forced || force; return false },
                                         isStoreOpen: { _ in true },
                                         diskutil: { _ in ejected = true; return true },
                                         processesUsing: { _ in holders },
                                         isMounted: { _ in true }, progress: { _ in })
            guard case .failed(let reason) = result else { throw TestFailure.failed("Busy store must fail") }
            try expect(!forced && !ejected, "Unknown holders and writers must never be forced")
            try expect(reason.contains("backup cifrato"), "The encrypted-store failure is readable")
        }
    }

    func test_indexersOnlyAllowFallback() throws {
        var forcedClose = false
        var commands: [[String]] = []
        let result = DiskEjection.run(disk: disk, store: store,
                                     closeStore: { _, force in forcedClose = forcedClose || force; return force },
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
}
