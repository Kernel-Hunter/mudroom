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
    /// Changes at paths the session's exclude patterns match: files the
    /// agent created there itself (the clones never had any). Listed, never
    /// applied.
    public var excludedChanges: [Change] = []

    public init(changes: [Change], gitMetadataChanges: [Change], excludedChanges: [Change] = []) {
        self.changes = changes
        self.gitMetadataChanges = gitMetadataChanges
        self.excludedChanges = excludedChanges
    }

    public var isEmpty: Bool { changes.isEmpty && gitMetadataChanges.isEmpty && excludedChanges.isEmpty }

    /// `excludedChanges` without the entries inside an excluded folder that
    /// is itself listed: what to name in a summary.
    public var excludedTopLevel: [Change] { Differ.topmost(excludedChanges) }

    /// `excludedTopLevel` as paths, folders ending in `/`.
    public var excludedNames: [String] {
        excludedTopLevel.map { $0.path + ($0.after.isDirectory || $0.before.isDirectory ? "/" : "") }
    }
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
        case ExcludeList.ignoreFileName where parts.count == 1: return "changes which files Mudroom keeps out of the sandbox"
        default: break
        }
        if parent == ".vscode", ["tasks.json", "settings.json", "launch.json", "extensions.json"].contains(name) {
            return "VS Code can run commands from this file"
        }
        if name.hasSuffix(".code-workspace") { return "VS Code can run commands from this file" }
        if parts.dropLast().contains(where: { $0 == ".husky" || $0 == ".githooks" }) {
            return "a git hook script that runs on the host"
        }
        // Inside .git (applied only with --include-git).
        if parent == ".git", name == "config" {
            return "git runs commands this file names (core.fsmonitor, core.hooksPath, aliases)"
        }
        if parent == "hooks", parts.dropLast(2).last == ".git" {
            return "a git hook script that runs on the host"
        }
        return nil
    }

    /// Files an agent leaves in the project for itself (Aider's repo-map
    /// cache and history files). Listed like any change, but not selected
    /// by default: they rarely belong in the real project.
    public static func agentArtifact(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        if parts.contains(where: { $0.hasPrefix(".aider.tags.cache.v") }) { return "Aider's repo-map cache, not part of your project" }
        if let name = parts.last, [".aider.chat.history.md", ".aider.input.history", ".aider.llm.history"].contains(String(name)) {
            return "Aider's history file, not part of your project"
        }
        return nil
    }

    /// The changes not inside another listed change's folder.
    public static func topmost(_ changes: [Change]) -> [Change] {
        let paths = Set(changes.map(\.path))
        return changes.filter { c in
            var p = Substring(c.path)
            while let slash = p.lastIndex(of: "/") {
                p = p[..<slash]
                if paths.contains(String(p)) { return false }
            }
            return true
        }
    }

    /// `hostRisk`, else `agentArtifact`: why a path starts unselected.
    public static func reviewNote(_ path: String) -> String? {
        hostRisk(path) ?? agentArtifact(path)
    }

    /// A session's base against its work copy, with its exclude patterns.
    public static func compare(_ handle: SessionHandle) throws -> DiffResult {
        try compare(base: handle.base, work: handle.work, exclude: handle.session.excludeRules)
    }

    /// Changes at paths `exclude` matches go to `excludedChanges`.
    public static func compare(base: URL, work: URL, exclude: ExcludeRules = .empty) throws -> DiffResult {
        // The two trees are independent; scan them side by side.
        let scans = parallelMap([base, work]) { url in Result { try TreeSnapshot.scan(url) } }
        let a = scans[0], b = scans[1]
        return compare(base: try a.get(), work: try b.get(), exclude: exclude)
    }

    public static func compare(base: TreeSnapshot, work: TreeSnapshot, exclude: ExcludeRules = .empty) -> DiffResult {
        var changes: [Change] = []
        var git: [Change] = []
        var excluded: [Change] = []
        var folders: [String: String?] = [:]
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
            if !exclude.isEmpty, exclude.match(path, before: before, after: after, folders: &folders) != nil {
                excluded.append(change)
            } else if isGitInternal(path) {
                git.append(change)
            } else {
                changes.append(change)
            }
        }
        return DiffResult(changes: changes, gitMetadataChanges: git, excludedChanges: excluded)
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
