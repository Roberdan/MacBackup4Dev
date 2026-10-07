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
                    timeout: TimeInterval = 300, environment: [String: String]? = nil,
                    stdin: String? = nil) -> Result {
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
        // stdin: secrets (a disk image password) go here, never in the arguments, which
        // anyone on the Mac can read in the process list.
        let inPipe = stdin.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice

        // Drain both pipes while the process runs: a full pipe would block it forever.
        // Handlers run serially per handle, so chunks keep their order.
        final class Buffer: @unchecked Sendable {
            var data = Data(); let lock = NSLock()
            func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
            func snapshot() -> (Data, Date) { lock.lock(); defer { lock.unlock() }; return (data, Date()) }
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
            if let inPipe, let stdin {
                inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                try? inPipe.fileHandleForWriting.close()
            }
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
        // The writer has exited, so everything it wrote is already in the pipe buffers.
        // Stop the handlers, let an in-flight one finish, then drain each pipe without
        // blocking (a grandchild such as an ssh ControlMaster may keep the pipe open):
        // nothing is cut by a timing guess (review R2).
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        usleep(30_000)
        drainNonBlocking(outPipe.fileHandleForReading.fileDescriptor, into: out.append)
        drainNonBlocking(errPipe.fileHandleForReading.fileDescriptor, into: err.append)
        let stderr = String(decoding: err.snapshot().0, as: UTF8.self)
        return Result(status: timedOut ? -2 : process.terminationStatus,
                      stdout: String(decoding: out.snapshot().0, as: UTF8.self),
                      stderr: timedOut ? "timeout dopo \(Int(timeout))s. \(stderr)" : stderr)
    }

    private static func drainNonBlocking(_ fd: Int32, into sink: (Data) -> Void) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { sink(Data(buffer[0..<n])); continue }
            break   // 0 = EOF, -1 = EAGAIN (nothing left) or error
        }
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
