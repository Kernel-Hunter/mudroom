import Foundation

public enum ChangeKind: String, Codable, Sendable, CaseIterable {
    case added
    case modified
    case deleted
    /// Same content, different permission bits.
    case modeChanged = "mode-changed"
    /// Symlink that now points somewhere else.
    case symlinkChanged = "symlink-changed"
    /// A path whose type changed, e.g. a file replaced by a symlink.
    case typeChanged = "type-changed"
}

public struct Change: Equatable, Sendable {
    public let path: String
    public let kind: ChangeKind
    public let before: FileNode
    public let after: FileNode

    public init(path: String, kind: ChangeKind, before: FileNode, after: FileNode) {
        self.path = path
        self.kind = kind
        self.before = before
        self.after = after
    }

    /// True for files whose content changed (as opposed to mode-only changes).
    public var contentChanged: Bool {
        switch (before, after) {
        case (.file(_, _, let a), .file(_, _, let b)): a != b
        default: false
        }
    }
}

public struct DiffResult: Sendable {
    /// Changes outside `.git/`, sorted by path.
    public var changes: [Change]
    /// Number of changed entries inside `.git/` (hidden unless asked for).
    public var gitMetadataChanges: [Change]

    public var isEmpty: Bool { changes.isEmpty && gitMetadataChanges.isEmpty }
}

public enum Differ {
    public static func isGitInternal(_ path: String) -> Bool {
        path == ".git" || path.hasPrefix(".git/")
    }

    public static func compare(base: URL, work: URL) throws -> DiffResult {
        compare(base: try TreeSnapshot.scan(base), work: try TreeSnapshot.scan(work))
    }

    public static func compare(base: TreeSnapshot, work: TreeSnapshot) -> DiffResult {
        var changes: [Change] = []
        var git: [Change] = []
        let paths = Set(base.nodes.keys).union(work.nodes.keys).sorted()
        for path in paths {
            let before = base.nodes[path] ?? .absent
            let after = work.nodes[path] ?? .absent
            guard let kind = classify(before: before, after: after) else { continue }
            let change = Change(path: path, kind: kind, before: before, after: after)
            if isGitInternal(path) { git.append(change) } else { changes.append(change) }
        }
        return DiffResult(changes: changes, gitMetadataChanges: git)
    }

    /// Returns nil when nothing reviewable changed.
    public static func classify(before: FileNode, after: FileNode) -> ChangeKind? {
        switch (before, after) {
        case (.absent, .absent):
            return nil
        case (.absent, _):
            return .added
        case (_, .absent):
            return .deleted
        case (.file(let m1, _, let h1), .file(let m2, _, let h2)):
            if h1 != h2 { return .modified }
            return m1 != m2 ? .modeChanged : nil
        case (.symlink(let t1), .symlink(let t2)):
            return t1 == t2 ? nil : .symlinkChanged
        case (.directory(let m1), .directory(let m2)):
            return m1 == m2 ? nil : .modeChanged
        case (.special, .special):
            return nil
        default:
            return .typeChanged
        }
    }
}
