import Darwin
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

    @Test("clonefile produces identical, independent base and work trees")
    func cloneTree() throws {
        let f = try Fixture(populate: populate)
        #expect(f.handle.session.cloneMethod == .clonefile)
        let original = try TreeSnapshot.scan(f.project).nodes
        #expect(try TreeSnapshot.scan(f.handle.base).nodes == original)
        #expect(try TreeSnapshot.scan(f.work).nodes == original)
        #expect(original["link"] == .symlink(target: "README.md"))
        #expect(original["bin/run.sh"]?.mode == 0o755)

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
