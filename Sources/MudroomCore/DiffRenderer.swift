import Foundation

/// Turns a `DiffResult` into text for a terminal.
///
/// Text diffs come from `LineDiff` (no `git` process per file) and files are
/// read with `SafeFS`, so a symlink or FIFO planted in work/ can't redirect
/// or stall the output.
public struct DiffRenderer: Sendable {
    public let base: URL
    public let work: URL

    /// Bigger files are summarised by size instead of diffed line by line.
    public static let maxDiffBytes: Int64 = 8 << 20

    public init(base: URL, work: URL) {
        self.base = base
        self.work = work
    }

    public static func octal(_ mode: UInt16) -> String { String(mode, radix: 8) }

    public static func sizeString(_ bytes: Int64?) -> String {
        guard let bytes else { return "-" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// One line per change, e.g. "M  src/app.swift".
    public func statLine(_ c: Change) -> String {
        var line = "\(Self.code(c.kind))  \(c.path)\(c.after.isDirectory || (c.kind == .deleted && c.before.isDirectory) ? "/" : "")"
        if let m1 = c.before.mode, let m2 = c.after.mode, m1 != m2 {
            line += "  (mode \(Self.octal(m1)) -> \(Self.octal(m2)))"
        }
        switch (c.kind, c.before, c.after) {
        case (.symlinkChanged, .symlink(let t1), .symlink(let t2)):
            line += "  (\(t1) -> \(t2))"
        case (.added, _, .symlink(let t)):
            line += "  -> \(t)"
        case (.typeChanged, let b, let a):
            line += "  (\(b.kindName) -> \(a.kindName))"
        case (.unreadable, .unreadable(let why), _), (.unreadable, _, .unreadable(let why)):
            line += "  (unreadable: \(why); not applied)"
        default:
            break
        }
        if let mode = c.after.mode, mode & 0o6000 != 0 {
            line += "  ! setuid/setgid bit, dropped on apply"
        }
        if let risk = Differ.hostRisk(c.path) {
            line += "  ! \(risk)"
        }
        return line
    }

    public func stat(_ result: DiffResult) -> String {
        var out: [String] = []
        writeStat(result) { out.append($0) }
        return out.joined(separator: "\n")
    }

    /// Streams the stat lines, one call per line.
    public func writeStat(_ result: DiffResult, _ emit: (String) -> Void) {
        for c in result.changes { emit(statLine(c)) }
        if !result.gitMetadataChanges.isEmpty {
            emit("git metadata changed (\(result.gitMetadataChanges.count) entries under .git/)")
        }
        if result.changes.isEmpty && result.gitMetadataChanges.isEmpty {
            emit("no changes")
            return
        }
        var counts: [ChangeKind: Int] = [:]
        for c in result.changes { counts[c.kind, default: 0] += 1 }
        let summary = ChangeKind.allCases.compactMap { k in counts[k].map { "\($0) \(k.rawValue)" } }
        if !summary.isEmpty { emit(summary.joined(separator: ", ")) }
    }

    /// Full output: a unified diff per text file, a one-line note otherwise.
    public func full(_ result: DiffResult) throws -> String {
        var out: [String] = []
        try writeFull(result) { out.append($0) }
        return out.joined(separator: "\n")
    }

    /// Streams the full diff, one call per file, so nothing big is held in
    /// memory.
    public func writeFull(_ result: DiffResult, _ emit: (String) -> Void) throws {
        for c in result.changes { emit(try render(c)) }
        if !result.gitMetadataChanges.isEmpty {
            emit("git metadata changed (\(result.gitMetadataChanges.count) entries under .git/; use --include-git to list)")
        }
        if result.changes.isEmpty && result.gitMetadataChanges.isEmpty { emit("no changes") }
    }

    func render(_ c: Change) throws -> String {
        let header = statLine(c)
        let beforeFile = if case .file = c.before { true } else { false }
        let afterFile = if case .file = c.after { true } else { false }
        guard c.contentChanged || (c.kind == .added && afterFile) || (c.kind == .deleted && beforeFile)
                || (c.kind == .typeChanged && (afterFile || beforeFile)) else {
            return header
        }
        if max(c.before.size ?? 0, c.after.size ?? 0) > Self.maxDiffBytes {
            return header + "\n    large file changed (size \(Self.sizeString(c.before.size)) -> \(Self.sizeString(c.after.size)))"
        }
        let old = beforeFile ? try SafeFS.readBeneath(base, c.path) : Data()
        let new = afterFile ? try SafeFS.readBeneath(work, c.path) : Data()
        if Self.looksBinary(old) || Self.looksBinary(new) {
            return header + "\n    binary changed (size \(Self.sizeString(c.before.size)) -> \(Self.sizeString(c.after.size)))"
        }
        let hunks = LineDiff.hunks(base: old, work: new)
        var lines = ["diff --git a/\(c.path) b/\(c.path)"]
        if !beforeFile, let m = c.after.mode { lines.append("new file mode 100\(Self.octal(m & 0o777))") }
        if !afterFile, let m = c.before.mode { lines.append("deleted file mode 100\(Self.octal(m & 0o777))") }
        if hunks.isEmpty {
            lines.append("(empty file)")
            return lines.joined(separator: "\n")
        }
        lines.append(beforeFile ? "--- a/\(c.path)" : "--- /dev/null")
        lines.append(afterFile ? "+++ b/\(c.path)" : "+++ /dev/null")
        lines.append(Self.unifiedBody(hunks))
        return lines.joined(separator: "\n")
    }

    /// Hunks in unified-diff form ("@@ -1,3 +1,4 @@", then " ", "-", "+" lines).
    public static func unifiedBody(_ hunks: [Hunk]) -> String {
        var out: [String] = []
        for h in hunks {
            out.append(h.header)
            for l in h.lines {
                let sign = switch l.kind { case .context: " "; case .removed: "-"; case .added: "+" }
                out.append(sign + l.text)
                if l.missingNewline { out.append("\\ No newline at end of file") }
            }
        }
        return out.joined(separator: "\n")
    }

    /// Same heuristic as git: a NUL byte in the first 8000 bytes means binary.
    public static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    /// `looksBinary` for a file inside `root`, read without following symlinks.
    public static func looksBinary(_ root: URL, _ relative: String) throws -> Bool {
        looksBinary(try SafeFS.readBeneath(root, relative, limit: 8000))
    }
}
