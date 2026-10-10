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

@Suite("Apply, conflicts and undo")
struct ApplyTests {
    func populate(_ root: URL) throws {
        try write("one\ntwo\n", to: root.appendingPathComponent("edit.txt"))
        try write("bye\n", to: root.appendingPathComponent("old.txt"))
        try write("same\n", to: root.appendingPathComponent("script.sh"), mode: 0o644)
        try write("keep\n", to: root.appendingPathComponent("keep.txt"))
        try write("x\n", to: root.appendingPathComponent("gone/inner.txt"))
        try write("file\n", to: root.appendingPathComponent("typeswap"))
        symlink("keep.txt", root.appendingPathComponent("ptr").path)
        try write("ref: refs/heads/main\n", to: root.appendingPathComponent(".git/HEAD"))
    }

    func agentEdits(_ w: URL) throws {
        try write("one\n2\n", to: w.appendingPathComponent("edit.txt"))
        unlink(w.appendingPathComponent("old.txt").path)
        chmod(w.appendingPathComponent("script.sh").path, 0o755)
        try write("new\n", to: w.appendingPathComponent("new.txt"))
        try write("nested\n", to: w.appendingPathComponent("src/deep/file.swift"))
        unlink(w.appendingPathComponent("gone/inner.txt").path)
        rmdir(w.appendingPathComponent("gone").path)
        unlink(w.appendingPathComponent("typeswap").path)
        try write("now a dir\n", to: w.appendingPathComponent("typeswap/inside.txt"))
        unlink(w.appendingPathComponent("ptr").path)
        symlink("new.txt", w.appendingPathComponent("ptr").path)
        try write("ref: refs/heads/agent\n", to: w.appendingPathComponent(".git/HEAD"))
    }

    func snapshot(_ url: URL, includeGit: Bool = true) throws -> [String: FileNode] {
        try TreeSnapshot.scan(url).nodes.filter { includeGit || !Differ.isGitInternal($0.key) }
    }

    @Test("--all makes the project match work/, except .git")
    func applyAll() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        let report = try Applier(handle: f.handle).apply(paths: nil)
        #expect(report.conflicts.isEmpty)
        #expect(report.bundle != nil)
        #expect(try snapshot(f.project, includeGit: false) == snapshot(f.work, includeGit: false))
        #expect(try read(f.project.appendingPathComponent(".git/HEAD")) == "ref: refs/heads/main\n")
        #expect(try modeOf(f.project.appendingPathComponent("script.sh")) == expectedMode(0o755))
        #expect(try FileNode.read(at: f.project.appendingPathComponent("ptr")) == .symlink(target: "new.txt"))
        #expect(!exists(f.project.appendingPathComponent("gone")))
    }

    @Test("includeGit applies .git changes too")
    func applyGit() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        _ = try Applier(handle: f.handle).apply(paths: nil, includeGit: true)
        #expect(try snapshot(f.project) == snapshot(f.work))
    }

    @Test("selected paths only; missing parent directories are created")
    func applySelected() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        let report = try Applier(handle: f.handle).apply(paths: ["src/deep/file.swift", "./edit.txt", "nothing-here"])
        #expect(Set(report.applied) == ["src/deep/file.swift", "edit.txt"])
        #expect(report.skipped.map(\.path) == ["nothing-here"])
        #expect(try read(f.project.appendingPathComponent("src/deep/file.swift")) == "nested\n")
        #expect(exists(f.project.appendingPathComponent("old.txt")))
        #expect(!exists(f.project.appendingPathComponent("new.txt")))

        // Undo removes the file and the directories it had to create.
        _ = try Applier(handle: f.handle).undo()
        #expect(!exists(f.project.appendingPathComponent("src")))
        #expect(try read(f.project.appendingPathComponent("edit.txt")) == "one\ntwo\n")
    }

    @Test("a directory selection applies everything under it")
    func applyDirectory() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        let report = try Applier(handle: f.handle).apply(paths: ["src/"])
        #expect(Set(report.applied) == ["src", "src/deep", "src/deep/file.swift"])
    }

    @Test("a file edited in the project after the session started is a conflict and is left alone")
    func conflictModified() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        try write("human edit\n", to: f.project.appendingPathComponent("edit.txt"))
        let report = try Applier(handle: f.handle).apply(paths: nil)
        #expect(report.conflicts.map(\.path) == ["edit.txt"])
        #expect(report.conflicts[0].reason.contains("project changed since the session started"))
        #expect(try read(f.project.appendingPathComponent("edit.txt")) == "human edit\n")
        #expect(report.applied.contains("new.txt"))
    }

    @Test("a file the human created at the same path is a conflict")
    func conflictAdded() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        try write("mine\n", to: f.project.appendingPathComponent("new.txt"))
        let report = try Applier(handle: f.handle).apply(paths: ["new.txt"])
        #expect(report.conflicts.map(\.path) == ["new.txt"])
        #expect(try read(f.project.appendingPathComponent("new.txt")) == "mine\n")
    }

    @Test("a deleted directory that gained a file in the project is not removed")
    func conflictDirectoryDelete() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        try write("important\n", to: f.project.appendingPathComponent("gone/human.txt"))
        let report = try Applier(handle: f.handle).apply(paths: ["gone"])
        #expect(report.applied == ["gone/inner.txt"])
        #expect(report.conflicts.map(\.path) == ["gone"])
        #expect(try read(f.project.appendingPathComponent("gone/human.txt")) == "important\n")
    }

    @Test("identical content already in the project counts as applied, not a conflict")
    func alreadyApplied() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        try write("new\n", to: f.project.appendingPathComponent("new.txt"))
        let report = try Applier(handle: f.handle).apply(paths: ["new.txt"])
        #expect(report.alreadyApplied == ["new.txt"])
        #expect(report.conflicts.isEmpty)
        #expect(report.bundle == nil)
    }

    @Test("a second apply is a no-op")
    func applyTwice() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        _ = try Applier(handle: f.handle).apply(paths: nil)
        let second = try Applier(handle: f.handle).apply(paths: nil)
        #expect(second.applied.isEmpty)
        #expect(second.conflicts.isEmpty)
    }

    @Test("won't write through a symlinked directory in the project")
    func symlinkEscape() throws {
        let f = try Fixture(populate: populate)
        let outside = f.tmp.path("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write("nested\n", to: f.work.appendingPathComponent("src/deep/file.swift"))
        symlink(outside.path, f.project.appendingPathComponent("src").path)
        let report = try Applier(handle: f.handle).apply(paths: ["src/deep/file.swift"])
        #expect(report.conflicts.map(\.path) == ["src/deep/file.swift"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("undo restores the exact original tree")
    func undoAll() throws {
        let f = try Fixture(populate: populate)
        let original = try snapshot(f.project)
        try agentEdits(f.work)
        _ = try Applier(handle: f.handle).apply(paths: nil, includeGit: true)
        #expect(try snapshot(f.project) != original)
        let report = try Applier(handle: f.handle).undo()
        #expect(report.conflicts.isEmpty)
        #expect(try snapshot(f.project) == original)
        #expect(throws: MudroomError.nothingToUndo(f.handle.session.id)) {
            try Applier(handle: f.handle).undo()
        }
    }

    @Test("undo skips a path edited after the apply unless forced")
    func undoConflict() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        _ = try Applier(handle: f.handle).apply(paths: ["edit.txt", "new.txt"])
        try write("edited later\n", to: f.project.appendingPathComponent("edit.txt"))
        let report = try Applier(handle: f.handle).undo()
        #expect(report.conflicts.map(\.path) == ["edit.txt"])
        #expect(report.restored == ["new.txt"])
        #expect(try read(f.project.appendingPathComponent("edit.txt")) == "edited later\n")
        #expect(!exists(f.project.appendingPathComponent("new.txt")))
    }

    @Test("forced undo overwrites later edits")
    func undoForce() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        _ = try Applier(handle: f.handle).apply(paths: ["edit.txt"])
        try write("edited later\n", to: f.project.appendingPathComponent("edit.txt"))
        let report = try Applier(handle: f.handle).undo(force: true)
        #expect(report.conflicts.isEmpty)
        #expect(try read(f.project.appendingPathComponent("edit.txt")) == "one\ntwo\n")
    }

    @Test("a directory replaced by a file applies and undoes cleanly")
    func directoryToFile() throws {
        let f = try Fixture { root in
            try write("a\n", to: root.appendingPathComponent("thing/a.txt"))
            try write("b\n", to: root.appendingPathComponent("thing/sub/b.txt"))
        }
        let original = try snapshot(f.project)
        try FileManager.default.removeItem(at: f.work.appendingPathComponent("thing"))
        try write("flat\n", to: f.work.appendingPathComponent("thing"), mode: 0o600)
        #expect(try f.diff().changes.first { $0.path == "thing" }?.kind == .typeChanged)

        let report = try Applier(handle: f.handle).apply(paths: ["thing"])
        #expect(report.conflicts.isEmpty)
        #expect(try snapshot(f.project) == snapshot(f.work))
        _ = try Applier(handle: f.handle).undo()
        #expect(try snapshot(f.project) == original)
    }

    @Test("rollback bundle holds copies of overwritten files")
    func bundleContents() throws {
        let f = try Fixture(populate: populate)
        try agentEdits(f.work)
        let report = try Applier(handle: f.handle).apply(paths: nil)
        let bundle = try #require(report.bundle)
        #expect(try read(bundle.appendingPathComponent("files/edit.txt")) == "one\ntwo\n")
        #expect(try read(bundle.appendingPathComponent("files/old.txt")) == "bye\n")
        #expect(exists(bundle.appendingPathComponent("manifest.json")))
        #expect(bundle.path.hasPrefix(f.handle.directory.path))
    }

    @Test("undo records the mode the disk kept (FAT has no Unix modes)",
          .disabled(if: isWindows, "Windows has no Unix modes; FileNode reports fixed ones there"))
    func modeOnDisk() throws {
        let f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        let url = f.project.appendingPathComponent("a.txt")
        chmod(url.path, 0o700)
        let n = Applier.withModeOnDisk(.file(mode: 0o644, size: 2, sha256: "x"), at: url)
        #expect(n == .file(mode: 0o700, size: 2, sha256: "x"))
        #expect(Applier.withModeOnDisk(.file(mode: 0o700, size: 2, sha256: "x"), at: url) == n)
    }

    @Test("a file the agent changes after the diff is refused; the rest applies, and staged copies don't linger")
    func changedAfterDiff() throws {
        let f = try Fixture { try write("base\n", to: $0.appendingPathComponent("keep.txt")) }
        try write("new a\n", to: f.work.appendingPathComponent("a.txt"), mode: 0o755)
        try write("new b\n", to: f.work.appendingPathComponent("sub/b.txt"))
        let diff = try f.diff()
        try write("swapped\n", to: f.work.appendingPathComponent("sub/b.txt"))
        let report = try Applier(handle: f.handle).apply(paths: nil, diff: diff)
        #expect(report.applied == ["a.txt", "sub"])
        #expect(report.conflicts.map(\.path) == ["sub/b.txt"])
        #expect(report.conflicts.first?.reason.contains("review again") == true)
        #expect(try read(f.project.appendingPathComponent("a.txt")) == "new a\n")
        #expect(try modeOf(f.project.appendingPathComponent("a.txt")) == expectedMode(0o755))
        #expect(!exists(f.project.appendingPathComponent("sub/b.txt")))
        #expect(try read(f.work.appendingPathComponent("a.txt")) == "new a\n")
        let bundle = try #require(report.bundle)
        #expect(!exists(bundle.appendingPathComponent("staged")))
        _ = try Applier(handle: f.handle).undo()
        #expect(!exists(f.project.appendingPathComponent("a.txt")))
    }
}
