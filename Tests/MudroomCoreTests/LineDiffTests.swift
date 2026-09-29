import Foundation
import Testing
@testable import MudroomCore

@Suite("Line diff, hunks and partial apply")
struct LineDiffTests {
    func d(_ s: String) -> Data { Data(s.utf8) }
    func s(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    func numbered(_ n: Int, prefix: String = "line") -> String {
        (1...n).map { "\(prefix) \($0)\n" }.joined()
    }

    @Test("line split keeps terminators and round-trips")
    func splitRoundTrip() {
        for text in ["", "a", "a\n", "a\nb", "a\r\nb\r\n", "\n\n", "x\r\ny\nz"] {
            let lines = TextLines(d(text))
            #expect(s(lines.data) == text)
        }
        #expect(TextLines(d("a\r\nb")).lines.map { s($0) } == ["a\r\n", "b"])
        #expect(TextLines.display(d("a\r\n")) == "a")
    }

    @Test("identical files give no hunks")
    func identical() {
        #expect(LineDiff.hunks(base: d("a\nb\n"), work: d("a\nb\n")).isEmpty)
        #expect(LineDiff.hunks(base: d(""), work: d("")).isEmpty)
    }

    @Test("one change in the middle gives one hunk with 3 lines of context")
    func singleHunk() throws {
        let base = numbered(20)
        let work = base.replacingOccurrences(of: "line 10\n", with: "line ten\n")
        let hunks = LineDiff.hunks(base: d(base), work: d(work))
        #expect(hunks.count == 1)
        let h = try #require(hunks.first)
        #expect(h.header == "@@ -7,7 +7,7 @@")
        #expect(h.added == 1 && h.removed == 1)
        #expect(h.lines.first?.text == "line 7")
        #expect(h.lines.first(where: { $0.kind == .removed })?.oldNumber == 10)
        #expect(h.lines.first(where: { $0.kind == .added })?.newNumber == 10)
    }

    @Test("distant changes are separate hunks, close ones merge")
    func hunkGrouping() {
        var lines = numbered(40).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[2] = "changed 3"
        lines[30] = "changed 31"
        let far = LineDiff.hunks(base: d(numbered(40)), work: d(lines.joined(separator: "\n")))
        #expect(far.count == 2)
        #expect(far.map(\.id) == [1, 2])

        var near = numbered(40).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        near[10] = "a"
        near[16] = "b"  // gap of 5 equal lines <= 6, so one hunk
        #expect(LineDiff.hunks(base: d(numbered(40)), work: d(near.joined(separator: "\n"))).count == 1)
    }

    @Test("insertions and deletions at the edges")
    func edges() {
        let base = "a\nb\nc\n"
        let cases = ["top\na\nb\nc\n", "a\nb\nc\nbottom\n", "b\nc\n", "a\nb\n", "", "only\n"]
        for work in cases {
            let hunks = LineDiff.hunks(base: d(base), work: d(work))
            #expect(!hunks.isEmpty)
            let all = Set(hunks.map(\.id))
            #expect(s(LineDiff.apply(selected: all, base: d(base), work: d(work))) == work)
            #expect(s(LineDiff.apply(selected: [], base: d(base), work: d(work))) == base)
        }
        #expect(LineDiff.hunks(base: d(""), work: d("new\n")).first?.header == "@@ -0,0 +1 @@")
    }

    @Test("applying a subset of hunks")
    func partialApply() {
        var w = numbered(60).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        w[4] = "first edit"
        w.insert("inserted", at: 30)
        w.remove(at: 55)
        let base = numbered(60)
        let work = w.joined(separator: "\n")
        let hunks = LineDiff.hunks(base: d(base), work: d(work))
        #expect(hunks.count == 3)

        let only2 = s(LineDiff.apply(selected: [2], base: d(base), work: d(work)))
        #expect(only2.contains("inserted\n"))
        #expect(!only2.contains("first edit"))
        #expect(only2.contains("line 55\n"))

        let oneAndThree = s(LineDiff.apply(selected: [1, 3], base: d(base), work: d(work)))
        #expect(oneAndThree.contains("first edit\n"))
        #expect(!oneAndThree.contains("inserted"))
        #expect(!oneAndThree.contains("line 55\n"))
        #expect(oneAndThree.split(separator: "\n").count == 59)
    }

    @Test("missing trailing newline is tracked and preserved")
    func noTrailingNewline() throws {
        let base = "a\nb\nc"
        let work = "a\nb\nc\nd"
        let hunks = LineDiff.hunks(base: d(base), work: d(work))
        let h = try #require(hunks.first)
        #expect(h.lines.filter { $0.kind == .removed }.map(\.text) == ["c"])
        #expect(h.lines.filter { $0.kind == .added }.map(\.text) == ["c", "d"])
        #expect(h.lines.last?.missingNewline == true)
        #expect(LineDiff.numberedText(hunks).contains("\\ No newline at end of file"))
        #expect(s(LineDiff.apply(selected: [1], base: d(base), work: d(work))) == work)

        // An untouched last line without newline stays that way.
        let base2 = numbered(20) + "tail"
        let work2 = base2.replacingOccurrences(of: "line 2\n", with: "LINE 2\n")
        #expect(s(LineDiff.apply(selected: [1], base: d(base2), work: d(work2))).hasSuffix("line 20\ntail"))
    }

    @Test("CRLF line endings survive a partial apply")
    func crlf() {
        let base = (1...30).map { "row \($0)\r\n" }.joined()
        let work = base
            .replacingOccurrences(of: "row 3\r\n", with: "row three\r\n")
            .replacingOccurrences(of: "row 25\r\n", with: "row twenty-five\r\n")
        let hunks = LineDiff.hunks(base: d(base), work: d(work))
        #expect(hunks.count == 2)
        #expect(hunks[0].lines.allSatisfy { !$0.text.hasSuffix("\r") })
        let out = s(LineDiff.apply(selected: [2], base: d(base), work: d(work)))
        #expect(out.contains("row twenty-five\r\n"))
        #expect(out.contains("row 3\r\n"))
        #expect(!out.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test("a line ending change counts as a change")
    func lineEndingChange() {
        let hunks = LineDiff.hunks(base: d("a\nb\n"), work: d("a\r\nb\n"))
        #expect(hunks.count == 1)
        #expect(hunks[0].removed == 1 && hunks[0].added == 1)
    }

    @Test("large file with a few edits is fast and exact")
    func largeFile() {
        let n = 100_000
        var w = (0..<n).map { "value \($0) = \($0 * 7 % 13)\n" }
        let base = w.joined()
        w[10] = "edited near top\n"
        w[50_000] = "edited in the middle\n"
        w.insert("inserted near end\n", at: 99_000)
        let work = w.joined()
        let start = Date()
        let hunks = LineDiff.hunks(base: d(base), work: d(work))
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(hunks.count == 3)
        #expect(s(LineDiff.apply(selected: [1, 2, 3], base: d(base), work: d(work))) == work)
        #expect(s(LineDiff.apply(selected: [2], base: d(base), work: d(work))).contains("edited in the middle"))
    }

    @Test("completely rewritten large file still diffs, as one block")
    func rewrite() {
        let base = (0..<20_000).map { "old \($0)\n" }.joined()
        let work = (0..<20_000).map { "new \($0)\n" }.joined()
        let hunks = LineDiff.hunks(base: d(base), work: d(work))
        #expect(!hunks.isEmpty)
        #expect(s(LineDiff.apply(selected: Set(hunks.map(\.id)), base: d(base), work: d(work))) == work)
    }

    @Test("random edits: all hunks give work, none give base, each hunk is independent")
    func randomized() {
        var rng = SeededRNG(seed: 42)
        for _ in 0..<200 {
            let count = Int.random(in: 0...60, using: &rng)
            let base = (0..<count).map { _ in "l\(Int.random(in: 0...9, using: &rng))\n" }
            var work = base
            for _ in 0..<Int.random(in: 0...8, using: &rng) {
                switch Int.random(in: 0...2, using: &rng) {
                case 0 where !work.isEmpty: work.remove(at: Int.random(in: 0..<work.count, using: &rng))
                case 1: work.insert("n\(Int.random(in: 0...9, using: &rng))\n", at: Int.random(in: 0...work.count, using: &rng))
                default: if !work.isEmpty { work[Int.random(in: 0..<work.count, using: &rng)] = "c\n" }
                }
            }
            let b = d(base.joined()), w = d(work.joined())
            let hunks = LineDiff.hunks(base: b, work: w)
            #expect(LineDiff.apply(selected: Set(hunks.map(\.id)), base: b, work: w) == w)
            #expect(LineDiff.apply(selected: [], base: b, work: w) == b)
            // Every hunk's lines agree with the files it came from.
            let bl = TextLines(b), wl = TextLines(w)
            for h in hunks {
                let old = h.lines.filter { $0.kind != .added }.map(\.text)
                let new = h.lines.filter { $0.kind != .removed }.map(\.text)
                #expect(old == bl.lines[h.oldRange].map(TextLines.display))
                #expect(new == wl.lines[h.newRange].map(TextLines.display))
            }
        }
    }
}

/// Deterministic generator so failures reproduce.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
