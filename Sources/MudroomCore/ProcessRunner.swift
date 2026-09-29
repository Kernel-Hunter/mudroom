import Darwin
import Foundation

public struct CapturedOutput: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum ProcessRunner {
    /// Runs a program to completion and captures its output.
    public static func capture(_ executable: String, _ arguments: [String], cwd: URL? = nil) throws -> CapturedOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        // Output goes to temp files rather than pipes: no reader threads, and
        // no deadlock when a child fills one pipe while we wait on the other.
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("mudroom-out-\(UUID().uuidString)")
        let errURL = tmp.appendingPathComponent("mudroom-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
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
        process.waitUntilExit()
        return CapturedOutput(
            status: process.terminationStatus,
            stdout: String(decoding: try Data(contentsOf: outURL), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: errURL), as: UTF8.self)
        )
    }

    /// Runs a program with this process's stdin/stdout/stderr (so TTYs pass
    /// straight through) and returns its exit status. SIGINT/SIGQUIT are
    /// ignored here while the child runs; the terminal delivers them to the
    /// child, which is in the same foreground process group.
    public static func runAttached(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let argv = [executable] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }

        let oldInt = signal(SIGINT, SIG_IGN)
        let oldQuit = signal(SIGQUIT, SIG_IGN)
        defer {
            signal(SIGINT, oldInt)
            signal(SIGQUIT, oldQuit)
        }

        // The child gets default signal handling back.
        var attrs = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGQUIT)
        posix_spawnattr_setsigdefault(&attrs, &defaults)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSIGDEF))

        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, executable, nil, &attrs, cArgs, environ)
        guard rc == 0 else { throw MudroomError.posix("posix_spawn", executable, rc) }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { throw MudroomError.posix("waitpid", executable, errno) }
        }
        // WIFEXITED / WEXITSTATUS are macros Swift can't import.
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }
        return 128 + low
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
