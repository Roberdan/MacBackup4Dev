import Foundation

/// Runs a command without a shell (no .zshrc, no globbing) and captures its output.
/// Used for git, sqlite3 and pg_dump: tools whose failure must be reported, never hidden.
enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    static func run(_ executable: String, _ arguments: [String], cwd: String? = nil,
                    timeout: TimeInterval = 300, environment: [String: String]? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        // Never let git open an editor, ask for a password or page its output.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["GIT_EDITOR"] = "true"
        for (key, value) in environment ?? [:] { env[key] = value }
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Drain both pipes while the process runs: a full pipe would block it forever.
        final class Buffer: @unchecked Sendable { var data = Data(); let lock = NSLock() }
        let out = Buffer(), err = Buffer()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; out.lock.lock(); out.data.append(d); out.lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; err.lock.lock(); err.data.append(d); err.lock.unlock()
        }
        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: "\(executable): \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        var timedOut = false
        if process.isRunning { process.terminate(); timedOut = true }
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        out.lock.lock(); out.data.append(outPipe.fileHandleForReading.readDataToEndOfFile()); out.lock.unlock()
        err.lock.lock(); err.data.append(errPipe.fileHandleForReading.readDataToEndOfFile()); err.lock.unlock()
        let stderr = String(decoding: err.data, as: UTF8.self)
        return Result(status: timedOut ? -2 : process.terminationStatus,
                      stdout: String(decoding: out.data, as: UTF8.self),
                      stderr: timedOut ? "timeout dopo \(Int(timeout))s. \(stderr)" : stderr)
    }

    /// First existing executable among the candidates (Homebrew first: /usr/bin/git is a
    /// shim that pops the Command Line Tools installer on a Mac without them).
    static func find(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var git: String? {
        find(["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"])
    }
}
