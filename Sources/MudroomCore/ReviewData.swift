import Foundation

/// How a changed path is grouped in the review list.
public enum ChangeGroup: Int, CaseIterable, Sendable, Comparable {
    case added, modified, deleted, other

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public init(_ kind: ChangeKind) {
        switch kind {
        case .added: self = .added
        case .modified: self = .modified
        case .deleted: self = .deleted
        case .modeChanged, .symlinkChanged, .typeChanged, .unreadable: self = .other
        }
    }

    public var title: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .other: "Mode & Type"
        }
    }
}

/// What the detail pane can show for a file.
public enum FileContent: Sendable {
    /// Line diff of a modified text file; hunks can be picked one by one.
    case text(hunks: [Hunk], partial: Bool)
    /// An added or deleted text file. Only the line count is loaded up
    /// front; the lines themselves come from `ReviewSnapshot.detail`.
    case lines(added: Int, removed: Int)
    case binary(before: Int64?, after: Int64?)
    case tooLarge(Int64)
    /// Mode, symlink, directory, type and unreadable changes.
    case meta(title: String, detail: String)
}

public struct FileEntry: Identifiable, Sendable {
    public var id: String { change.path }
    public let change: Change
    public let content: FileContent
    /// Why applying this path is refused, from the Applier's preflight.
    public var conflict: String?
    /// The project already matches the agent's version.
    public var isApplied: Bool
    /// Hunks already in the project from an earlier partial apply.
    public var appliedHunks: Set<Int>
    /// Shown for a timeline comparison (snapshot to work): look, don't apply.
    public var readOnly = false
    public let added: Int
    public let removed: Int
    /// Set for files that tools on the host act on (`Differ.hostRisk`),
    /// agent caches (`Differ.agentArtifact`) or files that carry
    /// setuid/setgid bits. A phrase, as in "Check before applying: <warning>."
    /// Never selected by default.
    public let warning: String?

    public init(change: Change, content: FileContent, conflict: String? = nil, isApplied: Bool = false,
                appliedHunks: Set<Int> = [], readOnly: Bool = false) {
        self.change = change
        self.content = content
        self.conflict = conflict
        self.isApplied = isApplied
        self.appliedHunks = appliedHunks
        self.readOnly = readOnly
        switch content {
        case .text(let hunks, _):
            added = hunks.reduce(0) { $0 + $1.added }
            removed = hunks.reduce(0) { $0 + $1.removed }
        case .lines(let a, let r):
            added = a
            removed = r
        default:
            added = 0
            removed = 0
        }
        if let risk = Differ.reviewNote(change.path) {
            warning = risk
        } else if let m = change.after.mode, m & 0o6000 != 0 {
            warning = "it has the setuid/setgid bit, which Mudroom drops when applying"
        } else {
            warning = nil
        }
    }

    public var path: String { change.path }
    public var group: ChangeGroup { ChangeGroup(change.kind) }
    public var name: String { (path as NSString).lastPathComponent }
    public var directory: String {
        let d = (path as NSString).deletingLastPathComponent
        return d.isEmpty ? "" : d + "/"
    }

    public var hunks: [Hunk] {
        if case .text(let h, _) = content { return h }
        return []
    }

    public var allowsPartial: Bool {
        if case .text(_, true) = content { return true }
        return false
    }

    /// Hunk ids still open (not applied yet).
    public var openHunks: Set<Int> { Set(hunks.map(\.id)).subtracting(appliedHunks) }

    public var canApply: Bool { conflict == nil && !isApplied && !readOnly && change.kind != .unreadable }
    /// Selected when the review opens.
    public var selectedByDefault: Bool { canApply && warning == nil }
}

/// A directory with so many changed rows that it is shown as one row.
public struct FolderSummary: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    /// Indices into `ReviewSnapshot.files`.
    public let rows: [Int]
    public let counts: [ChangeGroup: Int]

    public var title: String {
        let parts = ChangeGroup.allCases.compactMap { g -> String? in
            guard let n = counts[g], n > 0 else { return nil }
            return "\(n.formatted()) \(g.title.lowercased())"
        }
        return parts.joined(separator: ", ")
    }
}

/// Everything the review screen needs, computed off the main thread.
public struct ReviewSnapshot: Sendable {
    /// Rows, sorted by group then path.
    public var files: [FileEntry]
    /// Deleted directories that aren't shown as rows (their contents are).
    /// Applied when every row under them is selected.
    public var hiddenDeletedDirectories: [String]
    public var gitMetadataChanges: Int
    public var canUndo: Bool
    /// The changes as loaded: passed to the Applier so only what was
    /// reviewed is applied.
    public var reviewed: ReviewedChanges
    /// Directories shown collapsed (more than `collapseThreshold` rows).
    public var folders: [FolderSummary]
    public var totalAdded: Int
    public var totalRemoved: Int
    /// Path -> index in `files`.
    public var index: [String: Int]

    public static let maxTextBytes: Int64 = 4 << 20
    public static let collapseThreshold = 400

    public init(files: [FileEntry], hiddenDeletedDirectories: [String] = [], gitMetadataChanges: Int = 0,
                canUndo: Bool = false, reviewed: ReviewedChanges = ReviewedChanges([])) {
        self.files = files
        self.hiddenDeletedDirectories = hiddenDeletedDirectories
        self.gitMetadataChanges = gitMetadataChanges
        self.canUndo = canUndo
        self.reviewed = reviewed
        totalAdded = files.reduce(0) { $0 + $1.added }
        totalRemoved = files.reduce(0) { $0 + $1.removed }
        index = Dictionary(files.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
        folders = Self.collapse(files)
    }

    public static let empty = ReviewSnapshot(files: [])

    public func entry(_ path: String?) -> FileEntry? {
        guard let path, let i = index[path] else { return nil }
        return files[i]
    }

    /// Shallowest directories holding more than `collapseThreshold` rows.
    static func collapse(_ files: [FileEntry]) -> [FolderSummary] {
        guard files.count > collapseThreshold else { return [] }
        var counts: [String: Int] = [:]
        for f in files {
            var p = Substring(f.path)
            while let slash = p.lastIndex(of: "/") {
                p = p[..<slash]
                counts[String(p), default: 0] += 1
            }
        }
        let big = Set(counts.filter { $0.value > collapseThreshold }.map(\.key))
        let top = big.filter { dir in
            var p = Substring(dir)
            while let slash = p.lastIndex(of: "/") {
                p = p[..<slash]
                if big.contains(String(p)) { return false }
            }
            return true
        }
        guard !top.isEmpty else { return [] }
        var rows: [String: [Int]] = [:]
        for (i, f) in files.enumerated() {
            var p = Substring(f.path)
            while let slash = p.lastIndex(of: "/") {
                p = p[..<slash]
                if top.contains(String(p)) {
                    rows[String(p), default: []].append(i)
                    break
                }
            }
        }
        return rows.keys.sorted().map { dir in
            let idx = rows[dir]!
            var c: [ChangeGroup: Int] = [:]
            for i in idx { c[files[i].group, default: 0] += 1 }
            return FolderSummary(path: dir, rows: idx, counts: c)
        }
    }

    /// Changes from `from` (a snapshot directory) to work/, read-only: the
    /// review timeline. Apply always works on base -> work.
    public static func loadTimeline(_ handle: SessionHandle, from: URL) throws -> ReviewSnapshot {
        let diff = try Differ.compare(base: from, work: handle.work)
        let rows = visibleRows(diff.changes)
        let contents = parallelMap(rows.map(\.0)) { change in
            (try? content(for: change, before: from, after: handle.work, applier: nil)) ?? .meta(title: "Unreadable", detail: change.path)
        }
        var files = zip(rows, contents).map { FileEntry(change: $0.0.0, content: $0.1, readOnly: true) }
        files.sort { ($0.group, $0.path) < ($1.group, $1.path) }
        return ReviewSnapshot(files: files, gitMetadataChanges: diff.gitMetadataChanges.count)
    }

    /// Rows to show: every change except added or deleted directories that
    /// have changed children (those children are shown instead).
    static func visibleRows(_ changes: [Change]) -> [(Change, hiddenDeletedDir: Bool)] {
        var parents = Set<String>()
        for c in changes {
            var p = Substring(c.path)
            while let slash = p.lastIndex(of: "/") {
                p = p[..<slash]
                if !parents.insert(String(p)).inserted { break }
            }
        }
        var out: [(Change, Bool)] = []
        for change in changes {
            let isDir = change.after.isDirectory || (change.kind == .deleted && change.before.isDirectory)
            if isDir && (change.kind == .added || change.kind == .deleted) && parents.contains(change.path) {
                out.append((change, true))
                continue
            }
            out.append((change, false))
        }
        return out
    }

    public static func load(_ handle: SessionHandle) throws -> ReviewSnapshot {
        let diff = try Differ.compare(base: handle.base, work: handle.work)
        let applier = Applier(handle: handle)
        let preflight = try applier.preflight(diff: diff)
        let conflicts = Dictionary(preflight.conflicts.map { ($0.path, $0.reason) }, uniquingKeysWith: { a, _ in a })
        let applied = Set(preflight.alreadyApplied)
        let written = applier.lastWrittenIndex()

        let all = visibleRows(diff.changes)
        let hiddenDeleted = all.filter { $0.1 && $0.0.kind == .deleted }.map(\.0.path)
        let rows = all.filter { !$0.1 }.map(\.0)
        let loaded: [(FileContent, Set<Int>)] = parallelMap(rows) { change in
            let content: FileContent
            do {
                content = try Self.content(for: change, before: handle.base, after: handle.work, applier: applier)
            } catch {
                return (.meta(title: "Can't show this file", detail: "\(error)"), [])
            }
            guard case .text(let hunks, true) = content else { return (content, []) }
            // Hunks already in the project from an earlier partial apply.
            let real = (try? FileNode.read(at: handle.project.appendingPathComponent(change.path))) ?? .absent
            if real == Applier.sanitized(change.after) { return (content, Set(hunks.map(\.id))) }
            if real == change.before { return (content, []) }
            if let last = written[change.path], last.applied == real { return (content, Set(last.hunks ?? [])) }
            return (content, [])
        }
        var files: [FileEntry] = []
        files.reserveCapacity(rows.count)
        for (change, (content, appliedHunks)) in zip(rows, loaded) {
            files.append(FileEntry(change: change, content: content, conflict: conflicts[change.path],
                                   isApplied: applied.contains(change.path), appliedHunks: appliedHunks))
        }
        files.sort { ($0.group, $0.path) < ($1.group, $1.path) }
        return ReviewSnapshot(files: files, hiddenDeletedDirectories: hiddenDeleted,
                              gitMetadataChanges: diff.gitMetadataChanges.count, canUndo: applier.canUndo,
                              reviewed: ReviewedChanges(diff.changes))
    }

    /// `applier` is nil for timeline views: hunks are then computed between
    /// the two trees and can't be picked. Files are read without following
    /// symlinks or blocking on FIFOs.
    public static func content(for change: Change, before: URL, after: URL, applier: Applier?) throws -> FileContent {
        switch (change.kind, change.before, change.after) {
        case (.modified, .file, .file):
            if max(change.before.size ?? 0, change.after.size ?? 0) > maxTextBytes {
                return .tooLarge(change.after.size ?? 0)
            }
            if let applier {
                if let hunks = try applier.hunks(for: change) { return .text(hunks: hunks, partial: true) }
            } else {
                let b = try SafeFS.readBeneath(before, change.path), w = try SafeFS.readBeneath(after, change.path)
                if !DiffRenderer.looksBinary(b) && !DiffRenderer.looksBinary(w) {
                    return .text(hunks: LineDiff.hunks(base: b, work: w), partial: false)
                }
            }
            return .binary(before: change.before.size, after: change.after.size)
        case (.added, _, .file(_, let size, _)):
            if size > maxTextBytes { return .tooLarge(size) }
            let data = try SafeFS.readBeneath(after, change.path, limit: Int(maxTextBytes))
            if DiffRenderer.looksBinary(data) { return .binary(before: nil, after: size) }
            return .lines(added: lineCount(data), removed: 0)
        case (.deleted, .file(_, let size, _), _):
            if size > maxTextBytes { return .tooLarge(size) }
            let data = try SafeFS.readBeneath(before, change.path, limit: Int(maxTextBytes))
            if DiffRenderer.looksBinary(data) { return .binary(before: size, after: nil) }
            return .lines(added: 0, removed: lineCount(data))
        case (.modeChanged, let b, let a):
            return .meta(title: "Permissions changed", detail: "\(permString(b.mode)) → \(permString(a.mode))")
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
        case (.unreadable, .unreadable(let why), _), (.unreadable, _, .unreadable(let why)):
            return .meta(title: "Unreadable", detail: "\(why). It can't be reviewed or applied.")
        default:
            return .meta(title: change.kind.rawValue.capitalized, detail: change.path)
        }
    }

    /// The full lines of an added or deleted text file, for the detail pane.
    public static func detail(_ entry: FileEntry, before: URL, after: URL) throws -> [Hunk] {
        switch (entry.change.kind, entry.content) {
        case (.added, .lines):
            return LineDiff.hunks(base: Data(), work: try SafeFS.readBeneath(after, entry.path, limit: Int(maxTextBytes)))
        case (.deleted, .lines):
            return LineDiff.hunks(base: try SafeFS.readBeneath(before, entry.path, limit: Int(maxTextBytes)), work: Data())
        default:
            return entry.hunks
        }
    }

    static func lineCount(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        var n = 0
        for b in data where b == 0x0A { n += 1 }
        return data.last == 0x0A ? n : n + 1
    }

    /// "4755 (rwsr-xr-x)": all twelve bits, setuid/setgid/sticky included.
    public static func permString(_ mode: UInt16?) -> String {
        guard let mode else { return "-" }
        let chars = Array("rwxrwxrwx")
        var bits: [Character] = []
        for i in 0..<9 {
            let set: Bool = (mode >> UInt16(8 - i)) & 1 == 1
            bits.append(set ? chars[i] : "-")
        }
        if mode & 0o4000 != 0 { bits[2] = bits[2] == "x" ? "s" : "S" }
        if mode & 0o2000 != 0 { bits[5] = bits[5] == "x" ? "s" : "S" }
        if mode & 0o1000 != 0 { bits[8] = bits[8] == "x" ? "t" : "T" }
        return "\(String(mode, radix: 8)) (\(String(bits)))"
    }
}

/// Which files and hunks are ticked, and what "Apply Selected" sends.
/// Linear in the number of rows.
public struct ReviewSelection: Sendable, Equatable {
    /// Files whose checkbox is on (for non-partial files).
    public var files: Set<String> = []
    /// Selected hunk ids for files that allow partial apply.
    public var hunks: [String: Set<Int>] = [:]

    public init() {}

    public struct Pending: Sendable, Equatable {
        public var paths: [String]
        public var hunks: [String: Set<Int>]
        /// Rows counted in "n selected" (folders applied along with their
        /// contents aren't rows).
        public var rowCount: Int
        public var isEmpty: Bool { paths.isEmpty && hunks.isEmpty }
    }

    public func isSelected(_ f: FileEntry) -> Bool {
        if f.allowsPartial { return !(hunks[f.path] ?? []).intersection(f.openHunks).isEmpty }
        return files.contains(f.path)
    }

    /// Selects (or clears) one row the way the review starts: everything
    /// applicable except flagged files.
    public mutating func setDefault(_ f: FileEntry) {
        set(f, f.selectedByDefault)
    }

    /// Carries the selection over to a reloaded review. New rows (every row
    /// unless `keep`) start the way the review starts, and so do rows an undo
    /// just took back out of the project; hunks an undo took back are ticked
    /// again. Rows that can't be applied any more, and applied hunks, drop out.
    public mutating func refresh(from previous: ReviewSnapshot?, to snap: ReviewSnapshot, keep: Bool) {
        for f in snap.files {
            guard keep, let old = previous?.entry(f.path), !(old.isApplied && !f.isApplied) else {
                setDefault(f)
                continue
            }
            let undone = old.appliedHunks.subtracting(f.appliedHunks)
            if f.allowsPartial && !undone.isEmpty { hunks[f.path, default: []].formUnion(undone) }
        }
        for f in snap.files {
            if !f.canApply { set(f, false) }
            if f.allowsPartial { hunks[f.path] = (hunks[f.path] ?? []).subtracting(f.appliedHunks) }
        }
    }

    public mutating func set(_ f: FileEntry, _ on: Bool) {
        if f.allowsPartial {
            hunks[f.path] = on && f.canApply ? f.openHunks : []
        } else if on && f.canApply {
            files.insert(f.path)
        } else {
            files.remove(f.path)
        }
    }

    public func pending(_ snap: ReviewSnapshot) -> Pending {
        var paths: [String] = []
        var partial: [String: Set<Int>] = [:]
        var rows = 0
        // Directories with a row under them that isn't going in.
        var blocked = Set<String>()
        func block(_ path: String) {
            var p = Substring(path)
            while let slash = p.lastIndex(of: "/") {
                p = p[..<slash]
                if !blocked.insert(String(p)).inserted { break }
            }
        }
        for f in snap.files {
            var going = false
            if f.canApply {
                if f.allowsPartial {
                    let open = f.openHunks
                    let want = (hunks[f.path] ?? []).intersection(open)
                    if !want.isEmpty {
                        rows += 1
                        if want == open { paths.append(f.path); going = true } else { partial[f.path] = want }
                    }
                } else if files.contains(f.path) {
                    paths.append(f.path)
                    rows += 1
                    going = true
                }
            }
            if !going && !f.isApplied { block(f.path) }
        }
        // A deleted folder goes too when everything under it is selected.
        for dir in snap.hiddenDeletedDirectories where !blocked.contains(dir) {
            paths.append(dir)
        }
        return Pending(paths: paths, hunks: partial, rowCount: rows)
    }
}

/// `map` on all cores, keeping order.
func parallelMap<T, R>(_ items: [T], _ body: (T) -> R) -> [R] {
    guard items.count > 1 else { return items.map(body) }
    var out = [R?](repeating: nil, count: items.count)
    let workers = min(items.count, ProcessInfo.processInfo.activeProcessorCount * 2)
    withoutActuallyEscaping(body) { body in
        let fn = Unchecked(body)
        out.withUnsafeMutableBufferPointer { buf in
            let base = Unchecked(buf.baseAddress!)
            items.withUnsafeBufferPointer { list in
                let list = Unchecked(list)
                DispatchQueue.concurrentPerform(iterations: workers) { w in
                    var i = w
                    while i < list.value.count {
                        (base.value + i).pointee = fn.value(list.value[i])
                        i += workers
                    }
                }
            }
        }
    }
    return out.map { $0! }
}

/// Hands a value to `concurrentPerform` workers that each touch a separate
/// part of it. Only for that use.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
