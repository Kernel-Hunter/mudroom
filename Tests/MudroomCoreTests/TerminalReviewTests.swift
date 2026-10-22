import Foundation
import Testing
@testable import MudroomCore

@Suite("Terminal review")
struct TerminalReviewTests {
    func change(_ path: String, _ kind: ChangeKind = .modified) -> Change {
        Change(path: path, kind: kind, before: .file(mode: 0o644, size: 1, sha256: "a"), after: .file(mode: 0o644, size: 1, sha256: "b"))
    }

    @Test("everything starts selected except conflicts; space and a toggle")
    func selection() {
        var r = TerminalReview(changes: [change("a"), change("b", .added), change("c", .deleted)], conflicts: ["c": "changed"])
        #expect(r.selectedPaths == ["a", "b"])
        _ = r.handle(.space, height: 10)
        #expect(r.selectedPaths == ["b"])
        _ = r.handle(.char("a"), height: 10)
        #expect(r.selectedPaths == ["a", "b", "c"])
        _ = r.handle(.char("a"), height: 10)
        #expect(r.selectedPaths.isEmpty)
        #expect(r.handle(.char("x"), height: 10) == .none)
        #expect(r.message == "nothing selected")
    }

    @Test("cursor stays in range and scrolls the list")
    func cursor() {
        var r = TerminalReview(changes: (0..<10).map { change("f\($0)") })
        _ = r.handle(.up, height: 3)
        #expect(r.cursor == 0)
        for _ in 0..<5 { _ = r.handle(.down, height: 3) }
        #expect(r.cursor == 5 && r.listTop == 3)
        #expect(r.body(width: 40, height: 3).first?.hasSuffix("f3") == true)
        _ = r.handle(.end, height: 3)
        #expect(r.cursor == 9)
        #expect(r.handle(.enter, height: 3) == .openDiff(9))
    }

    @Test("apply asks first, then marks applied paths")
    func apply() {
        var r = TerminalReview(changes: [change("a"), change("b")])
        #expect(r.handle(.char("x"), height: 5) == .none)
        #expect(r.mode == .confirm)
        #expect(r.handle(.char("n"), height: 5) == .none)
        #expect(r.mode == .list && r.message == "apply cancelled")
        _ = r.handle(.char("x"), height: 5)
        #expect(r.handle(.char("y"), height: 5) == .apply(["a", "b"]))
        r.markApplied(["a"], conflicts: ["b": "project changed"])
        #expect(r.selectedPaths.isEmpty)
        let rows = r.body(width: 80, height: 5)
        #expect(rows[0].contains("[=]") && rows[0].contains("applied"))
        #expect(rows[1].contains("CONFLICT"))
    }

    @Test("the diff view scrolls within bounds and colors lines")
    func diff() {
        var r = TerminalReview(changes: [change("a")])
        r.showDiff((1...20).map { "+line \($0)" }.joined(separator: "\n"))
        _ = r.handle(.pageDown, height: 5)
        guard case .diff(_, let top) = r.mode else { Issue.record("not in diff mode"); return }
        #expect(top == 4)
        _ = r.handle(.end, height: 5)
        let rows = r.body(width: 80, height: 5) { s, style in style == .added ? "<\(s)>" : s }
        #expect(rows.count == 5 && rows.last == "<+line 20>")
        _ = r.handle(.char("q"), height: 5)
        #expect(r.mode == .list)
        #expect(r.handle(.char("q"), height: 5) == .quit)
    }

    /// Three hunks (lines 3, 20 and 38), as in HunkApplyTests.
    var threeHunks: [Hunk] { LineDiff.hunks(base: Data(HunkApplyTests.base.utf8), work: Data(HunkApplyTests.edited(HunkApplyTests.base).utf8)) }

    @Test("the hunk view toggles hunks; some selected makes the file partial")
    func hunkToggling() {
        var r = TerminalReview(changes: [change("a"), change("b")])
        #expect(threeHunks.count == 3)
        r.showHunks(threeHunks)
        guard case .hunks(_, let starts, 0, 0) = r.mode else { Issue.record("not in hunk view"); return }
        #expect(starts.count == 3)
        // A selected file starts with every hunk selected: still a whole-file apply.
        #expect(r.items[0].selectedHunks == [1, 2, 3])
        #expect(r.selectedPaths == ["a", "b"] && r.selectedHunks.isEmpty)
        let rows = r.body(width: 80, height: 40)
        #expect(rows.filter { $0.hasPrefix("[x] [") }.count == 3)

        _ = r.handle(.char("j"), height: 40)
        _ = r.handle(.space, height: 40)
        #expect(r.items[0].selectedHunks == [1, 3])
        #expect(r.selectedPaths == ["b"])
        #expect(r.selectedHunks == ["a": [1, 3]])
        #expect(r.selectedCount == 2)
        #expect(r.body(width: 80, height: 40).contains { $0.hasPrefix("[ ] [2] @@") })

        // n clears the file, a selects it again.
        _ = r.handle(.char("n"), height: 40)
        #expect(!r.items[0].selected && r.selectedPaths == ["b"] && r.selectedHunks.isEmpty)
        _ = r.handle(.char("a"), height: 40)
        #expect(r.selectedPaths == ["a", "b"] && r.selectedHunks.isEmpty)

        // Back in the list a partial file shows [~] and how many hunks go in.
        _ = r.handle(.char("G"), height: 40)
        _ = r.handle(.space, height: 40)
        _ = r.handle(.char("q"), height: 40)
        #expect(r.mode == .list)
        let row = r.body(width: 80, height: 5)[0]
        #expect(row.hasPrefix("[~] M a") && row.contains("(2 of 3 hunks)"))
        #expect(r.footer.contains("enter diff/hunks"))

        // Reopening keeps the choice.
        r.showHunks(threeHunks)
        #expect(r.selectedHunks == ["a": [1, 2]])
        _ = r.handle(.char("q"), height: 40)
        // Space on a partial file in the list selects all of it.
        _ = r.handle(.space, height: 40)
        #expect(r.items[0].selectedHunks == [1, 2, 3] && r.selectedHunks.isEmpty)
        _ = r.handle(.space, height: 40)
        #expect(r.items[0].selectedHunks.isEmpty && !r.items[0].selected)
    }

    @Test("an unselected file opens with no hunks selected; x confirms a mixed apply")
    func hunkApplyAction() {
        var r = TerminalReview(changes: [change("a"), change("b")])
        _ = r.handle(.space, height: 10)
        r.showHunks(threeHunks)
        #expect(r.items[0].selectedHunks.isEmpty)
        #expect(r.handle(.char("x"), height: 10) == .none)
        #expect(r.mode == .confirm)
        #expect(r.footer == "apply 1 selected path(s) to the project? y/N")
        _ = r.handle(.char("n"), height: 10)
        r.showHunks(threeHunks)
        _ = r.handle(.end, height: 10)
        _ = r.handle(.space, height: 10)
        _ = r.handle(.char("x"), height: 10)
        #expect(r.footer.contains("1 of them in part"))
        #expect(r.handle(.char("y"), height: 10) == .apply(["b"], hunks: ["a": [3]]))

        // After the apply, hunk 3 is in; 1 and 2 stay open and can't be
        // confused with it.
        r.markApplied(["a", "b"], conflicts: [:], hunks: ["a": [3]])
        #expect(!r.items[0].applied && r.items[0].appliedHunks == [3] && r.items[1].applied)
        #expect(r.selectedCount == 0)
        #expect(r.body(width: 80, height: 5)[0].contains("(1 of 3 hunks applied)"))
        r.showHunks(threeHunks)
        _ = r.handle(.end, height: 10)
        _ = r.handle(.space, height: 10)
        #expect(r.items[0].selectedHunks.isEmpty)
        #expect(r.body(width: 80, height: 40).contains { $0.hasPrefix("[=] [3] @@") && $0.contains("(applied)") })
        _ = r.handle(.char("a"), height: 10)
        #expect(r.selectedPaths == ["a"] && r.selectedHunks.isEmpty)
        r.markApplied(["a"], conflicts: [:])
        #expect(r.items[0].applied)
    }

    @Test("moving between hunks scrolls them into view; paging moves the hunk cursor")
    func hunkScrolling() {
        var r = TerminalReview(changes: [change("a")])
        r.showHunks(threeHunks)
        guard case .hunks(let lines, let starts, _, _) = r.mode else { Issue.record("not in hunk view"); return }
        _ = r.handle(.end, height: 5)
        guard case .hunks(_, _, 2, let top) = r.mode else { Issue.record("not on the last hunk"); return }
        #expect(top == min(starts[2], lines.count - 5))
        _ = r.handle(.home, height: 5)
        _ = r.handle(.char("f"), height: 5)
        guard case .hunks(_, _, let hunk, let top2) = r.mode else { Issue.record("left the hunk view"); return }
        // Hunk 2's header (line 8) is now on screen, so the cursor is on it.
        #expect(top2 == 4 && hunk == 1)
        _ = r.handle(.char("f"), height: 5)
        _ = r.handle(.char("f"), height: 5)
        guard case .hunks(_, _, let hunk3, let top3) = r.mode else { Issue.record("left the hunk view"); return }
        // Inside hunk 2, no header on screen: still hunk 2.
        #expect(top3 == 12 && hunk3 == 1)
        _ = r.handle(.up, height: 5)
        _ = r.handle(.up, height: 5)
        guard case .hunks(_, _, 0, 0) = r.mode else { Issue.record("not back at the top"); return }
        _ = r.handle(.escape, height: 5)
        #expect(r.mode == .list)
    }

    @Test("a review selection of 1 of 3 hunks writes that hunk only; undo restores the file")
    func hunkApplyThroughApplier() throws {
        let f = try HunkApplyTests().fixture()
        let applier = Applier(handle: f.handle)
        let diff = try f.diff()
        let reviewed = ReviewedChanges(diff.changes + diff.gitMetadataChanges)
        var r = TerminalReview(changes: diff.changes)
        let i = try #require(r.items.firstIndex { $0.path == "src/file.txt" })
        while r.cursor < i { _ = r.handle(.down, height: 10) }
        #expect(r.handle(.enter, height: 10) == .openDiff(i))
        // What `mudroom review` does on enter.
        let change = r.items[i].change
        guard case .text(let hunks, true) = try ReviewSnapshot.content(for: change, before: f.handle.base, after: f.work, applier: applier) else {
            Issue.record("no hunk view for a modified text file"); return
        }
        r.showHunks(hunks, applied: try applier.appliedHunks(for: change, hunks: hunks))
        _ = r.handle(.char("n"), height: 10)
        _ = r.handle(.down, height: 10)
        _ = r.handle(.space, height: 10)
        _ = r.handle(.char("x"), height: 10)
        guard case .apply(let paths, let sel) = r.handle(.char("y"), height: 10) else { Issue.record("no apply"); return }
        #expect(paths == ["other.txt"] && sel == ["src/file.txt": [2]])

        let report = try applier.apply(paths: paths, hunks: sel, reviewed: reviewed)
        #expect(Set(report.applied) == ["other.txt", "src/file.txt"] && report.conflicts.isEmpty)
        let target = f.project.appendingPathComponent("src/file.txt")
        #expect(try read(target) == HunkApplyTests.base.replacingOccurrences(of: "line 20\n", with: "line twenty\nextra\n"))
        #expect(try read(f.project.appendingPathComponent("other.txt")) == "y\n")
        let now = try applier.appliedHunks(for: change, hunks: hunks)
        #expect(now == [2])
        r.markApplied(report.applied + report.alreadyApplied, conflicts: [:], hunks: ["src/file.txt": now])
        #expect(r.items[i].openHunks == [1, 3])

        // One apply, one bundle: a single undo puts both files back.
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.handle.rollbackRoot.path).count == 1)
        let undo = try applier.undo()
        #expect(Set(undo.restored) == ["other.txt", "src/file.txt"])
        #expect(try read(target) == HunkApplyTests.base)
        #expect(try read(f.project.appendingPathComponent("other.txt")) == "x\n")
        #expect(!applier.canUndo)
    }
}
