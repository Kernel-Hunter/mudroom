import Darwin
import Foundation

/// One path touched by an apply, with enough to put it back.
public struct RollbackEntry: Codable, Sendable, Equatable {
    public var path: String
    /// What the real project had before the apply.
    public var prior: FileNode
    /// What the apply wrote. Undo only restores a path still in this state.
    public var applied: FileNode
    /// For a prior regular file: its copy inside the bundle's `files/` dir.
    public var backup: String?
}

public struct RollbackManifest: Codable, Sendable {
    public var sessionID: String
    public var created: Date
    public var entries: [RollbackEntry]
    public var undone: Bool
}

public struct PathIssue: Sendable, Equatable, CustomStringConvertible {
    public let path: String
    public let reason: String
    public var description: String { "\(path): \(reason)" }
}

public struct ApplyReport: Sendable {
    public var applied: [String] = []
    /// The project already matched the agent's version.
    public var alreadyApplied: [String] = []
    /// Refused because the real project changed since the session started.
    public var conflicts: [PathIssue] = []
    public var skipped: [PathIssue] = []
    /// Rollback bundle directory, if anything was written.
    public var bundle: URL?
}

public struct UndoReport: Sendable {
    public var restored: [String] = []
    public var conflicts: [PathIssue] = []
}

/// Applies reviewed changes from a session's `work/` to the real project.
///
/// Safety rule: a path is only written if the real project still has exactly
/// what `base/` has (the state the agent started from). Anything else is a
/// conflict and is left alone.
public struct Applier {
    public let handle: SessionHandle
    private let fm = FileManager.default

    public init(handle: SessionHandle) { self.handle = handle }

    var project: URL { handle.project }

    static func normalize(_ selection: String) -> String {
        var s = selection
        while s.hasPrefix("./") { s.removeFirst(2) }
        while s.hasSuffix("/") && s.count > 1 { s.removeLast() }
        return s
    }

    static func matches(_ path: String, selection: [String]) -> Bool {
        selection.contains { sel in sel == "." || path == sel || path.hasPrefix(sel + "/") }
    }

    /// - Parameters:
    ///   - paths: project-relative paths (files or directories) to apply; nil applies everything.
    ///   - includeGit: also apply changes inside `.git/`.
    public func apply(paths: [String]?, includeGit: Bool = false) throws -> ApplyReport {
        let diff = try Differ.compare(base: handle.base, work: handle.work)
        var changes = diff.changes + (includeGit ? diff.gitMetadataChanges : [])
        var report = ApplyReport()

        if let paths {
            let selection = paths.map(Self.normalize)
            changes = changes.filter { Self.matches($0.path, selection: selection) }
            for sel in selection where sel != "." && !changes.contains(where: { Self.matches($0.path, selection: [sel]) }) {
                report.skipped.append(PathIssue(path: sel, reason: "no change at this path"))
            }
        }

        // Directories this apply will create; their children aren't blocked by
        // whatever currently sits at that path (it gets replaced first).
        let becomingDirs = Set(changes.filter { $0.after.isDirectory }.map(\.path))

        // Decide per path before writing anything.
        var planned: [Change] = []
        for change in changes {
            if case .special = change.after {
                report.skipped.append(PathIssue(path: change.path, reason: "special file (fifo/socket/device) not applied"))
                continue
            }
            if let bad = unsafeAncestor(of: change.path, allowing: becomingDirs) {
                report.conflicts.append(PathIssue(path: change.path, reason: "\(bad) in the project is not a plain directory"))
                continue
            }
            let real = try FileNode.read(at: project.appendingPathComponent(change.path))
            if real == change.after {
                report.alreadyApplied.append(change.path)
            } else if real != change.before {
                report.conflicts.append(PathIssue(
                    path: change.path,
                    reason: "project changed since the session started (expected \(describe(change.before)), found \(describe(real)))"))
            } else {
                planned.append(change)
            }
        }
        guard !planned.isEmpty else { return report }

        let bundle = try makeBundleDirectory()
        report.bundle = bundle
        var entries: [RollbackEntry] = []
        defer {
            let manifest = RollbackManifest(sessionID: handle.session.id, created: Date(), entries: entries, undone: false)
            try? Self.writeManifest(manifest, to: bundle)
        }

        func run(_ change: Change, _ body: () throws -> Void) {
            do {
                try body()
                if !report.applied.contains(change.path) { report.applied.append(change.path) }
            } catch {
                report.conflicts.append(PathIssue(path: change.path, reason: "\(error)"))
            }
        }

        // 1. Deletions, deepest first, so directories are empty when removed.
        for change in planned.filter({ $0.kind == .deleted }).sorted(by: { $0.path > $1.path }) {
            run(change) {
                let entry = try backup(change.path, prior: change.before, applied: .absent, bundle: bundle)
                try remove(project.appendingPathComponent(change.path), node: change.before)
                entries.append(entry)
            }
        }

        // 2. Everything else, parents before children.
        var deferredDirModes: [(String, UInt16)] = []
        for change in planned.filter({ $0.kind != .deleted }).sorted(by: { $0.path < $1.path }) {
            run(change) {
                if let bad = unsafeAncestor(of: change.path) {
                    throw MudroomError.invalid("\(bad) in the project is not a plain directory")
                }
                try createMissingParents(of: change.path, entries: &entries)
                let target = project.appendingPathComponent(change.path)
                let entry = try backup(change.path, prior: change.before, applied: change.after, bundle: bundle)
                switch (change.kind, change.after) {
                case (.modeChanged, .file(let mode, _, _)):
                    try chmodOrThrow(target, mode)
                case (.modeChanged, .directory(let mode)):
                    deferredDirModes.append((change.path, mode))
                default:
                    if change.kind == .typeChanged { try remove(target, node: change.before) }
                    try write(change.after, from: handle.work.appendingPathComponent(change.path), to: target,
                              deferredDirModes: &deferredDirModes, path: change.path)
                }
                entries.append(entry)
            }
        }

        // 3. Directory permissions last, so a read-only dir doesn't block its children.
        for (path, mode) in deferredDirModes.sorted(by: { $0.0 > $1.0 }) {
            try chmodOrThrow(project.appendingPathComponent(path), mode)
        }
        return report
    }

    // MARK: - Undo

    /// Restores the most recent apply that hasn't been undone.
    public func undo(force: Bool = false) throws -> UndoReport {
        guard let (bundle, manifest) = try latestBundle() else {
            throw MudroomError.nothingToUndo(handle.session.id)
        }
        var report = UndoReport()
        var dirModes: [(String, UInt16)] = []
        for entry in manifest.entries.reversed() {
            let target = project.appendingPathComponent(entry.path)
            do {
                if let bad = unsafeAncestor(of: entry.path) {
                    throw MudroomError.invalid("\(bad) in the project is not a plain directory")
                }
                let current = try FileNode.read(at: target)
                if current != entry.applied && current != entry.prior && !force {
                    report.conflicts.append(PathIssue(
                        path: entry.path,
                        reason: "changed after apply (expected \(describe(entry.applied)), found \(describe(current)))"))
                    continue
                }
                if current != entry.prior {
                    try restore(entry, current: current, bundle: bundle, dirModes: &dirModes)
                }
                report.restored.append(entry.path)
            } catch {
                report.conflicts.append(PathIssue(path: entry.path, reason: "\(error)"))
            }
        }
        for (path, mode) in dirModes.sorted(by: { $0.0 > $1.0 }) {
            try? chmodOrThrow(project.appendingPathComponent(path), mode)
        }
        var done = manifest
        done.undone = true
        try Self.writeManifest(done, to: bundle)
        return report
    }

    private func restore(_ entry: RollbackEntry, current: FileNode, bundle: URL, dirModes: inout [(String, UInt16)]) throws {
        let target = project.appendingPathComponent(entry.path)
        switch entry.prior {
        case .absent:
            try remove(target, node: current)
        case .file(let mode, _, _):
            guard let backup = entry.backup else { throw MudroomError.invalid("rollback bundle has no copy of \(entry.path)") }
            if current.isDirectory { try remove(target, node: current) }
            try placeFile(from: bundle.appendingPathComponent(backup), to: target, mode: mode)
        case .symlink(let dest):
            if current.isDirectory { try remove(target, node: current) }
            try placeSymlink(dest, at: target)
        case .directory(let mode):
            if !current.isDirectory {
                if current != .absent { try remove(target, node: current) }
                try mkdirOrThrow(target)
            }
            dirModes.append((entry.path, mode))
        case .special:
            throw MudroomError.invalid("cannot restore special file")
        }
    }

    func latestBundle() throws -> (URL, RollbackManifest)? {
        let root = handle.rollbackRoot
        guard fm.fileExists(atPath: root.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for name in try fm.contentsOfDirectory(atPath: root.path).sorted().reversed() {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { continue }
            let manifest = try decoder.decode(RollbackManifest.self, from: data)
            if !manifest.undone { return (dir, manifest) }
        }
        return nil
    }

    // MARK: - Helpers

    private func makeBundleDirectory() throws -> URL {
        try fm.createDirectory(at: handle.rollbackRoot, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(atPath: handle.rollbackRoot.path)) ?? []
        let next = (existing.compactMap(Int.init).max() ?? 0) + 1
        let dir = handle.rollbackRoot.appendingPathComponent(String(format: "%04d", next), isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent("files"), withIntermediateDirectories: true)
        return dir
    }

    static func writeManifest(_ manifest: RollbackManifest, to bundle: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: bundle.appendingPathComponent("manifest.json"), options: .atomic)
    }

    /// Returns the first ancestor of `path` in the real project that exists but
    /// isn't a real directory (e.g. a symlink), which would let a write escape.
    func unsafeAncestor(of path: String, allowing allowed: Set<String> = []) -> String? {
        var components = path.split(separator: "/").map(String.init)
        components.removeLast()
        var current = ""
        for c in components {
            current = current.isEmpty ? c : current + "/" + c
            if allowed.contains(current) { continue }
            switch (try? FileNode.read(at: project.appendingPathComponent(current))) ?? .special {
            case .directory, .absent: continue
            default: return current
            }
        }
        return nil
    }

    /// Records the prior state (copying a regular file into the bundle).
    private func backup(_ path: String, prior: FileNode, applied: FileNode, bundle: URL) throws -> RollbackEntry {
        var entry = RollbackEntry(path: path, prior: prior, applied: applied, backup: nil)
        if case .file = prior {
            let rel = "files/" + path
            let dest = bundle.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Cloner.cloneItem(from: project.appendingPathComponent(path), to: dest)
            entry.backup = rel
        }
        return entry
    }

    /// Creates parent directories that exist in work/ but not in the project,
    /// e.g. when only `new/dir/file.txt` was selected.
    private func createMissingParents(of path: String, entries: inout [RollbackEntry]) throws {
        var components = path.split(separator: "/").map(String.init)
        components.removeLast()
        var current = ""
        for c in components {
            current = current.isEmpty ? c : current + "/" + c
            let target = project.appendingPathComponent(current)
            if try FileNode.read(at: target) == .absent {
                let workNode = try FileNode.read(at: handle.work.appendingPathComponent(current))
                try mkdirOrThrow(target)
                if let mode = workNode.mode { try chmodOrThrow(target, mode) }
                entries.append(RollbackEntry(path: current, prior: .absent, applied: try FileNode.read(at: target), backup: nil))
            }
        }
    }

    private func write(_ node: FileNode, from source: URL, to target: URL,
                       deferredDirModes: inout [(String, UInt16)], path: String) throws {
        switch node {
        case .file(let mode, _, _):
            try placeFile(from: source, to: target, mode: mode)
        case .symlink(let dest):
            try placeSymlink(dest, at: target)
        case .directory(let mode):
            try mkdirOrThrow(target)
            deferredDirModes.append((path, mode))
        case .absent, .special:
            break
        }
    }

    /// Copies to a temp name next to the target, then renames over it.
    private func placeFile(from source: URL, to target: URL, mode: UInt16) throws {
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".mudroom-tmp-\(UUID().uuidString.prefix(8))-" + target.lastPathComponent)
        try Cloner.cloneItem(from: source, to: tmp)
        do {
            try chmodOrThrow(tmp, mode)
            if rename(tmp.path, target.path) != 0 { throw MudroomError.posix("rename", target.path, errno) }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    private func placeSymlink(_ dest: String, at target: URL) throws {
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".mudroom-tmp-\(UUID().uuidString.prefix(8))-" + target.lastPathComponent)
        if symlink(dest, tmp.path) != 0 { throw MudroomError.posix("symlink", tmp.path, errno) }
        if rename(tmp.path, target.path) != 0 {
            let err = errno
            unlink(tmp.path)
            throw MudroomError.posix("rename", target.path, err)
        }
    }

    /// Removes one entry. Directories must already be empty (rmdir), so an
    /// unexpected file in the project stops the removal instead of vanishing.
    private func remove(_ target: URL, node: FileNode) throws {
        if node.isDirectory {
            if rmdir(target.path) != 0 { throw MudroomError.posix("rmdir", target.path, errno) }
        } else if node != .absent {
            if unlink(target.path) != 0 { throw MudroomError.posix("unlink", target.path, errno) }
        }
    }

    private func mkdirOrThrow(_ target: URL) throws {
        if mkdir(target.path, 0o755) != 0 { throw MudroomError.posix("mkdir", target.path, errno) }
    }

    private func chmodOrThrow(_ target: URL, _ mode: UInt16) throws {
        if chmod(target.path, mode_t(mode)) != 0 { throw MudroomError.posix("chmod", target.path, errno) }
    }

    private func describe(_ node: FileNode) -> String {
        switch node {
        case .absent: "nothing"
        case .file(let mode, let size, let sha): "file \(DiffRenderer.octal(mode)) \(size)B \(sha.prefix(8))"
        case .symlink(let t): "symlink -> \(t)"
        case .directory(let mode): "directory \(DiffRenderer.octal(mode))"
        case .special: "special file"
        }
    }
}
