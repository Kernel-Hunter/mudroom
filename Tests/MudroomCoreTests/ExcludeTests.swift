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
import Testing
@testable import MudroomCore

@Suite("Exclude patterns")
struct ExcludeMatcherTests {
    func ex(_ patterns: [String], _ path: String, dir: Bool = false) -> Bool {
        ExcludeRules(patterns).excludes(path, isDirectory: dir)
    }

    @Test("a name without a slash matches at any depth, without case")
    func basename() {
        #expect(ex([".env"], ".env"))
        #expect(ex([".env"], "services/api/.env"))
        #expect(ex([".env"], ".ENV"))
        #expect(ex([".env"], "Config/.Env"))
        #expect(!ex([".env"], ".env.example"))
        #expect(!ex([".env"], "x.env"))
        #expect(!ex([".env"], "env"))
        // A folder of that name takes its contents with it.
        #expect(ex([".env"], ".env/inner.txt"))
    }

    @Test("the default list keeps .env files out and examples in")
    func defaults() {
        let rules = ExcludeRules(ExcludeList.defaults)
        for p in [".env", ".env.local", ".env.production", "api/.env.development.local", ".envrc", "certs/server.pem",
                  "tls/server.KEY", "keys/id_rsa", "deploy/id_ed25519", ".netrc", "store.p12"] {
            #expect(rules.excludes(p, isDirectory: false), "\(p)")
        }
        for p in [".env.example", "api/.env.sample", ".env.template", "README.md", "id_rsa.pub", "src/key.swift",
                  "environment.ts", ".npmrc"] {
            #expect(!rules.excludes(p, isDirectory: false), "\(p)")
        }
    }

    @Test("a trailing slash matches folders (and symlinks) only")
    func directoryOnly() {
        #expect(ex(["secrets/"], "secrets", dir: true))
        #expect(ex(["secrets/"], "secrets/key.txt"))
        #expect(ex(["secrets/"], "app/secrets/deep/key.txt"))
        #expect(!ex(["secrets/"], "secrets"))
        #expect(!ex(["secrets/"], "app/secrets"))
        // A symlink named like an excluded folder counts as one.
        let rules = ExcludeRules(["secrets/"])
        #expect(rules.match("secrets", before: .absent, after: .symlink(target: "/vault")) == "secrets/")
        #expect(rules.match("secrets", before: .absent, after: .file(mode: 0o644, size: 1, sha256: "x")) == nil)
    }

    @Test("a slash at the start or in the middle anchors to the project root")
    func anchored() {
        #expect(ex(["/build"], "build", dir: true))
        #expect(!ex(["/build"], "src/build", dir: true))
        #expect(ex(["config/secrets.json"], "config/secrets.json"))
        #expect(!ex(["config/secrets.json"], "app/config/secrets.json"))
        #expect(ex(["config/*.json"], "config/a.json"))
        #expect(!ex(["config/*.json"], "config/sub/a.json"))
    }

    @Test("** matches any number of folders")
    func doubleStar() {
        #expect(ex(["**/id_rsa"], "id_rsa"))
        #expect(ex(["**/id_rsa"], "a/b/c/id_rsa"))
        #expect(ex(["logs/**"], "logs/a.txt"))
        #expect(ex(["logs/**"], "logs/2026/10/a.txt"))
        // logs/** is what is inside, not the folder itself (so a ! line can take one back).
        #expect(!ex(["logs/**"], "logs", dir: true))
        #expect(!ex(["logs/**", "!logs/keep.txt"], "logs/keep.txt"))
        #expect(ex(["a/**/b"], "a/b"))
        #expect(ex(["a/**/b"], "a/x/y/b"))
        #expect(!ex(["a/**/b"], "a/x/c"))
        #expect(ex(["**/secrets/**"], "deep/secrets/x/y"))
    }

    @Test("* ? and [sets] stay within one name")
    func globs() {
        #expect(ex(["*.pem"], "a/b/server.pem"))
        #expect(!ex(["src/*.pem"], "src/a/server.pem"))
        #expect(ex(["?.txt"], "a.txt"))
        #expect(!ex(["?.txt"], "ab.txt"))
        #expect(ex(["key[0-9].txt"], "key7.txt"))
        #expect(!ex(["key[0-9].txt"], "keyx.txt"))
        #expect(ex(["key[!0-9].txt"], "keyx.txt"))
        #expect(ex(["[ab]*.env"], "B-prod.env"))
        #expect(ex(["*secret*"], "my-secret-file"))
        #expect(ex(["a*b*c"], "aXXbYYbZc"))
        #expect(!ex(["a*b*c"], "aXXbYY"))
        // An unclosed [ is a plain character.
        #expect(ex(["[oops"], "[oops"))
    }

    @Test("! takes a file back; the last matching line wins; nothing comes back out of an excluded folder")
    func negation() {
        #expect(!ex(["*.key", "!public.key"], "certs/public.key"))
        #expect(ex(["*.key", "!public.key"], "certs/private.key"))
        #expect(ex(["!a.txt", "a.txt"], "a.txt"))
        #expect(ex(["secrets/", "!secrets/ok.txt"], "secrets/ok.txt"))
        #expect(!ex([".env.*", "!.env.example"], "app/.env.example"))
    }

    @Test("comments, blank lines, escapes and trailing spaces")
    func syntax() {
        #expect(!ExcludeRules.isPattern(""))
        #expect(!ExcludeRules.isPattern("   "))
        #expect(!ExcludeRules.isPattern("# a comment"))
        #expect(!ExcludeRules.isPattern("!"))
        #expect(!ExcludeRules.isPattern("/"))
        #expect(ExcludeRules.isPattern(".env"))
        #expect(ex(["\\#notes"], "#notes"))
        #expect(ex(["\\!bang"], "!bang"))
        #expect(ex([".env   "], ".env"))
        #expect(ex(["a\\*b"], "a*b"))
        #expect(!ex(["a\\*b"], "axxb"))
        #expect(ExcludeRules.lines(of: "# team list\r\n.env\r\n\r\n*.sqlite\n!keep.sqlite\n") == [".env", "*.sqlite", "!keep.sqlite"])
    }

    @Test("names are compared after Unicode normalization")
    func unicode() {
        let nfc = "caf\u{e9}.key", nfd = "cafe\u{301}.key"
        #expect(ex([nfc], nfd))
        #expect(ex([nfd], nfc))
        #expect(ex(["\u{c9}T\u{c9}/"], "\u{e9}t\u{e9}", dir: true))
    }

    @Test("on Windows, trailing dots and spaces don't make a different name")
    func windowsNames() {
        #expect(ExcludeRules.canonicalName(".env.", windowsNames: true) == ".env")
        #expect(ExcludeRules.canonicalName(".ENV . ", windowsNames: true) == ".env")
        #expect(ExcludeRules.canonicalName("...", windowsNames: true) == "...")
        #expect(ExcludeRules.canonicalName(".env.", windowsNames: false) == ".env.")
        let rules = ExcludeRules([".env"])
        #expect(rules.matchEntry(ExcludeRules.components("a/.env. ", windowsNames: true)[...], isDirectory: false) == ".env")
    }

    @Test("a second list adds patterns but its ! lines can't take back the first list's")
    func separateLists() {
        let rules = ExcludeList(patterns: [".env"], ignoreFile: ["!.env", "*.sqlite", "!keep.sqlite"]).rules
        #expect(rules.excludes(".env", isDirectory: false))
        #expect(rules.excludes("db/app.sqlite", isDirectory: false))
        #expect(!rules.excludes("keep.sqlite", isDirectory: false))
        #expect(!rules.excludes("README.md", isDirectory: false))
        #expect(ExcludeList.empty.rules.isEmpty)
    }

    @Test("match reports the pattern, for folders above too")
    func reportsPattern() {
        let rules = ExcludeRules(["*.pem", "vault/"])
        #expect(rules.match("a/server.pem", isDirectory: false) == "*.pem")
        #expect(rules.match("vault/x/y.txt", isDirectory: false) == "vault/")
        var cache: [String: String?] = [:]
        #expect(rules.match("vault/a", isDirectory: false, folders: &cache) == "vault/")
        #expect(rules.match("vault/b", isDirectory: false, folders: &cache) == "vault/")
        #expect(rules.match("src/b", isDirectory: false, folders: &cache) == nil)
    }
}

@Suite("Exclude config")
struct ExcludeConfigTests {
    @Test("new and older project files get the defaults; an emptied list stays empty")
    func defaults() throws {
        let tmp = try TempDir()
        let store = ProjectConfigStore(directory: tmp.path("projects"))
        let project = tmp.path("p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        #expect(try store.load(project.path).excludePatterns == ExcludeList.defaults)

        // A file written before exclusions existed.
        let old = #"{"projectPath":"\#(project.resolvingSymlinksInPath().path)","networkMode":"open"}"#
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(old.utf8).write(to: store.url(for: project.path))
        let loaded = try store.load(project.path)
        #expect(loaded.networkMode == .open)
        #expect(loaded.excludePatterns == ExcludeList.defaults)

        try store.update(project.path) { $0.excludePatterns = [] }
        #expect(try store.load(project.path).excludePatterns.isEmpty)
    }

    @Test("add and remove patterns")
    func edit() {
        var c = ProjectConfig(projectPath: "/p")
        let results = [c.exclude("secrets/"), c.exclude("secrets/"), c.exclude("# comment"), c.exclude("  "),
                       c.unexclude(".env"), c.unexclude(".env")]
        #expect(results == [true, false, false, false, true, false])
        #expect(c.excludePatterns.last == "secrets/")
        #expect(!c.excludePatterns.contains(".env"))
    }

    @Test(".mudroomignore lines are read from the project root")
    func ignoreFile() throws {
        let tmp = try TempDir()
        try write("# team\n*.sqlite\n\nlocal/\n", to: tmp.path(".mudroomignore"))
        #expect(ExcludeList.readIgnoreFile(tmp.url) == ["*.sqlite", "local/"])
        #expect(ExcludeList.readIgnoreFile(tmp.path("missing")) == [])
    }

    @Test("the summary names paths and counts files")
    func summary() {
        let e = [ExcludedEntry(path: ".env", files: 1, pattern: ".env"),
                 ExcludedEntry(path: "secrets/", files: 3, pattern: "secrets/")]
        #expect(ExcludedEntry.summary(e) == ".env, secrets/ (4 files)")
        #expect(ExcludedEntry.summary([e[0]]) == ".env (1 file)")
        #expect(ExcludedEntry.summary(e, limit: 1) == ".env and 1 more (4 files)")
        #expect(ExcludedEntry.summary([]) == nil)
    }
}

@Suite("Exclude in clones and apply")
struct ExcludeSessionTests {
    static let patterns = ExcludeList.defaults + ["secrets/", "/local.json"]

    func populate(_ root: URL) throws {
        try write("SECRET=1\n", to: root.appendingPathComponent(".env"))
        try write("SECRET=\n", to: root.appendingPathComponent(".env.example"))
        try write("LOCAL=1\n", to: root.appendingPathComponent("api/.env.local"))
        try write("-----BEGIN-----\n", to: root.appendingPathComponent("certs/server.pem"))
        try write("k\n", to: root.appendingPathComponent("secrets/key.txt"))
        try write("k\n", to: root.appendingPathComponent("secrets/nested/more.txt"))
        try write("{}\n", to: root.appendingPathComponent("local.json"))
        try write("{}\n", to: root.appendingPathComponent("src/local.json"))
        try write("print(1)\n", to: root.appendingPathComponent("src/app.py"))
        try write("hello\n", to: root.appendingPathComponent("README.md"))
        // A symlink named like a secret is left out; one pointing at a
        // secret stays, dangling.
        try write("<html>\n", to: root.appendingPathComponent("web/index.html"))
        symlink("../.env", root.appendingPathComponent("web/.env").path)
        symlink(".env", root.appendingPathComponent("env-link").path)
        // An excluded file inside a read-only folder.
        try write("RO=1\n", to: root.appendingPathComponent("ro/.env"))
        try write("ok\n", to: root.appendingPathComponent("ro/ok.txt"))
        chmod(root.appendingPathComponent("ro").path, 0o555)
    }

    static let gone = [".env", "api/.env.local", "certs/server.pem", "secrets", "secrets/key.txt", "secrets/nested",
                       "secrets/nested/more.txt", "local.json", "web/.env", "ro/.env"]
    static let kept = [".env.example", "src/local.json", "src/app.py", "README.md", "env-link", "ro/ok.txt", "web"]

    func check(_ f: Fixture) throws {
        defer { for d in [f.project, f.handle.base, f.handle.work] { chmod(d.appendingPathComponent("ro").path, 0o755) } }
        for tree in [f.handle.base, f.handle.work] {
            let nodes = try TreeSnapshot.scan(tree).nodes
            for p in Self.gone { #expect(nodes[p] == nil, "\(p) in \(tree.lastPathComponent)") }
            for p in Self.kept { #expect(nodes[p] != nil, "\(p) missing in \(tree.lastPathComponent)") }
            #expect(nodes["env-link"] == .symlink(target: ".env"))
            #expect(nodes["ro"]?.mode == 0o555)
        }
        // The project is only read.
        #expect(exists(f.project.appendingPathComponent(".env")))
        #expect(exists(f.project.appendingPathComponent("ro/.env")))
        let s = f.handle.session
        #expect(s.exclude?.patterns == Self.patterns)
        let excluded = try #require(s.excluded)
        #expect(excluded.map(\.path) == [".env", "api/.env.local", "certs/server.pem", "local.json", "ro/.env", "secrets/", "web/.env"])
        #expect(excluded.first { $0.path == "secrets/" }?.files == 2)
        #expect(excluded.first { $0.path == "secrets/" }?.pattern == "secrets/")
        #expect(ExcludedEntry.summary(excluded)?.hasSuffix("(8 files)") == true)
        // Nothing to review right after cloning.
        #expect(try f.diff().isEmpty)
        // And what session.json says survives a reload.
        let reopened = try f.store.open(s.id)
        #expect(reopened.session.excluded == excluded)
        #expect(reopened.session.exclude == s.exclude)
    }

    @Test("a whole-folder clone has excluded entries removed before the session exists",
          .enabled(if: !isWindows && !isRoot))
    func clonefile() throws {
        let f = try Fixture(exclude: ExcludeList(patterns: Self.patterns), populate: populate)
        #if os(macOS)
        #expect(f.handle.session.cloneMethod == .clonefile)
        #endif
        try check(f)
    }

    @Test("a plain copy skips excluded entries", .enabled(if: !isWindows && !isRoot))
    func plainCopy() throws {
        let f = try Fixture(clone: false, exclude: ExcludeList(patterns: Self.patterns), populate: populate)
        #expect(f.handle.session.cloneMethod == .copy)
        try check(f)
    }

    @Test("Cloner reports what it left out, for each method")
    func clonerResult() throws {
        let tmp = try TempDir()
        let src = tmp.path("src")
        try write("a\n", to: src.appendingPathComponent(".env"))
        try write("a\n", to: src.appendingPathComponent("keep.txt"))
        try write("a\n", to: src.appendingPathComponent("vault/a.txt"))
        let rules = ExcludeRules([".env", "vault/"])
        for (i, clone) in [true, false].enumerated() {
            let dst = tmp.path("dst\(i)")
            let r = try Cloner.clone(from: src, to: dst, allowClonefile: clone, exclude: rules)
            #expect(r.excluded.map(\.path) == [".env", "vault/"])
            #expect(!exists(dst.appendingPathComponent(".env")))
            #expect(!exists(dst.appendingPathComponent("vault")))
            #expect(exists(dst.appendingPathComponent("keep.txt")))
        }
        // No rules: everything, nothing reported.
        let r = try Cloner.clone(from: src, to: tmp.path("all"), exclude: .empty)
        #expect(r.excluded.isEmpty)
        #expect(exists(tmp.path("all/.env")))
    }

    @Test("sessions use the project's list and .mudroomignore by default")
    func projectDefaults() throws {
        let f = try Fixture { root in
            try write("S=1\n", to: root.appendingPathComponent(".env"))
            try write("S=\n", to: root.appendingPathComponent(".env.example"))
            try write("db\n", to: root.appendingPathComponent("data/app.sqlite"))
            // The team file can't take the project's .env pattern back.
            try write("*.sqlite\n!.env\n", to: root.appendingPathComponent(".mudroomignore"))
        }
        #expect(f.handle.session.exclude == ExcludeList(patterns: ExcludeList.defaults, ignoreFile: ["*.sqlite", "!.env"]))
        #expect(!exists(f.work.appendingPathComponent(".env")))
        #expect(!exists(f.work.appendingPathComponent("data/app.sqlite")))
        #expect(exists(f.work.appendingPathComponent(".env.example")))
        #expect(exists(f.work.appendingPathComponent(".mudroomignore")))

        // With .env taken off the project's list, the next session copies it.
        try ProjectConfigStore(store: f.store).update(f.project.path) { $0.unexclude(".env") }
        let next = try f.store.create(project: f.project, command: ["true"], image: "test")
        #expect(exists(next.work.appendingPathComponent(".env")))
        #expect(!exists(next.work.appendingPathComponent("data/app.sqlite")))
    }

    @Test("an empty list copies everything, as before")
    func noExclusions() throws {
        let f = try Fixture(exclude: .empty) { root in
            try write("S=1\n", to: root.appendingPathComponent(".env"))
        }
        #expect(exists(f.work.appendingPathComponent(".env")))
        #expect(f.handle.session.excluded == nil)
    }

    func agentFixture(projectHasEnv: Bool) throws -> Fixture {
        let f = try Fixture(exclude: ExcludeList(patterns: ExcludeList.defaults + ["secrets/"])) { root in
            if projectHasEnv { try write("REAL=1\n", to: root.appendingPathComponent(".env")) }
            try write("a\n", to: root.appendingPathComponent("app.txt"))
        }
        // The agent writes a .env of its own, a case variant, a secrets
        // folder, and one ordinary edit.
        try write("AGENT=1\n", to: f.work.appendingPathComponent(".env"))
        try write("AGENT=1\n", to: f.work.appendingPathComponent(".ENV.local"))
        try write("x\n", to: f.work.appendingPathComponent("secrets/token.txt"))
        try write("b\n", to: f.work.appendingPathComponent("app.txt"))
        return f
    }

    @Test("files the agent creates at excluded paths are listed apart and never applied")
    func agentCreated() throws {
        for projectHasEnv in [false, true] {
            let f = try agentFixture(projectHasEnv: projectHasEnv)
            let diff = try f.diff()
            #expect(diff.changes.map(\.path) == ["app.txt"])
            #expect(Set(diff.excludedTopLevel.map(\.path)) == [".env", ".ENV.local", "secrets"])

            let report = try Applier(handle: f.handle).apply(paths: nil, reviewed: ReviewedChanges(diff.changes))
            #expect(report.applied == ["app.txt"])
            #expect(report.conflicts.isEmpty)
            let skipped = Dictionary(report.skipped.map { ($0.path, $0.reason) }) { a, _ in a }
            #expect(skipped[".env"] == "matches the exclude pattern .env; never applied")
            #expect(skipped[".ENV.local"] == "matches the exclude pattern .env.*; never applied")
            #expect(skipped["secrets"] == "matches the exclude pattern secrets/; never applied")
            #expect(try read(f.project.appendingPathComponent("app.txt")) == "b\n")
            if projectHasEnv {
                #expect(try read(f.project.appendingPathComponent(".env")) == "REAL=1\n")
            } else {
                #expect(!exists(f.project.appendingPathComponent(".env")))
            }
            #expect(!exists(f.project.appendingPathComponent(".ENV.local")))
            #expect(!exists(f.project.appendingPathComponent("secrets")))
        }
    }

    @Test("asking for an excluded path by name, or for a path inside one, is refused with the reason")
    func explicitPaths() throws {
        let f = try agentFixture(projectHasEnv: false)
        let applier = Applier(handle: f.handle)
        let r1 = try applier.apply(paths: [".env", "secrets/token.txt"])
        #expect(r1.applied.isEmpty)
        #expect(Set(r1.skipped.map(\.path)) == [".env", "secrets"])
        #expect(!r1.skipped.contains { $0.reason == "no change at this path" })
        let r2 = try applier.apply(paths: ["app.txt", ".env.LOCAL"])
        #expect(r2.applied == ["app.txt"])
        #expect(r2.skipped.map(\.path) == [".env.LOCAL"])
        #expect(r2.skipped.first?.reason == "no change at this path")
        let r3 = try applier.applyHunks(path: ".env", hunks: [1])
        #expect(r3.applied.isEmpty)
        #expect(r3.skipped.first?.path == ".env")
        #expect(!exists(f.project.appendingPathComponent(".env")))
        #expect(!exists(f.project.appendingPathComponent("secrets")))
    }

    @Test("apply refuses excluded paths even from a diff made without the session's rules")
    func precomputedDiff() throws {
        let f = try agentFixture(projectHasEnv: false)
        let raw = try Differ.compare(base: f.handle.base, work: f.work)
        #expect(raw.changes.contains { $0.path == ".env" })
        let report = try Applier(handle: f.handle).apply(paths: nil, reviewed: ReviewedChanges(raw.changes), diff: raw)
        #expect(report.applied == ["app.txt"])
        #expect(!exists(f.project.appendingPathComponent(".env")))
        #expect(!exists(f.project.appendingPathComponent("secrets")))
        #expect(report.skipped.contains { $0.path == ".env" })
    }

    @Test("review data, the timeline and the terminal diff list excluded files apart")
    func review() throws {
        let f = try agentFixture(projectHasEnv: false)
        let snap = try ReviewSnapshot.load(f.handle)
        #expect(snap.files.map(\.path) == ["app.txt"])
        #expect(snap.excluded == [".ENV.local", ".env", "secrets/"])
        #expect(snap.reviewed.changes.keys.sorted() == ["app.txt"])

        // A snapshot taken while the agent ran has the .env too; the
        // timeline view still keeps it out of the file list.
        let s = try #require(try SnapshotStore(handle: f.handle).take())
        try write("c\n", to: f.work.appendingPathComponent("app.txt"))
        let timeline = try ReviewSnapshot.loadTimeline(f.handle, from: s.directory)
        #expect(timeline.files.map(\.path) == ["app.txt"])

        let renderer = DiffRenderer(base: f.handle.base, work: f.work)
        let stat = renderer.stat(try f.diff())
        #expect(stat.contains("X  .env  (on the exclude list; never applied)"))
        #expect(stat.contains("X  secrets/  (on the exclude list; never applied)"))
        #expect(!stat.contains("secrets/token.txt"))
        #expect(try renderer.full(try f.diff()).contains("X  .env"))
    }

    @Test("only excluded changes: the diff is not empty, nothing applies")
    func onlyExcluded() throws {
        let f = try Fixture(exclude: ExcludeList(patterns: [".env"])) { root in
            try write("a\n", to: root.appendingPathComponent("a.txt"))
        }
        try write("X=1\n", to: f.work.appendingPathComponent(".env"))
        let diff = try f.diff()
        #expect(!diff.isEmpty)
        #expect(diff.changes.isEmpty)
        let stat = DiffRenderer(base: f.handle.base, work: f.work).stat(diff)
        #expect(!stat.contains("no changes"))
        let report = try Applier(handle: f.handle).apply(paths: nil)
        #expect(!report.wroteAnything)
        #expect(report.skipped.map(\.path) == [".env"])
    }

    @Test("an agent edit to .mudroomignore is flagged")
    func ignoreFileFlagged() {
        #expect(Differ.hostRisk(".mudroomignore") != nil)
        #expect(Differ.hostRisk("sub/.mudroomignore") == nil)
    }

    @Test("sessions from before exclusions keep working")
    func oldSession() throws {
        let f = try Fixture(exclude: .empty) { root in
            try write("a\n", to: root.appendingPathComponent("a.txt"))
        }
        var h = f.handle
        h.session.exclude = nil
        try h.save()
        let json = try String(contentsOf: h.directory.appendingPathComponent("session.json"), encoding: .utf8)
        #expect(!json.contains("\"exclude\""))
        let reopened = try f.store.open(h.session.id)
        #expect(reopened.session.excludeRules.isEmpty)
        try write("X=1\n", to: f.work.appendingPathComponent(".env"))
        // Nothing recorded, nothing excluded: same as before.
        #expect(try Differ.compare(reopened).changes.map(\.path) == [".env"])
    }

    @Test("preview lists what a new session would leave out, without touching the project")
    func preview() throws {
        let tmp = try TempDir()
        try write("a\n", to: tmp.path(".env"))
        try write("a\n", to: tmp.path("k/a.pem"))
        try write("a\n", to: tmp.path("vault/a"))
        try write("a\n", to: tmp.path("vault/b/c"))
        try write("a\n", to: tmp.path("ok.txt"))
        let found = ExcludeList.preview(tmp.url, rules: ExcludeRules(ExcludeList.defaults + ["vault/"]))
        #expect(found.map(\.path) == [".env", "k/a.pem", "vault/"])
        #expect(found.last?.files == 2)
        #expect(exists(tmp.path(".env")))
    }
}
