#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import Testing
@testable import MudroomCore

@Suite("Diff classification and rendering")
struct DiffTests {
    func populate(_ root: URL) throws {
        try write("one\ntwo\nthree\n", to: root.appendingPathComponent("edit.txt"))
        try write("bye\n", to: root.appendingPathComponent("old.txt"))
        try write("same\n", to: root.appendingPathComponent("script.sh"), mode: 0o644)
        try write("keep\n", to: root.appendingPathComponent("keep.txt"))
        try write("file\n", to: root.appendingPathComponent("becomes-link"))
        try write("x\n", to: root.appendingPathComponent("gone/inner.txt"))
        symlink("keep.txt", root.appendingPathComponent("ptr").path)
        try write("ref: refs/heads/main\n", to: root.appendingPathComponent(".git/HEAD"))
    }

    func agentEdits(_ w: URL) throws {
        try write("one\n2\nthree\n", to: w.appendingPathComponent("edit.txt"))
        unlink(w.appendingPathComponent("old.txt").path)
        chmod(w.appendingPathComponent("script.sh").path, 0o755)
        try write("new\n", to: w.appendingPathComponent("new.txt"))
        unlink(w.appendingPathComponent("becomes-link").path)
        symlink("keep.txt", w.appendingPathComponent("becomes-link").path)
        unlink(w.appendingPathComponent("ptr").path)
        symlink("new.txt", w.appendingPathComponent("ptr").path)
        unlink(w.appendingPathComponent("gone/inner.txt").path)
        rmdir(w.appendingPathComponent("gone").path)
        try write("ref: refs/heads/agent\n", to: w.appendingPathComponent(".git/HEAD"))
    }

    @Test("classifies every kind of change")
    func classification() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        let result = try f.diff()
        let kinds = Dictionary(uniqueKeysWithValues: result.changes.map { ($0.path, $0.kind) })
        #expect(kinds == [
            "edit.txt": .modified,
            "old.txt": .deleted,
            "script.sh": .modeChanged,
            "new.txt": .added,
            "becomes-link": .typeChanged,
            "ptr": .symlinkChanged,
            "gone": .deleted,
            "gone/inner.txt": .deleted,
        ])
        #expect(kinds["keep.txt"] == nil)
        #expect(result.gitMetadataChanges.map(\.path) == [".git/HEAD"])
    }

    @Test("no changes means an empty result")
    func noChanges() throws {
        let f = try Fixture(populate: populate)
        #expect(try f.diff().isEmpty)
    }

    @Test("content change is caught even when size and mtime are restored")
    func sneakyEdit() throws {
        let f = try Fixture(populate: populate)
        let url = f.work.appendingPathComponent("keep.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        try write("KEEP\n", to: url)
        try FileManager.default.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: url.path)
        #expect(try f.diff().changes.map(\.path) == ["keep.txt"])
    }

    @Test("classify() pairs")
    func classifyPairs() {
        let a = FileNode.file(mode: 0o644, size: 1, sha256: "a")
        #expect(Differ.classify(before: a, after: a) == nil)
        #expect(Differ.classify(before: .absent, after: a) == .added)
        #expect(Differ.classify(before: a, after: .absent) == .deleted)
        #expect(Differ.classify(before: a, after: .file(mode: 0o644, size: 1, sha256: "b")) == .modified)
        #expect(Differ.classify(before: a, after: .file(mode: 0o755, size: 1, sha256: "b")) == .modified)
        #expect(Differ.classify(before: a, after: .file(mode: 0o755, size: 1, sha256: "a")) == .modeChanged)
        #expect(Differ.classify(before: .directory(mode: 0o755), after: .directory(mode: 0o700)) == .modeChanged)
        #expect(Differ.classify(before: .symlink(target: "x"), after: .symlink(target: "y")) == .symlinkChanged)
        #expect(Differ.classify(before: .directory(mode: 0o755), after: a) == .typeChanged)
    }

    @Test("unified diff for text uses project-relative headers")
    func unifiedText() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        let out = try DiffRenderer(base: f.handle.base, work: f.work).full(f.diff())
        #expect(out.contains("--- a/edit.txt\n+++ b/edit.txt"))
        #expect(out.contains("-two\n+2"))
        #expect(out.contains("--- /dev/null\n+++ b/new.txt"))
        #expect(out.contains("--- a/old.txt\n+++ /dev/null"))
        #expect(out.contains("P  script.sh  (mode 644 -> 755)"))
        #expect(out.contains("L  ptr  (keep.txt -> new.txt)"))
        #expect(out.contains("git metadata changed (1 entry under .git/"))
        #expect(!out.contains(f.handle.base.path))
        #expect(!out.contains(f.work.path))
    }

    @Test("binary files are summarised with sizes")
    func binary() throws {
        let f = try Fixture { root in
            try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("blob.bin"))
            try "text\n".write(to: root.appendingPathComponent("t.txt"), atomically: false, encoding: .utf8)
            chmod(root.appendingPathComponent("t.txt").path, 0o644)
        }
        try Data([0, 1, 2, 3, 4, 5, 6, 7]).write(to: f.work.appendingPathComponent("blob.bin"))
        let out = try DiffRenderer(base: f.handle.base, work: f.work).full(f.diff())
        #expect(out.contains("M  blob.bin"))
        #expect(out.contains("binary changed (size 4 bytes -> 8 bytes)"))

        try Data([0, 9]).write(to: f.work.appendingPathComponent("new.bin"))
        try "changed\n".write(to: f.work.appendingPathComponent("t.txt"), atomically: false, encoding: .utf8)
        chmod(f.work.appendingPathComponent("t.txt").path, 0o600)
        let added = try DiffRenderer(base: f.handle.base, work: f.work).full(f.diff())
        #expect(added.contains("binary added (2 bytes)"))
        #expect(added.contains("old mode 100644\nnew mode 100600"))
    }

    @Test("stat lists paths and a summary")
    func stat() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        let out = DiffRenderer(base: f.handle.base, work: f.work).stat(try f.diff())
        #expect(out.contains("A  new.txt"))
        #expect(out.contains("D  gone/"))
        #expect(out.contains("T  becomes-link  (file -> symlink)"))
        #expect(out.contains("1 added, 1 modified, 3 deleted, 1 mode-changed, 1 symlink-changed, 1 type-changed"))
    }
}
