// POSIX signals and descriptors; WindowsTests covers runAttached on Windows.
#if !os(Windows)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import Testing
@testable import MudroomCore

/// Serialized: `runAttached` swaps this process's signal handlers while it
/// runs, so two at once could leave SIGTERM unhandled for the other.
@Suite("Child processes", .serialized)
struct ProcessRunnerTests {
    /// A shell that survives this only had SIGTERM blocked when it started.
    static let killsItself = ["-c", "kill -TERM $$; echo survived"]

    @Test("capture's child starts with no signals blocked, whatever thread starts it")
    func captureUnblocksSignals() throws {
        let out = try onThreadBlockingSIGTERM { try ProcessRunner.capture("/bin/sh", Self.killsItself) }
        #expect(out.status == SIGTERM)
        #expect(out.stdout.isEmpty)

        // So the timeout's SIGTERM stops it, rather than the SIGKILL 3 s later.
        let slept = try onThreadBlockingSIGTERM { try ProcessRunner.capture("/bin/sleep", ["30"], timeout: 0.5) }
        #expect(slept.timedOut)
        #expect(slept.status == SIGTERM)
    }

    @Test("stream's child starts with no signals blocked, whatever thread starts it")
    func streamUnblocksSignals() throws {
        let r = try onThreadBlockingSIGTERM { try ProcessRunner.stream("/bin/sh", Self.killsItself) { _ in } }
        #expect(r.status == SIGTERM)
        #expect(r.tail.isEmpty)
    }

    @Test("runAttached's child starts with no signals blocked, whatever thread starts it")
    func attachedUnblocksSignals() throws {
        let status = try onThreadBlockingSIGTERM { try ProcessRunner.runAttached("/bin/sh", Self.killsItself) }
        #expect(status == 128 + SIGTERM)
    }

    @Test("a child that ignores the forwarded SIGTERM (a stuck `container run`) is killed after a grace period")
    func attachedChildKilledAfterGrace() throws {
        let start = Date()
        Thread.detachNewThread { usleep(500_000); kill(getpid(), SIGTERM) }
        let status = try ProcessRunner.runAttached("/bin/sh", ["-c", "trap '' TERM HUP; sleep 30"], killAfter: 0.5)
        #expect(status == 128 + SIGKILL)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    #if os(Linux)
    /// Foundation's Process on Linux sees its child exit when every copy of
    /// a socket it hands the child is closed. A copy leaked into a sandbox
    /// process that outlives the child kept `capture` waiting for that
    /// process instead.
    @Test("runAttached's child inherits the runner lock but not other open descriptors")
    func attachedChildGetsOnlyTheLock() throws {
        var stray: [Int32] = [0, 0]
        #expect(pipe(&stray) == 0)
        defer { stray.forEach { close($0) } }
        var info = stat()
        #expect(fstat(stray[0], &info) == 0)
        let tmp = try TempDir()
        let lockURL = tmp.path("runner.lock")
        let lock = try #require(FileLock.tryAcquire(lockURL, inheritable: true))
        defer { lock.release() }

        // The child lists its descriptors: "lrwx------ … 3 -> /path", one per line.
        let listing = tmp.path("fds")
        let status = try ProcessRunner.runAttached("/bin/sh", ["-c", "exec ls -l /proc/self/fd > \"$OUT\""],
                                                   environment: ["OUT": listing.path])
        #expect(status == 0)
        let targets = try read(listing).split(separator: "\n").compactMap { line -> String? in
            let parts = line.components(separatedBy: " -> ")
            guard parts.count == 2, let fd = parts[0].split(separator: " ").last.flatMap({ Int($0) }), fd > 2 else { return nil }
            return parts[1]
        }
        #expect(targets.contains(lockURL.path))
        #expect(!targets.contains("pipe:[\(info.st_ino)]"))
    }
    #endif
}

/// Runs `body` on a thread of its own with SIGTERM blocked, as libdispatch's
/// worker threads on Linux have it (and a child inherits it).
private func onThreadBlockingSIGTERM<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
    let result = LockedBox<Result<T, any Error>?>(nil)
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, SIGTERM)
        pthread_sigmask(SIG_BLOCK, &set, nil)
        result.value = Result { try body() }
        done.signal()
    }
    done.wait()
    return try result.value!.get()
}
#endif
