import Foundation
import Testing
@testable import MudroomCore

@Suite("Snapshots")
struct SnapshotTests {
    @Test("nothing changed since base: no snapshot")
    func skipUnchanged() throws {
        let f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        let store = SnapshotStore(handle: f.handle)
        #expect(try store.take() == nil)
        #expect(store.list().isEmpty)
    }

    @Test("snapshots are numbered clones of work/, taken only when it changed")
    func takeAndSkip() throws {
        let f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        let store = SnapshotStore(handle: f.handle)
        try write("b\n", to: f.work.appendingPathComponent("a.txt"))
        let s1 = try #require(try store.take(now: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(s1.number == 1)
        #expect(s1.directory.lastPathComponent == "1-20270115-080000")
        #expect(try read(s1.directory.appendingPathComponent("a.txt")) == "b\n")
        #expect(try store.take() == nil)

        try write("new\n", to: f.work.appendingPathComponent("dir/n.txt"))
        let s2 = try #require(try store.take())
        #expect(s2.number == 2)
        // Snapshot 1 is a frozen copy: later edits in work/ don't reach it.
        try write("c\n", to: f.work.appendingPathComponent("a.txt"))
        #expect(try read(s1.directory.appendingPathComponent("a.txt")) == "b\n")
        #expect(store.list().map(\.number) == [1, 2])

        // Diffs between points in time.
        let d12 = try Differ.compare(base: store.url(for: .snapshot(1)), work: store.url(for: .snapshot(2)))
        #expect(d12.changes.map(\.path) == ["dir", "dir/n.txt"])
        let d2w = try Differ.compare(base: store.url(for: .snapshot(2)), work: store.url(for: .work))
        #expect(d2w.changes.map(\.path) == ["a.txt"])
        #expect(throws: MudroomError.self) { try store.url(for: .snapshot(9)) }
    }

    @Test("a mode-only change counts as a change", .disabled(if: isWindows, "no mode bits on Windows"))
    func modeChange() throws {
        let f = try Fixture { try write("#!/bin/sh\n", to: $0.appendingPathComponent("run.sh"), mode: 0o644) }
        chmod(f.work.appendingPathComponent("run.sh").path, 0o755)
        #expect(try SnapshotStore(handle: f.handle).take() != nil)
    }

    @Test("pruning keeps the newest snapshots and never reuses numbers")
    func prune() throws {
        let f = try Fixture { try write("0\n", to: $0.appendingPathComponent("n.txt")) }
        let store = SnapshotStore(handle: f.handle)
        for i in 1...5 {
            try write("\(i)\n", to: f.work.appendingPathComponent("n.txt"))
            try store.take(limit: 3)
        }
        #expect(store.list().map(\.number) == [3, 4, 5])
        try write("6\n", to: f.work.appendingPathComponent("n.txt"))
        #expect(try store.take(limit: 3)?.number == 6)
        #expect(store.list().map(\.number) == [4, 5, 6])
    }

    @Test("the snapshotter takes a final snapshot when stopped")
    func snapshotterFinish() throws {
        let f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        let s = Snapshotter(store: SnapshotStore(handle: f.handle), interval: 0, limit: 10)
        s.start()
        try write("b\n", to: f.work.appendingPathComponent("a.txt"))
        #expect(s.finish()?.number == 1)
    }

    @Test("discard removes snapshots with the clones")
    func discard() throws {
        let f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        try write("b\n", to: f.work.appendingPathComponent("a.txt"))
        try SnapshotStore(handle: f.handle).take()
        try f.store.discard(f.handle, keepRecord: true)
        #expect(!exists(f.handle.snapshotsRoot))
    }

    @Test("tree references parse")
    func refs() {
        #expect(TreeRef("base") == .base)
        #expect(TreeRef("work") == .work)
        #expect(TreeRef("3") == .snapshot(3))
        #expect(TreeRef("-1") == nil)
        #expect(TreeRef("x") == nil)
    }
}

/// Records specs instead of booting VMs.
final class FakeBackend: SandboxBackend, @unchecked Sendable {
    let name = "fake"
    var hostOnly: SandboxNetwork?
    var nat = SandboxNetwork(name: "default", hostOnly: false, gateway: "192.168.64.1", subnet: "192.168.64.0/24")
    var specs: [SandboxSpec] = []
    var onRun: ((SandboxSpec) -> Void)?

    init(hostOnly: Bool) {
        self.hostOnly = hostOnly
            ? SandboxNetwork(name: "mudroom-hostonly", hostOnly: true, gateway: "192.168.128.1", subnet: "192.168.128.0/24")
            : nil
    }

    func checkAvailable() throws {}
    func run(_ spec: SandboxSpec) throws -> Int32 {
        specs.append(spec)
        onRun?(spec)
        return 0
    }
    func capture(_ spec: SandboxSpec) throws -> CapturedOutput {
        specs.append(spec)
        return CapturedOutput(status: 0, stdout: "", stderr: "")
    }
    func buildImage(containerfile: URL, context: URL, tag: String) throws {}
    func hostOnlyNetwork() throws -> SandboxNetwork? { hostOnly }
    func defaultNetwork() throws -> SandboxNetwork? { nat }
}

@Suite("Network plan")
struct NetworkPlanTests {
    let list = Allowlist(strings: ["api.anthropic.com"])

    @Test("locked uses the host-only network and is enforced")
    func lockedEnforced() throws {
        let plan = try NetworkPlan.make(mode: .locked, allowlist: list, backend: FakeBackend(hostOnly: true))
        #expect(plan.record.enforcement == .enforced)
        #expect(plan.vmNetwork == "mudroom-hostonly")
        #expect(plan.proxyHost == "192.168.128.1")
        #expect(plan.clientSubnet == IPv4Subnet("192.168.128.0/24"))
    }

    @Test("locked without host-only networks falls back to advisory")
    func lockedAdvisory() throws {
        let plan = try NetworkPlan.make(mode: .locked, allowlist: list, backend: FakeBackend(hostOnly: false))
        #expect(plan.record.enforcement == .advisory)
        #expect(plan.vmNetwork == nil)
        #expect(plan.proxyHost == "192.168.64.1")
    }

    @Test("offline needs host-only; open needs nothing")
    func offlineOpen() throws {
        let off = try NetworkPlan.make(mode: .offline, allowlist: list, backend: FakeBackend(hostOnly: true))
        #expect(off.record.enforcement == .enforced && off.proxyHost == nil && off.vmNetwork == "mudroom-hostonly")
        #expect(throws: MudroomError.self) {
            try NetworkPlan.make(mode: .offline, allowlist: list, backend: FakeBackend(hostOnly: false))
        }
        let open = try NetworkPlan.make(mode: .open, allowlist: list, backend: FakeBackend(hostOnly: true))
        #expect(open.record.enforcement == NetworkEnforcement.none && open.vmNetwork == nil && open.proxyHost == nil)
    }

    @Test("a locked run sets proxy variables, mounts the agent config, records the network and snapshots on exit")
    func lockedRun() throws {
        var f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        f.handle.session.agent = "Claude Code"
        f.handle.session.command = ["claude"]
        let backend = FakeBackend(hostOnly: true)
        let work = f.work
        backend.onRun = { _ in try? write("edited\n", to: work.appendingPathComponent("a.txt")) }
        let runner = SessionRunner(backend: backend, store: f.store) { _ in }
        let result = try runner.run(&f.handle, options: RunOptions(tty: false, environmentNames: ["ANTHROPIC_API_KEY"]))

        let spec = try #require(backend.specs.first)
        #expect(spec.network == "mudroom-hostonly")
        let proxy = try #require(spec.environment["HTTPS_PROXY"])
        #expect(proxy.hasPrefix("http://192.168.128.1:"))
        #expect(spec.environment["NODE_USE_ENV_PROXY"] == "1")
        #expect(spec.environment["CLAUDE_CONFIG_DIR"] == "/home/node/.claude")
        #expect(spec.environmentNames == ["ANTHROPIC_API_KEY"])
        #expect(spec.environment.values.allSatisfy { !$0.contains("sk-") })
        // The session's own copy of the agent home, never the shared one.
        #expect(spec.mounts.first == SandboxMount(source: f.handle.agentHomeCopy, target: "/home/node/.claude"))
        let args = AppleContainerBackend.runArguments(for: spec)
        #expect(args.contains("--network") && args.contains("mudroom-hostonly"))

        #expect(result.network.enforcement == .enforced)
        #expect(result.finalSnapshot?.number == 1)
        var h = f.handle
        try h.reload()
        #expect(h.session.network?.mode == .locked)
        #expect(h.session.network?.allowlist.contains("api.anthropic.com") == true)
        #expect(h.session.network?.proxy == proxy)
        #expect(h.session.status == .finished)
    }

    @Test("an open run has no proxy variables and no network flag")
    func openRun() throws {
        var f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        try ProjectConfigStore(store: f.store).update(f.project.path) { $0.networkMode = .open }
        let backend = FakeBackend(hostOnly: true)
        _ = try SessionRunner(backend: backend, store: f.store) { _ in }.run(&f.handle, options: RunOptions(tty: false, environmentNames: []))
        let spec = try #require(backend.specs.first)
        #expect(spec.network == nil)
        #expect(spec.environment["HTTPS_PROXY"] == nil)
        #expect(spec.mounts.isEmpty) // custom command: no agent config dir
    }

    @Test("container network inspect output parses")
    func parseInspect() {
        let json = #"[{"configuration":{"mode":"hostOnly","name":"mudroom-hostonly"},"id":"mudroom-hostonly","status":{"ipv4Gateway":"192.168.128.1","ipv4Subnet":"192.168.128.0/24"}}]"#
        #expect(AppleContainerBackend.parseNetwork(Data(json.utf8)) ==
                SandboxNetwork(name: "mudroom-hostonly", hostOnly: true, gateway: "192.168.128.1", subnet: "192.168.128.0/24"))
        #expect(AppleContainerBackend.parseNetwork(Data("[]".utf8)) == nil)
    }
}
