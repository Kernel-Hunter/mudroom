#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

public struct CapturedOutput: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    /// Stopped by `capture`'s timeout.
    public var timedOut: Bool = false
}

/// Lets a timer stop a child that is waited on elsewhere.
private struct UncheckedProcess: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

public enum ProcessRunner {
    /// Runs a program to completion and captures its output.
    /// `environment` adds variables to the child's environment (on top of
    /// this process's), never to its arguments. With `timeout`, a program
    /// still running after that many seconds is stopped (SIGTERM, then
    /// SIGKILL) and the result has `timedOut` set.
    public static func capture(_ executable: String, _ arguments: [String], cwd: URL? = nil,
                               environment: [String: String] = [:], timeout: TimeInterval? = nil) throws -> CapturedOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let cwd { process.currentDirectoryURL = cwd }
        // Output goes to temp files rather than pipes: no reader threads, and
        // no deadlock when a child fills one pipe while we wait on the other.
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("mudroom-out-\(UUID().uuidString)")
        let errURL = tmp.appendingPathComponent("mudroom-err-\(UUID().uuidString)")
        _ = FileManager.default.createFile(atPath: outURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let timedOut = LockedBox(false)
        if let timeout {
            let pid = process.processIdentifier
            let finished = DispatchSemaphore(value: 0)
            // A thread of its own: with GCD's pool busy (many captures
            // waiting at once) the watchdog itself could wait its turn.
            Thread.detachNewThread {
                guard finished.wait(timeout: .now() + timeout) == .timedOut else { return }
                timedOut.value = true
                kill(pid, SIGTERM)
                if finished.wait(timeout: .now() + 3) == .timedOut { kill(pid, SIGKILL) }
            }
            process.waitUntilExit()
            finished.signal()
            finished.signal()
        } else {
            process.waitUntilExit()
        }
        return CapturedOutput(
            status: process.terminationStatus,
            stdout: String(decoding: try Data(contentsOf: outURL), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: errURL), as: UTF8.self),
            timedOut: timedOut.value
        )
    }

    /// Runs a program with this process's stdin/stdout/stderr (so TTYs pass
    /// straight through) and returns its exit status. SIGINT/SIGQUIT are
    /// ignored here while the child runs; the terminal delivers them to the
    /// child, which is in the same foreground process group. SIGTERM and
    /// SIGHUP are passed on to the child instead of killing this process,
    /// so the caller still gets to clean up (stop the sandbox, record the
    /// exit) when the terminal closes. `environment` adds variables to the
    /// child's environment only.
    ///
    /// Descriptors opened without O_CLOEXEC (the session's runner lock) are
    /// inherited by the child on purpose.
    public static func runAttached(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                                   killAfter: TimeInterval = 10) throws -> Int32 {
        let argv = [executable] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }

        let oldInt = signal(SIGINT, SIG_IGN)
        let oldQuit = signal(SIGQUIT, SIG_IGN)
        let oldTerm = signal(SIGTERM, forwardSignal)
        let oldHup = signal(SIGHUP, forwardSignal)
        defer {
            signal(SIGINT, oldInt)
            signal(SIGQUIT, oldQuit)
            signal(SIGTERM, oldTerm)
            signal(SIGHUP, oldHup)
            attachedChild = 0
            forwardedSignal = 0
        }

        // The child gets default signal handling back.
        #if canImport(Darwin)
        var attrs: posix_spawnattr_t? = nil
        #else
        var attrs = posix_spawnattr_t()
        #endif
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGQUIT)
        sigaddset(&defaults, SIGTERM)
        sigaddset(&defaults, SIGHUP)
        posix_spawnattr_setsigdefault(&attrs, &defaults)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSIGDEF))

        // Built from ProcessInfo rather than `environ`, which Swift 6 treats
        // as unsafe shared state on Linux.
        let env = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer { cEnv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, executable, nil, &attrs, cArgs, cEnv)
        guard rc == 0 else { throw MudroomError.posix("posix_spawn", executable, rc) }
        attachedChild = pid

        // A child that ignores the forwarded SIGTERM/SIGHUP (a `container
        // run` whose VM is stuck does) is killed after `killAfter` seconds,
        // so this process still gets to clean up and exit. Polled, because the
        // signal may be handled on another thread and not interrupt waitpid.
        var status: Int32 = 0
        var deadline: Date?
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { break }
            if r < 0 && errno != EINTR { throw MudroomError.posix("waitpid", executable, errno) }
            if deadline == nil, forwardedSignal != 0 { deadline = Date().addingTimeInterval(killAfter) }
            if let d = deadline, Date() >= d {
                kill(pid, SIGKILL)
                deadline = .distantFuture
            }
            usleep(50_000)
        }
        // WIFEXITED / WEXITSTATUS are macros Swift can't import.
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }
        return 128 + low
    }

    /// Runs a program to completion, handing each line of its output
    /// (stdout and stderr together) to `onLine` as it arrives. Returns the
    /// exit status and the last `keep` lines.
    @discardableResult
    public static func stream(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                              keep: Int = 40, onLine: @escaping @Sendable (String) -> Void) throws -> (status: Int32, tail: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Closed here so the read ends when the child (and its children) do.
        let reader = pipe.fileHandleForReading
        let tail = LockedBox<[String]>([])
        var partial = Data()
        func emit(_ line: Data) {
            // Progress bars redraw with \r; the last frame is the line.
            let text = String(decoding: line, as: UTF8.self).split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? ""
            onLine(text)
            var t = tail.value
            t.append(text)
            if t.count > keep { t.removeFirst(t.count - keep) }
            tail.value = t
        }
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            partial.append(chunk)
            while let nl = partial.firstIndex(of: 0x0A) {
                emit(partial[partial.startIndex..<nl])
                partial = Data(partial[partial.index(after: nl)...])
            }
        }
        if !partial.isEmpty { emit(partial) }
        process.waitUntilExit()
        return (process.terminationStatus, tail.value)
    }

    /// Finds an executable on PATH (plus Homebrew's usual prefixes).
    public static func which(_ name: String) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in dirs {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// The child `runAttached` is waiting for; signals are passed on to it.
nonisolated(unsafe) private var attachedChild: pid_t = 0
/// The last signal passed on to it (0: none yet).
nonisolated(unsafe) private var forwardedSignal: Int32 = 0

private let forwardSignal: @convention(c) (Int32) -> Void = { sig in
    let pid = attachedChild
    if pid > 0 {
        forwardedSignal = sig
        kill(pid, sig)
    }
}
