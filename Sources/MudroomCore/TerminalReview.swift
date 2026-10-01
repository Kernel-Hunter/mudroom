import Foundation

/// State for `mudroom review`, the terminal review screen: a list of
/// changed paths with checkboxes, and a scrollable diff of one of them.
/// Pure state and plain-text rendering; the CLI handles the terminal.
public struct TerminalReview: Sendable {
    public struct Item: Sendable, Equatable {
        public var change: Change
        public var selected: Bool
        /// Set when a dry run reports a conflict; such paths start unselected.
        public var conflict: String?
        public var applied = false

        public var path: String { change.path }
    }

    public enum Mode: Sendable, Equatable {
        case list
        case diff(lines: [String], top: Int)
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
        /// The user confirmed: apply these paths.
        case apply([String])
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

    public var selectedPaths: [String] { items.filter { $0.selected && !$0.applied }.map(\.path) }

    public mutating func showDiff(_ text: String) {
        mode = .diff(lines: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), top: 0)
    }

    public mutating func markApplied(_ paths: [String], conflicts: [String: String]) {
        let done = Set(paths)
        for i in items.indices {
            if done.contains(items[i].path) {
                items[i].applied = true
                items[i].selected = false
            }
            if let c = conflicts[items[i].path] {
                items[i].conflict = c
                items[i].selected = false
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
                return .apply(selectedPaths)
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
                if !items[cursor].applied { items[cursor].selected.toggle() }
            case .char("a"):
                let all = items.filter { !$0.applied }.allSatisfy(\.selected)
                for i in items.indices where !items[i].applied { items[i].selected = !all }
            case .enter, .right, .char("l"), .char("d"):
                return .openDiff(cursor)
            case .char("x"):
                if selectedPaths.isEmpty {
                    message = "nothing selected"
                } else {
                    mode = .confirm
                }
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
        case .list, .confirm:
            if items.isEmpty { return ["no changes"] }
            return items.indices.dropFirst(listTop).prefix(height).map { i in
                let it = items[i]
                let box = it.applied ? "[=]" : it.selected ? "[x]" : "[ ]"
                let code = DiffRenderer.code(it.change.kind)
                var line = "\(box) \(code) \(it.path)"
                if it.applied { line += "  (applied)" }
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
        case .list: "space toggle  a all  enter diff  x apply selected  q quit"
        case .diff: "up/down scroll  space/b page  g/G top/end  q back"
        case .confirm: "apply \(selectedPaths.count) selected path(s) to the project? y/N"
        }
    }

    public enum Style: Sendable { case bold, added, deleted, hunk, cursor, dim }

    static func clip(_ s: String, _ width: Int) -> String {
        let clean = s.replacingOccurrences(of: "\t", with: "    ")
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
