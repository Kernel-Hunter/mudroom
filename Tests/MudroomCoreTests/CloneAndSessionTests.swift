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

@Suite("Clone and sessions")
struct CloneAndSessionTests {
    func populate(_ root: URL) throws {
        try write("hello\n", to: root.appendingPathComponent("README.md"))
        try write("#!/bin/sh\necho hi\n", to: root.appendingPathComponent("bin/run.sh"), mode: 0o755)
        try write("deep\n", to: root.appendingPathComponent("a/b/c/deep.txt"))
        symlink("README.md", root.appendingPathComponent("link").path)
    }

    @Test("cloning produces identical, independent base and work trees")
    func cloneTree() throws {
        let f = try Fixture(populate: populate)
        #if os(macOS)
        // The temp dir is on APFS.
        #expect(f.handle.session.cloneMethod == .clonefile)
        #else
        // A reflink on btrfs/XFS, a plain copy on ext4 or overlayfs.
        #expect(f.handle.session.cloneMethod != .clonefile)
        #endif
        let original = try TreeSnapshot.scan(f.project).nodes
        #expect(try TreeSnapshot.scan(f.handle.base).nodes == original)
        #expect(try TreeSnapshot.scan(f.work).nodes == original)
        #expect(original["link"] == .symlink(target: "README.md"))
        #expect(original["bin/run.sh"]?.mode == expectedMode(0o755))

        try write("changed\n", to: f.work.appendingPathComponent("README.md"))
        #expect(try read(f.project.appendingPathComponent("README.md")) == "hello\n")
        #expect(try read(f.handle.base.appendingPathComponent("README.md")) == "hello\n")
    }

    @Test("copy fallback keeps symlinks and modes")
    func copyFallback() throws {
        let f = try Fixture(clone: false, populate: populate)
        #expect(f.handle.session.cloneMethod == .copy)
        #expect(try TreeSnapshot.scan(f.work).nodes == TreeSnapshot.scan(f.project).nodes)
    }

    @Test("session.json records id, project, ISO8601 date, command, image, status")
    func sessionMetadata() throws {
        let f = try Fixture(populate: populate)
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: f.handle.directory.appendingPathComponent("session.json"))) as? [String: Any]
        #expect(json?["id"] as? String == f.handle.session.id)
        #expect(json?["projectPath"] as? String == f.project.path)
        #expect(json?["command"] as? [String] == ["true"])
        #expect(json?["image"] as? String == "test")
        #expect(json?["status"] as? String == "created")
        let created = try #require(json?["created"] as? String)
        #expect(ISO8601DateFormatter().date(from: created) != nil)
    }

    @Test("open by id, prefix and 'last'; discard leaves the project alone")
    func openAndDiscard() throws {
        let f = try Fixture(populate: populate)
        let id = f.handle.session.id
        #expect(try f.store.open(id).session.projectPath == f.handle.session.projectPath)
        #expect(try f.store.open(String(id.prefix(10))).session.id == id)
        #expect(try f.store.open("last").session.id == id)
        #expect(throws: MudroomError.sessionNotFound("nope")) { try f.store.open("nope") }

        try f.store.discard(f.handle)
        #expect(!exists(f.handle.directory))
        #expect(try read(f.project.appendingPathComponent("README.md")) == "hello\n")
        #expect(try f.store.list().isEmpty)
    }

    @Test("refuses to create a store inside the project")
    func storeInsideProject() throws {
        let tmp = try TempDir()
        let project = tmp.path("p")
        try write("x", to: project.appendingPathComponent("x"))
        let store = SessionStore(root: project.appendingPathComponent(".mudroom"))
        #expect(throws: MudroomError.self) {
            try store.create(project: project, command: [], image: "i")
        }
    }

    @Test("refuses /, the home folder, folders inside the store and unreadable folders")
    func projectProblems() throws {
        let tmp = try TempDir()
        let store = SessionStore(root: tmp.path("store"))
        let home = tmp.path("home")
        try write("x", to: home.appendingPathComponent("code/app/x"))
        try write("x", to: tmp.path("store/sessions/1/work/x"))
        #expect(store.projectProblem(URL(fileURLWithPath: "/"), home: home) != nil)
        #expect(store.projectProblem(home, home: home) != nil)
        #expect(store.projectProblem(tmp.path("store/sessions/1/work"), home: home) != nil)
        #expect(store.projectProblem(tmp.url, home: home) != nil)
        #expect(store.projectProblem(home.appendingPathComponent("code/app"), home: home) == nil)
        // A path with spaces, quotes, $ and non-ASCII is just a folder.
        let odd = tmp.path("iCloud Drive/it's $HOME — café")
        try write("x", to: odd.appendingPathComponent("x"))
        #expect(store.projectProblem(odd, home: home) == nil)

        let locked = tmp.path("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0)
        defer { chmod(locked.path, 0o755) }
        // Windows has no mode bits to lock a folder with.
        if !isRoot && !isWindows { #expect(store.projectProblem(locked, home: home) != nil) }
    }

    @Test("errors read as sentences, not Foundation dumps")
    func errorMessages() throws {
        #expect(MudroomError.message(MudroomError.invalid("no")) == "no")
        let tmp = try TempDir()
        do {
            _ = try Data(contentsOf: tmp.path("missing.txt"))
            Issue.record("read a missing file")
        } catch {
            let text = MudroomError.message(error)
            #expect(!text.contains("Error Domain"))
            #expect(!text.contains("UserInfo"))
            #expect(text.contains("missing.txt"))
        }
    }

    @Test("rejects a project path that is not a directory")
    func notADirectory() throws {
        let tmp = try TempDir()
        try write("x", to: tmp.path("file"))
        let store = SessionStore(root: tmp.path("store"))
        #expect(throws: MudroomError.notADirectory(tmp.path("file").path)) {
            try store.create(project: tmp.path("file"), command: [], image: "i")
        }
    }
}
