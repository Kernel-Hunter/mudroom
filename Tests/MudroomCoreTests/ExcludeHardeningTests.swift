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

@Suite("Exclude hardening")
struct ExcludeHardeningTests {
    @Test("a pattern full of ** against a deep path finishes quickly")
    func noBacktrackingBlowup() {
        let pattern = String(repeating: "**/a/", count: 18) + "b"
        let deep = Array(repeating: "a", count: 40).joined(separator: "/")
        let rules = ExcludeRules([pattern])
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(!rules.excludes(deep, isDirectory: false))
            #expect(!rules.excludes(deep + "/c", isDirectory: false))
            #expect(rules.excludes(deep + "/b", isDirectory: false))
            // Fewer than 18 a's before the b can't match.
            #expect(!rules.excludes(Array(repeating: "a", count: 17).joined(separator: "/") + "/b", isDirectory: false))
        }
        #expect(elapsed < .seconds(2))
    }

    @Test("** semantics hold with the table-driven matcher")
    func doubleStarStillRight() {
        let r = ExcludeRules(["a/**/b/**/c", "x/**"])
        #expect(r.excludes("a/b/c", isDirectory: false))
        #expect(r.excludes("a/1/2/b/3/c", isDirectory: false))
        #expect(!r.excludes("a/1/c", isDirectory: false))
        #expect(r.excludes("x/y", isDirectory: false))
        #expect(!r.excludes("x", isDirectory: true))
    }

    @Test("POSIX classes in sets")
    func posixClasses() {
        func ex(_ p: String, _ path: String) -> Bool { ExcludeRules([p]).excludes(path, isDirectory: false) }
        #expect(ex("key[[:digit:]].txt", "key7.txt"))
        #expect(!ex("key[[:digit:]].txt", "keyx.txt"))
        #expect(ex("[[:alpha:]]*.env", "prod.env"))
        #expect(!ex("[[:alpha:]]*.env", "1.env"))
        #expect(ex("v[![:alnum:]]x", "v-x"))
        #expect(!ex("v[![:alnum:]]x", "v1x"))
        // Names are compared lower-cased, so upper and lower take either case.
        #expect(ex("[[:upper:]]", "A"))
        #expect(ex("[[:upper:]]", "a"))
        #expect(ex("[[:lower:]]", "B"))
        #expect(!ex("[[:upper:]]", "1"))
        #expect(ex("id[[:space:]]x", "id x"))
        #expect(ex("a[[:punct:]]b", "a-b"))
        #expect(ex("[[:xdigit:]][[:xdigit:]]", "fF"))
        #expect(!ex("[[:xdigit:]]", "g"))
        #expect(ex("[[:digit:]a-c]", "b"))
        // An unknown class is an error, not a pattern that matches nothing.
        #expect(!ExcludeRules.isPattern("[[:bogus:]]"))
        #expect(ExcludeRules.problem("[[:bogus:]]")?.contains("unknown character class") == true)
        #expect(ExcludeRules.problem("*.pem") == nil)
        #expect(ExcludeRules.problem("# comment") == nil)
    }

    @Test("over-long lines are refused")
    func longLines() {
        let long = String(repeating: "a", count: ExcludeRules.maxLineLength + 1)
        #expect(ExcludeRules.problem(long) != nil)
        #expect(ExcludeRules.problem(String(long.dropLast())) == nil)
        #expect(throws: ExcludeRules.PatternError.self) { try ExcludeRules.lines(of: ".env\n" + long + "\n") }
    }

    func ignoreFileError(_ setUp: (URL) throws -> Void) throws -> String? {
        let tmp = try TempDir()
        try setUp(tmp.url)
        do {
            _ = try ExcludeList.readIgnoreFile(tmp.url)
            return nil
        } catch {
            return MudroomError.message(error)
        }
    }

    @Test(".mudroomignore must be a small regular file of patterns", .enabled(if: !isWindows))
    func ignoreFileChecks() throws {
        let name = ExcludeList.ignoreFileName
        // Missing is fine.
        #expect(try ignoreFileError { _ in } == nil)
        // A symlink, even to a good file, is refused (it isn't followed).
        let link = try ignoreFileError { root in
            try write(".env\n", to: root.appendingPathComponent("real"))
            symlink("real", root.appendingPathComponent(name).path)
        }
        #expect(link?.contains("can't be used") == true)
        #expect(try ignoreFileError { root in symlink("/dev/zero", root.appendingPathComponent(name).path) } != nil)
        #expect(try ignoreFileError { root in symlink("missing", root.appendingPathComponent(name).path) } != nil)
        // A FIFO is refused without blocking.
        #if !os(Windows)
        #expect(try ignoreFileError { root in mkfifo(root.appendingPathComponent(name).path, 0o644) } != nil)
        #endif
        // A folder.
        #expect(try ignoreFileError { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        } != nil)
        // Too big, too many patterns, a bad line, not UTF-8.
        let big = try ignoreFileError { root in
            try Data(repeating: UInt8(ascii: "#"), count: ExcludeList.maxIgnoreFileBytes + 1).write(to: root.appendingPathComponent(name))
        }
        #expect(big?.contains("larger than 1 MB") == true)
        let many = try ignoreFileError { root in
            let text = (0...ExcludeList.maxIgnoreFilePatterns).map { "file\($0)" }.joined(separator: "\n")
            try write(text, to: root.appendingPathComponent(name))
        }
        #expect(many?.contains("more than 1000 patterns") == true)
        let bad = try ignoreFileError { root in try write(".env\n[[:nope:]]\n", to: root.appendingPathComponent(name)) }
        #expect(bad?.contains("line 2") == true)
        #expect(try ignoreFileError { root in try Data([0xff, 0xfe, 0x00]).write(to: root.appendingPathComponent(name)) } != nil)
        // Exactly at the limit is fine.
        #expect(try ignoreFileError { root in
            try write((1...ExcludeList.maxIgnoreFilePatterns).map { "f\($0)" }.joined(separator: "\n"), to: root.appendingPathComponent(name))
        } == nil)
    }

    @Test("a session isn't created when .mudroomignore can't be used", .enabled(if: !isWindows))
    func sessionRefusesBadIgnoreFile() throws {
        let tmp = try TempDir()
        let project = tmp.path("project")
        try write("a\n", to: project.appendingPathComponent("a.txt"))
        symlink("/dev/zero", project.appendingPathComponent(ExcludeList.ignoreFileName).path)
        let store = SessionStore(root: tmp.path("store"))
        #expect(throws: MudroomError.self) { try store.create(project: project, command: ["true"], image: "test") }
        #expect(try store.list().isEmpty)
        #expect(store.brokenSessions().isEmpty)
    }

    @Test("an exclude list passed to create wins over the saved project config")
    func explicitListWins() throws {
        let f = try Fixture(exclude: ExcludeList(patterns: ["notes.txt"])) { root in
            try write("S=1\n", to: root.appendingPathComponent(".env"))
            try write("n\n", to: root.appendingPathComponent("notes.txt"))
        }
        // The saved config still has the defaults (.env); the session used what it was given.
        #expect(try ProjectConfigStore(store: f.store).load(f.project.path).excludePatterns == ExcludeList.defaults)
        #expect(exists(f.work.appendingPathComponent(".env")))
        #expect(!exists(f.work.appendingPathComponent("notes.txt")))
    }

    func git(_ args: [String], in dir: URL) throws {
        let out = try ProcessRunner.capture(ProcessRunner.which("git")!, ["-c", "user.name=t", "-c", "user.email=t@example.com",
                                                                          "-c", "commit.gpgsign=false"] + args, cwd: dir)
        #expect(out.status == 0, "\(args): \(out.stderr)")
    }

    @Test("excluded files that git tracks are recorded for a warning", .enabled(if: ProcessRunner.which("git") != nil && !isWindows))
    func trackedByGit() throws {
        let f = try Fixture(exclude: ExcludeList(patterns: [".env", "secrets/", "local.key"])) { root in
            try write("S=1\n", to: root.appendingPathComponent(".env"))
            try write("k\n", to: root.appendingPathComponent("secrets/a.txt"))
            try write("x\n", to: root.appendingPathComponent("app.txt"))
            try self.git(["init", "-q"], in: root)
            try self.git(["add", ".env", "secrets/a.txt", "app.txt"], in: root)
            try self.git(["commit", "-q", "-m", "init"], in: root)
            // Not tracked: excluded, but no warning needed.
            try write("k\n", to: root.appendingPathComponent("local.key"))
        }
        #expect(f.handle.session.excludedTracked == [".env", "secrets/"])
        #expect(Set(f.handle.session.excluded?.map(\.path) ?? []) == [".env", "local.key", "secrets/"])
        // No git repository: nothing to warn about.
        let plain = try Fixture(exclude: ExcludeList(patterns: [".env"])) { root in
            try write("S=1\n", to: root.appendingPathComponent(".env"))
        }
        #expect(plain.handle.session.excludedTracked == nil)
        #expect(ExcludedEntry.trackedByGit(plain.handle.session.excluded ?? [], project: plain.project, git: nil).isEmpty)
    }

    #if canImport(Darwin)
    @Test("a locked (uchg) excluded file is still removed from an APFS clone", .enabled(if: !isRoot))
    func lockedFile() throws {
        var project: URL?
        defer {
            if let project {
                chflags(project.appendingPathComponent("locked").path, 0)
                chflags(project.appendingPathComponent("locked/.env").path, 0)
            }
        }
        let f = try Fixture(exclude: ExcludeList(patterns: [".env"])) { root in
            project = root
            try write("S=1\n", to: root.appendingPathComponent("locked/.env"))
            try write("ok\n", to: root.appendingPathComponent("locked/ok.txt"))
            #expect(chflags(root.appendingPathComponent("locked/.env").path, UInt32(UF_IMMUTABLE)) == 0)
        }
        defer {
            for tree in [f.handle.base, f.handle.work] { chflags(tree.appendingPathComponent("locked/ok.txt").path, 0) }
        }
        #expect(f.handle.session.cloneMethod == .clonefile)
        for tree in [f.handle.base, f.handle.work] {
            #expect(!exists(tree.appendingPathComponent("locked/.env")))
            #expect(exists(tree.appendingPathComponent("locked/ok.txt")))
        }
        // removeEntry also clears a lock on the parent folder, and puts it back.
        let tmp = try TempDir()
        let dir = tmp.path("d")
        try write("x\n", to: dir.appendingPathComponent("f"))
        #expect(chflags(dir.appendingPathComponent("f").path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(chflags(dir.path, UInt32(UF_IMMUTABLE)) == 0)
        try ExcludeWalk.removeEntry(dir.appendingPathComponent("f").path)
        #expect(!exists(dir.appendingPathComponent("f")))
        var st = stat()
        lstat(dir.path, &st)
        #expect(st.st_flags & UInt32(UF_IMMUTABLE) != 0)
        chflags(dir.path, 0)
    }
    #endif

    @Test("deleting a folder that holds an excluded project file: the folder is a conflict, the file stays")
    func deletedFolderWithExcludedFile() throws {
        let f = try Fixture(exclude: ExcludeList(patterns: [".env"])) { root in
            try write("S=1\n", to: root.appendingPathComponent("src/.env"))
            try write("code\n", to: root.appendingPathComponent("src/app.py"))
            try write("a\n", to: root.appendingPathComponent("other.txt"))
        }
        try FileManager.default.removeItem(at: f.work.appendingPathComponent("src"))
        try write("b\n", to: f.work.appendingPathComponent("other.txt"))
        let report = try Applier(handle: f.handle).apply(paths: nil)
        #expect(report.applied.contains("src/app.py"))
        #expect(report.applied.contains("other.txt"))
        #expect(report.conflicts.map(\.path) == ["src"])
        #expect(try read(f.project.appendingPathComponent("src/.env")) == "S=1\n")
        #expect(!exists(f.project.appendingPathComponent("src/app.py")))
    }

    @Test("a session still being created isn't listed as broken and can't be discarded")
    func creationLock() throws {
        let tmp = try TempDir()
        let store = SessionStore(root: tmp.path("store"))
        let dir = store.sessionsDirectory.appendingPathComponent("20261030-000000-abcd", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = try #require(FileLock.tryAcquire(dir.appendingPathComponent(SessionStore.creatingLockName)))
        #expect(store.brokenSessions().isEmpty)
        #expect(throws: MudroomError.self) { try store.discardBroken(dir.lastPathComponent) }
        #expect(exists(dir))
        lock.release()
        #expect(store.brokenSessions().map(\.lastPathComponent) == [dir.lastPathComponent])
        try store.discardBroken(dir.lastPathComponent)
        #expect(!exists(dir))
        // A finished session keeps no creation lock behind.
        let f = try Fixture { root in try write("a\n", to: root.appendingPathComponent("a.txt")) }
        #expect(!exists(f.handle.directory.appendingPathComponent(SessionStore.creatingLockName)))
        #expect(!exists(f.handle.runnerLockURL))
    }
}
