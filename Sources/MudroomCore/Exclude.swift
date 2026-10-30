#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif
import Foundation

/// gitignore-style patterns for files that stay out of the sandbox.
///
/// The syntax is gitignore's, relative to the project root:
///
/// - `name` (no slash) matches a file or folder of that name at any depth.
/// - A slash at the start or in the middle (`/build`, `config/secrets.json`)
///   anchors the pattern to the project root.
/// - A trailing slash (`secrets/`) matches folders only. Mudroom also lets it
///   match a symlink of that name, so a link standing in for the folder
///   stays out too.
/// - `*` matches anything but `/`, `?` one character, `[a-z]` and `[!a-z]`
///   a set; `**` matches any number of folders (`**/id_rsa`, `logs/**`,
///   `a/**/b`).
/// - `!pattern` takes a file back in (`!.env.example`). As in git, nothing
///   inside an excluded folder can be taken back.
/// - Blank lines and lines starting with `#` are ignored; `\` escapes the
///   next character (`\#notes`, `\!important`).
///
/// Names are compared without case and after Unicode normalization, so
/// `.ENV` matches `.env` (APFS and NTFS treat them as one file). On Windows,
/// trailing dots and spaces are ignored too (`.env.` is `.env` there).
///
/// Several lists can be combined (`ExcludeRules(sets:)`). A path is excluded
/// when any list excludes it, and a `!` line only takes back what its own
/// list excluded: a `.mudroomignore` file in the project can add patterns
/// but can't undo the project's own list.
public struct ExcludeRules: Sendable, Equatable {
    struct Rule: Sendable, Equatable {
        let source: String
        let negated: Bool
        let directoryOnly: Bool
        /// Path segments; `nil` is `**`.
        let segments: [[GlobToken]?]
    }

    enum GlobToken: Sendable, Equatable {
        case literal(Character)
        case any            // *
        case one            // ?
        case set([ClosedRange<Character>], classes: [CharClass], negated: Bool)
    }

    /// POSIX classes inside a set, e.g. `[[:digit:]]`. Names are compared
    /// lower-cased, so `upper` and `lower` both match any letter that has
    /// case.
    enum CharClass: String, Sendable, Equatable, CaseIterable {
        case alpha, digit, alnum, upper, lower, space, punct, xdigit

        func contains(_ c: Character) -> Bool {
            switch self {
            case .alpha: c.isLetter
            case .digit: c.isASCII && c.isWholeNumber
            case .alnum: c.isLetter || (c.isASCII && c.isWholeNumber)
            case .upper, .lower: c.isCased
            case .space: c.isWhitespace
            case .punct: c.isASCII && (c.isPunctuation || c.isSymbol)
            case .xdigit: c.isHexDigit
            }
        }
    }

    /// Why a line isn't a usable pattern.
    public struct PatternError: Error, Equatable, CustomStringConvertible {
        public let line: String
        public let reason: String
        public var description: String { "\(line.debugDescription): \(reason)" }
    }

    /// Longest pattern line accepted, in characters.
    public static let maxLineLength = 1024

    let sets: [[Rule]]

    public static let empty = ExcludeRules(sets: [])

    public init(_ patterns: [String]) { self.init(sets: [patterns]) }

    public init(sets: [[String]]) {
        self.sets = sets.map { $0.compactMap(Self.compile) }.filter { !$0.isEmpty }
    }

    public var isEmpty: Bool { sets.isEmpty }

    /// Whether `pattern` is a usable pattern line (not blank, not a comment).
    public static func isPattern(_ pattern: String) -> Bool { compile(pattern) != nil }

    /// Why `line` can't be used, or nil if it is a pattern, a comment or
    /// blank.
    public static func problem(_ line: String) -> String? {
        if case .failure(let e) = parse(line) { return e.reason }
        return nil
    }

    /// The pattern lines of a `.mudroomignore` (or `.gitignore`-style) file.
    /// Throws on a line that is neither a pattern nor a comment or blank.
    public static func lines(of text: String) throws -> [String] {
        var out: [String] = []
        for (n, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            switch parse(String(line)) {
            case .success(.some): out.append(String(line))
            case .success(.none): continue
            case .failure(let e): throw PatternError(line: e.line, reason: "line \(n + 1): \(e.reason)")
            }
        }
        return out
    }

    // MARK: Matching

    /// The pattern that keeps `path` (relative, `/`-separated) out of the
    /// sandbox, or nil. A folder above it that is excluded excludes it too.
    /// `isDirectory` is true for folders (and symlinks, see above).
    public func match(_ path: String, isDirectory: Bool) -> String? {
        var cache: [String: String?] = [:]
        return match(path, isDirectory: isDirectory, folders: &cache)
    }

    /// `match`, remembering the verdict for each folder above `path` in
    /// `folders`, for many paths in a row (a diff).
    public func match(_ path: String, isDirectory: Bool, folders: inout [String: String?]) -> String? {
        guard !isEmpty else { return nil }
        let parts = Self.components(path)
        guard !parts.isEmpty else { return nil }
        var key = ""
        for i in 1..<parts.count {
            key += (i == 1 ? "" : "/") + parts[i - 1]
            if let known = folders[key] {
                if let p = known { return p }
                continue
            }
            let verdict = matchEntry(parts[..<i], isDirectory: true)
            folders[key] = .some(verdict)
            if let p = verdict { return p }
        }
        return matchEntry(parts[...], isDirectory: isDirectory)
    }

    public func excludes(_ path: String, isDirectory: Bool) -> Bool { match(path, isDirectory: isDirectory) != nil }

    /// `match` for a change: folders and symlinks on either side count as
    /// folders.
    public func match(_ path: String, before: FileNode, after: FileNode) -> String? {
        match(path, isDirectory: Self.folderLike(before) || Self.folderLike(after))
    }

    public func match(_ path: String, before: FileNode, after: FileNode, folders: inout [String: String?]) -> String? {
        match(path, isDirectory: Self.folderLike(before) || Self.folderLike(after), folders: &folders)
    }

    static func folderLike(_ node: FileNode) -> Bool {
        switch node {
        case .directory, .symlink: true
        default: false
        }
    }

    /// For tree walks that stop at excluded folders: checks only the entry
    /// itself, not the folders above it (they were checked on the way down).
    func matchEntry(_ parts: ArraySlice<String>, isDirectory: Bool) -> String? {
        for set in sets {
            if let p = Self.decide(set, parts, isDirectory: isDirectory) { return p }
        }
        return nil
    }

    /// The last rule matching `parts` decides: its pattern if it excludes,
    /// nil if it takes the path back or nothing matches.
    static func decide(_ rules: [Rule], _ parts: ArraySlice<String>, isDirectory: Bool) -> String? {
        for rule in rules.reversed() where !(rule.directoryOnly && !isDirectory) {
            if matches(rule.segments[...], parts) { return rule.negated ? nil : rule.source }
        }
        return nil
    }

    /// Path components as they are compared: lower case, NFC, and on
    /// Windows without trailing dots and spaces.
    static func components(_ path: String, windowsNames: Bool = isWindowsHost) -> [String] {
        path.split(separator: "/").filter { $0 != "." }.map { canonicalName(String($0), windowsNames: windowsNames) }
    }

    static func canonicalName(_ name: String, windowsNames: Bool = isWindowsHost) -> String {
        var s = name.precomposedStringWithCanonicalMapping.lowercased()
        if windowsNames {
            var t = Substring(s)
            while let last = t.last, last == "." || last == " " { t = t.dropLast() }
            if !t.isEmpty { s = String(t) }
        }
        return s
    }

    #if os(Windows)
    static let isWindowsHost = true
    #else
    static let isWindowsHost = false
    #endif

    /// Segments against path components, by dynamic programming over
    /// (segment, component) so a pattern full of `**` can't take
    /// exponential time: at most segments x components name matches.
    static func matches(_ segs: ArraySlice<[GlobToken]?>, _ parts: ArraySlice<String>) -> Bool {
        let s = Array(segs), p = Array(parts)
        let cols = p.count + 1
        // ok[i * cols + j]: s[i...] matches p[j...]. Filled from the end.
        var ok = [Bool](repeating: false, count: (s.count + 1) * cols)
        ok[s.count * cols + p.count] = true
        var names: [[Character]?] = Array(repeating: nil, count: p.count)
        for i in stride(from: s.count - 1, through: 0, by: -1) {
            for j in stride(from: p.count, through: 0, by: -1) {
                let v: Bool
                if let glob = s[i] {
                    if j < p.count, ok[(i + 1) * cols + j + 1] {
                        if names[j] == nil { names[j] = Array(p[j]) }
                        v = globMatch(glob[...], names[j]![...])
                    } else {
                        v = false
                    }
                } else if i == s.count - 1 {
                    // A trailing `**` matches what is inside, not the folder itself.
                    v = j < p.count
                } else {
                    // `**`: none of the components, or one more.
                    v = ok[(i + 1) * cols + j] || (j < p.count && ok[i * cols + j + 1])
                }
                ok[i * cols + j] = v
            }
        }
        return ok[0]
    }

    /// One name against one segment's tokens. `*` backtracks to the last
    /// star only, which is enough for single-segment globs.
    static func globMatch(_ pattern: ArraySlice<GlobToken>, _ name: ArraySlice<Character>) -> Bool {
        var p = pattern.startIndex, n = name.startIndex
        var star: (p: Int, n: Int)?
        while n < name.endIndex {
            if p < pattern.endIndex {
                switch pattern[p] {
                case .any:
                    star = (p, n)
                    p += 1
                    continue
                case .one:
                    p += 1; n += 1
                    continue
                case .literal(let c) where c == name[n]:
                    p += 1; n += 1
                    continue
                case .set(let ranges, let classes, let negated)
                    where (ranges.contains { $0.contains(name[n]) } || classes.contains { $0.contains(name[n]) }) != negated:
                    p += 1; n += 1
                    continue
                default:
                    break
                }
            }
            guard let s = star else { return false }
            p = s.p + 1
            n = s.n + 1
            star = (s.p, s.n + 1)
        }
        while p < pattern.endIndex, pattern[p] == .any { p += 1 }
        return p == pattern.endIndex
    }

    // MARK: Parsing

    static func compile(_ line: String) -> Rule? {
        if case .success(let rule) = parse(line) { return rule }
        return nil
    }

    /// A rule, nil for a comment or blank line, or why the line is unusable.
    static func parse(_ line: String) -> Result<Rule?, PatternError> {
        func bad(_ why: String) -> Result<Rule?, PatternError> { .failure(PatternError(line: line, reason: why)) }
        if line.count > maxLineLength { return bad("longer than \(maxLineLength) characters") }
        if line.contains("\u{0}") { return bad("contains a NUL character") }
        var chars = Array(line.precomposedStringWithCanonicalMapping)
        // Line endings, then trailing spaces unless escaped.
        while let last = chars.last, last == "\r" || last == "\n" { chars.removeLast() }
        while let last = chars.last, last == " " || last == "\t" {
            if chars.count >= 2, chars[chars.count - 2] == "\\" { break }
            chars.removeLast()
        }
        guard let first = chars.first, first != "#" else { return .success(nil) }
        var negated = false
        if first == "!" {
            negated = true
            chars.removeFirst()
        }
        var directoryOnly = false
        if chars.last == "/" {
            while chars.last == "/" { chars.removeLast() }
            directoryOnly = true
        }
        guard !chars.isEmpty else { return bad("no pattern") }
        do {
            guard let rule = try build(chars, source: line, negated: negated, directoryOnly: directoryOnly) else {
                return bad("no pattern")
            }
            return .success(rule)
        } catch let e as PatternError {
            return .failure(PatternError(line: line, reason: e.reason))
        } catch {
            return bad("\(error)")
        }
    }

    private static func build(_ chars: [Character], source: String, negated: Bool, directoryOnly: Bool) throws -> Rule? {
        // Split on unescaped slashes.
        var raw: [[Character]] = [[]]
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                raw[raw.count - 1] += [c, chars[i + 1]]
                i += 2
                continue
            }
            if c == "/" { raw.append([]) } else { raw[raw.count - 1].append(c) }
            i += 1
        }
        // A slash anywhere but the end anchors the pattern to the root.
        let anchored = raw.count > 1
        if raw.first?.isEmpty == true { raw.removeFirst() }
        raw.removeAll { $0.isEmpty }
        guard !raw.isEmpty else { return nil }
        var segments: [[GlobToken]?] = []
        for seg in raw {
            if seg == ["*", "*"] {
                if segments.last.map({ $0 == nil }) != true { segments.append(nil) }
                continue
            }
            segments.append(try tokenize(seg))
        }
        if !anchored, segments.first.map({ $0 != nil }) ?? false { segments.insert(nil, at: 0) }
        return Rule(source: source.trimmingCharacters(in: .whitespacesAndNewlines), negated: negated,
                    directoryOnly: directoryOnly, segments: segments)
    }

    /// Lower-cased tokens for one segment. Runs of `*` are one `*`; an
    /// unclosed `[` is a literal.
    static func tokenize(_ seg: [Character]) throws -> [GlobToken] {
        var out: [GlobToken] = []
        var i = 0
        func lower(_ c: Character) -> Character { Character(String(c).lowercased()) }
        while i < seg.count {
            let c = seg[i]
            switch c {
            case "\\" where i + 1 < seg.count:
                out.append(.literal(lower(seg[i + 1])))
                i += 2
            case "*":
                if out.last != .any { out.append(.any) }
                i += 1
            case "?":
                out.append(.one)
                i += 1
            case "[":
                if let (set, next) = try parseSet(seg, from: i + 1) {
                    out.append(set)
                    i = next
                } else {
                    out.append(.literal("["))
                    i += 1
                }
            default:
                out.append(.literal(lower(c)))
                i += 1
            }
        }
        return out
    }

    /// `[...]` starting after the `[`; returns the token and the index after
    /// `]`, or nil if the set isn't closed. Throws on an unknown `[:class:]`.
    static func parseSet(_ seg: [Character], from start: Int) throws -> (GlobToken, Int)? {
        var i = start
        var negated = false
        if i < seg.count, seg[i] == "!" || seg[i] == "^" {
            negated = true
            i += 1
        }
        var ranges: [ClosedRange<Character>] = []
        var classes: [CharClass] = []
        var first = true
        func lower(_ c: Character) -> Character { Character(String(c).lowercased()) }
        while i < seg.count {
            var c = seg[i]
            if c == "]" && !first { return (.set(ranges, classes: classes, negated: negated), i + 1) }
            first = false
            if c == "[", i + 1 < seg.count, seg[i + 1] == ":" {
                // [:name:]
                var j = i + 2
                while j + 1 < seg.count, !(seg[j] == ":" && seg[j + 1] == "]") { j += 1 }
                guard j + 1 < seg.count else { return nil }
                let name = String(seg[(i + 2)..<j])
                guard let cls = CharClass(rawValue: name) else {
                    throw PatternError(line: "", reason: "unknown character class [:\(name):]; use one of "
                                       + CharClass.allCases.map { "[:\($0.rawValue):]" }.joined(separator: " "))
                }
                classes.append(cls)
                i = j + 2
                continue
            }
            if c == "\\", i + 1 < seg.count {
                i += 1
                c = seg[i]
            }
            if i + 2 < seg.count, seg[i + 1] == "-", seg[i + 2] != "]" {
                let a = lower(c), b = lower(seg[i + 2])
                if a <= b { ranges.append(a...b) }
                i += 3
            } else {
                ranges.append(lower(c)...lower(c))
                i += 1
            }
        }
        return nil
    }
}

/// The patterns a session was created with: the project's own list
/// (Mudroom's defaults unless changed) and the lines of the project's
/// `.mudroomignore`. Kept in session.json, so the diff and apply use what
/// the clone used, and nothing the agent writes into its copy can change it.
public struct ExcludeList: Codable, Sendable, Equatable {
    public var patterns: [String]
    /// Lines of `.mudroomignore` at the project root when the session was
    /// created; empty if there was none.
    public var ignoreFile: [String]

    public init(patterns: [String], ignoreFile: [String] = []) {
        self.patterns = patterns
        self.ignoreFile = ignoreFile
    }

    public static let empty = ExcludeList(patterns: [])

    public var rules: ExcludeRules { ExcludeRules(sets: [patterns, ignoreFile]) }

    public static let ignoreFileName = ".mudroomignore"

    /// Patterns kept out of new projects' sandboxes until changed with
    /// `mudroom exclude` or in New Session. Files that hold credentials and
    /// little else; examples and templates of `.env` stay in.
    public static let defaults: [String] = [
        ".env",
        ".env.*",
        "!.env.example",
        "!.env.sample",
        "!.env.template",
        ".envrc",
        "*.pem",
        "*.key",
        "*.p12",
        "*.pfx",
        "id_rsa",
        "id_dsa",
        "id_ecdsa",
        "id_ed25519",
        ".netrc",
    ]

    /// The project's list from its config plus its `.mudroomignore`.
    public static func forProject(_ project: URL, config: ProjectConfig) throws -> ExcludeList {
        ExcludeList(patterns: config.excludePatterns, ignoreFile: try readIgnoreFile(project))
    }

    public static let maxIgnoreFileBytes = 1 << 20
    public static let maxIgnoreFilePatterns = 1000

    /// Pattern lines of `<project>/.mudroomignore`, or [] if there is none.
    /// Throws if it exists but can't be used: a symlink, not a regular file,
    /// unreadable, over 1 MB, over 1,000 patterns, not UTF-8, or a line that
    /// isn't a pattern. It is opened without following links or blocking on
    /// a FIFO, so it can't point the read somewhere else.
    public static func readIgnoreFile(_ project: URL) throws -> [String] {
        let url = project.appendingPathComponent(ignoreFileName)
        guard entryExists(url) else { return [] }
        func unusable(_ why: String) -> MudroomError {
            .invalid("\(url.path) can't be used: \(why). Make it a regular file (at most 1 MB, \(maxIgnoreFilePatterns) patterns) or remove it")
        }
        let data: Data
        do {
            data = try SafeFS.readBeneath(project, ignoreFileName, limit: maxIgnoreFileBytes + 1)
        } catch {
            throw unusable(MudroomError.message(error))
        }
        guard data.count <= maxIgnoreFileBytes else { throw unusable("it is larger than 1 MB") }
        guard let text = String(data: data, encoding: .utf8) else { throw unusable("it is not UTF-8 text") }
        let lines: [String]
        do { lines = try ExcludeRules.lines(of: text) } catch { throw unusable("\(error)") }
        guard lines.count <= maxIgnoreFilePatterns else { throw unusable("it has more than \(maxIgnoreFilePatterns) patterns") }
        return lines
    }

    /// Whether anything (a dangling symlink included) is at `url`.
    static func entryExists(_ url: URL) -> Bool {
        #if os(Windows)
        if case .failure(let e) = WinFS.lstat(url.path),
           e.code == DWORD(ERROR_FILE_NOT_FOUND) || e.code == DWORD(ERROR_PATH_NOT_FOUND) { return false }
        return true
        #else
        var st = stat()
        return lstat(url.path, &st) == 0 || errno != ENOENT
        #endif
    }
}

extension ExcludeList {
    /// What a session of `project` created now would leave out. Only reads.
    public static func preview(_ project: URL, rules: ExcludeRules) -> [ExcludedEntry] {
        guard !rules.isEmpty else { return [] }
        var out: [ExcludedEntry] = []
        func walk(_ dir: String, _ rel: [String], _ canonical: [String]) {
            for e in entries(dir).sorted(by: { $0.name < $1.name }) {
                let path = dir + "/" + e.name
                let r = rel + [e.name], canon = canonical + [ExcludeRules.canonicalName(e.name)]
                if let pattern = rules.matchEntry(canon[...], isDirectory: e.isDirectory || e.isSymlink) {
                    out.append(ExcludedEntry(path: r.joined(separator: "/") + (e.isDirectory ? "/" : ""),
                                             files: e.isDirectory ? countFiles(path) : 1, pattern: pattern))
                } else if e.isDirectory {
                    walk(path, r, canon)
                }
            }
        }
        walk(project.path, [], [])
        return out
    }

    private static func countFiles(_ dir: String) -> Int {
        entries(dir).reduce(0) { $0 + ($1.isDirectory ? countFiles(dir + "/" + $1.name) : 1) }
    }

    private static func entries(_ dir: String) -> [(name: String, isDirectory: Bool, isSymlink: Bool)] {
        #if os(Windows)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.map { name in
            let type = (try? FileManager.default.attributesOfItem(atPath: dir + "/" + name))?[.type] as? FileAttributeType
            return (name, type == .typeDirectory, type == .typeSymbolicLink)
        }
        #else
        return ((try? ExcludeWalk.list(dir)) ?? []).map { ($0.name, $0.isDirectory, $0.isSymlink) }
        #endif
    }
}

extension ExcludedEntry {
    /// The entries of `entries` that git tracks in `project`: they look
    /// deleted to git inside the sandbox. Empty when the project isn't a git
    /// work tree, git isn't installed, or it fails. Runs `git ls-files`
    /// with fsmonitor off and no optional locks, so it runs no hooks and
    /// writes nothing.
    public static func trackedByGit(_ entries: [ExcludedEntry], project: URL,
                                    git: String? = ProcessRunner.which("git")) -> [String] {
        guard !entries.isEmpty, let git, ExcludeList.entryExists(project.appendingPathComponent(".git")) else { return [] }
        let names = entries.prefix(500).map { $0.path.hasSuffix("/") ? String($0.path.dropLast()) : $0.path }
        let args = ["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "ls-files", "-z", "--"]
            + names.map { ":(literal)" + $0 }
        guard let out = try? ProcessRunner.capture(git, args, cwd: project, environment: ["GIT_OPTIONAL_LOCKS": "0"], timeout: 15),
              out.status == 0, !out.timedOut else { return [] }
        let files = out.stdout.split(separator: "\u{0}").map(String.init)
        return entries.prefix(500).filter { e in
            let name = e.path.hasSuffix("/") ? String(e.path.dropLast()) : e.path
            return files.contains { $0 == name || $0.hasPrefix(name + "/") }
        }.map(\.path)
    }
}

/// Something the clone left out because it matched an exclude pattern.
public struct ExcludedEntry: Codable, Sendable, Equatable, CustomStringConvertible {
    /// Relative path; folders end in `/`.
    public var path: String
    /// Files (and symlinks) it held: 1 for a file, the count inside a folder.
    public var files: Int
    /// The pattern that matched.
    public var pattern: String

    public init(path: String, files: Int, pattern: String) {
        self.path = path
        self.files = files
        self.pattern = pattern
    }

    public var description: String { path }

    /// "left out of the sandbox: .env, secrets/ (3 files)", or nil when
    /// nothing was. At most `limit` paths are named.
    public static func summary(_ entries: [ExcludedEntry], limit: Int = 8) -> String? {
        guard !entries.isEmpty else { return nil }
        let names = entries.prefix(limit).map { TextLines.visible($0.path) }.joined(separator: ", ")
        let more = entries.count > limit ? " and \(entries.count - limit) more" : ""
        let files = entries.reduce(0) { $0 + $1.files }
        return "\(names)\(more) (\(files) file\(files == 1 ? "" : "s"))"
    }
}
