import Foundation

/// State for `mudroom review`, the terminal review screen: a list of
/// changed paths with checkboxes, and a scrollable diff of one of them. For
/// files the Applier can apply hunk by hunk, the diff has a checkbox per hunk.
/// Pure state and plain-text rendering; the CLI handles the terminal.
public struct TerminalReview: Sendable {
    public struct Item: Sendable, Equatable {
        public var change: Change
        public var selected: Bool
        /// Set when a dry run reports a conflict; such paths start unselected.
        public var conflict: String?
        public var applied = false
        /// Set once the file is opened in the hunk view (see `showHunks`).
        /// From then on `selectedHunks` decides what goes in.
        public var hunks: [Hunk]?
        public var selectedHunks: Set<Int> = []
        /// Hunks already in the project from an earlier partial apply.
        public var appliedHunks: Set<Int> = []

        public var path: String { change.path }

        /// Hunk ids not in the project yet.
        public var openHunks: Set<Int> { Set((hunks ?? []).map(\.id)).subtracting(appliedHunks) }

        /// Some open hunks are selected, not all: applied hunk by hunk.
        public var isPartial: Bool {
            guard hunks != nil, !applied else { return false }
            let open = openHunks
            let want = selectedHunks.intersection(open)
            return !want.isEmpty && want != open
        }

        /// Selects or clears the whole file, or all its open hunks.
        mutating func set(_ on: Bool) {
            guard !applied else { return }
            selected = on
            if hunks != nil { selectedHunks = on ? openHunks : [] }
        }
    }

    public enum Mode: Sendable, Equatable {
        case list
        case diff(lines: [String], top: Int)
        /// The diff of the file under the list cursor, one checkbox per hunk.
        /// `starts[i]` is the line of hunk i's header; `hunk` is the hunk
        /// under the cursor (an index into the item's `hunks`).
        case hunks(lines: [String], starts: [Int], hunk: Int, top: Int)
        case confirm
    }

    public enum Key: Sendable, Equatable {
        case up, down, pageUp, pageDown, home, end, left, right, enter, space, escape
        case char(Character)
    }

    public enum Action: Sendable, Equatable {
        case none
        case quit
        /// The CLI should load the diff text for this item and call `showDiff`.
        case openDiff(Int)
        /// The user confirmed: apply these whole paths, plus only these hunk
        /// ids of the files in `hunks` (Applier's `apply(paths:hunks:)`).
        case apply([String], hunks: [String: Set<Int>] = [:])
    }

    public private(set) var items: [Item]
    public private(set) var cursor = 0
    public private(set) var listTop = 0
    public private(set) var mode: Mode = .list
    /// One line of feedback under the list ("applied 3 paths").
    public var message: String?

    public init(changes: [Change], conflicts: [String: String] = [:]) {
        // Conflicts, unreadable entries and files the host acts on start unselected.
        items = changes.map {
            Item(change: $0, selected: conflicts[$0.path] == nil && $0.kind != .unreadable && Differ.reviewNote($0.path) == nil,
                 conflict: conflicts[$0.path])
        }
    }

    /// Paths applied as a whole: selected files, and files with every open
    /// hunk selected (same rule as the app's `ReviewSelection.pending`).
    public var selectedPaths: [String] {
        items.filter { $0.selected && !$0.applied && !$0.isPartial }.map(\.path)
    }

    /// Files applied hunk by hunk, with the hunk ids that go in.
    public var selectedHunks: [String: Set<Int>] {
        var out: [String: Set<Int>] = [:]
        for it in items where it.isPartial { out[it.path] = it.selectedHunks.intersection(it.openHunks) }
        return out
    }

    /// Files that an apply would touch, whole or in part.
    public var selectedCount: Int { selectedPaths.count + selectedHunks.count }

    public mutating func showDiff(_ text: String) {
        mode = .diff(lines: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), top: 0)
    }

    /// Opens the hunk view for the item under the cursor. `hunks` come from
    /// `Applier.hunks(for:)`, so the ids are the ones the Applier takes;
    /// `applied` are hunks already in the project. The first time, the
    /// file's checkbox decides whether its hunks start selected; after that
    /// the earlier choice is kept.
    public mutating func showHunks(_ hunks: [Hunk], applied: Set<Int> = []) {
        guard items.indices.contains(cursor), !hunks.isEmpty else { return }
        if items[cursor].hunks != hunks {
            items[cursor].hunks = hunks
            items[cursor].appliedHunks = applied
            items[cursor].selectedHunks = items[cursor].selected && !items[cursor].applied ? items[cursor].openHunks : []
            if items[cursor].openHunks.isEmpty && !items[cursor].applied {
                items[cursor].selected = false
            }
        }
        var lines: [String] = []
        var starts: [Int] = []
        for h in hunks {
            starts.append(lines.count)
            lines += LineDiff.numberedText([h]).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        mode = .hunks(lines: lines, starts: starts, hunk: 0, top: 0)
    }

    /// `paths` are what the Applier reports as applied or already applied.
    /// `hunks` maps the files sent hunk by hunk to the hunk ids now in the
    /// project; those stay open for their remaining hunks.
    public mutating func markApplied(_ paths: [String], conflicts: [String: String], hunks: [String: Set<Int>] = [:]) {
        let done = Set(paths)
        for i in items.indices {
            if done.contains(items[i].path) {
                if let ids = hunks[items[i].path], items[i].hunks != nil {
                    items[i].appliedHunks.formUnion(ids)
                    items[i].selectedHunks = []
                    items[i].selected = false
                    items[i].applied = items[i].openHunks.isEmpty
                } else {
                    items[i].applied = true
                    items[i].selected = false
                    items[i].selectedHunks = []
                }
            }
            if let c = conflicts[items[i].path] {
                items[i].conflict = c
                items[i].selected = false
                items[i].selectedHunks = []
            }
        }
        mode = .list
    }

    /// Handles one key. `height` is the number of rows available for the
    /// list or diff body.
    public mutating func handle(_ key: Key, height: Int) -> Action {
        let page = max(1, height - 1)
        switch mode {
        case .confirm:
            if key == .char("y") || key == .char("Y") {
                mode = .list
                return .apply(selectedPaths, hunks: selectedHunks)
            }
            mode = .list
            message = "apply cancelled"
            return .none
        case .diff(let lines, let top):
            let maxTop = max(0, lines.count - height)
            var t = top
            switch key {
            case .up, .char("k"): t -= 1
            case .down, .char("j"), .enter: t += 1
            case .pageUp, .char("b"): t -= page
            case .pageDown, .space, .char("f"): t += page
            case .home, .char("g"): t = 0
            case .end, .char("G"): t = maxTop
            case .left, .escape, .char("q"), .char("h"): mode = .list; return .none
            default: return .none
            }
            mode = .diff(lines: lines, top: min(max(0, t), maxTop))
            return .none
        case .hunks(let lines, let starts, let hunk, let top):
            return handleHunks(key, lines: lines, starts: starts, hunk: hunk, top: top, height: height)
        case .list:
            guard !items.isEmpty else { return key == .char("q") || key == .escape ? .quit : .none }
            switch key {
            case .up, .char("k"): cursor -= 1
            case .down, .char("j"): cursor += 1
            case .pageUp: cursor -= page
            case .pageDown: cursor += page
            case .home, .char("g"): cursor = 0
            case .end, .char("G"): cursor = items.count - 1
            case .space:
                // A partly selected file becomes fully selected.
                items[cursor].set(!items[cursor].selected || items[cursor].isPartial)
            case .char("a"):
                let all = items.filter { !$0.applied }.allSatisfy { $0.selected && !$0.isPartial }
                for i in items.indices { items[i].set(!all) }
            case .enter, .right, .char("l"), .char("d"):
                return .openDiff(cursor)
            case .char("x"):
                confirmApply()
            case .char("q"), .escape:
                return .quit
            default:
                break
            }
            cursor = min(max(0, cursor), items.count - 1)
            if cursor < listTop { listTop = cursor }
            if cursor >= listTop + height { listTop = cursor - height + 1 }
            return .none
        }
    }

    private mutating func confirmApply() {
        if selectedCount == 0 {
            message = "nothing selected"
        } else {
            mode = .confirm
        }
    }

    /// Keys in the hunk view: move between hunks, toggle them, scroll.
    private mutating func handleHunks(_ key: Key, lines: [String], starts: [Int], hunk: Int, top: Int, height: Int) -> Action {
        let page = max(1, height - 1)
        let maxTop = max(0, lines.count - height)
        var h = hunk, t = top
        switch key {
        case .up, .char("k"), .down, .char("j"), .enter, .home, .char("g"), .end, .char("G"):
            switch key {
            case .up, .char("k"): h -= 1
            case .home, .char("g"): h = 0
            case .end, .char("G"): h = starts.count - 1
            default: h += 1
            }
            h = min(max(0, h), starts.count - 1)
            // Bring the hunk into view: all of it if it fits, else from its header.
            let first = starts[h], end = h + 1 < starts.count ? starts[h + 1] : lines.count
            if end - first > height || first < t { t = first } else if end > t + height { t = end - height }
        case .pageUp, .char("b"), .pageDown, .char("f"):
            t += key == .pageUp || key == .char("b") ? -page : page
            t = min(max(0, t), maxTop)
            // The cursor follows: the first hunk whose header is on screen,
            // else the one the top line belongs to.
            h = starts.firstIndex { $0 >= t && $0 < t + height } ?? starts.lastIndex { $0 <= t } ?? 0
        case .space:
            let id = items[cursor].hunks?[hunk].id ?? 0
            if !items[cursor].applied && !items[cursor].appliedHunks.contains(id) {
                if items[cursor].selectedHunks.contains(id) { items[cursor].selectedHunks.remove(id) } else { items[cursor].selectedHunks.insert(id) }
                items[cursor].selected = !items[cursor].selectedHunks.intersection(items[cursor].openHunks).isEmpty
            }
        case .char("a"): items[cursor].set(true)
        case .char("n"): items[cursor].set(false)
        case .char("x"):
            confirmApply()
            return .none
        case .left, .escape, .char("q"), .char("h"):
            mode = .list
            return .none
        default:
            return .none
        }
        mode = .hunks(lines: lines, starts: starts, hunk: h, top: min(max(0, t), maxTop))
        return .none
    }

    /// Plain rows for the body, at most `height` rows of at most `width`
    /// characters. `style` wraps text in terminal colors (identity for tests).
    public func body(width: Int, height: Int, style: (String, Style) -> String = { s, _ in s }) -> [String] {
        switch mode {
        case .diff(let lines, let top):
            return lines.dropFirst(top).prefix(height).map { line in
                let s = Self.clip(line, width)
                if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") { return style(s, .bold) }
                if line.hasPrefix("+") { return style(s, .added) }
                if line.hasPrefix("-") { return style(s, .deleted) }
                if line.hasPrefix("@@") { return style(s, .hunk) }
                return s
            }
        case .hunks(let lines, let starts, let hunk, let top):
            let it = items[cursor]
            let hunks = it.hunks ?? []
            var index = (starts.lastIndex(where: { $0 <= top }) ?? 0)
            return lines.indices.dropFirst(top).prefix(height).map { n in
                if index + 1 < starts.count && n >= starts[index + 1] { index += 1 }
                let id = hunks.indices.contains(index) ? hunks[index].id : 0
                let done = it.applied || it.appliedHunks.contains(id)
                let on = !done && it.selectedHunks.contains(id)
                if n == starts[index] {
                    let s = Self.clip("\(done ? "[=]" : on ? "[x]" : "[ ]") \(lines[n])\(done ? "  (applied)" : "")", width)
                    return index == hunk ? style(s.padding(toLength: max(s.count, width), withPad: " ", startingAt: 0), .cursor) : style(s, .hunk)
                }
                // Four spaces line the body up under the header's text.
                let s = Self.clip("    " + lines[n], width)
                if !on { return style(s, .dim) }
                if lines[n].hasPrefix("+") { return style(s, .added) }
                if lines[n].hasPrefix("-") { return style(s, .deleted) }
                return s
            }
        case .list, .confirm:
            if items.isEmpty { return ["no changes"] }
            return items.indices.dropFirst(listTop).prefix(height).map { i in
                let it = items[i]
                let box = it.applied ? "[=]" : it.isPartial ? "[~]" : it.selected ? "[x]" : "[ ]"
                let code = DiffRenderer.code(it.change.kind)
                var line = "\(box) \(code) \(it.path)"
                if it.applied { line += "  (applied)" }
                else if let hunks = it.hunks {
                    if it.isPartial { line += "  (\(it.selectedHunks.intersection(it.openHunks).count) of \(it.openHunks.count) hunks)" }
                    if !it.appliedHunks.isEmpty { line += "  (\(it.appliedHunks.count) of \(hunks.count) hunks applied)" }
                }
                if let c = it.conflict, !it.applied { line += "  CONFLICT: \(c)" }
                var s = Self.clip(line, width)
                if i == cursor { s = style(s.padding(toLength: max(s.count, width), withPad: " ", startingAt: 0), .cursor) }
                else if it.conflict != nil && !it.applied { s = style(s, .deleted) }
                else if it.applied { s = style(s, .dim) }
                return s
            }
        }
    }

    public var footer: String {
        switch mode {
        case .list: "space toggle  a all  enter diff/hunks  x apply selected  q quit"
        case .diff: "up/down scroll  space/b page  g/G top/end  q back"
        case .hunks: "j/k hunk  space toggle  a/n all/none  b/f page  x apply  q back"
        case .confirm:
            if selectedHunks.isEmpty {
                "apply \(selectedCount) selected path(s) to the project? y/N"
            } else {
                "apply \(selectedCount) selected path(s), \(selectedHunks.count) of them in part, to the project? y/N"
            }
        }
    }

    public enum Style: Sendable { case bold, added, deleted, hunk, cursor, dim }

    static func clip(_ s: String, _ width: Int) -> String {
        let clean = TextLines.visible(s).replacingOccurrences(of: "\t", with: "    ")
        return clean.count > width ? String(clean.prefix(max(0, width - 1))) + "~" : clean
    }
}

extension DiffRenderer {
    /// The one-letter code `diff --stat` uses.
    public static func code(_ kind: ChangeKind) -> String {
        switch kind {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .modeChanged: "P"
        case .symlinkChanged: "L"
        case .typeChanged: "T"
        case .unreadable: "?"
        }
    }

    /// The diff (or one-line note) for a single change.
    public func renderOne(_ c: Change) throws -> String { try render(c) }
}
