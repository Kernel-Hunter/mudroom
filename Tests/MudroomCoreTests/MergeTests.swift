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
import Testing
@testable import MudroomCore

@Suite("Three-way merge (LineDiff.merge)")
struct LineMergeTests {
    func merge(_ base: String, _ ours: String, _ theirs: String) -> MergeResult {
        LineDiff.merge(base: TextLines(Data(base.utf8)), ours: TextLines(Data(ours.utf8)), theirs: TextLines(Data(theirs.utf8)))
    }

    func clean(_ r: MergeResult) -> String? {
        if case .clean(let lines) = r { return String(decoding: lines.data, as: UTF8.self) }
        return nil
    }

    static let base = (1...20).map { "line \($0)\n" }.joined()

    @Test("changes in different places merge, both kept")
    func separate() {
        let ours = Self.base.replacingOccurrences(of: "line 2\n", with: "line two\n")
        let theirs = Self.base.replacingOccurrences(of: "line 15\n", with: "line fifteen\nmore\n")
        let want = ours.replacingOccurrences(of: "line 15\n", with: "line fifteen\nmore\n")
        #expect(clean(merge(Self.base, ours, theirs)) == want)
        // Which side is which doesn't change the result.
        #expect(clean(merge(Self.base, theirs, ours)) == want)
    }

    @Test("the same line changed two ways is a conflict at that line")
    func overlap() {
        let ours = Self.base.replacingOccurrences(of: "line 7\n", with: "mine\n")
        let theirs = Self.base.replacingOccurrences(of: "line 7\n", with: "agent\n")
        #expect(merge(Self.base, ours, theirs) == .conflict([6..<7]))
    }

    @Test("changes on neighbouring lines touch and are a conflict")
    func touching() {
        let ours = Self.base.replacingOccurrences(of: "line 7\n", with: "mine\n")
        let theirs = Self.base.replacingOccurrences(of: "line 8\n", with: "agent\n")
        #expect(merge(Self.base, ours, theirs) == .conflict([6..<8]))
        // One unchanged line between them is enough.
        let apart = Self.base.replacingOccurrences(of: "line 9\n", with: "agent\n")
        #expect(clean(merge(Self.base, ours, apart)) != nil)
    }

    @Test("both sides making the same change is taken once")
    func same() {
        let both = Self.base.replacingOccurrences(of: "line 4\n", with: "fixed\n")
        #expect(clean(merge(Self.base, both, both)) == both)
        let ours = both.replacingOccurrences(of: "line 18\n", with: "ours\n")
        let theirs = both.replacingOccurrences(of: "line 1\n", with: "theirs\n")
        #expect(clean(merge(Self.base, ours, theirs)) == ours.replacingOccurrences(of: "line 1\n", with: "theirs\n"))
    }

    @Test("CRLF lines stay CRLF; a line-ending switch is a change like any other")
    func crlf() {
        let base = (1...12).map { "row \($0)\r\n" }.joined()
        let ours = base.replacingOccurrences(of: "row 2\r\n", with: "row 2b\r\n")
        let theirs = base.replacingOccurrences(of: "row 11\r\n", with: "row 11b\r\n")
        #expect(clean(merge(base, ours, theirs)) == ours.replacingOccurrences(of: "row 11\r\n", with: "row 11b\r\n"))
        // The whole file converted to LF on one side, an edit on the other: overlap.
        let lf = base.replacingOccurrences(of: "\r\n", with: "\n")
        if case .clean = merge(base, lf, theirs) { Issue.record("a line-ending switch merged with an edit") }
    }

    @Test("a missing final newline is kept, and adding one is a change")
    func finalNewline() {
        let base = "a\nb\nc\nd\ne"
        #expect(clean(merge(base, "A\nb\nc\nd\ne", "a\nb\nc\nd\nE")) == "A\nb\nc\nd\nE")
        #expect(clean(merge(base, "A\nb\nc\nd\ne", "a\nb\nc\nd\ne\n")) == "A\nb\nc\nd\ne\n")
        if case .clean = merge(base, "a\nb\nc\nd\ne\n", "a\nb\nc\nd\nE") { Issue.record("two changes to the last line merged") }
    }

    @Test("empty files: two different additions conflict, identical ones merge")
    func empty() {
        #expect(merge("", "x\n", "y\n") == .conflict([0..<0]))
        #expect(clean(merge("", "x\n", "x\n")) == "x\n")
        #expect(clean(merge("a\n", "", "a\n")) == "")
        #expect(clean(merge("", "", "")) == "")
    }

    @Test("the result is deterministic")
    func deterministic() {
        let ours = Self.base.replacingOccurrences(of: "line 3\n", with: "")
        let theirs = Self.base + "tail\n"
        #expect(merge(Self.base, ours, theirs) == merge(Self.base, ours, theirs))
    }
}

@Suite("Apply merges files that changed in the project too")
struct MergeApplyTests {
    static let base = (1...40).map { "line \($0)\n" }.joined()
    /// The agent: line 30 rewritten.
    static let agent = base.replacingOccurrences(of: "line 30\n", with: "line thirty\n")
    /// The project, meanwhile: line 3 rewritten.
    static let mine = base.replacingOccurrences(of: "line 3\n", with: "line three\n")
    static let both = mine.replacingOccurrences(of: "line 30\n", with: "line thirty\n")

    func fixture(base: String = Self.base, agent: String = Self.agent, mine: String = Self.mine) throws -> Fixture {
        let f = try Fixture { root in
            try write(base, to: root.appendingPathComponent("src/file.txt"))
            try write("x\n", to: root.appendingPathComponent("other.txt"))
        }
        try write(agent, to: f.work.appendingPathComponent("src/file.txt"))
        try write(mine, to: f.project.appendingPathComponent("src/file.txt"))
        return f
    }

    func target(_ f: Fixture) -> URL { f.project.appendingPathComponent("src/file.txt") }

    @Test("a clean merge is applied, reported as merged, and undo restores the project's bytes")
    func cleanMerge() throws {
        let f = try fixture()
        let applier = Applier(handle: f.handle)
        let dry = try applier.preflight()
        #expect(dry.merged == ["src/file.txt"] && dry.applied == ["src/file.txt"] && dry.conflicts.isEmpty)
        #expect(try read(target(f)) == Self.mine)

        let report = try applier.apply(paths: nil)
        #expect(report.applied == ["src/file.txt"])
        #expect(report.merged == ["src/file.txt"])
        #expect(report.conflicts.isEmpty)
        #expect(try read(target(f)) == Self.both)

        // Nothing left to do, and nothing is written over the merge.
        let again = try applier.apply(paths: nil)
        #expect(again.alreadyApplied == ["src/file.txt"] && again.applied.isEmpty)
        #expect(try read(target(f)) == Self.both)

        let undo = try applier.undo()
        #expect(undo.restored == ["src/file.txt"])
        #expect(try read(target(f)) == Self.mine)
    }

    @Test("two sessions on one project editing one file: the second apply merges")
    func twoSessions() throws {
        let f = try fixture(mine: Self.base)
        let second = try f.store.create(project: f.project, command: ["true"], image: "test")
        try write(Self.mine, to: second.work.appendingPathComponent("src/file.txt"))
        #expect(try Applier(handle: second).apply(paths: nil).applied == ["src/file.txt"])
        let report = try Applier(handle: f.handle).apply(paths: nil)
        #expect(report.merged == ["src/file.txt"])
        #expect(try read(target(f)) == Self.both)
        // The first session can't undo over the merge; the second one can.
        #expect(try Applier(handle: second).undo().conflicts.map(\.path) == ["src/file.txt"])
        _ = try Applier(handle: f.handle).undo()
        #expect(try read(target(f)) == Self.mine)
        _ = try Applier(handle: second).undo()
        #expect(try read(target(f)) == Self.base)
    }

    @Test("overlapping changes are a conflict and nothing is written")
    func overlap() throws {
        let mine = Self.base.replacingOccurrences(of: "line 30\n", with: "my thirty\n")
        let f = try fixture(mine: mine)
        let report = try Applier(handle: f.handle).apply(paths: ["src/file.txt"])
        #expect(report.applied.isEmpty && report.merged.isEmpty)
        let c = try #require(report.conflicts.first)
        #expect(c.path == "src/file.txt")
        #expect(c.reason.hasPrefix("project changed since the session started"))
        #expect(c.reason.contains("near line 30"))
        #expect(report.bundle == nil)
        #expect(try read(target(f)) == mine)
    }

    @Test("CRLF files merge and stay CRLF")
    func crlf() throws {
        let crlf = (1...30).map { "row \($0)\r\n" }.joined()
        let f = try fixture(base: crlf,
                            agent: crlf.replacingOccurrences(of: "row 25\r\n", with: "row 25b\r\n"),
                            mine: crlf.replacingOccurrences(of: "row 2\r\n", with: "row 2b\r\n"))
        #expect(try Applier(handle: f.handle).apply(paths: nil).merged == ["src/file.txt"])
        #expect(try read(target(f)) == crlf.replacingOccurrences(of: "row 2\r\n", with: "row 2b\r\n")
            .replacingOccurrences(of: "row 25\r\n", with: "row 25b\r\n"))
    }

    @Test("a file without a final newline merges and keeps it missing")
    func missingNewline() throws {
        let base = (1...20).map { "l\($0)" }.joined(separator: "\n")
        let f = try fixture(base: base,
                            agent: base.replacingOccurrences(of: "l20", with: "last"),
                            mine: base.replacingOccurrences(of: "l1\n", with: "first\n"))
        #expect(try Applier(handle: f.handle).apply(paths: nil).merged == ["src/file.txt"])
        let out = try read(target(f))
        #expect(out.hasPrefix("first\n") && out.hasSuffix("\nlast"))
    }

    @Test("the same change on both sides plus one elsewhere is kept once")
    func sameChange() throws {
        let fix = Self.base.replacingOccurrences(of: "line 10\n", with: "fixed\n")
        let f = try fixture(agent: fix.replacingOccurrences(of: "line 30\n", with: "line thirty\n"),
                            mine: fix.replacingOccurrences(of: "line 3\n", with: "line three\n"))
        #expect(try Applier(handle: f.handle).apply(paths: nil).merged == ["src/file.txt"])
        #expect(try read(target(f)) == Self.both.replacingOccurrences(of: "line 10\n", with: "fixed\n"))
    }

    @Test("delete against edit, edit against delete and add against add stay conflicts")
    func notMergeable() throws {
        // The agent deleted it, the project edited it.
        var f = try fixture()
        unlink(f.work.appendingPathComponent("src/file.txt").path)
        var r = try Applier(handle: f.handle).apply(paths: nil)
        #expect(r.conflicts.map(\.path) == ["src/file.txt"] && r.merged.isEmpty)
        #expect(try read(target(f)) == Self.mine)

        // The agent edited it, the project deleted it.
        f = try fixture()
        unlink(target(f).path)
        r = try Applier(handle: f.handle).apply(paths: nil)
        #expect(r.conflicts.map(\.path) == ["src/file.txt"] && !exists(target(f)))

        // Both added a file at the same path.
        f = try fixture(mine: Self.base)
        try write("agent\nnew\n", to: f.work.appendingPathComponent("added.txt"))
        try write("my\nnew\n", to: f.project.appendingPathComponent("added.txt"))
        r = try Applier(handle: f.handle).apply(paths: ["added.txt"])
        #expect(r.conflicts.map(\.path) == ["added.txt"] && r.merged.isEmpty)
        #expect(try read(f.project.appendingPathComponent("added.txt")) == "my\nnew\n")
    }

    @Test("binary files are not merged")
    func binary() throws {
        let base = Self.base + "\u{0}bin\n"
        let f = try fixture(base: base,
                            agent: base.replacingOccurrences(of: "line 30\n", with: "x\n"),
                            mine: base.replacingOccurrences(of: "line 3\n", with: "y\n"))
        let r = try Applier(handle: f.handle).apply(paths: nil)
        #expect(r.conflicts.map(\.path) == ["src/file.txt"] && r.merged.isEmpty)
        #expect(r.conflicts[0].reason.hasPrefix("project changed since the session started (expected"))
    }

    @Test("a symlink in the project, or a mode-only change, is not merged",
          .disabled(if: isWindows, "symlinks and modes"))
    func symlinkAndMode() throws {
        var f = try fixture()
        unlink(target(f).path)
        symlink("../other.txt", target(f).path)
        var r = try Applier(handle: f.handle).apply(paths: nil)
        #expect(r.conflicts.map(\.path) == ["src/file.txt"] && r.merged.isEmpty)

        // The agent only changed the mode; the project edited the text.
        f = try fixture(agent: Self.base)
        chmod(f.work.appendingPathComponent("src/file.txt").path, 0o755)
        r = try Applier(handle: f.handle).apply(paths: nil)
        #expect(r.conflicts.map(\.path) == ["src/file.txt"] && r.merged.isEmpty)
        #expect(try modeOf(target(f)) == 0o644)
    }

    @Test("permissions merge too: the side that changed them wins", .disabled(if: isWindows, "no mode bits on Windows"))
    func modes() throws {
        let f = try fixture()
        chmod(f.work.appendingPathComponent("src/file.txt").path, 0o755)
        #expect(try Applier(handle: f.handle).apply(paths: nil).merged == ["src/file.txt"])
        #expect(try modeOf(target(f)) == 0o755)
        _ = try Applier(handle: f.handle).undo()
        #expect(try modeOf(target(f)) == 0o644)
        #expect(try read(target(f)) == Self.mine)

        // Both changed them, differently: conflict.
        let g = try fixture()
        chmod(g.work.appendingPathComponent("src/file.txt").path, 0o755)
        chmod(target(g).path, 0o600)
        let r = try Applier(handle: g.handle).apply(paths: nil)
        #expect(r.conflicts.first?.reason.contains("permissions") == true)
    }

    @Test("a merge keeps the project's own setuid bit but never takes one from work/",
          .disabled(if: isWindows, "no mode bits on Windows"))
    func setuid() throws {
        let f = try fixture()
        chmod(target(f).path, 0o4755)
        #expect(try Applier(handle: f.handle).apply(paths: nil).merged == ["src/file.txt"])
        #expect(try modeOf(target(f)) == 0o4755)

        let g = try fixture()
        chmod(g.work.appendingPathComponent("src/file.txt").path, 0o4755)
        #expect(try Applier(handle: g.handle).apply(paths: nil).merged == ["src/file.txt"])
        #expect(try modeOf(target(g)) == 0o755)
    }

    @Test("undo of a merged file refuses after a later edit, unless forced")
    func undoAfterEdit() throws {
        let f = try fixture()
        let applier = Applier(handle: f.handle)
        _ = try applier.apply(paths: nil)
        try write(Self.both + "later\n", to: target(f))
        let undo = try applier.undo()
        #expect(undo.conflicts.map(\.path) == ["src/file.txt"] && undo.restored.isEmpty)
        #expect(try read(target(f)) == Self.both + "later\n")
        let forced = try applier.undo(force: true)
        #expect(forced.restored == ["src/file.txt"])
        #expect(try read(target(f)) == Self.mine)
    }

    @Test("files inside .git are never merged")
    func gitInternal() throws {
        let f = try Fixture { root in try write(Self.base, to: root.appendingPathComponent(".git/description")) }
        try write(Self.agent, to: f.work.appendingPathComponent(".git/description"))
        try write(Self.mine, to: f.project.appendingPathComponent(".git/description"))
        let r = try Applier(handle: f.handle).apply(paths: nil, includeGit: true)
        #expect(r.conflicts.map(\.path) == [".git/description"] && r.merged.isEmpty)
    }

    @Test("hunks merge into a project copy changed elsewhere, one at a time, and undo step by step")
    func hunks() throws {
        // Agent: three hunks (lines 10, 25, 38). Project: line 3.
        let agent = Self.base.replacingOccurrences(of: "line 10\n", with: "ten\n")
            .replacingOccurrences(of: "line 25\n", with: "twenty-five\n")
            .replacingOccurrences(of: "line 38\n", with: "")
        let f = try fixture(agent: agent)
        let applier = Applier(handle: f.handle)
        let change = try #require(try f.diff().changes.first { $0.path == "src/file.txt" })
        #expect(try applier.hunks(for: change)?.map(\.id) == [1, 2, 3])

        let first = try applier.applyHunks(path: "src/file.txt", hunks: [2])
        #expect(first.merged == ["src/file.txt"] && first.conflicts.isEmpty)
        let afterFirst = Self.mine.replacingOccurrences(of: "line 25\n", with: "twenty-five\n")
        #expect(try read(target(f)) == afterFirst)
        #expect(try applier.appliedHunks(for: change) == [2])

        let second = try applier.applyHunks(path: "src/file.txt", hunks: [1, 3])
        #expect(second.merged == ["src/file.txt"])
        let all = Self.mine.replacingOccurrences(of: "line 10\n", with: "ten\n")
            .replacingOccurrences(of: "line 25\n", with: "twenty-five\n")
            .replacingOccurrences(of: "line 38\n", with: "")
        #expect(try read(target(f)) == all)
        #expect(try applier.appliedHunks(for: change) == [1, 2, 3])
        #expect(try applier.apply(paths: nil).alreadyApplied == ["src/file.txt"])

        _ = try applier.undo()
        #expect(try read(target(f)) == afterFirst)
        _ = try applier.undo()
        #expect(try read(target(f)) == Self.mine)
        #expect(!applier.canUndo)
    }

    @Test("a hunk overlapping the project's change is a conflict; another one still merges")
    func hunkOverlap() throws {
        let agent = Self.base.replacingOccurrences(of: "line 3\n", with: "agent three\n")
            .replacingOccurrences(of: "line 30\n", with: "line thirty\n")
        let f = try fixture(agent: agent)
        let applier = Applier(handle: f.handle)
        let bad = try applier.applyHunks(path: "src/file.txt", hunks: [1])
        #expect(bad.conflicts.map(\.path) == ["src/file.txt"] && bad.bundle == nil)
        #expect(try read(target(f)) == Self.mine)
        let good = try applier.applyHunks(path: "src/file.txt", hunks: [2])
        #expect(good.merged == ["src/file.txt"])
        #expect(try read(target(f)) == Self.both)
    }

    @Test("a rollback entry for a merge is marked in the journal before the write")
    func journal() throws {
        let f = try fixture()
        let report = try Applier(handle: f.handle).apply(paths: nil)
        let bundle = try #require(report.bundle)
        let manifest = try #require(try Applier.readManifest(bundle))
        let entry = try #require(manifest.entries.first { $0.path == "src/file.txt" })
        #expect(entry.merged == true && entry.pending == nil)
        let journal = try read(bundle.appendingPathComponent(Journal.name))
        #expect(journal.contains("\"merged\":true"))
        #expect(try read(bundle.appendingPathComponent(try #require(entry.backup))) == Self.mine)
    }

    @Test("the review marks a mergeable file and starts it selected")
    func review() throws {
        let f = try fixture()
        try write("y\n", to: f.work.appendingPathComponent("other.txt"))
        let snap = try ReviewSnapshot.load(f.handle)
        let entry = try #require(snap.entry("src/file.txt"))
        #expect(entry.merges && entry.conflict == nil && entry.selectedByDefault)
        #expect(snap.entry("other.txt")?.merges == false)

        let dry = try Applier(handle: f.handle).preflight()
        let term = TerminalReview(changes: try f.diff().changes, merges: Set(dry.merged))
        let lines = term.body(width: 200, height: 10)
        #expect(lines.contains { $0.contains("src/file.txt") && $0.contains("MERGE") })
        #expect(!lines.contains { $0.contains("other.txt") && $0.contains("MERGE") })
    }
}
