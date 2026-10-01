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
}
