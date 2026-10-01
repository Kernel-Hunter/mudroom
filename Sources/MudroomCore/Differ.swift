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
    /// Couldn't be read on one side (permissions, or it changed while being
    /// read). Shown so nothing is hidden, never applied.
    case unreadable
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
    /// Changes outside git internals, sorted by path.
    public var changes: [Change]
    /// Changed entries inside any `.git` (the project's, a nested repo's,
    /// any case spelling). Hidden and never applied unless asked for.
    public var gitMetadataChanges: [Change]

    public var isEmpty: Bool { changes.isEmpty && gitMetadataChanges.isEmpty }
}

public enum Differ {
    /// True for a path with any component named `.git`, compared without
    /// case: `vendor/lib/.git/config` (a nested repo) and `.GIT/HEAD`
    /// (which *is* `.git` on a case-insensitive volume) included.
    public static func isGitInternal(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.count == 4 && $0.lowercased() == ".git" }
    }

    /// Why a path deserves a second look before it reaches the real
    /// project: files that tools on the host read and act on. Nil for
    /// ordinary files. These are never selected by default in the app.
    public static func hostRisk(_ path: String) -> String? {
        let parts = path.split(separator: "/").map { $0.lowercased() }
        guard let name = parts.last else { return nil }
        let parent = parts.dropLast().last
        switch name {
        case ".envrc": return "direnv runs this file when you enter the folder"
        case ".gitmodules": return "sets submodule URLs and paths for git"
        case ".gitattributes": return "can name filter and diff drivers that git runs"
        case ".pre-commit-config.yaml": return "pre-commit runs the hooks listed here"
        case ".npmrc", ".yarnrc", ".yarnrc.yml": return "package manager settings (registries, scripts)"
        default: break
        }
        if parent == ".vscode", ["tasks.json", "settings.json", "launch.json", "extensions.json"].contains(name) {
            return "VS Code can run commands from this file"
        }
        if name.hasSuffix(".code-workspace") { return "VS Code can run commands from this file" }
        if parts.dropLast().contains(where: { $0 == ".husky" || $0 == ".githooks" }) {
            return "a git hook script that runs on the host"
        }
        return nil
    }

    public static func compare(base: URL, work: URL) throws -> DiffResult {
        // The two trees are independent; scan them side by side.
        var a: Result<TreeSnapshot, Error> = .failure(MudroomError.invalid("not scanned"))
        var b: Result<TreeSnapshot, Error> = .failure(MudroomError.invalid("not scanned"))
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            if i == 0 { a = Result { try TreeSnapshot.scan(base) } } else { b = Result { try TreeSnapshot.scan(work) } }
        }
        return compare(base: try a.get(), work: try b.get())
    }

    public static func compare(base: TreeSnapshot, work: TreeSnapshot) -> DiffResult {
        var changes: [Change] = []
        var git: [Change] = []
        // Below a directory that couldn't be listed on either side nothing
        // can be compared; only the directory itself is reported.
        let blind = Set((base.nodes.filter { $0.value.isUnreadable } .map(\.key))
                        + (work.nodes.filter { $0.value.isUnreadable }.map(\.key)))
        func underBlind(_ path: String) -> Bool {
            guard !blind.isEmpty else { return false }
            var p = Substring(path)
            while let slash = p.lastIndex(of: "/") {
                p = p[..<slash]
                if blind.contains(String(p)) { return true }
            }
            return false
        }
        var paths = Array(base.nodes.keys)
        for k in work.nodes.keys where base.nodes[k] == nil { paths.append(k) }
        paths.sort()
        for path in paths {
            let before = base.nodes[path] ?? .absent
            let after = work.nodes[path] ?? .absent
            guard let kind = classify(before: before, after: after), !underBlind(path) else { continue }
            let change = Change(path: path, kind: kind, before: before, after: after)
            if isGitInternal(path) { git.append(change) } else { changes.append(change) }
        }
        return DiffResult(changes: changes, gitMetadataChanges: git)
    }

    /// Returns nil when nothing reviewable changed.
    public static func classify(before: FileNode, after: FileNode) -> ChangeKind? {
        switch (before, after) {
        case (.absent, .absent), (.unreadable, .unreadable):
            return nil
        case (.unreadable, _), (_, .unreadable):
            return .unreadable
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
