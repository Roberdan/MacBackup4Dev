import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

func fail(_ message: String) throws {
    throw TestFailure.failed(message)
}

@discardableResult
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws -> Bool {
    if try !condition() {
        throw TestFailure.failed(message)
    }
    return true
}

func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, _ message: String) throws {
    let lhs = try actual()
    let rhs = try expected()
    if lhs != rhs {
        throw TestFailure.failed("\(message) (got: \(lhs), expected: \(rhs))")
    }
}

func expectNil<T>(_ value: @autoclosure () -> T?, _ message: String) throws {
    if value() != nil {
        throw TestFailure.failed(message)
    }
}

func expectNotNil<T>(_ value: @autoclosure () -> T?, _ message: String) throws {
    if value() == nil {
        throw TestFailure.failed(message)
    }
}

/// Holds a value produced inside a `Task` so a synchronous test can read it after
/// waiting. A captured `var` is a concurrency error under Swift 6 checking.
final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

struct AppTestFixture {
    let box: SafetyTests.Sandbox
    let roots: [AppInventory.Root]
    var config: Config
    var restoreHome: String { box.root.appendingPathComponent("new-home").path }
    var restoreRoots: [AppInventory.Root] {
        [AppInventory.Root(kind: .system, url: box.root.appendingPathComponent("new-apps")),
         AppInventory.Root(kind: .user, url: URL(fileURLWithPath: restoreHome + "/Applications"))]
    }

    init() throws {
        let safety = SafetyTests()
        box = try safety.makeSandbox()
        roots = [AppInventory.Root(kind: .system, url: box.root.appendingPathComponent("apps")),
                 AppInventory.Root(kind: .user, url: URL(fileURLWithPath: box.home + "/Applications"))]
        config = safety.config(box, sources: ["data"])
        try FileManager.default.createDirectory(at: roots[0].url, withIntermediateDirectories: true)
        try safety.write("document", to: box.home + "/data/document.txt")
        try FileManager.default.createDirectory(atPath: restoreHome, withIntermediateDirectories: true)
    }

    func cleanup() { SafetyTests().cleanup(box) }

    func write(_ text: String, _ path: String) throws { try SafetyTests().write(text, to: path) }

    @discardableResult
    func app(_ path: String = "Shoji.app", identifier: String = "com.example.shoji",
             root: AppInventory.Root.Kind = .system, signed: Bool = false) throws -> URL {
        let app = roots.first { $0.kind == root }!.url.appendingPathComponent(path)
        let info = ["CFBundleIdentifier": identifier, "CFBundleName": "Shoji",
                    "CFBundleExecutable": "Shoji", "CFBundlePackageType": "APPL",
                    "CFBundleShortVersionString": "1.2.2", "CFBundleVersion": "12"]
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = app.appendingPathComponent("Contents/MacOS/Shoji")
        if signed {
            try AppBundleCopy.copyRegularFile(from: "/usr/bin/true", to: executable.path)
            let result = Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
            try expect(result.ok, "signing the sandbox app: \(result.stderr)")
        } else {
            try write("#!/bin/sh\nexit 0\n", executable.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return app
    }

    func run(config: Config? = nil, configure: (inout BackupRunOptions) -> Void = { _ in }) throws -> BackupRunResult? {
        var options = BackupRunOptions(home: box.home, captureEnvironment: false, captureGit: false,
                                       captureDatabases: false, auditCoverage: false,
                                       applicationRoots: roots, applicationInstallers: [:])
        configure(&options)
        let runOptions = options
        let configuration = config ?? self.config
        let result = ResultBox<Result<BackupRunResult?, Error>>()
        let done = DispatchSemaphore(value: 0)
        Task {
            do { result.value = .success(try await BackupEngine.run(config: configuration,
                statusWriter: StatusWriter(directory: box.state), options: runOptions)) }
            catch { result.value = .failure(error) }
            done.signal()
        }
        guard done.wait(timeout: .now() + 120) == .success else { throw TestFailure.failed("app backup timed out") }
        return try result.value!.get()
    }

    func backup(config: Config? = nil, configure: (inout BackupRunOptions) -> Void = { _ in }) throws -> BackupRunResult {
        guard let result = try run(config: config, configure: configure) else { throw TestFailure.failed("backup cancelled") }
        return result
    }
}
