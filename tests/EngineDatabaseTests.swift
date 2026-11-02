import Foundation

final class EngineDatabaseTests {
    let safety = SafetyTests()
    let profile = "Library/Application Support/Copilot/Default"

    func test_recognisesOnlyKnownEngineDatabasesInsideAChromiumProfile() throws {
        let home = "/Users/x"
        let marked: (String) -> Bool = { $0.hasSuffix("/Local State") }
        func engine(_ p: String, _ exists: (String) -> Bool = marked) -> Bool { EngineInternalDatabases.isInternal(p, fileExists: exists) }
        try expect(engine("\(home)/\(profile)/declarative_performance_observer.db"), "Copilot telemetry")
        try expect(engine("\(home)/Library/Application Support/Microsoft Edge/Profile 2/EdgeHubAppUsageSQLite.db"), "Edge profile")
        try expect(engine("\(home)/\(profile)/Load_Statistics.db"), "name match ignores case")
        try expect(!engine("\(home)/\(profile)/notes.db"), "an unknown database is the user's")
        try expect(!engine("\(home)/GitHub/app/load_statistics.db"), "outside a profile it is a project file")
        try expect(!engine("\(home)/GitHub/Default/load_statistics.db", { _ in false }), "a folder called Default without Local State")
        try expect(!engine("\(home)/Library/Application Support/App/load_statistics.db"), "Application Support alone is not a profile")
        try expect(!engine("\(home)/Library/Application Support/persisted_state.db"), "its root neither")
        try expect(!engine("\(home)/\(profile)/../../x/Default/load_statistics.db"), "no dot parts")
        try expect(!engine("\(home)/\(profile)/load_statistics.db", { _ in false }), "no Local State, no profile")
    }

    func test_discoveryNeverProposesEngineDatabases() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let url = box.root.appendingPathComponent("config.toml")
        try safety.config(box, sources: ["Library/Application Support/Copilot"]).save(to: url)
        let engineDB = box.home + "/\(profile)/declarative_performance_observer.db"
        let real = box.home + "/\(profile)/notes.db"
        for path in [engineDB, real] { try safety.write("sqlite", to: path) }
        try safety.write("{}", to: box.home + "/Library/Application Support/Copilot/Local State")
        let config = try Config.load(from: url)
        let found = CoverageAuditor.audit(config: config, home: box.home, measuringSizes: false).map(\.path)
        try expect(found.contains { $0.hasSuffix("notes.db") }, "a real database is still proposed: \(found)")
        try expect(!found.contains { $0.hasSuffix("declarative_performance_observer.db") }, "engine database not proposed: \(found)")
        let gap = CoverageGap(kind: .database, path: ConfigDiscovery.contract(engineDB, home: box.home),
                              lastModified: "", approximateBytes: 1)
        try expect(!AutomaticCoverage.Admission(config: config, home: box.home).admits(gap), "admission refuses it too")
    }

    func test_savedEngineDatabasesAreIgnoredAndCleanedFromTheSettings() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let url = box.root.appendingPathComponent("config.toml")
        var config = safety.config(box, sources: ["existing"])
        config.databases.sqlite = ["~/\(profile)/load_statistics.db", "~/x/history.db"]
        try config.save(to: url)
        try safety.write("data", to: box.home + "/existing/a.txt")
        try safety.write("{}", to: box.home + "/Library/Application Support/Copilot/Local State")
        let kept = DatabaseDumps.captureAll(config: config.databases, home: box.home,
                                            into: box.root.appendingPathComponent("snap"))
        try expectEqual(kept.map(\.source), ["~/x/history.db"], "the engine database is not captured, nor reported")
        let prepared = try AutomaticCoverage.prepareReporting(from: url, home: box.home)
        try expectEqual(prepared.config.databases.sqlite, ["~/x/history.db"], "cleaned from the prepared settings")
        try expectEqual(try Config.load(from: url).databases.sqlite, ["~/x/history.db"], "and from the saved file")
    }

    func test_aLockedUserDatabaseStaysAnError() throws {
        guard let sqlite3 = DatabaseDumps.sqlite3 else { return }
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let db = box.home + "/\(profile)/notes.db"
        try safety.write("{}", to: box.home + "/Library/Application Support/Copilot/Local State")
        try safety.write("", to: db)
        try FileManager.default.removeItem(atPath: db)
        try expect(Shell.run(sqlite3, [db, "create table t(a); insert into t values(1);"]).ok, "database created")
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-c", "import sqlite3,time,sys\nc=sqlite3.connect(sys.argv[1],isolation_level=None)\nc.execute('begin exclusive')\nprint('ok',flush=True)\ntime.sleep(40)", db]
        let pipe = Pipe()
        holder.standardOutput = pipe
        try holder.run()
        defer { holder.terminate() }
        _ = pipe.fileHandleForReading.availableData
        let records = DatabaseDumps.captureAll(config: DatabaseConfig(sqlite: ["~/\(profile)/notes.db"]), home: box.home,
                                               into: box.root.appendingPathComponent("snap"))
        try expectEqual(records.count, 1, "the user's database is still captured")
        try expect(records[0].file == nil && records[0].error != nil, "its lock is reported, never hidden: \(records[0])")
    }
}
