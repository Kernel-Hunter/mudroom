#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif
import Foundation
import Testing
@testable import MudroomCore

/// Peak resident memory of this process so far, in MB.
func peakRSSMB() -> Int {
    #if os(Windows)
    var c = PROCESS_MEMORY_COUNTERS()
    c.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
    guard K32GetProcessMemoryInfo(GetCurrentProcess(), &c, c.cb) else { return 0 }
    return Int(c.PeakWorkingSetSize) >> 20
    #else
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

/// Apply and undo on a generated session of MUDROOM_PERF_APPLY files
/// (node_modules-shaped: many small files in nested folders):
///   MUDROOM_PERF_APPLY=40000 swift test -c release --filter PerfApply
@Suite("PerfApply", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MUDROOM_PERF_APPLY"] != nil))
struct PerfApplyTests {
    @Test("apply --all and undo on many added files")
    func applyMany() throws {
        let n = Int(ProcessInfo.processInfo.environment["MUDROOM_PERF_APPLY"]!) ?? 40_000
        let f = try Fixture { try write("{}\n", to: $0.appendingPathComponent("package.json")) }
        for i in 0..<n {
            let url = f.work.appendingPathComponent("node_modules/pkg\(i / 100)/lib/d\(i % 10)/file\(i).js")
            try write("module.exports = \(i);\n", to: url)
        }
        var t = Date()
        let report = try Applier(handle: f.handle).apply(paths: nil)
        print("PERF apply --all: \(report.applied.count) paths, \(String(format: "%.2f", Date().timeIntervalSince(t))) s, peak RSS \(peakRSSMB()) MB")
        #expect(report.conflicts.isEmpty)
        t = Date()
        _ = try Applier(handle: f.handle).undo()
        print("PERF undo: \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
    }
}
