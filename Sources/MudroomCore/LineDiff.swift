import Foundation

/// A text file split into lines. Each line keeps its own terminator ("\n",
/// "\r\n" or none for a last line without a newline), so joining the lines
/// gives back the exact original bytes. CRLF files stay CRLF.
public struct TextLines: Sendable, Equatable {
    public let lines: [Data]

    public init(lines: [Data]) { self.lines = lines }

    public init(_ data: Data) {
        var out: [Data] = []
        var start = data.startIndex
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == 0x0A {
                out.append(data[start...i])
                start = data.index(after: i)
            }
            i = data.index(after: i)
        }
        if start < data.endIndex { out.append(data[start..<data.endIndex]) }
        lines = out.map { Data($0) }
    }

    public var count: Int { lines.count }

    public var data: Data {
        var d = Data()
        d.reserveCapacity(lines.reduce(0) { $0 + $1.count })
        for l in lines { d.append(l) }
        return d
    }

    /// The line without its terminator, decoded for display.
    public static func display(_ line: Data) -> String {
        var end = line.endIndex
        if end > line.startIndex, line[line.index(before: end)] == 0x0A { end = line.index(before: end) }
        if end > line.startIndex, line[line.index(before: end)] == 0x0D { end = line.index(before: end) }
        return visible(String(decoding: line[line.startIndex..<end], as: UTF8.self))
    }

    /// `s` with characters that change how text is drawn spelled out:
    /// control characters (an escape sequence or a carriage return could
    /// redraw a terminal line and hide what follows) as `\x1b`, `\r`, `\n`,
    /// and bidirectional overrides (which reorder what is shown, the
    /// "Trojan Source" trick) as `<U+202E>`. Tabs stay. Used for every line
    /// and path a review shows, since the agent chose those bytes.
    public static func visible(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: needsEscape) else { return s }
        var out = ""
        for u in s.unicodeScalars {
            guard needsEscape(u) else { out.unicodeScalars.append(u); continue }
            switch u {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:
                out += u.value < 0x100 ? "\\x" + String(format: "%02x", u.value) : String(format: "<U+%04X>", u.value)
            }
        }
        return out
    }

    static func needsEscape(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09: false
        case 0x00...0x1F, 0x7F...0x9F: true
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }

    public static func hasNewline(_ line: Data) -> Bool { line.last == 0x0A }
}

/// One line in a hunk, ready to draw.
public struct DiffLine: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable { case context, removed, added }
    public let kind: Kind
    /// 1-based line number in the base file (nil for added lines).
    public let oldNumber: Int?
    /// 1-based line number in the work file (nil for removed lines).
    public let newNumber: Int?
    public let text: String
    /// True when this is the last line of its file and has no terminator.
    public let missingNewline: Bool
}

/// A block of changes plus surrounding context, like a `@@` section in a
/// unified diff. Ranges are 0-based, half-open line ranges; context lines are
/// identical on both sides, so applying a hunk means replacing `oldRange` of
/// the base with `newRange` of the work file.
public struct Hunk: Sendable, Equatable, Identifiable {
    /// 1-based, in file order. This is the number `mudroom apply --hunks` takes.
    public let id: Int
    public let oldRange: Range<Int>
    public let newRange: Range<Int>
    public let lines: [DiffLine]

    public var added: Int { lines.filter { $0.kind == .added }.count }
    public var removed: Int { lines.filter { $0.kind == .removed }.count }

    /// "@@ -12,7 +12,9 @@" with git's conventions for empty ranges.
    public var header: String {
        func part(_ r: Range<Int>) -> String {
            let start = r.isEmpty ? r.lowerBound : r.lowerBound + 1
            return r.count == 1 ? "\(start)" : "\(start),\(r.count)"
        }
        return "@@ -\(part(oldRange)) +\(part(newRange)) @@"
    }
}

public enum LineDiff {
    /// Past this many edits Myers gives up and reports the rest of the
    /// differing region as one replaced block. Keeps worst-case time bounded
    /// on large, completely rewritten files.
    public static let maxEditDistance = 1500

    /// Changed blocks (old range replaced by new range), in order. Equal runs
    /// are not included.
    public static func changes(_ a: [Data], _ b: [Data]) -> [(old: Range<Int>, new: Range<Int>)] {
        // Intern lines so the inner loop compares Ints.
        var ids: [Data: Int] = [:]
        func intern(_ l: Data) -> Int {
            if let id = ids[l] { return id }
            let id = ids.count
            ids[l] = id
            return id
        }
        let x = a.map(intern)
        let y = b.map(intern)

        // Trim common prefix and suffix; most agent edits are local.
        var prefix = 0
        while prefix < x.count, prefix < y.count, x[prefix] == y[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < x.count - prefix, suffix < y.count - prefix,
              x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
        let xs = Array(x[prefix..<(x.count - suffix)])
        let ys = Array(y[prefix..<(y.count - suffix)])
        if xs.isEmpty && ys.isEmpty { return [] }

        let pairs = myersMatches(xs, ys)
        // Turn matched pairs into replaced blocks between them.
        var result: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0
        for (mi, mj) in pairs + [(xs.count, ys.count)] {
            if mi > i || mj > j {
                result.append(((prefix + i)..<(prefix + mi), (prefix + j)..<(prefix + mj)))
            }
            i = mi + 1
            j = mj + 1
        }
        return result.map { (old: $0.0, new: $0.1) }
    }

    /// Greedy Myers O(ND). Returns matched index pairs in increasing order.
    static func myersMatches(_ a: [Int], _ b: [Int]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return [] }
        let maxD = min(n + m, maxEditDistance)
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        // trace[d] holds V (diagonals -d-1...d+1) as it was before step d.
        var trace: [[Int]] = []
        func snapshot(_ d: Int) -> [Int] {
            Array(v[max(0, offset - d - 1)...min(v.count - 1, offset + d + 1)])
        }
        var found = false
        outer: for d in 0...maxD {
            trace.append(snapshot(d))
            var k = -d
            while k <= d {
                var xk: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    xk = v[offset + k + 1]
                } else {
                    xk = v[offset + k - 1] + 1
                }
                var yk = xk - k
                while xk < n, yk < m, a[xk] == b[yk] {
                    xk += 1
                    yk += 1
                }
                v[offset + k] = xk
                if xk >= n && yk >= m {
                    found = true
                    break outer
                }
                k += 2
            }
        }
        guard found else {
            // Too different: keep only a common prefix (none, already trimmed),
            // and call the whole region one change.
            return []
        }
        // Backtrack through the saved V arrays.
        var pairs: [(Int, Int)] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let snap = trace[d]
            let base = max(0, offset - d - 1)
            func vd(_ k: Int) -> Int { snap[offset + k - base] }
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vd(k - 1) < vd(k + 1)) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = d == 0 ? 0 : vd(prevK)
            let prevY = prevX - prevK
            while x > prevX && y > prevY {
                x -= 1
                y -= 1
                pairs.append((x, y))
            }
            if d == 0 { break }
            x = prevX
            y = prevY
        }
        return pairs.reversed()
    }

    /// Groups changes into hunks with `context` lines around each, merging
    /// hunks whose context would touch (same rule as `diff -U3`).
    public static func hunks(base: TextLines, work: TextLines, context: Int = 3) -> [Hunk] {
        let blocks = changes(base.lines, work.lines)
        guard !blocks.isEmpty else { return [] }

        // Merge blocks whose gap is at most 2 * context equal lines.
        var groups: [[(old: Range<Int>, new: Range<Int>)]] = [[blocks[0]]]
        for b in blocks.dropFirst() {
            let last = groups[groups.count - 1].last!
            if b.old.lowerBound - last.old.upperBound <= 2 * context {
                groups[groups.count - 1].append(b)
            } else {
                groups.append([b])
            }
        }

        var hunks: [Hunk] = []
        for (gi, group) in groups.enumerated() {
            let first = group.first!, last = group.last!
            let lead = min(context, first.old.lowerBound, first.new.lowerBound)
            let trail = min(context, base.count - last.old.upperBound, work.count - last.new.upperBound)
            let oldRange = (first.old.lowerBound - lead)..<(last.old.upperBound + trail)
            let newRange = (first.new.lowerBound - lead)..<(last.new.upperBound + trail)

            var lines: [DiffLine] = []
            func ctx(_ oi: Int, _ ni: Int) {
                let l = base.lines[oi]
                lines.append(DiffLine(kind: .context, oldNumber: oi + 1, newNumber: ni + 1,
                                      text: TextLines.display(l),
                                      missingNewline: !TextLines.hasNewline(l)))
            }
            var oi = oldRange.lowerBound, ni = newRange.lowerBound
            for b in group {
                while oi < b.old.lowerBound { ctx(oi, ni); oi += 1; ni += 1 }
                for i in b.old {
                    let l = base.lines[i]
                    lines.append(DiffLine(kind: .removed, oldNumber: i + 1, newNumber: nil,
                                          text: TextLines.display(l), missingNewline: !TextLines.hasNewline(l)))
                }
                for i in b.new {
                    let l = work.lines[i]
                    lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: i + 1,
                                          text: TextLines.display(l), missingNewline: !TextLines.hasNewline(l)))
                }
                oi = b.old.upperBound
                ni = b.new.upperBound
            }
            while oi < oldRange.upperBound { ctx(oi, ni); oi += 1; ni += 1 }
            hunks.append(Hunk(id: gi + 1, oldRange: oldRange, newRange: newRange, lines: lines))
        }
        return hunks
    }

    public static func hunks(base: Data, work: Data, context: Int = 3) -> [Hunk] {
        hunks(base: TextLines(base), work: TextLines(work), context: context)
    }

    /// Builds the file you get by applying only `selected` hunks (by id) to
    /// the base. Unselected hunks keep the base's lines.
    public static func apply(_ hunks: [Hunk], selected: Set<Int>, base: TextLines, work: TextLines) -> TextLines {
        var out: [Data] = []
        out.reserveCapacity(max(base.count, work.count))
        var oi = 0
        for h in hunks.sorted(by: { $0.oldRange.lowerBound < $1.oldRange.lowerBound }) {
            out.append(contentsOf: base.lines[oi..<h.oldRange.lowerBound])
            if selected.contains(h.id) {
                out.append(contentsOf: work.lines[h.newRange])
            } else {
                out.append(contentsOf: base.lines[h.oldRange])
            }
            oi = h.oldRange.upperBound
        }
        out.append(contentsOf: base.lines[oi..<base.count])
        return TextLines(lines: out)
    }

    public static func apply(selected: Set<Int>, base: Data, work: Data, context: Int = 3) -> Data {
        let b = TextLines(base), w = TextLines(work)
        return apply(hunks(base: b, work: w, context: context), selected: selected, base: b, work: w).data
    }

    /// A unified diff with numbered hunk headers ("[1] @@ -1,3 +1,4 @@").
    public static func numberedText(_ hunks: [Hunk]) -> String {
        var out: [String] = []
        for h in hunks {
            out.append("[\(h.id)] \(h.header)  +\(h.added) -\(h.removed)")
            for l in h.lines {
                let sign = switch l.kind { case .context: " "; case .removed: "-"; case .added: "+" }
                out.append(sign + l.text)
                if l.missingNewline { out.append("\\ No newline at end of file") }
            }
        }
        return out.joined(separator: "\n")
    }
}
