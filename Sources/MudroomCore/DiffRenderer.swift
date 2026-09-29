import Foundation

/// Turns a `DiffResult` into text for a terminal.
public struct DiffRenderer: Sendable {
    public let base: URL
    public let work: URL

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
        let tag: String = switch c.kind {
        case .added: "A "
        case .modified: "M "
        case .deleted: "D "
        case .modeChanged: "P "
        case .symlinkChanged: "L "
        case .typeChanged: "T "
        }
        var line = "\(tag) \(c.path)\(c.after.isDirectory || (c.kind == .deleted && c.before.isDirectory) ? "/" : "")"
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
        default:
            break
        }
        return line
    }

    public func stat(_ result: DiffResult) -> String {
        var lines = result.changes.map(statLine)
        if !result.gitMetadataChanges.isEmpty {
            lines.append("git metadata changed (\(result.gitMetadataChanges.count) entries under .git/)")
        }
        if lines.isEmpty { return "no changes" }
        let counts = Dictionary(grouping: result.changes, by: \.kind).mapValues(\.count)
        let summary = ChangeKind.allCases.compactMap { k in counts[k].map { "\($0) \(k.rawValue)" } }
        if !summary.isEmpty { lines.append(summary.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    /// Full output: a unified diff per text file, a one-line note otherwise.
    public func full(_ result: DiffResult) throws -> String {
        var out: [String] = []
        for c in result.changes {
            out.append(try render(c))
        }
        if !result.gitMetadataChanges.isEmpty {
            out.append("git metadata changed (\(result.gitMetadataChanges.count) entries under .git/; use --include-git to list)")
        }
        return out.isEmpty ? "no changes" : out.joined(separator: "\n")
    }

    func render(_ c: Change) throws -> String {
        let header = statLine(c)
        let beforeFile: URL? = if case .file = c.before { base.appendingPathComponent(c.path) } else { nil }
        let afterFile: URL? = if case .file = c.after { work.appendingPathComponent(c.path) } else { nil }
        guard c.contentChanged || (c.kind == .added && afterFile != nil) || (c.kind == .deleted && beforeFile != nil)
                || (c.kind == .typeChanged && (afterFile != nil || beforeFile != nil)) else {
            return header
        }
        let binary = try [beforeFile, afterFile].compactMap { $0 }.contains { try Self.looksBinary($0) }
        if binary {
            return header + "\n    binary changed (size \(Self.sizeString(c.before.size)) -> \(Self.sizeString(c.after.size)))"
        }
        let text = try Self.unifiedDiff(path: c.path, before: beforeFile, after: afterFile)
        return text.isEmpty ? header : text
    }

    /// Same heuristic as git: a NUL byte in the first 8000 bytes means binary.
    public static func looksBinary(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 8000) ?? Data()
        return head.contains(0)
    }

    /// Runs `git diff --no-index` between two files (nil means /dev/null) and
    /// rewrites the header so both sides show the project-relative path.
    public static func unifiedDiff(path: String, before: URL?, after: URL?) throws -> String {
        let a = before?.path ?? "/dev/null"
        let b = after?.path ?? "/dev/null"
        let result = try ProcessRunner.capture("/usr/bin/git", [
            "-c", "core.quotepath=off", "-c", "diff.noprefix=false",
            "diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv",
            "--", a, b,
        ])
        // Exit 1 means "files differ"; anything else is a real failure.
        guard result.status == 0 || result.status == 1 else {
            throw MudroomError.commandFailed("git diff --no-index", result.status, result.stderr)
        }
        return rewriteHeaders(result.stdout, path: path)
    }

    static func rewriteHeaders(_ diff: String, path: String) -> String {
        var lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for i in lines.indices {
            let line = lines[i]
            if line.hasPrefix("@@") { break }
            if line.hasPrefix("diff --git ") {
                lines[i] = "diff --git a/\(path) b/\(path)"
            } else if line.hasPrefix("--- ") {
                lines[i] = line == "--- /dev/null" ? line : "--- a/\(path)"
            } else if line.hasPrefix("+++ ") {
                lines[i] = line == "+++ /dev/null" ? line : "+++ b/\(path)"
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
