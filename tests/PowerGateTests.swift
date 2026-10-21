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
            var rome = Calendar(identifier: .gregorian)
            rome.timeZone = TimeZone(identifier: "Europe/Rome")!
            let now = rome.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15, minute: 7))!
            let nowMinute = 15 * 60 + 7
            let nextMinute: Int = (nowMinute / minutes + 1) * minutes
            let expected: Date = rome.date(byAdding: .minute, value: nextMinute - nowMinute, to: now)!
            try expectEqual(status.nextRun(after: now, calendar: rome), expected, "next slot after 15:07 for every \(minutes) min")
        }
        let dailyPlist = try plistDictionary(ScheduleManager.generatePlistDaily(hour: 3))
        let daily = ScheduleManager.scheduleStatus(from: dailyPlist, installed: true)
        var rome = Calendar(identifier: .gregorian)
        rome.timeZone = TimeZone(identifier: "Europe/Rome")!
        let afternoon = rome.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15))!
        let tomorrow3 = rome.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 3))
        try expectEqual(daily.nextRun(after: afternoon, calendar: rome), tomorrow3, "daily runs tomorrow at 3:00")
        let interval = ScheduleManager.scheduleStatus(from: ["StartInterval": 420], installed: true)
        try expectNil(interval.nextRun(after: afternoon), "a launchd interval has no exact wall-clock time")
        let off = ScheduleManager.scheduleStatus(from: dailyPlist, installed: false)
        try expectNil(off.nextRun(after: afternoon), "no automatic backup when the schedule is off")
    }

    func test_nextBackupIsExplainedInTheMenu() throws {
        let state = AppUIState()
        try expectNil(state.nextBackupText, "unknown schedule: nothing invented")
        var calendar = Calendar.current; calendar.timeZone = .current
        let now = calendar.date(bySettingHour: 15, minute: 7, second: 0, of: Date())!
        state.now = { now }
        state.schedule = ScheduleStatus(installed: true, intervalMinutes: 60, dailyHour: nil, slots: Array(stride(from: 0, to: 1440, by: 60)))
        state.appState = .idle
        try expectEqual(state.nextBackupText, "Prossimo backup automatico: oggi alle 16:00", "time of the next run")
        state.onBattery = true
        try expect(state.nextBackupText?.contains("solo con l'alimentatore collegato") == true, "battery skips the run, said up front")
        state.appState = .diskAbsent
        try expect(state.nextBackupText?.hasSuffix("se colleghi il disco") == true, "needs the disk")
        state.schedule = ScheduleStatus(installed: false, intervalMinutes: nil, dailyHour: nil)
        try expectEqual(state.nextBackupText, "Backup automatico disattivato", "schedule off is explicit")
        state.schedule = ScheduleStatus(installed: true, intervalMinutes: 7, dailyHour: nil)
        try expectEqual(state.nextBackupText, "Backup automatico ogni 7 min", "inexact interval: no invented time")
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

    func test_existingSchedulesRefreshRegistration() throws {
        let schedules = [
            ScheduleManager.generatePlist(intervalSeconds: 3600),
            ScheduleManager.generatePlistDaily(hour: 3),
            ScheduleManager.generatePlist(intervalSeconds: 90),
        ]
        for (index, schedule) in schedules.enumerated() {
            let name = ["hourly calendar", "daily", "custom 90 s interval"][index]
            let safety = SafetyTests()
            let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
            let destination = URL(fileURLWithPath: box.dest)
            let path = box.root.appendingPathComponent("schedule.plist")
            var original = try plistDictionary(schedule)
            original["ProgramArguments"] = ["/custom/on-ac", "/custom/backup", "backup", "--scheduled"]
            original["StandardOutPath"] = "/custom/backup.log"
            let data = try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0)
            try data.write(to: path)
            var installs = 0
            let install: (String) throws -> Void = { xml in
                installs += 1
                do {
                    _ = try DestinationLock(at: destination)
                    try fail("registration refresh must hold the backup lock")
                } catch BackupError.lockExists {}
                try xml.write(to: path, atomically: true, encoding: .utf8)
            }
            try expectEqual(refreshOutcome {
                try ScheduleManager.refreshScheduleRegistrationWhenIdle(
                    destination: destination, path: path, jobIsRunning: { true }, install: install)
            }, "deferred", "\(name): while launchd reports the scheduled job running, the refresh must defer "
                + "(BackupError.lockExists) without reinstalling it")
            do {
                let backup = try DestinationLock(at: destination)
                try withExtendedLifetime(backup) {
                    try expectEqual(refreshOutcome {
                        try ScheduleManager.refreshScheduleRegistrationWhenIdle(
                            destination: destination, path: path, jobIsRunning: { false }, install: install)
                    }, "deferred", "\(name): while a backup holds the destination lock, the refresh must defer "
                        + "(BackupError.lockExists)")
                }
            }
            try expectEqual(installs, 0, "\(name): never unload a running calendar or custom job")
            try expect(try ScheduleManager.refreshScheduleRegistrationWhenIdle(
                destination: destination, path: path, jobIsRunning: { false }, install: install),
                       "\(name): refresh registration even when no interval migration is needed")
            try expectEqual(installs, 1, "\(name): reload the existing job once")
            let refreshed = try plistDictionary(String(contentsOf: path, encoding: .utf8))
            try expect(NSDictionary(dictionary: refreshed).isEqual(to: original),
                       "\(name): preserve calendar times, arbitrary intervals, wrappers and custom job settings")
        }
    }

    func test_scheduleRefreshKeepsDisabledAndDefersOffline() throws {
        let safety = SafetyTests()
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let path = box.root.appendingPathComponent("schedule.plist")
        var installs = 0
        let install: (String) throws -> Void = { _ in installs += 1 }
        try expectEqual(try ScheduleManager.refreshScheduleRegistrationWhenIdle(
            destination: URL(fileURLWithPath: box.dest), path: path, jobIsRunning: { false }, install: install), false,
                        "do not recreate a disabled schedule")
        let original = Data(ScheduleManager.generatePlist(intervalSeconds: 3600).utf8)
        try original.write(to: path)
        let offline = box.root.appendingPathComponent("unmounted-destination")
        try expectEqual(try ScheduleManager.refreshScheduleRegistrationWhenIdle(
            destination: offline, path: path, jobIsRunning: { false }, install: install), false,
                        "wait for the destination before taking its operation lock")
        try expectEqual(installs, 0, "neither disabled nor offline schedules are reinstalled")
        try expectEqual(try Data(contentsOf: path), original, "keep the offline schedule intact")
        try expect(!FileManager.default.fileExists(atPath: offline.path), "never create an unmounted destination")
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
                    _ = try ScheduleManager.refreshScheduleRegistrationWhenIdle(
                        destination: destination, path: path, jobIsRunning: { false }, install: install)
                    try fail("a running backup must defer migration")
                } catch BackupError.lockExists {}
            }
        }
        try expectEqual(installs, 0, "never bootout a running backup")
        try expectEqual(try Data(contentsOf: path), old, "a busy schedule remains unchanged")
        try expect(try ScheduleManager.refreshScheduleRegistrationWhenIdle(
            destination: destination, path: path, jobIsRunning: { false }, install: install),
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
            _ = try ScheduleManager.refreshScheduleRegistrationWhenIdle(
                destination: destination, path: path, jobIsRunning: { false }, install: { xml in
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

    func test_scheduleJobRunningStateComesFromLaunchctl() throws {
        var asked: [[String]] = []
        func job(_ status: Int32, _ stdout: String, _ stderr: String = "") -> ScheduleManager.LaunchctlRunner {
            { arguments in asked.append(arguments); return (status, stdout, stderr) }
        }
        let running = "{\n\t\"Label\" = \"\(ScheduleManager.label)\";\n\t\"LastExitStatus\" = 0;\n\t\"PID\" = 4242;\n};\n"
        let idle = "{\n\t\"Label\" = \"\(ScheduleManager.label)\";\n\t\"LastExitStatus\" = 0;\n};\n"
        try expect(try ScheduleManager.scheduleJobIsRunning(launchctl: job(0, running)),
                   "a PID in `launchctl list` means the scheduled backup process is alive")
        try expectEqual(asked.last ?? [], ["list", ScheduleManager.label], "ask launchd about the backup job")
        try expect(try !ScheduleManager.scheduleJobIsRunning(launchctl: job(0, idle)),
                   "a loaded job without PID is idle")
        try expect(try !ScheduleManager.scheduleJobIsRunning(launchctl: job(
            113, "", "Could not find service \"\(ScheduleManager.label)\" in domain for port")),
                   "a job launchd does not know cannot be running")
        let unknown = refreshOutcome {
            try ScheduleManager.scheduleJobIsRunning(launchctl: job(5, "", "Input/output error"))
        }
        try expect(unknown.hasPrefix("threw") && unknown.contains("Input/output error"),
                   "an unreadable launchd state must fail, never count as idle (got: \(unknown))")

        let safety = SafetyTests()
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let path = box.root.appendingPathComponent("schedule.plist")
        try ScheduleManager.generatePlistDaily(hour: 3).write(to: path, atomically: true, encoding: .utf8)
        var installs = 0
        try expectEqual(refreshOutcome {
            try ScheduleManager.refreshScheduleRegistrationWhenIdle(
                destination: URL(fileURLWithPath: box.dest), path: path,
                jobIsRunning: { try ScheduleManager.scheduleJobIsRunning(launchctl: job(0, running)) },
                install: { _ in installs += 1 })
        }, "deferred", "a running scheduled job reported by launchctl defers the refresh")
        try expectEqual(installs, 0, "a running scheduled job is never reinstalled")
    }

    func test_installRechecksScheduledJobRightBeforeBootout() throws {
        let safety = SafetyTests()
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let path = box.root.appendingPathComponent("LaunchAgents/schedule.plist")
        let logs = box.root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = ScheduleManager.generatePlistDaily(hour: 3)
        try old.write(to: path, atomically: true, encoding: .utf8)
        var jobRunning = true
        var calls: [String] = []
        let launchctl: ScheduleManager.LaunchctlRunner = { arguments in
            calls.append(arguments[0])
            if arguments[0] == "list" { return jobRunning ? (0, "\"PID\" = 77;", "") : (0, "{};", "") }
            return (0, "", "")
        }
        let new = ScheduleManager.generatePlist(intervalSeconds: 3600)
        let install = {
            try ScheduleManager.installSchedule(plistContent: new, path: path, logDirectory: logs, launchctl: launchctl,
                                                beforeUnload: { try ScheduleManager.ensureScheduleJobIdle(launchctl: launchctl) })
        }
        try expectEqual(refreshOutcome { try install() }, "deferred",
                        "a job that started after the first check must stop the install before bootout")
        try expectEqual(calls, ["list"], "no bootout or bootstrap while the job runs")
        try expectEqual(try String(contentsOf: path, encoding: .utf8), old, "the running job's plist stays intact")
        jobRunning = false
        try install()
        try expectEqual(calls, ["list", "list", "bootout", "bootstrap"], "recheck, then reload the idle job")
        try expectEqual(try String(contentsOf: path, encoding: .utf8), new, "the idle job is replaced")

        var installs = 0
        try ScheduleManager.generatePlistDaily(hour: 3).write(to: path, atomically: true, encoding: .utf8)
        try expectEqual(refreshOutcome {
            try ScheduleManager.refreshScheduleRegistrationWhenIdle(
                destination: URL(fileURLWithPath: box.dest), path: path, jobIsRunning: { false },
                install: { _ in installs += 1; throw BackupError.lockExists })
        }, "deferred", "a job started just before bootout defers the refresh")
        try expectEqual(installs, 1, "nothing was unloaded, so no rollback reinstall")
    }

    func test_registrationRefreshWaitsForIdleAppAndRetries() throws {
        try MainActor.assumeIsolated {
            let harness = RefresherHarness()
            harness.busy = true
            harness.refresher.run()
            try expectEqual(harness.refreshes, 0, "never refresh launchd while the app is busy")
            try expectEqual(harness.retryDelays, [ScheduleRegistrationRefresher.retryDelay], "retry later while busy")
            harness.refresher.run()
            try expectEqual(harness.refreshes, 0, "a poll tick does not bypass the pending retry")
            harness.busy = false
            harness.outcomes = [.deferred]
            harness.fireRetry()
            try expectEqual(harness.refreshes, 1, "the retry refreshes once the app is idle")
            try expectEqual(harness.retryDelays.count, 2, "an offline destination is retried later")
            harness.outcomes = [.failure(BackupError.lockExists)]
            harness.fireRetry()
            try expectEqual(harness.refreshes, 2, "the second retry refreshes again")
            try expectEqual(harness.retryDelays.count, 3, "a busy backup is retried later")
            try expect(!harness.refresher.finished, "not done while the backup is busy")
            try expectEqual(harness.finishedCalls, 0, "legacy migration waits for the refresh")
            harness.outcomes = [.refreshed]
            harness.fireRetry()
            try expectEqual(harness.refreshes, 3, "the refresh finally runs")
            try expectEqual(harness.labelUpdates, 1, "the menu shows the refreshed schedule")
            try expectEqual(harness.finishedCalls, 1, "legacy migration runs after the refresh")
            try expectEqual(harness.pendingRetries, 0, "no retry left after success")
        }
    }

    func test_registrationRefreshRunsOncePerLaunch() throws {
        try MainActor.assumeIsolated {
            let harness = RefresherHarness()
            harness.outcomes = [.refreshed]
            for _ in 0..<10 { harness.refresher.run() } // as if called at every 30 s status tick
            try expectEqual(harness.refreshes, 1, "launchd is refreshed once per launch, not at every tick")
            try expectEqual(harness.retryDelays, [], "a successful refresh schedules nothing else")
            try expectEqual(harness.finishedCalls, 1, "finish once")
        }
    }

    func test_registrationRefreshFailureIsReadable() throws {
        try MainActor.assumeIsolated {
            let harness = RefresherHarness()
            let raw = "Failed to bootstrap schedule: Bootstrap failed: 5: Input/output error"
            harness.outcomes = [.failure(NSError(domain: "ScheduleManager", code: 1,
                                                 userInfo: [NSLocalizedDescriptionKey: raw]))]
            harness.refresher.run()
            try expectEqual(harness.labelUpdates, 1, "the menu label shows what launchd has after a failure")
            try expectEqual(harness.failures.count, 1, "the user is told once")
            let message = harness.failures.first ?? ""
            try expect(!message.contains("Bootstrap") && !message.contains("Input/output"),
                       "no raw launchctl error in the notification (got: \(message))")
            try expect(message.contains("frequenza"), "tell the user how to fix it (got: \(message))")
            try expectEqual(harness.retryDelays, [], "a launchd failure is reported, not retried in a loop")
            try expectEqual(harness.finishedCalls, 1, "legacy migration still runs after a failure")
            harness.refresher.run()
            try expectEqual(harness.refreshes, 1, "do not retry a failed refresh at every tick")
        }
    }

    /// "deferred" for BackupError.lockExists, otherwise what the call returned or threw.
    private func refreshOutcome<T>(_ body: () throws -> T) -> String {
        do { return "returned \(try body())" }
        catch BackupError.lockExists { return "deferred" }
        catch { return "threw \(error.localizedDescription)" }
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

@MainActor
private final class RefresherHarness {
    enum Step { case refreshed, deferred, notNeeded, failure(Error) }
    var busy = false
    var outcomes: [Step] = []
    var refreshes = 0
    var labelUpdates = 0
    var finishedCalls = 0
    var failures: [String] = []
    var retryDelays: [TimeInterval] = []
    private var retries: [@MainActor @Sendable () -> Void] = []
    var pendingRetries: Int { retries.count }

    lazy var refresher = ScheduleRegistrationRefresher(
        isBusy: { [unowned self] in busy },
        refresh: { [unowned self] in
            refreshes += 1
            switch outcomes.isEmpty ? .notNeeded : outcomes.removeFirst() {
            case .refreshed: return .refreshed
            case .deferred: return .deferred
            case .notNeeded: return .notNeeded
            case .failure(let error): throw error
            }
        },
        scheduleRetry: { [unowned self] delay, work in retryDelays.append(delay); retries.append(work) },
        updateScheduleLabel: { [unowned self] in labelUpdates += 1 },
        reportFailure: { [unowned self] readable, _ in failures.append(readable) },
        onFinished: { [unowned self] in finishedCalls += 1 })

    func fireRetry() {
        guard !retries.isEmpty else { return }
        retries.removeFirst()()
    }
}
