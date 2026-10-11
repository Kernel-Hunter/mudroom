#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif
import Foundation

#if !os(Windows)
/// A program running on a pseudo-terminal, so tools that only work in a
/// terminal (sign-in flows drawn with Ink and friends) can be driven and
/// read from code. The terminal is made very wide so long links and tokens
/// come out on one line instead of being wrapped.
public final class PtyProcess: @unchecked Sendable {
    public let process = Process()
    private let master: Int32
    private let lock = NSLock()
    private var output = Data()
    private var readerDone = DispatchSemaphore(value: 0)
    /// Called on a background thread with each chunk of raw output.
    public var onOutput: (@Sendable (Data) -> Void)?

    public static let columns: UInt16 = 1000

    public init(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                cwd: URL? = nil) throws {
        let (m, slavePath) = try Self.openMaster(executable)
        let s = open(slavePath, O_RDWR | O_NOCTTY)
        guard s >= 0 else {
            let e = errno
            close(m)
            throw MudroomError.posix("open", slavePath, e)
        }
        var ws = winsize(ws_row: 50, ws_col: Self.columns, ws_xpixel: 0, ws_ypixel: 0)
        #if os(Linux)
        _ = ioctl(m, UInt(0x5414), &ws)  // TIOCSWINSZ
        #else
        _ = ioctl(m, TIOCSWINSZ, &ws)
        #endif
        master = m
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = env["TERM"].flatMap { $0 == "dumb" ? nil : $0 } ?? "xterm-256color"
        env["COLUMNS"] = String(Self.columns)
        env["LINES"] = "50"
        env.merge(environment) { _, new in new }
        process.environment = env
        let slave = FileHandle(fileDescriptor: s, closeOnDealloc: true)
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        do {
            try process.run()
        } catch {
            close(m)
            throw error
        }
        // The child has its own copy now.
        try? slave.close()
        let t = Thread { [self] in readLoop() }
        t.name = "mudroom.pty"
        t.start()
    }

    /// A new pseudo-terminal: the master descriptor and the slave's path.
    static func openMaster(_ what: String) throws -> (Int32, String) {
        #if os(Linux)
        // Glibc's Swift module leaves out posix_openpt and friends; these
        // are the ioctls they wrap (devpts needs no grantpt).
        let m = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard m >= 0 else { throw MudroomError.posix("open", "/dev/ptmx", errno) }
        var unlock: Int32 = 0
        var n: UInt32 = 0
        guard ioctl(m, UInt(0x4004_5431), &unlock) == 0, ioctl(m, UInt(0x8004_5430), &n) == 0 else {  // TIOCSPTLCK, TIOCGPTN
            let e = errno
            close(m)
            throw MudroomError.posix("ioctl", what, e)
        }
        return (m, "/dev/pts/\(n)")
        #else
        let m = posix_openpt(O_RDWR | O_NOCTTY)
        guard m >= 0 else { throw MudroomError.posix("posix_openpt", what, errno) }
        guard grantpt(m) == 0, unlockpt(m) == 0, let name = ptsname(m) else {
            let e = errno
            close(m)
            throw MudroomError.posix("grantpt", what, e)
        }
        return (m, String(cString: name))
        #endif
    }

    private func readLoop() {
        defer { readerDone.signal() }
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(master, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            // EIO once the child side is closed.
            if n <= 0 { return }
            let data = Data(buf[0..<n])
            lock.withLock { output.append(data) }
            onOutput?(data)
        }
    }

    /// Everything printed so far.
    public var allOutput: Data { lock.withLock { output } }

    /// Types into the terminal, as if pasted.
    public func send(_ text: String) {
        let bytes = Array(text.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            off += n
        }
    }

    /// Sends text and then Enter. Some prompts treat a newline arriving in
    /// the same read as part of a paste, so Enter goes separately.
    public func sendLine(_ text: String) {
        send(text)
        usleep(150_000)
        send("\r")
    }

    public var isRunning: Bool { process.isRunning }

    /// Waits for the program to exit and the output to be drained.
    public func wait() -> Int32 {
        process.waitUntilExit()
        _ = readerDone.wait(timeout: .now() + 2)
        return process.terminationStatus
    }

    /// Stops the program (SIGTERM, then SIGKILL after a moment).
    public func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.process.isRunning == true { kill(pid, SIGKILL) }
        }
    }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        close(master)
    }
}
#else
/// Not on Windows yet (it would need a ConPTY): `init` throws, so the
/// sign-in flows that drive a terminal program say so instead.
public final class PtyProcess: @unchecked Sendable {
    public let process = Process()
    public var onOutput: (@Sendable (Data) -> Void)?
    public static let columns: UInt16 = 1000

    public init(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                cwd: URL? = nil) throws {
        throw MudroomError.invalid("running \((executable as NSString).lastPathComponent) on a terminal of its own isn't supported on Windows yet")
    }

    public var allOutput: Data { Data() }
    public func send(_ text: String) {}
    public func sendLine(_ text: String) {}
    public var isRunning: Bool { false }
    public func wait() -> Int32 { -1 }
    public func terminate() {}
}
#endif
