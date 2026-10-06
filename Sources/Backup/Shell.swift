import Foundation
import Darwin

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
        // Never let git open an editor, ask for a password or page its output, and keep
        // messages in English: the code parses some of them ("The bundle requires…").
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["GIT_EDITOR"] = "true"
        env["LC_ALL"] = "C"
        for (key, value) in environment ?? [:] { env[key] = value }
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Drain both pipes while the process runs: a full pipe would block it forever.
        // Handlers run serially per handle, so chunks keep their order.
        final class Buffer: @unchecked Sendable {
            var data = Data(); let lock = NSLock(); var lastWrite = Date()
            func append(_ d: Data) { lock.lock(); data.append(d); lastWrite = Date(); lock.unlock() }
            func snapshot() -> (Data, Date) { lock.lock(); defer { lock.unlock() }; return (data, lastWrite) }
        }
        let out = Buffer(), err = Buffer()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { out.append(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { err.append(d) }
        }
        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return Result(status: -1, stdout: "", stderr: "\(executable): \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            let grace = Date().addingTimeInterval(5)
            while process.isRunning && Date() < grace { usleep(20_000) }
            // A process that ignores SIGTERM must not hang the backup's finalization.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        // Let the handlers collect what is still in the pipes, without a blocking read: a
        // grandchild (ssh ControlMaster, git daemon) may keep the pipe open forever.
        usleep(100_000)  // output written just before exit is still on its way to the handlers
        let settle = Date().addingTimeInterval(1)
        while Date() < settle {
            let quietOut = Date().timeIntervalSince(out.snapshot().1) > 0.1
            let quietErr = Date().timeIntervalSince(err.snapshot().1) > 0.1
            if quietOut && quietErr { break }
            usleep(20_000)
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let stderr = String(decoding: err.snapshot().0, as: UTF8.self)
        return Result(status: timedOut ? -2 : process.terminationStatus,
                      stdout: String(decoding: out.snapshot().0, as: UTF8.self),
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
