import Foundation

/// Scheduled backups run only on wall power, fail-closed.
struct PowerGateTests {
    func test_acAllowsScheduled() throws {
        try expectEqual(PowerGate.scheduledBackupAllowed(reader: { .ac }), true, "AC must allow")
    }

    func test_batteryBlocksScheduled() throws {
        try expectEqual(PowerGate.scheduledBackupAllowed(reader: { .battery }), false, "battery must skip")
    }

    func test_unknownBlocksScheduled() throws {
        try expectEqual(PowerGate.scheduledBackupAllowed(reader: { .unknown }), false, "unknown power must skip (fail-closed)")
    }

    func test_plistsPassScheduledFlag() throws {
        for plist in [ScheduleManager.generatePlist(intervalSeconds: 3600), ScheduleManager.generatePlistDaily(hour: 3)] {
            let args = try plistArgs(plist)
            try expectEqual(Array(args.suffix(2)), ["backup", "--scheduled"], "plist must run `backup --scheduled`")
        }
    }

    func test_liveReaderReturnsAValue() throws {
        // Must not crash on any machine (desktop, laptop, CI); the value itself depends on the host.
        _ = PowerGate.currentSource()
    }

    private func plistArgs(_ xml: String) throws -> [String] {
        let obj = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)
        return (obj as? [String: Any])?["ProgramArguments"] as? [String] ?? []
    }
}
