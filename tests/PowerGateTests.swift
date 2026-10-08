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

    func test_intervalUsesWallClockCalendar() throws {
        for minutes in [15, 60, 90, 360, 1440] {
            let plist = try plistDictionary(ScheduleManager.generatePlist(intervalSeconds: minutes * 60))
            try expectNil(plist["StartInterval"], "calendar schedules must not drift with backup duration")
            guard let calendar = plist["StartCalendarInterval"] as? [[String: Int]] else {
                throw TestFailure.failed("interval \(minutes) must use a calendar array")
            }
            let slots = calendar.compactMap { entry -> Int? in
                guard let hour = entry["Hour"], let minute = entry["Minute"] else { return nil }
                return hour * 60 + minute
            }
            try expectEqual(slots, Array(stride(from: 0, to: 1440, by: minutes)),
                            "wall-clock slots for interval \(minutes)")
            let status = ScheduleManager.scheduleStatus(from: plist, installed: true)
            try expectEqual(status.intervalMinutes, minutes, "menu and CLI read calendar intervals")
            try expectNil(status.dailyHour, "interval must not be mistaken for daily")
        }
    }

    func test_calendarMigrationPreservesJob() throws {
        let old: [String: Any] = [
            "Label": ScheduleManager.label, "StartInterval": 3600, "RunAtLoad": true,
            "ProgramArguments": ["/custom/on-ac", "/Applications/MacBackup4Dev.app/Contents/MacOS/MacBackup4Dev",
                                 "backup", "--scheduled"],
            "StandardOutPath": "/custom/backup.log", "Nice": 10,
        ]
        guard let new = ScheduleManager.calendarPlist(from: old) else { throw TestFailure.failed("must migrate hourly") }
        try expectNil(new["StartInterval"], "old timer removed")
        for key in ["Label", "RunAtLoad", "ProgramArguments", "StandardOutPath", "Nice"] {
            try expectEqual(String(describing: new[key]), String(describing: old[key]), "preserve \(key)")
        }
        try expectEqual(ScheduleManager.scheduleStatus(from: new, installed: false).intervalMinutes, 60,
                        "schedule interval readable even when unloaded")
        try expectNil(ScheduleManager.calendarPlist(from: new), "migration is idempotent")
        try expectNil(ScheduleManager.calendarPlist(from: ["StartInterval": 420]), "unsupported interval kept")
        try expectNil(ScheduleManager.calendarPlist(from: [
            "StartInterval": 3600, "StartCalendarInterval": ["Hour": 3, "Minute": 0],
        ]), "do not overwrite a custom mixed schedule")
        let invalid: [String: Any] = ["StartCalendarInterval": [["Hour": 1, "Minute": 0], ["Hour": 3, "Minute": 0]]]
        try expectNil(ScheduleManager.scheduleStatus(from: invalid, installed: true).intervalMinutes,
                      "irregular calendar is not an interval")
    }

    func test_nonCalendarIntervalsArePreserved() throws {
        for seconds in [90, 420, 90000] {
            let plist = try plistDictionary(ScheduleManager.generatePlist(intervalSeconds: seconds))
            try expectEqual(plist["StartInterval"] as? Int, seconds, "do not round unsupported intervals")
            try expectNil(plist["StartCalendarInterval"], "no inexact calendar substitute")
        }
        let daily = try plistDictionary(ScheduleManager.generatePlistDaily(hour: 3))
        try expectEqual(daily["StartCalendarInterval"] as? [String: Int], ["Hour": 3, "Minute": 0],
                        "daily scheduling remains unchanged")
    }

    func test_calendarMigrationSerializesWithBackup() throws {
        let safety = SafetyTests()
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let destination = URL(fileURLWithPath: box.dest)
        let path = box.root.appendingPathComponent("schedule.plist")
        let old = try PropertyListSerialization.data(fromPropertyList: ["StartInterval": 3600], format: .xml, options: 0)
        try old.write(to: path)
        var installs = 0
        let install: (String) throws -> Void = { xml in
            installs += 1
            do {
                _ = try DestinationLock(at: destination)
                try fail("migration must hold the backup lock while changing the schedule")
            } catch BackupError.lockExists {}
            try xml.write(to: path, atomically: true, encoding: .utf8)
        }
        do {
            let backup = try DestinationLock(at: destination)
            try withExtendedLifetime(backup) {
                do {
                    _ = try ScheduleManager.migrateIntervalScheduleWhenIdle(destination: destination, path: path, install: install)
                    try fail("a running backup must defer migration")
                } catch BackupError.lockExists {}
            }
        }
        try expectEqual(installs, 0, "never bootout a running backup")
        try expectEqual(try Data(contentsOf: path), old, "a busy schedule remains unchanged")
        try expect(try ScheduleManager.migrateIntervalScheduleWhenIdle(destination: destination, path: path, install: install),
                   "migration succeeds once the backup is idle")
        try expectEqual(installs, 1, "install only once")
        _ = try DestinationLock(at: destination)
    }

    func test_calendarMigrationRollbackHoldsLock() throws {
        let safety = SafetyTests()
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let destination = URL(fileURLWithPath: box.dest)
        let path = box.root.appendingPathComponent("schedule.plist")
        let old = try PropertyListSerialization.data(fromPropertyList: ["StartInterval": 3600], format: .xml, options: 0)
        try old.write(to: path)
        var installs = 0
        do {
            _ = try ScheduleManager.migrateIntervalScheduleWhenIdle(destination: destination, path: path, install: { xml in
                installs += 1
                do {
                    _ = try DestinationLock(at: destination)
                    try fail("rollback must retain the backup lock")
                } catch BackupError.lockExists {}
                try xml.write(to: path, atomically: true, encoding: .utf8)
                if installs == 1 { throw POSIXError(.EIO) }
            })
            try fail("a failed install must report its error")
        } catch let error as POSIXError {
            try expectEqual(error.code, .EIO, "preserve the original install error")
        }
        try expectEqual(installs, 2, "retry the original schedule as rollback")
        try expectEqual(try Data(contentsOf: path), old, "restore the original schedule")
        _ = try DestinationLock(at: destination)
    }

    private func plistDictionary(_ xml: String) throws -> [String: Any] {
        let obj = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)
        guard let dict = obj as? [String: Any] else { throw TestFailure.failed("invalid schedule plist") }
        return dict
    }

    private func plistArgs(_ xml: String) throws -> [String] {
        let obj = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil)
        return (obj as? [String: Any])?["ProgramArguments"] as? [String] ?? []
    }
}
