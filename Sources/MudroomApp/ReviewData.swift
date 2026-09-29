import Foundation
import MudroomCore

/// How a changed path is grouped in the file list.
enum ChangeGroup: Int, CaseIterable, Sendable, Comparable {
    case added, modified, deleted, other

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    init(_ kind: ChangeKind) {
        switch kind {
        case .added: self = .added
        case .modified: self = .modified
        case .deleted: self = .deleted
        case .modeChanged, .symlinkChanged, .typeChanged: self = .other
        }
    }

    var title: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .other: "Mode & Type"
        }
    }
}

/// What the right pane can show for a file.
enum FileContent: Sendable {
    /// Line diff. `partial` is true when hunks can be picked one by one
    /// (modified text files); added/deleted files are all-or-nothing.
    case text(hunks: [Hunk], partial: Bool)
    case binary(before: Int64?, after: Int64?)
    case tooLarge(Int64)
    /// Mode, symlink, directory and type changes: a short description.
    case meta(title: String, detail: String)
}

struct FileEntry: Identifiable, Sendable {
    var id: String { change.path }
    let change: Change
    let content: FileContent
    /// Why applying this path is refused, from the Applier's preflight.
    var conflict: String?
    /// The project already matches the agent's version.
    var isApplied: Bool
    /// Hunks already in the project from an earlier partial apply.
    var appliedHunks: Set<Int>

    var path: String { change.path }
    var group: ChangeGroup { ChangeGroup(change.kind) }
    var name: String { (path as NSString).lastPathComponent }
    var directory: String {
        let d = (path as NSString).deletingLastPathComponent
        return d.isEmpty ? "" : d + "/"
    }

    var hunks: [Hunk] {
        if case .text(let h, _) = content { return h }
        return []
    }

    var allowsPartial: Bool {
        if case .text(_, true) = content { return true }
        return false
    }

    var added: Int { hunks.reduce(0) { $0 + $1.added } }
    var removed: Int { hunks.reduce(0) { $0 + $1.removed } }
    var canApply: Bool { conflict == nil && !isApplied }
}

/// Everything the review screen needs, computed off the main thread.
struct ReviewSnapshot: Sendable {
    var files: [FileEntry]
    /// Deleted directories that aren't shown as rows (their contents are).
    /// Applied when every row under them is selected.
    var hiddenDeletedDirectories: [String]
    var gitMetadataChanges: Int
    var canUndo: Bool

    static let maxTextBytes: Int64 = 4 << 20

    static func load(_ handle: SessionHandle) throws -> ReviewSnapshot {
        let diff = try Differ.compare(base: handle.base, work: handle.work)
        let applier = Applier(handle: handle)
        let preflight = try applier.preflight()
        let conflicts = Dictionary(preflight.conflicts.map { ($0.path, $0.reason) }, uniquingKeysWith: { a, _ in a })
        let applied = Set(preflight.alreadyApplied)

        let paths = diff.changes.map(\.path)
        func hasChildChange(_ dir: String) -> Bool {
            paths.contains { $0.hasPrefix(dir + "/") }
        }

        var files: [FileEntry] = []
        var hiddenDeleted: [String] = []
        for change in diff.changes {
            let isDir = change.after.isDirectory || (change.kind == .deleted && change.before.isDirectory)
            if isDir && (change.kind == .added || change.kind == .deleted) && hasChildChange(change.path) {
                if change.kind == .deleted { hiddenDeleted.append(change.path) }
                continue
            }
            let content = try Self.content(for: change, handle: handle, applier: applier)
            var appliedHunks: Set<Int> = []
            if case .text(_, true) = content { appliedHunks = (try? applier.appliedHunks(for: change)) ?? [] }
            files.append(FileEntry(change: change, content: content, conflict: conflicts[change.path],
                                   isApplied: applied.contains(change.path), appliedHunks: appliedHunks))
        }
        files.sort { ($0.group, $0.path) < ($1.group, $1.path) }
        return ReviewSnapshot(files: files, hiddenDeletedDirectories: hiddenDeleted,
                              gitMetadataChanges: diff.gitMetadataChanges.count, canUndo: applier.canUndo)
    }

    static func content(for change: Change, handle: SessionHandle, applier: Applier) throws -> FileContent {
        let beforeURL = handle.base.appendingPathComponent(change.path)
        let afterURL = handle.work.appendingPathComponent(change.path)
        switch (change.kind, change.before, change.after) {
        case (.modified, .file, .file):
            if max(change.before.size ?? 0, change.after.size ?? 0) > maxTextBytes {
                return .tooLarge(change.after.size ?? 0)
            }
            if let hunks = try applier.hunks(for: change) { return .text(hunks: hunks, partial: true) }
            return .binary(before: change.before.size, after: change.after.size)
        case (.added, _, .file(_, let size, _)):
            if size > maxTextBytes { return .tooLarge(size) }
            if try DiffRenderer.looksBinary(afterURL) { return .binary(before: nil, after: size) }
            return .text(hunks: LineDiff.hunks(base: Data(), work: try Data(contentsOf: afterURL)), partial: false)
        case (.deleted, .file(_, let size, _), _):
            if size > maxTextBytes { return .tooLarge(size) }
            if try DiffRenderer.looksBinary(beforeURL) { return .binary(before: size, after: nil) }
            return .text(hunks: LineDiff.hunks(base: try Data(contentsOf: beforeURL), work: Data()), partial: false)
        case (.modeChanged, let b, let a):
            return .meta(title: "Permissions changed",
                         detail: "\(permString(b.mode)) → \(permString(a.mode))")
        case (.symlinkChanged, .symlink(let t1), .symlink(let t2)):
            return .meta(title: "Symlink target changed", detail: "\(t1) → \(t2)")
        case (.added, _, .symlink(let t)):
            return .meta(title: "New symlink", detail: "→ \(t)")
        case (.deleted, .symlink(let t), _):
            return .meta(title: "Symlink removed", detail: "was → \(t)")
        case (.added, _, .directory):
            return .meta(title: "New empty folder", detail: change.path + "/")
        case (.deleted, .directory, _):
            return .meta(title: "Folder removed", detail: change.path + "/")
        case (.typeChanged, let b, let a):
            return .meta(title: "Type changed", detail: "\(b.kindName) → \(a.kindName)")
        default:
            return .meta(title: change.kind.rawValue.capitalized, detail: change.path)
        }
    }

    static func permString(_ mode: UInt16?) -> String {
        guard let mode else { return "-" }
        let chars = Array("rwxrwxrwx")
        let bits = (0..<9).map { i in (mode >> (8 - i)) & 1 == 1 ? String(chars[i]) : "-" }.joined()
        return "\(String(mode, radix: 8)) (\(bits))"
    }
}
