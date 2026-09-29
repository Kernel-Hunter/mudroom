import Darwin
import Foundation
import Testing
@testable import MudroomCore

@Suite("Per-hunk apply through the Applier")
struct HunkApplyTests {
    static let base = (1...40).map { "line \($0)\n" }.joined()

    /// Three separate hunks: line 3, line 20, line 38.
    static func edited(_ s: String) -> String {
        s.replacingOccurrences(of: "line 3\n", with: "line three\n")
            .replacingOccurrences(of: "line 20\n", with: "line twenty\nextra\n")
            .replacingOccurrences(of: "line 38\n", with: "")
    }

    func fixture() throws -> Fixture {
        let f = try Fixture { root in
            try write(Self.base, to: root.appendingPathComponent("src/file.txt"))
            try write("x\n", to: root.appendingPathComponent("other.txt"))
        }
        try write(Self.edited(Self.base), to: f.work.appendingPathComponent("src/file.txt"))
        try write("y\n", to: f.work.appendingPathComponent("other.txt"))
        return f
    }

    var target: (Fixture) -> URL { { $0.project.appendingPathComponent("src/file.txt") } }

    @Test("hunks are numbered and exposed for modified text files")
    func listing() throws {
        let f = try fixture()
        let applier = Applier(handle: f.handle)
        let change = try #require(try f.diff().changes.first { $0.path == "src/file.txt" })
        let hunks = try #require(try applier.hunks(for: change))
        #expect(hunks.map(\.id) == [1, 2, 3])
        #expect(try applier.appliedHunks(for: change).isEmpty)
    }

    @Test("apply one hunk, then the rest, then undo step by step")
    func incremental() throws {
        let f = try fixture()
        let applier = Applier(handle: f.handle)
        let first = try applier.applyHunks(path: "src/file.txt", hunks: [2])
        #expect(first.applied == ["src/file.txt"])
        let afterFirst = try read(target(f))
        #expect(afterFirst.contains("line twenty\nextra\n"))
        #expect(afterFirst.contains("line 3\n") && afterFirst.contains("line 38\n"))

        let change = try #require(try f.diff().changes.first { $0.path == "src/file.txt" })
        #expect(try applier.appliedHunks(for: change) == [2])

        // Earlier partial apply is not a conflict for the next one.
        let second = try applier.applyHunks(path: "src/file.txt", hunks: [1])
        #expect(second.conflicts.isEmpty)
        let expected = Self.base.replacingOccurrences(of: "line 3\n", with: "line three\n")
            .replacingOccurrences(of: "line 20\n", with: "line twenty\nextra\n")
        #expect(try read(target(f)) == expected)

        // A whole-path apply after partial ones is fine too.
        let rest = try applier.apply(paths: ["src/file.txt"])
        #expect(rest.conflicts.isEmpty)
        #expect(try read(target(f)) == Self.edited(Self.base))

        _ = try applier.undo()
        #expect(try applier.appliedHunks(for: change) == [1, 2])
        _ = try applier.undo()
        #expect(try read(target(f)) == afterFirst)
        _ = try applier.undo()
        #expect(try read(target(f)) == Self.base)
        #expect(!applier.canUndo)
    }

    @Test("selecting every hunk equals a whole-file apply and keeps the work mode")
    func allHunks() throws {
        let f = try fixture()
        chmod(f.work.appendingPathComponent("src/file.txt").path, 0o755)
        let report = try Applier(handle: f.handle).applyHunks(path: "src/file.txt", hunks: [1, 2, 3])
        #expect(report.applied == ["src/file.txt"])
        #expect(try read(target(f)) == Self.edited(Self.base))
        #expect(try modeOf(target(f)) == 0o755)
        #expect(try Applier(handle: f.handle).apply(paths: ["src/file.txt"]).alreadyApplied == ["src/file.txt"])
    }

    @Test("a human edit to the file is a conflict and nothing is written")
    func conflict() throws {
        let f = try fixture()
        try write(Self.base + "mine\n", to: target(f))
        let report = try Applier(handle: f.handle).applyHunks(path: "src/file.txt", hunks: [1])
        #expect(report.conflicts.map(\.path) == ["src/file.txt"])
        #expect(try read(target(f)) == Self.base + "mine\n")
        #expect(report.bundle == nil)
    }

    @Test("unknown hunk ids and non-text paths are rejected")
    func invalid() throws {
        let f = try fixture()
        let applier = Applier(handle: f.handle)
        #expect(throws: MudroomError.self) { try applier.applyHunks(path: "src/file.txt", hunks: [9]) }
        try write("new\n", to: f.work.appendingPathComponent("added.txt"))
        #expect(try applier.applyHunks(path: "added.txt", hunks: [1]).skipped.count == 1)
        #expect(try applier.applyHunks(path: "missing.txt", hunks: [1]).skipped.count == 1)
    }

    @Test("CRLF file stays CRLF after a partial apply")
    func crlfOnDisk() throws {
        let crlf = (1...30).map { "row \($0)\r\n" }.joined()
        let f = try Fixture { root in try write(crlf, to: root.appendingPathComponent("win.txt")) }
        let edited = crlf.replacingOccurrences(of: "row 2\r\n", with: "row 2b\r\n")
            .replacingOccurrences(of: "row 28\r\n", with: "row 28b\r\n")
        try write(edited, to: f.work.appendingPathComponent("win.txt"))
        _ = try Applier(handle: f.handle).applyHunks(path: "win.txt", hunks: [2])
        let out = try read(f.project.appendingPathComponent("win.txt"))
        #expect(out == crlf.replacingOccurrences(of: "row 28\r\n", with: "row 28b\r\n"))
    }

    @Test("preflight reports conflicts and planned paths without writing")
    func preflight() throws {
        let f = try fixture()
        try write("changed by me\n", to: f.project.appendingPathComponent("other.txt"))
        let report = try Applier(handle: f.handle).preflight()
        #expect(report.applied == ["src/file.txt"])
        #expect(report.conflicts.map(\.path) == ["other.txt"])
        #expect(report.bundle == nil)
        #expect(try read(target(f)) == Self.base)
        #expect(!exists(f.handle.rollbackRoot))
    }
}
