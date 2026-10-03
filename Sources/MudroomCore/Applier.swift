#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
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
    /// Set when only some hunks were applied: every hunk id now present in
    /// the project (including ones applied earlier). Nil for a whole-path apply.
    public var hunks: [Int]?
    /// Recorded before the write started and not confirmed finished (a
    /// crash in between). Undo may then also find the path missing.
    public var pending: Bool?
    /// This entry has been rolled back.
    public var undone: Bool?

    public init(path: String, prior: FileNode, applied: FileNode, backup: String? = nil, hunks: [Int]? = nil) {
        self.path = path
        self.prior = prior
        self.applied = applied
        self.backup = backup
        self.hunks = hunks
    }

    var isUndone: Bool { undone == true }
}

public struct RollbackManifest: Codable, Sendable {
    public var sessionID: String
    public var created: Date
    public var entries: [RollbackEntry]
    /// Every entry has been rolled back.
    public var undone: Bool

    var remaining: [RollbackEntry] { entries.filter { !$0.isUndone } }
}

public struct PathIssue: Sendable, Equatable, CustomStringConvertible {
    public let path: String
    public let reason: String
    public var description: String { "\(TextLines.visible(path)): \(reason)" }

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct ApplyReport: Sendable {
    public var applied: [String] = []
    /// The project already matched the agent's version.
    public var alreadyApplied: [String] = []
    /// Refused because the real project (or the agent's copy) changed.
    public var conflicts: [PathIssue] = []
    public var skipped: [PathIssue] = []
    /// Applied paths that tools on the host act on (see `Differ.hostRisk`).
    public var warnings: [PathIssue] = []
    /// Rollback bundle directory, if anything was written.
    public var bundle: URL?

    public var wroteAnything: Bool { !applied.isEmpty }
}

public struct UndoReport: Sendable {
    public var restored: [String] = []
    public var conflicts: [PathIssue] = []
    /// Entries of this bundle still not rolled back (after conflicts). A
    /// later `undo` retries them before going further back.
    public var remaining: Int = 0
}

/// What a person looked at: each path's before and after state at review
/// time. An apply given this refuses any path whose change is different
/// now, so what lands in the project is what was reviewed.
public struct ReviewedChanges: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var before: FileNode
        public var after: FileNode
    }

    public var created: Date
    public var changes: [String: Entry]

    public init(_ changes: [Change], created: Date = Date()) {
        self.created = created
        self.changes = Dictionary(changes.map { ($0.path, Entry(before: $0.before, after: $0.after)) }, uniquingKeysWith: { _, b in b })
    }

    public mutating func merge(_ more: [Change]) {
        for c in more { changes[c.path] = Entry(before: c.before, after: c.after) }
        created = Date()
    }

    /// The review record after looking at one file (`mudroom hunks`). With
    /// no earlier review it starts from the whole diff: looking at one file
    /// must not make `apply --all` refuse every other file as unreviewed.
    public static func viewing(_ change: Change, in diff: DiffResult, existing: ReviewedChanges?) -> ReviewedChanges {
        var record = existing ?? ReviewedChanges(diff.changes + diff.gitMetadataChanges)
        record.merge([change])
        return record
    }

    /// Nil if `c` is exactly what was reviewed, else why not.
    func mismatch(_ c: Change) -> String? {
        guard let e = changes[c.path] else { return "appeared after you reviewed; review again to include it" }
        if e.before == c.before && e.after == c.after { return nil }
        return "changed in the agent's copy after you reviewed it; review again"
    }

    static func url(_ handle: SessionHandle) -> URL { handle.directory.appendingPathComponent("reviewed.json") }

    /// The CLI's last review of a session (`diff`, `hunks`, `review`).
    public static func load(_ handle: SessionHandle) -> ReviewedChanges? {
        guard let data = try? Data(contentsOf: url(handle)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(ReviewedChanges.self, from: data)
    }

    public func save(_ handle: SessionHandle) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        try e.encode(self).write(to: Self.url(handle), options: .atomic)
    }
}

/// Applies reviewed changes from a session's `work/` to the real project.
///
/// Safety rules:
/// - A path is only written if the real project still has exactly what
///   `base/` has (the state the agent started from), or what an earlier
///   apply of this session wrote. Anything else is a conflict, left alone.
/// - Bytes are copied out of work/ without following symlinks, into the
///   rollback bundle first, and checked against the hash in the diff (and
///   the review, when given) before they go into the project.
/// - Every destructive step is recorded in the bundle's journal first.
/// - One apply or undo at a time per session and per project (flock).
public struct Applier {
    public let handle: SessionHandle
    private let fm = FileManager.default

    public init(handle: SessionHandle) { self.handle = handle }

    var project: URL { handle.project }
    var storeRoot: URL { handle.directory.deletingLastPathComponent().deletingLastPathComponent() }

    static func normalize(_ selection: String) -> String {
        // "./a//b/" and "a/./b" name a/b. ".." is left alone (it matches nothing).
        let parts = selection.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        let joined = parts.joined(separator: "/")
        if selection.hasPrefix("/") { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    public static func normalizePath(_ s: String) -> String { normalize(s) }

    static func matches(_ path: String, selection: [String]) -> Bool {
        selection.contains { sel in sel == "." || path == sel || path.hasPrefix(sel + "/") }
    }

    /// Modes as Mudroom writes them: setuid and setgid are never applied.
    static func sanitized(_ node: FileNode) -> FileNode {
        switch node {
        case .file(let m, let s, let h): .file(mode: m & ~0o6000, size: s, sha256: h)
        case .directory(let m): .directory(mode: m & ~0o6000)
        default: node
        }
    }

    // MARK: - What Mudroom wrote earlier

    /// What Mudroom itself last wrote at each path, from entries not yet
    /// undone. A project path in this state is not a conflict: the user
    /// didn't touch it, a previous (partial) apply did.
    func lastWrittenIndex() -> [String: RollbackEntry] {
        guard let bundles = try? activeBundles() else { return [:] }
        var index: [String: RollbackEntry] = [:]
        for (_, manifest) in bundles {
            for e in manifest.entries where !e.isUndone { index[e.path] = e }
        }
        return index
    }

    public func lastWritten(_ path: String) -> RollbackEntry? { lastWrittenIndex()[path] }

    // MARK: - Apply

    /// Checks every change against the real project without writing.
    /// `applied` lists what would be written. Pass `diff` to reuse one
    /// already computed.
    public func preflight(paths: [String]? = nil, includeGit: Bool = false, diff: DiffResult? = nil) throws -> ApplyReport {
        try apply(paths: paths, includeGit: includeGit, dryRun: true, diff: diff)
    }

    /// - Parameters:
    ///   - paths: project-relative paths (files or directories) to apply; nil applies everything.
    ///   - hunks: for modified text files, apply only these hunk ids (see `hunks(for:)`)
    ///     instead of the whole file. Hunks applied earlier stay applied.
    ///   - includeGit: also apply changes inside `.git` directories.
    ///   - dryRun: only check; `applied` then lists what would be written.
    ///   - reviewed: what the user reviewed. Paths whose change differs now
    ///     (or that appeared since) are refused.
    ///   - diff: a diff of base -> work computed just before, to save a scan.
    ///
    /// Everything written by one call goes into one rollback bundle, so one
    /// `undo` reverts it.
    public func apply(paths: [String]?, hunks hunkSelection: [String: Set<Int>] = [:],
                      includeGit: Bool = false, dryRun: Bool = false,
                      reviewed: ReviewedChanges? = nil, diff precomputed: DiffResult? = nil) throws -> ApplyReport {
        if dryRun {
            return try applyLocked(paths: paths, hunks: hunkSelection, includeGit: includeGit, dryRun: true,
                                   reviewed: reviewed, diff: precomputed)
        }
        return try withLocks {
            try applyLocked(paths: paths, hunks: hunkSelection, includeGit: includeGit, dryRun: false,
                            reviewed: reviewed, diff: precomputed)
        }
    }

    private func applyLocked(paths: [String]?, hunks hunkSelection: [String: Set<Int>], includeGit: Bool, dryRun: Bool,
                             reviewed: ReviewedChanges?, diff precomputed: DiffResult?) throws -> ApplyReport {
        try requireProjectFolder()
        let diff = try precomputed ?? Differ.compare(base: handle.base, work: handle.work)
        var changes = diff.changes + (includeGit ? diff.gitMetadataChanges : [])
        var report = ApplyReport()
        let hunkSel = Dictionary(hunkSelection.map { (Self.normalize($0.key), $0.value) }, uniquingKeysWith: { $0.union($1) })
        let written = lastWrittenIndex()

        if let paths {
            let selection = paths.map(Self.normalize) + hunkSel.keys
            if !selection.contains(".") {
                let exact = Set(selection)
                changes = changes.filter { c in
                    if exact.contains(c.path) { return true }
                    var p = Substring(c.path)
                    while let slash = p.lastIndex(of: "/") {
                        p = p[..<slash]
                        if exact.contains(String(p)) { return true }
                    }
                    return false
                }
                var covered = Set<String>()
                for c in changes {
                    covered.insert(c.path)
                    var p = Substring(c.path)
                    while let slash = p.lastIndex(of: "/") {
                        p = p[..<slash]
                        covered.insert(String(p))
                    }
                }
                for sel in selection where !covered.contains(sel) {
                    let isGit = Differ.isGitInternal(sel) && !includeGit
                    report.skipped.append(PathIssue(path: sel, reason: isGit ? "inside .git; pass --include-git to apply it" : "no change at this path"))
                }
            }
        }

        // What was reviewed is what may be applied.
        if let reviewed {
            changes = changes.filter { c in
                guard let why = reviewed.mismatch(c) else { return true }
                report.conflicts.append(PathIssue(path: c.path, reason: why))
                return false
            }
        }
        changes = changes.filter { c in
            switch (c.before, c.after) {
            case (.unreadable(let why), _), (_, .unreadable(let why)):
                report.skipped.append(PathIssue(path: c.path, reason: "unreadable (\(why)); not applied"))
                return false
            case (_, .special):
                report.skipped.append(PathIssue(path: c.path, reason: "special file (fifo/socket/device) not applied"))
                return false
            default:
                return true
            }
        }

        // Per-hunk paths are planned separately (below).
        var hunkPlans: [HunkPlan] = []
        for (path, selected) in hunkSel.sorted(by: { $0.key < $1.key }) {
            guard let change = changes.first(where: { $0.path == path }) else {
                if !report.skipped.contains(where: { $0.path == path }) && !report.conflicts.contains(where: { $0.path == path }) {
                    report.skipped.append(PathIssue(path: path, reason: "no change at this path"))
                }
                continue
            }
            if let plan = try planHunks(change, selected: selected, written: written, report: &report) { hunkPlans.append(plan) }
        }
        changes.removeAll { hunkSel[$0.path] != nil }

        // On a case-insensitive volume, two paths that differ only in case
        // are one name. A rename by case alone (Readme.md -> README.md) is
        // done as one step; any other clash is refused.
        let caseInsensitive = Self.isCaseInsensitive(project)
        var renames: [String: Change] = [:]   // added path -> the deleted change it replaces
        var renamedAway = Set<String>()       // deleted paths handled by a rename
        if caseInsensitive {
            let groups = Dictionary(grouping: changes, by: { $0.path.lowercased() }).filter { $0.value.count > 1 }
            var refused = Set<String>()
            for (_, group) in groups {
                let del = group.filter { $0.kind == .deleted && !$0.before.isDirectory }
                let add = group.filter { $0.kind == .added && !$0.after.isDirectory }
                if group.count == 2, del.count == 1, add.count == 1,
                   (del[0].path as NSString).deletingLastPathComponent == (add[0].path as NSString).deletingLastPathComponent {
                    renames[add[0].path] = del[0]
                    renamedAway.insert(del[0].path)
                } else {
                    for c in group {
                        refused.insert(c.path)
                        let others = group.filter { $0.path != c.path }.map(\.path).joined(separator: ", ")
                        report.conflicts.append(PathIssue(path: c.path, reason: "differs from \(others) only in letter case, which this volume treats as the same name; apply it by hand"))
                    }
                }
            }
            if !refused.isEmpty { changes.removeAll { refused.contains($0.path) } }
        }

        // Directories this apply will create; their children aren't blocked by
        // whatever currently sits at that path (it gets replaced first).
        let becomingDirs = Set(changes.filter { $0.after.isDirectory }.map(\.path))

        // Read the project state of every path in parallel, then decide.
        var ancestorCache: [String: String?] = [:]
        var candidates: [Change] = []
        for change in changes {
            if let bad = unsafeAncestor(of: change.path, allowing: becomingDirs, cache: &ancestorCache) {
                report.conflicts.append(PathIssue(path: change.path, reason: "\(bad) in the project is not a plain directory"))
                continue
            }
            candidates.append(change)
        }
        let reals = readProject(candidates.map(\.path))
        var listings: [String: Set<String>] = [:]
        var planned: [(change: Change, real: FileNode)] = []
        for (change, real) in zip(candidates, reals) {
            if renamedAway.contains(change.path) {
                // Checked along with its rename partner.
                if real != change.before && written[change.path]?.applied != real {
                    report.conflicts.append(PathIssue(path: change.path, reason: conflictReason(change, real)))
                    renames = renames.filter { $0.value.path != change.path }
                    renamedAway.remove(change.path)
                }
                continue
            }
            let want = Self.sanitized(change.after)
            if let from = renames[change.path] {
                // The old name must still hold what base had; lstat of the
                // new name finds that same file.
                guard renamedAway.contains(from.path) else {
                    report.conflicts.append(PathIssue(path: change.path, reason: "its case-only rename partner \(from.path) conflicts"))
                    continue
                }
                planned.append((change, .absent))
                continue
            }
            if caseInsensitive && real != .absent && !exactNameExists(change.path, listings: &listings) {
                report.conflicts.append(PathIssue(path: change.path, reason: "the project has a file whose name differs only in letter case"))
                continue
            }
            if real == want {
                report.alreadyApplied.append(change.path)
            } else if !(real == change.before || written[change.path]?.applied == real) {
                report.conflicts.append(PathIssue(path: change.path, reason: conflictReason(change, real)))
            } else {
                planned.append((change, real))
            }
        }
        // A repository's .git goes in whole or not at all. Half of one (the
        // agent's refs and objects with your index, say, after a `git
        // status` rewrote it) is a repository state nobody made.
        let blockedGitDirs = Set(report.conflicts.compactMap { Self.gitDirectory(of: $0.path) })
        if !blockedGitDirs.isEmpty {
            planned.removeAll { p in
                guard let dir = Self.gitDirectory(of: p.change.path), blockedGitDirs.contains(dir) else { return false }
                report.conflicts.append(PathIssue(path: p.change.path, reason: "not applied: another path in \(dir)/ conflicts, and a .git directory is applied all or nothing"))
                return true
            }
        }
        for (added, _) in renames where !planned.contains(where: { $0.change.path == added }) {
            renamedAway.remove(renames[added]!.path)
            renames[added] = nil
        }
        for (change, _) in planned {
            if let risk = Differ.hostRisk(change.path) { report.warnings.append(PathIssue(path: change.path, reason: risk)) }
        }
        if dryRun {
            report.applied = planned.map(\.change.path) + Array(renamedAway).sorted() + hunkPlans.map(\.change.path)
            return report
        }
        guard !planned.isEmpty || !hunkPlans.isEmpty else { return report }

        let bundle = try makeBundleDirectory()
        report.bundle = bundle
        let journal = try Journal(bundle: bundle)
        var entries: [RollbackEntry] = []
        defer {
            journal.close()
            let manifest = RollbackManifest(sessionID: handle.session.id, created: Date(), entries: entries, undone: false)
            try? Self.writeManifest(manifest, to: bundle)
        }
        /// Records an entry (pending) before the step that changes the project.
        func record(_ e: RollbackEntry) throws -> Int {
            var e = e
            e.pending = true
            try journal.append(e)
            entries.append(e)
            return entries.count - 1
        }
        func done(_ i: Int, applied: FileNode? = nil) {
            entries[i].pending = nil
            if let applied { entries[i].applied = applied }
        }
        func run(_ path: String, _ body: () throws -> Void) {
            do {
                try body()
                if !report.applied.contains(path) { report.applied.append(path) }
            } catch {
                report.conflicts.append(PathIssue(path: path, reason: "\(error)"))
            }
        }
        let staging = bundle.appendingPathComponent("staged", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var stagedCount = 0
        /// Copies a file out of work/ into the bundle and checks its hash.
        func stage(_ change: Change) throws -> URL {
            stagedCount += 1
            let dest = staging.appendingPathComponent(String(stagedCount))
            let sha = try SafeFS.copyBeneath(handle.work, change.path, to: dest)
            guard sha == change.after.sha256 else {
                try? fm.removeItem(at: dest)
                throw MudroomError.invalid("changed in the agent's copy since the diff was taken; review again")
            }
            return dest
        }

        // 1. Deletions, deepest first, so directories are empty when removed.
        for (change, real) in planned.filter({ $0.change.kind == .deleted }).sorted(by: { $0.change.path > $1.change.path }) {
            run(change.path) {
                let i = try record(try backup(change.path, prior: real, applied: .absent, bundle: bundle))
                try remove(project.appendingPathComponent(change.path), node: real)
                done(i)
            }
        }

        // 2. Everything else, parents before children.
        var deferredDirModes: [(String, UInt16)] = []
        for (change, real) in planned.filter({ $0.change.kind != .deleted }).sorted(by: { $0.change.path < $1.change.path }) {
            run(change.path) {
                var cache: [String: String?] = [:]
                if let bad = unsafeAncestor(of: change.path, cache: &cache) {
                    throw MudroomError.invalid("\(bad) in the project is not a plain directory")
                }
                try createMissingParents(of: change.path) { e in done(try record(e)) }
                let target = project.appendingPathComponent(change.path)
                let after = Self.sanitized(change.after)

                if let old = renames[change.path] {
                    try caseRename(from: old, to: change, bundle: bundle, stage: stage, record: record, done: done)
                    report.applied.append(old.path)
                    return
                }
                switch (change.kind, after) {
                case (.modeChanged, .file(let mode, _, _)):
                    let i = try record(try backup(change.path, prior: real, applied: after, bundle: bundle))
                    try chmodOrThrow(target, mode)
                    done(i, applied: Self.withModeOnDisk(after, at: target))
                case (.modeChanged, .directory(let mode)):
                    done(try record(RollbackEntry(path: change.path, prior: real, applied: after)))
                    deferredDirModes.append((change.path, mode))
                default:
                    // Bytes first, checked, into the bundle; then the project.
                    let staged: URL? = if case .file = after { try stage(change) } else { nil }
                    let i = try record(try backup(change.path, prior: real, applied: after, bundle: bundle))
                    let aside = change.kind == .typeChanged ? try moveAside(target, node: real) : nil
                    do {
                        try place(after, staged: staged, at: target, deferredDirModes: &deferredDirModes, path: change.path)
                    } catch {
                        if let aside { _ = rename(aside.path, target.path) }
                        throw error
                    }
                    if let aside { try? fm.removeItem(at: aside) }
                    done(i, applied: Self.withModeOnDisk(after, at: target))
                }
            }
        }

        // 2b. Partial files: write the base with the chosen hunks applied.
        for plan in hunkPlans {
            run(plan.change.path) {
                var cache: [String: String?] = [:]
                if let bad = unsafeAncestor(of: plan.change.path, cache: &cache) {
                    throw MudroomError.invalid("\(bad) in the project is not a plain directory")
                }
                let target = project.appendingPathComponent(plan.change.path)
                stagedCount += 1
                let staged = staging.appendingPathComponent(String(stagedCount))
                try plan.content.write(to: staged)
                let i = try record(try backup(plan.change.path, prior: plan.real, applied: .absent, bundle: bundle))
                try placeFile(from: staged, to: target, mode: plan.mode & ~0o6000)
                entries[i].hunks = plan.hunks
                done(i, applied: try FileNode.read(at: target))
            }
        }

        // 3. Directory permissions last, so a read-only dir doesn't block its children.
        for (path, mode) in deferredDirModes.sorted(by: { $0.0 > $1.0 }) {
            try chmodOrThrow(project.appendingPathComponent(path), mode & ~0o6000)
        }
        try? fm.removeItem(at: staging)
        report.applied.sort()
        return report
    }

    /// Readme.md -> README.md on a case-insensitive volume: the old name is
    /// renamed aside, the new file put in place, and the aside copy removed
    /// (the bundle keeps a backup). Undo reverses both entries.
    private func caseRename(from old: Change, to new: Change, bundle: URL, stage: (Change) throws -> URL,
                            record: (RollbackEntry) throws -> Int, done: (Int, FileNode?) -> Void) throws {
        let oldURL = project.appendingPathComponent(old.path)
        let newURL = project.appendingPathComponent(new.path)
        let real = try FileNode.read(at: oldURL)
        guard real == old.before else { throw MudroomError.invalid(conflictReason(old, real)) }
        var listings: [String: Set<String>] = [:]
        guard exactNameExists(old.path, listings: &listings) else {
            throw MudroomError.invalid("\(old.path) is no longer in the project under that exact name")
        }
        let after = Self.sanitized(new.after)
        let staged: URL? = if case .file = after { try stage(new) } else { nil }
        let iOld = try record(try backup(old.path, prior: real, applied: .absent, bundle: bundle))
        let iNew = try record(RollbackEntry(path: new.path, prior: .absent, applied: after))
        let aside = try moveAside(oldURL, node: real)
        do {
            var unused: [(String, UInt16)] = []
            try place(after, staged: staged, at: newURL, deferredDirModes: &unused, path: new.path)
        } catch {
            if let aside { _ = rename(aside.path, oldURL.path) }
            throw error
        }
        if let aside { try? fm.removeItem(at: aside) }
        done(iOld, nil)
        done(iNew, nil)
    }

    private func conflictReason(_ change: Change, _ real: FileNode) -> String {
        "project changed since the session started (expected \(describe(change.before)), found \(describe(real)))"
    }

    /// FileNode.read of many project paths, on all cores.
    private func readProject(_ paths: [String]) -> [FileNode] {
        let root = project
        return parallelMap(paths) {
            (try? FileNode.read(at: root.appendingPathComponent($0))) ?? .unreadable(reason: "lstat failed")
        }
    }

    // MARK: - Hunks

    struct HunkPlan {
        let change: Change
        let real: FileNode
        let content: Data
        let mode: UInt16
        /// Hunk ids present after the write; nil when that is all of them.
        let hunks: [Int]?
    }

    /// Base and work bytes of a modified text file, read without following
    /// symlinks; the work bytes are checked against the diff's hash.
    func texts(for change: Change) throws -> (Data, Data)? {
        guard change.kind == .modified, case .file = change.before, case .file(_, _, let sha) = change.after else { return nil }
        let b = try SafeFS.readBeneath(handle.base, change.path)
        let fd = try SafeFS.openBeneath(handle.work, change.path)
        defer { close(fd) }
        let w = try SafeFS.readAll(fd, limit: .max)
        guard SafeFS.sha256(w) == sha else {
            throw MudroomError.invalid("\(change.path) changed in the agent's copy since the diff was taken; review again")
        }
        if DiffRenderer.looksBinary(b) || DiffRenderer.looksBinary(w) { return nil }
        return (b, w)
    }

    /// The hunks of a modified text file, numbered from 1. Nil when the path
    /// isn't a text file on both sides (binary, added, deleted, symlink...).
    public func hunks(for change: Change) throws -> [Hunk]? {
        guard let (b, w) = try texts(for: change) else { return nil }
        return LineDiff.hunks(base: b, work: w)
    }

    /// Hunk ids of `path` already in the project because of an earlier
    /// partial apply. Empty when the project still has the base version.
    public func appliedHunks(for change: Change, hunks known: [Hunk]? = nil) throws -> Set<Int> {
        let real = try FileNode.read(at: project.appendingPathComponent(change.path))
        if real == Self.sanitized(change.after) {
            guard let hunks = try known ?? hunks(for: change) else { return [] }
            return Set(hunks.map(\.id))
        }
        if real == change.before { return [] }
        guard let last = lastWritten(change.path), last.applied == real, let ids = last.hunks else { return [] }
        return Set(ids)
    }

    /// Checks one per-hunk selection and computes the file to write. Returns
    /// nil (after noting why in `report`) when there is nothing to write.
    func planHunks(_ change: Change, selected: Set<Int>, written: [String: RollbackEntry], report: inout ApplyReport) throws -> HunkPlan? {
        let path = change.path
        guard let (baseData, workData) = try texts(for: change) else {
            report.skipped.append(PathIssue(path: path, reason: "not a modified text file; apply the whole path instead"))
            return nil
        }
        let baseLines = TextLines(baseData), workLines = TextLines(workData)
        let hunks = LineDiff.hunks(base: baseLines, work: workLines)
        let unknown = selected.subtracting(hunks.map(\.id))
        if !unknown.isEmpty {
            throw MudroomError.invalid("\(path) has hunks 1-\(hunks.count); no hunk \(unknown.sorted().map(String.init).joined(separator: ", "))")
        }
        var cache: [String: String?] = [:]
        if let bad = unsafeAncestor(of: path, cache: &cache) {
            report.conflicts.append(PathIssue(path: path, reason: "\(bad) in the project is not a plain directory"))
            return nil
        }
        let real = try FileNode.read(at: project.appendingPathComponent(path))
        let previous: Set<Int>
        if real == change.before {
            previous = []
        } else if real == Self.sanitized(change.after) {
            report.alreadyApplied.append(path)
            return nil
        } else if let last = written[path], last.applied == real {
            previous = Set(last.hunks ?? [])
        } else {
            report.conflicts.append(PathIssue(path: path, reason: conflictReason(change, real)))
            return nil
        }
        let wanted = previous.union(selected)
        if wanted == previous {
            report.alreadyApplied.append(path)
            return nil
        }
        let content = LineDiff.apply(hunks, selected: wanted, base: baseLines, work: workLines).data
        let complete = content == workData
        return HunkPlan(change: change, real: real, content: content,
                        mode: (complete ? change.after.mode : change.before.mode) ?? 0o644,
                        hunks: complete ? nil : wanted.sorted())
    }

    /// Applies some hunks of one modified text file. Shorthand for
    /// `apply(paths: [], hunks: [path: hunks])`.
    public func applyHunks(path: String, hunks selected: Set<Int>, reviewed: ReviewedChanges? = nil) throws -> ApplyReport {
        try apply(paths: [], hunks: [path: selected], reviewed: reviewed)
    }

    // MARK: - Undo

    /// True when there is an apply that `undo` would roll back.
    public var canUndo: Bool { ((try? latestBundle()) ?? nil) != nil }

    /// Restores the most recent apply not yet (fully) undone. Paths that
    /// changed after the apply are left alone and stay in the bundle, so a
    /// later undo can still restore them once they're back.
    public func undo(force: Bool = false) throws -> UndoReport {
        try withLocks { try undoLocked(force: force) }
    }

    private func undoLocked(force: Bool) throws -> UndoReport {
        guard let (bundle, manifest) = try latestBundle() else {
            throw MudroomError.nothingToUndo(handle.session.id)
        }
        try requireProjectFolder()
        var report = UndoReport()
        var dirModes: [(String, UInt16)] = []
        var updated = manifest
        for index in manifest.entries.indices.reversed() where !manifest.entries[index].isUndone {
            let entry = manifest.entries[index]
            let target = project.appendingPathComponent(entry.path)
            do {
                var cache: [String: String?] = [:]
                if let bad = unsafeAncestor(of: entry.path, cache: &cache) {
                    throw MudroomError.invalid("\(bad) in the project is not a plain directory")
                }
                let current = try FileNode.read(at: target)
                let interrupted = entry.pending == true && current == .absent
                if current != entry.applied && current != entry.prior && !interrupted && !force {
                    report.conflicts.append(PathIssue(
                        path: entry.path,
                        reason: "changed after apply (expected \(describe(entry.applied)), found \(describe(current)))"))
                    continue
                }
                if current != entry.prior {
                    try restore(entry, current: current, bundle: bundle, dirModes: &dirModes)
                }
                updated.entries[index].undone = true
                report.restored.append(entry.path)
            } catch {
                report.conflicts.append(PathIssue(path: entry.path, reason: "\(error)"))
            }
        }
        for (path, mode) in dirModes.sorted(by: { $0.0 > $1.0 }) {
            try? chmodOrThrow(project.appendingPathComponent(path), mode)
        }
        report.remaining = updated.remaining.count
        updated.undone = report.remaining == 0
        try Self.writeManifest(updated, to: bundle)
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
        case .special, .unreadable:
            throw MudroomError.invalid("cannot restore a \(entry.prior.kindName) entry")
        }
    }

    func latestBundle() throws -> (URL, RollbackManifest)? {
        try activeBundles().last
    }

    /// Bundles with entries not yet undone, oldest first.
    func activeBundles() throws -> [(URL, RollbackManifest)] {
        let root = handle.rollbackRoot
        guard fm.fileExists(atPath: root.path) else { return [] }
        var out: [(URL, RollbackManifest)] = []
        let names = try fm.contentsOfDirectory(atPath: root.path).filter { Int($0) != nil }.sorted { Int($0)! < Int($1)! }
        for name in names {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            guard let manifest = try Self.readManifest(dir) else { continue }
            if !manifest.undone && !manifest.remaining.isEmpty { out.append((dir, manifest)) }
        }
        return out
    }

    /// The manifest, or for a bundle whose apply was interrupted before it
    /// could write one, the journal of what it had started.
    static func readManifest(_ bundle: URL) throws -> RollbackManifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: bundle.appendingPathComponent("manifest.json")) {
            return try decoder.decode(RollbackManifest.self, from: data)
        }
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent(Journal.name)) else { return nil }
        var entries: [RollbackEntry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let e = try? decoder.decode(RollbackEntry.self, from: Data(line)) { entries.append(e) }
        }
        return RollbackManifest(sessionID: "", created: Date(), entries: entries, undone: false)
    }

    // MARK: - Locks

    /// Holds the project's and the session's apply locks for `body`, so two
    /// applies (app and CLI, two windows, two sessions on one project)
    /// can't interleave.
    func withLocks<T>(_ body: () throws -> T) throws -> T {
        let locks = storeRoot.appendingPathComponent("locks", isDirectory: true)
        try fm.createDirectory(at: locks, withIntermediateDirectories: true)
        let projectLock = try FileLock.acquire(locks.appendingPathComponent("project-\(ProjectConfigStore.key(for: project.path)).lock"),
                                               waiting: 30, what: "an apply or undo for this project")
        defer { projectLock.release() }
        let sessionLock = try FileLock.acquire(handle.directory.appendingPathComponent("apply.lock"),
                                               waiting: 30, what: "an apply or undo for this session")
        defer { sessionLock.release() }
        return try body()
    }

    // MARK: - Helpers

    /// "sub/.git" for "sub/.git/refs/heads/main": the innermost .git
    /// directory a path is in (or is). Nil outside any .git.
    static func gitDirectory(of path: String) -> String? {
        let parts = path.split(separator: "/")
        guard let i = parts.lastIndex(where: { $0.count == 4 && $0.lowercased() == ".git" }) else { return nil }
        return parts[...i].joined(separator: "/")
    }

    /// The project folder must still be where the session found it. If it
    /// was moved or deleted, every path would look deleted by the user, and
    /// new files would fail one by one with a copy error.
    func requireProjectFolder() throws {
        var st = stat()
        guard stat(project.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else {
            throw MudroomError.invalid("the project folder \(project.path) isn't there anymore (moved, renamed or deleted?). Put it back at that path to apply or undo this session's changes.")
        }
    }

    /// A new numbered bundle. mkdir fails if the number is taken, so two
    /// processes never share one.
    private func makeBundleDirectory() throws -> URL {
        try fm.createDirectory(at: handle.rollbackRoot, withIntermediateDirectories: true)
        var next = ((try? fm.contentsOfDirectory(atPath: handle.rollbackRoot.path)) ?? []).compactMap(Int.init).max() ?? 0
        for _ in 0..<1000 {
            next += 1
            let dir = handle.rollbackRoot.appendingPathComponent(String(format: "%04d", next), isDirectory: true)
            if mkdir(dir.path, 0o700) == 0 {
                try fm.createDirectory(at: dir.appendingPathComponent("files"), withIntermediateDirectories: true)
                return dir
            }
            if errno != EEXIST { throw MudroomError.posix("mkdir", dir.path, errno) }
        }
        throw MudroomError.invalid("couldn't create a rollback bundle in \(handle.rollbackRoot.path)")
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
        var cache: [String: String?] = [:]
        return unsafeAncestor(of: path, allowing: allowed, cache: &cache)
    }

    func unsafeAncestor(of path: String, allowing allowed: Set<String> = [], cache: inout [String: String?]) -> String? {
        var components = path.split(separator: "/").map(String.init)
        components.removeLast()
        var current = ""
        for c in components {
            current = current.isEmpty ? c : current + "/" + c
            if allowed.contains(current) { continue }
            if let hit = cache[current] {
                if let bad = hit { return bad }
                continue
            }
            var st = stat()
            let ok: Bool
            if lstat(project.appendingPathComponent(current).path, &st) != 0 {
                ok = errno == ENOENT
            } else {
                ok = st.st_mode & S_IFMT == S_IFDIR
            }
            cache[current] = ok ? .some(nil) : .some(current)
            if !ok { return current }
        }
        return nil
    }

    /// True if the last component of `path` is in its parent's listing with
    /// exactly that spelling (not just a case variant of it).
    func exactNameExists(_ path: String, listings: inout [String: Set<String>]) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if listings[parent] == nil {
            let dir = parent.isEmpty ? project : project.appendingPathComponent(parent)
            listings[parent] = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        }
        return listings[parent]!.contains(name)
    }

    /// Whether `dir`'s volume treats names that differ in case as one.
    static func isCaseInsensitive(_ dir: URL) -> Bool {
        #if canImport(Darwin)
        let r = pathconf(dir.path, _PC_CASE_SENSITIVE)
        if r >= 0 { return r == 0 }
        #endif
        // Probe: the directory's own name with its case flipped.
        let name = dir.lastPathComponent
        let flipped = String(name.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
        guard flipped != name else { return false }
        var a = stat(), b = stat()
        guard lstat(dir.path, &a) == 0,
              lstat(dir.deletingLastPathComponent().appendingPathComponent(flipped).path, &b) == 0 else { return false }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    /// Records the prior state (copying a regular file into the bundle).
    /// `node` with the mode the volume actually kept. Disks without Unix
    /// permissions (FAT, exFAT, some network shares) report their own, and
    /// undo would otherwise see that as a change made after the apply.
    static func withModeOnDisk(_ node: FileNode, at url: URL) -> FileNode {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return node }
        let mode = UInt16(st.st_mode & 0o7777)
        switch node {
        case .file(let m, let size, let sha) where m & 0o7777 != mode: return .file(mode: mode, size: size, sha256: sha)
        case .directory(let m) where m & 0o7777 != mode: return .directory(mode: mode)
        default: return node
        }
    }

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
    private func createMissingParents(of path: String, record: (RollbackEntry) throws -> Void) throws {
        var components = path.split(separator: "/").map(String.init)
        components.removeLast()
        var current = ""
        for c in components {
            current = current.isEmpty ? c : current + "/" + c
            let target = project.appendingPathComponent(current)
            if try FileNode.read(at: target) == .absent {
                let workNode = try FileNode.read(at: handle.work.appendingPathComponent(current))
                try mkdirOrThrow(target)
                if let mode = workNode.mode { try chmodOrThrow(target, mode & ~0o6000) }
                try record(RollbackEntry(path: current, prior: .absent, applied: try FileNode.read(at: target)))
            }
        }
    }

    private func place(_ node: FileNode, staged: URL?, at target: URL,
                       deferredDirModes: inout [(String, UInt16)], path: String) throws {
        switch node {
        case .file(let mode, _, _):
            guard let staged else { throw MudroomError.invalid("nothing staged for \(path)") }
            try placeFile(from: staged, to: target, mode: mode)
        case .symlink(let dest):
            try placeSymlink(dest, at: target)
        case .directory(let mode):
            try mkdirOrThrow(target)
            deferredDirModes.append((path, mode))
        case .absent, .special, .unreadable:
            break
        }
    }

    /// A short temp name next to `target` (never longer than NAME_MAX,
    /// whatever the target's name).
    private func tempName(near target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(".mudroom-\(UUID().uuidString.prefix(8).lowercased())")
    }

    /// Moves a file or symlink out of the way (to a temp name in the same
    /// directory) so it can be put back if placing its replacement fails.
    /// A directory must be empty and is removed instead. Returns the temp.
    private func moveAside(_ target: URL, node: FileNode) throws -> URL? {
        switch node {
        case .absent: return nil
        case .directory:
            try remove(target, node: node)
            return nil
        default:
            let tmp = tempName(near: target)
            if rename(target.path, tmp.path) != 0 { throw MudroomError.posix("rename", target.path, errno) }
            return tmp
        }
    }

    /// Copies to a temp name next to the target, then renames over it.
    private func placeFile(from source: URL, to target: URL, mode: UInt16) throws {
        let tmp = tempName(near: target)
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
        let tmp = tempName(near: target)
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
        case .unreadable(let why): "unreadable (\(why))"
        }
    }
}

/// The bundle's write-ahead record: one JSON line per entry, written before
/// the step it describes.
final class Journal {
    static let name = "journal.jsonl"
    private let handle: FileHandle
    private let encoder: JSONEncoder

    init(bundle: URL) throws {
        let url = bundle.appendingPathComponent(Self.name)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func append(_ entry: RollbackEntry) throws {
        var line = try encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))
        try handle.write(contentsOf: line)
    }

    func close() { try? handle.close() }
}

/// An exclusive flock(2) on a file, released when the process exits even
/// if it crashes.
public final class FileLock {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// Waits up to `waiting` seconds for the lock.
    public static func acquire(_ url: URL, waiting: TimeInterval, what: String) throws -> FileLock {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MudroomError.posix("open", url.path, errno) }
        let deadline = Date().addingTimeInterval(waiting)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                close(fd)
                throw MudroomError.invalid("\(what) is already running; try again when it finishes")
            }
            usleep(50_000)
        }
        return FileLock(fd: fd)
    }

    /// Takes the lock only if nobody holds it. With `inheritable`, child
    /// processes started with posix_spawn share it, so it stays held while
    /// any of them lives.
    public static func tryAcquire(_ url: URL, inheritable: Bool = false) -> FileLock? {
        let fd = open(url.path, O_RDWR | O_CREAT | (inheritable ? 0 : O_CLOEXEC), 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return FileLock(fd: fd)
    }

    /// True if some process holds the lock on `url` (false if the file
    /// doesn't exist).
    public static func isHeld(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
