#if canImport(WinSDK)
import WinSDK
#endif
import Foundation
import Testing
@testable import MudroomCore

/// The Windows port's plain string code: how host paths reach Docker and
/// how a command line is built. These run on every platform.
@Suite("Windows paths and command lines")
struct WindowsStringTests {
    let windows = DockerBackend.Host(isLinux: false, uid: 1000, gid: 1000, rootlessPodman: false, isWindows: true)
    let mac = DockerBackend.Host(isLinux: false, uid: 501, gid: 20, rootlessPodman: false)

    @Test("bind mount sources are Windows paths on a Windows host, untouched elsewhere")
    func mountSource() {
        #expect(DockerBackend.mountSource("C:/Users/me/AppData/Local/Mudroom/sessions/s1/work", host: windows)
                == #"C:\Users\me\AppData\Local\Mudroom\sessions\s1\work"#)
        #expect(DockerBackend.mountSource("/C:/Users/me/work", host: windows) == #"C:\Users\me\work"#)
        #expect(DockerBackend.mountSource(#"D:\src\app"#, host: windows) == #"D:\src\app"#)
        #expect(DockerBackend.mountSource("/home/me/work", host: mac) == "/home/me/work")
    }

    @Test("docker run gets the Windows path of work/ and of every mount")
    func runArguments() {
        let spec = SandboxSpec(name: "mudroom-s1", image: "mudroom/agent-base:latest",
                               workspace: URL(fileURLWithPath: "/C:/Users/me/AppData/Local/Mudroom/sessions/s1/work"),
                               command: ["claude"], environmentNames: [], interactive: true, tty: true,
                               mounts: [SandboxMount(source: URL(fileURLWithPath: "/C:/Users/me/AppData/Local/Mudroom/agents/claude/home"),
                                                     target: "/home/node/.claude")],
                               environment: [:], network: nil)
        let args = DockerBackend.runArguments(for: spec, host: windows)
        let mounts = args.indices.filter { args[$0] == "--mount" }.map { args[$0 + 1] }
        #expect(mounts.count == 2)
        #expect(mounts.allSatisfy { $0.contains(#"source=C:\Users\me\AppData\Local\Mudroom\"#) && !$0.contains("/C:") })
        #expect(mounts[0].hasSuffix("target=/workspace"))
        // Docker Desktop maps ownership on shared folders itself.
        #expect(!args.contains("--user"))
    }

    @Test("arguments are quoted the way the Microsoft C runtime splits them")
    func quote() {
        #expect(WindowsCommandLine.quote("plain") == "plain")
        #expect(WindowsCommandLine.quote(#"C:\no\spaces"#) == #"C:\no\spaces"#)
        #expect(WindowsCommandLine.quote("") == #""""#)
        #expect(WindowsCommandLine.quote("two words") == #""two words""#)
        #expect(WindowsCommandLine.quote(#"say "hi""#) == #""say \"hi\"""#)
        // Backslashes are only special before a quote.
        #expect(WindowsCommandLine.quote(#"C:\Program Files\"#) == #""C:\Program Files\\""#)
        #expect(WindowsCommandLine.quote(#"a\"b c"#) == #""a\\\"b c""#)
        #expect(WindowsCommandLine.quote("tab\there") == "\"tab\there\"")
        #expect(WindowsCommandLine.join(["docker", "run", "--env", "A=b c"]) == #"docker run --env "A=b c""#)
    }

    @Test("the environment block is sorted without regard to case and ends in two NULs")
    func environmentBlock() {
        let block = WindowsCommandLine.environmentBlock(["b": "2", "A": "1", "Path": #"C:\bin"#])
        #expect(String(decoding: block, as: UTF16.self) == "A=1\u{0}b=2\u{0}Path=C:\\bin\u{0}\u{0}")
        #expect(WindowsCommandLine.environmentBlock([:]) == [0, 0])
    }

    @Test("a whole drive is refused as a project folder")
    func driveRoot() {
        for p in ["C:", "C:/", #"C:\"#, "/C:/", "d:/"] { #expect(SessionStore.isDriveRoot(p), "\(p)") }
        for p in ["/", "C:/src", "/home", "CC:/", "1:/"] { #expect(!SessionStore.isDriveRoot(p), "\(p)") }
    }

    @Test("a file converted to CRLF is a modification, and apply writes it byte for byte")
    func crlfConversion() throws {
        let lf = (1...20).map { "line \($0)\n" }.joined()
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let f = try Fixture { root in try write(lf, to: root.appendingPathComponent("notes.txt")) }
        try write(crlf.replacingOccurrences(of: "line 10\r\n", with: "line ten\r\n"), to: f.work.appendingPathComponent("notes.txt"))
        let diff = try f.diff()
        #expect(diff.changes.map(\.path) == ["notes.txt"])
        #expect(diff.changes.first?.kind == .modified)
        let out = try DiffRenderer(base: f.handle.base, work: f.work).full(diff)
        #expect(out.contains("line ten"))
        let report = try Applier(handle: f.handle).apply(paths: nil)
        #expect(report.applied == ["notes.txt"])
        #expect(try Data(contentsOf: f.project.appendingPathComponent("notes.txt"))
                == Data(crlf.replacingOccurrences(of: "line 10\r\n", with: "line ten\r\n").utf8))
        _ = try Applier(handle: f.handle).undo()
        #expect(try read(f.project.appendingPathComponent("notes.txt")) == lf)
    }
}

#if os(Windows)
/// Windows behaviour the POSIX tests can't cover: no mode bits, read-only
/// files, long paths, junctions, Credential Manager and CreateProcessW.
@Suite("Windows file system and processes")
struct WindowsTests {
    @Test("modes are fixed: files read as 0644, folders as 0755, and chmod changes nothing")
    func fixedModes() throws {
        let f = try Fixture { root in try write("#!/bin/sh\n", to: root.appendingPathComponent("bin/run.sh")) }
        #expect(try FileNode.read(at: f.work.appendingPathComponent("bin/run.sh")) ==
                .file(mode: 0o644, size: 10, sha256: SafeFS.sha256(Data("#!/bin/sh\n".utf8))))
        #expect(try FileNode.read(at: f.work.appendingPathComponent("bin")) == .directory(mode: 0o755))
        chmod(f.work.appendingPathComponent("bin/run.sh").path, 0o755)
        #expect(try f.diff().changes.isEmpty)
    }

    @Test("a read-only project file is replaced on apply and restored on undo")
    func readOnlyTarget() throws {
        let f = try Fixture { root in try write("old\n", to: root.appendingPathComponent("locked.txt")) }
        let target = f.project.appendingPathComponent("locked.txt")
        #expect(setReadOnly(target.path))
        try write("new\n", to: f.work.appendingPathComponent("locked.txt"))
        let report = try Applier(handle: f.handle).apply(paths: nil)
        #expect(report.applied == ["locked.txt"])
        #expect(report.conflicts.isEmpty && report.skipped.isEmpty)
        #expect(try read(target) == "new\n")
        _ = try Applier(handle: f.handle).undo()
        #expect(try read(target) == "old\n")
    }

    @Test("rename replaces an existing file, as it does on POSIX")
    func renameReplaces() throws {
        let tmp = try TempDir()
        try write("a\n", to: tmp.path("a"))
        try write("b\n", to: tmp.path("b"))
        #expect(rename(tmp.path("a").path, tmp.path("b").path) == 0)
        #expect(try read(tmp.path("b")) == "a\n")
        #expect(!exists(tmp.path("a")))
    }

    @Test("paths longer than MAX_PATH diff and apply")
    func longPaths() throws {
        let f = try Fixture { root in try write("x\n", to: root.appendingPathComponent("keep.txt")) }
        let deep = (1...12).map { "folder-with-a-long-name-\($0)" }.joined(separator: "/") + "/file.txt"
        #expect(f.work.appendingPathComponent(deep).path.utf16.count > 300)
        try write("deep\n", to: f.work.appendingPathComponent(deep))
        let diff = try f.diff()
        #expect(diff.changes.contains { $0.path == deep && $0.kind == .added })
        let report = try Applier(handle: f.handle).apply(paths: nil)
        #expect(report.applied.contains(deep))
        #expect(try read(f.project.appendingPathComponent(deep)) == "deep\n")
    }

    @Test("a junction the agent makes is reported, never followed or applied")
    func junction() throws {
        let tmp = try TempDir()
        try write("secret\n", to: tmp.path("outside/secret.txt"))
        let f = try Fixture { root in try write("x\n", to: root.appendingPathComponent("keep.txt")) }
        let cmd = try #require(ProcessRunner.which("cmd"))
        let made = try ProcessRunner.capture(cmd, ["/c", "mklink", "/J", Win32.path(f.work.appendingPathComponent("j").path),
                                                   Win32.path(tmp.path("outside").path)])
        try #require(made.status == 0, "mklink /J: \(made.stdout) \(made.stderr)")
        #expect(try FileNode.read(at: f.work.appendingPathComponent("j")) == .special)
        let diff = try f.diff()
        #expect(diff.changes.map(\.path) == ["j"])
        #expect(throws: (any Error).self) { try SafeFS.readBeneath(f.work, "j/secret.txt") }
        _ = try Applier(handle: f.handle).apply(paths: nil)
        #expect(!exists(f.project.appendingPathComponent("j/secret.txt")))
        #expect(try read(tmp.path("outside/secret.txt")) == "secret\n")
    }

    @Test("on ReFS the session clones are block clones that read back byte for byte",
          .enabled(if: !(ProcessInfo.processInfo.environment["MUDROOM_TEST_REFS"] ?? "").isEmpty,
                   "set MUDROOM_TEST_REFS to a folder or drive (E:) on a ReFS volume, such as a Dev Drive"))
    func refsBlockClone() throws {
        var path = ProcessInfo.processInfo.environment["MUDROOM_TEST_REFS"]!
        if path.hasSuffix(":") { path += "\\" }
        let refs = URL(fileURLWithPath: path, isDirectory: true)
        let root = refs.appendingPathComponent("mudroom-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        // Sizes that aren't a multiple of the cluster size, an empty file,
        // and one bigger than a single clone request.
        var files: [String: Data] = ["empty.txt": Data(), "small.txt": Data("hello\r\n".utf8)]
        files["src/big.bin"] = Data((0..<1_234_567).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) })
        files["src/huge.bin"] = Data(repeating: 0x5A, count: 5 * 1024 * 1024 + 3)
        for (rel, data) in files {
            let url = project.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try #require(WinFS.supportsBlockClone(project.path), "\(refs.path) is not on a volume with block cloning")

        let store = SessionStore(root: root.appendingPathComponent("store"))
        let handle = try store.create(project: project, command: ["true"], image: "test")
        #expect(handle.session.cloneMethod == .blockClone)
        for (rel, data) in files {
            #expect(try Data(contentsOf: handle.work.appendingPathComponent(rel)) == data, "\(rel)")
            #expect(try Data(contentsOf: handle.base.appendingPathComponent(rel)) == data, "\(rel)")
        }
        #expect(try Differ.compare(base: handle.base, work: handle.work).changes.isEmpty)

        // Writing to a clone leaves the project and the other clone alone.
        let fh = try FileHandle(forWritingTo: handle.work.appendingPathComponent("src/big.bin"))
        try fh.seek(toOffset: 100_000)
        try fh.write(contentsOf: Data(repeating: 0xFF, count: 10))
        try fh.close()
        #expect(try Data(contentsOf: project.appendingPathComponent("src/big.bin")) == files["src/big.bin"])
        #expect(try Data(contentsOf: handle.base.appendingPathComponent("src/big.bin")) == files["src/big.bin"])
        #expect(try Differ.compare(base: handle.base, work: handle.work).changes.map(\.path) == ["src/big.bin"])
    }

    @Test("tokens round-trip through Windows Credential Manager")
    func credentialManager() throws {
        let store = CredentialTokenStore()
        let agent = "test-\(UUID().uuidString.prefix(8))"
        do {
            try store.write(agent, "sk-ant-oat01-WINDOWSTEST")
        } catch {
            // CI services without a logon session have no credential vault.
            withKnownIssue("Credential Manager unavailable here: \(error)") { throw error }
            return
        }
        defer { _ = try? store.delete(agent) }
        #expect(try store.read(agent) == "sk-ant-oat01-WINDOWSTEST")
        #expect(store.contains(agent))
        #expect(try store.accounts().contains(agent))
        try store.write(agent, "sk-ant-oat01-REPLACED")
        #expect(try store.read(agent) == "sk-ant-oat01-REPLACED")
        #expect(try store.delete(agent))
        #expect(try store.read(agent) == nil)
        #expect(try !store.delete(agent))
    }

    @Test("which finds .exe files on PATH")
    func which() throws {
        let cmd = try #require(ProcessRunner.which("cmd"))
        #expect(cmd.lowercased().hasSuffix("cmd.exe"))
        #expect(ProcessRunner.which("no-such-program-\(UUID().uuidString)") == nil)
    }

    @Test("runAttached runs a program and returns its exit code")
    func runAttached() throws {
        let cmd = try #require(ProcessRunner.which("cmd"))
        #expect(try ProcessRunner.runAttached(cmd, ["/c", "exit 3"]) == 3)
        // The quoted argument and the added variable both reach the child.
        #expect(try ProcessRunner.runAttached(cmd, ["/c", "exit %MUDROOM_TEST_CODE%"],
                                              environment: ["MUDROOM_TEST_CODE": "7"]) == 7)
    }

    @Test("Win32 paths use backslashes and the long-path prefix when needed")
    func win32Path() {
        #expect(Win32.path("C:/Users/me") == #"C:\Users\me"#)
        #expect(Win32.path("/C:/Users/me") == #"C:\Users\me"#)
        let long = "C:/" + String(repeating: "a/", count: 130)
        #expect(Win32.path(long).hasPrefix(#"\\?\C:\"#))
    }

    func setReadOnly(_ path: String) -> Bool {
        Win32.withPath(path) { SetFileAttributesW($0, DWORD(FILE_ATTRIBUTE_READONLY)) }
    }
}
#endif
