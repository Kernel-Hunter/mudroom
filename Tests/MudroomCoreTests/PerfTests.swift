#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import MudroomCore

/// Peak resident memory of this process so far, in MB.
func peakRSSMB() -> Int {
    var u = rusage()
    #if canImport(Glibc)
    getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &u)
    #else
    getrusage(RUSAGE_SELF, &u)
    #endif
    #if canImport(Darwin)
    return Int(u.ru_maxrss) >> 20
    #else
    return Int(u.ru_maxrss) >> 10
    #endif
}

/// Timings on a large session. Point MUDROOM_PERF_SESSION at a session
/// directory (scripts or a generator make one) and run in release:
///   MUDROOM_PERF_SESSION=<dir> swift test -c release --filter Perf
@Suite("Performance", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MUDROOM_PERF_SESSION"] != nil))
struct PerfTests {
    func handle() throws -> SessionHandle {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MUDROOM_PERF_SESSION"]!)
        return SessionHandle(directory: dir, session: try SessionStore.decode(Data(contentsOf: dir.appendingPathComponent("session.json"))))
    }

    @Test("diff, review load and selection on a big session")
    func appLoad() throws {
        let h = try handle()
        var t = Date()
        let diff = try Differ.compare(base: h.base, work: h.work)
        print("PERF Differ.compare: \(diff.changes.count) changes, \(String(format: "%.2f", Date().timeIntervalSince(t))) s, peak RSS \(peakRSSMB()) MB")
        t = Date()
        let snap = try ReviewSnapshot.load(h)
        print("PERF ReviewSnapshot.load: \(snap.files.count) rows, \(snap.folders.count) collapsed folders, \(String(format: "%.2f", Date().timeIntervalSince(t))) s, peak RSS \(peakRSSMB()) MB")
        var sel = ReviewSelection()
        for f in snap.files { sel.setDefault(f) }
        t = Date()
        let p = sel.pending(snap)
        print("PERF pending selection: \(p.paths.count) paths, \(String(format: "%.3f", Date().timeIntervalSince(t))) s")
        #expect(p.rowCount <= snap.files.count)
    }
}
