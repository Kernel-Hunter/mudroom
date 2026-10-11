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

@Suite("Network probe and repair")
struct NetworkProbeTests {
    func out(_ stdout: String, _ status: Int32 = 0, err: String = "") -> CapturedOutput {
        CapturedOutput(status: status, stdout: stdout, stderr: err)
    }

    @Test("probe output is classified; unreachable and timeouts need a repair")
    func classify() {
        let p = "192.168.128.1:5000"
        #expect(NetworkProbe.classify(out("MUDROOM_PROBE ok\n"), proxy: p) == .ok(proxy: p))
        let unreach = NetworkProbe.classify(out("noise\nMUDROOM_PROBE EHOSTUNREACH\n"), proxy: p)
        #expect(unreach == .unreachable(code: "EHOSTUNREACH", proxy: p) && unreach.needsRepair)
        #expect(NetworkProbe.classify(out("MUDROOM_PROBE timeout"), proxy: p).needsRepair)
        #expect(NetworkProbe.classify(out("MUDROOM_PROBE ENETUNREACH"), proxy: p).needsRepair)
        let refused = NetworkProbe.classify(out("MUDROOM_PROBE ECONNREFUSED"), proxy: p)
        #expect(refused == .refused(proxy: p) && !refused.needsRepair && !refused.isOK)
        let failed = NetworkProbe.classify(out("", 1, err: "Error: image not found"), proxy: p)
        #expect(failed == .failed("Error: image not found") && !failed.needsRepair)
        #expect(NetworkProbe.script(host: "192.168.128.1", port: 5000).contains(#"host: "192.168.128.1", port: 5000"#))
    }

    @Test("a passed probe is remembered for a short while only")
    func remembered() throws {
        let tmp = try TempDir()
        let store = SessionStore(root: tmp.url)
        let t = Date()
        #expect(!NetworkProbe.passedRecently(store: store, now: t))
        NetworkProbe.remember(.ok(proxy: "x"), store: store, now: t)
        #expect(NetworkProbe.passedRecently(store: store, within: 90, now: t.addingTimeInterval(60)))
        #expect(!NetworkProbe.passedRecently(store: store, within: 90, now: t.addingTimeInterval(120)))
        NetworkProbe.remember(.timeout(proxy: "x"), store: store, now: t)
        #expect(!NetworkProbe.passedRecently(store: store, now: t))
    }

    /// Records `container` calls and answers from a script.
    final class FakeContainer: @unchecked Sendable {
        var calls: [[String]] = []
        var list = "[]"
        var help = "USAGE: container system start [--enable-kernel-install] [--disable-kernel-install]"
        func run(_ args: [String]) throws -> CapturedOutput {
            calls.append(args)
            if args == ["list", "--format", "json"] { return CapturedOutput(status: 0, stdout: list, stderr: "") }
            if args == ["system", "start", "--help"] { return CapturedOutput(status: 0, stdout: help, stderr: "") }
            return CapturedOutput(status: 0, stdout: "", stderr: "")
        }
    }

    @Test("repair restarts the container system with the kernel installed without a prompt, then probes")
    func repairRestarts() throws {
        let fake = FakeContainer()
        var probes = 0
        var steps: [NetworkRepair.Step] = []
        let r = try NetworkRepair.repair(run: fake.run, progress: { steps.append($0) }, probe: {
            probes += 1
            return .ok(proxy: "p")
        })
        #expect(r.isOK && probes == 1)
        #expect(fake.calls.contains(["system", "stop"]))
        #expect(fake.calls.contains(["system", "start", "--enable-kernel-install"]))
        #expect(!fake.calls.contains { $0.first == "network" })
        #expect(steps == [.stopping, .starting, .checking])
    }

    @Test("if a restart isn't enough, Mudroom's VM network is recreated and probed again")
    func repairRecreatesNetwork() throws {
        let fake = FakeContainer()
        fake.help = "USAGE: container system start [--timeout <t>]"
        var results: [NetworkProbe.Result] = [.unreachable(code: "EHOSTUNREACH", proxy: "p"), .ok(proxy: "p")]
        let r = try NetworkRepair.repair(run: fake.run, probe: { results.removeFirst() })
        #expect(r.isOK)
        #expect(fake.calls.contains(["system", "start"]))
        #expect(fake.calls.contains(["network", "delete", "mudroom-hostonly"]))
    }

    @Test("repair refuses while Mudroom containers run, unless forced")
    func repairBusy() throws {
        let fake = FakeContainer()
        fake.list = #"[{"configuration":{"id":"mudroom-abc123"},"status":"running"},{"configuration":{"id":"buildkit"},"status":"running"},{"configuration":{"id":"mudroom-old"},"status":"stopped"}]"#
        #expect(NetworkRepair.running(fake.run) == ["mudroom-abc123"])
        #expect(throws: MudroomError.self) { try NetworkRepair.repair(run: fake.run, probe: { .ok(proxy: "p") }) }
        #expect(!fake.calls.contains(["system", "stop"]))
        _ = try NetworkRepair.repair(run: fake.run, force: true, probe: { .ok(proxy: "p") })
        #expect(fake.calls.contains(["system", "stop"]))
        #expect(NetworkRepair.runningMudroomContainers(Data("not json".utf8)).isEmpty)
    }

    /// A runtime whose `run` never returns, as a wedged container system does.
    struct HangingBackend: SandboxBackend {
        let name = "hanging"
        func checkAvailable() throws {}
        func run(_ spec: SandboxSpec) throws -> Int32 { 0 }
        func capture(_ spec: SandboxSpec) throws -> CapturedOutput {
            let sleep = sleepCommand(30)
            return try ProcessRunner.capture(sleep.0, sleep.1, timeout: spec.timeout)
        }
        func buildImage(containerfile: URL, context: URL, tag: String) throws {}
        func hostOnlyNetwork() throws -> SandboxNetwork? {
            SandboxNetwork(name: "n", hostOnly: true, gateway: "127.0.0.1", subnet: "127.0.0.0/8")
        }
        func defaultNetwork() throws -> SandboxNetwork? { nil }
    }

    @Test("a probe VM that never finishes gives up in time, and a restart is offered")
    func stuckRuntime() throws {
        let tmp = try TempDir()
        let start = Date()
        let r = NetworkProbe.run(backend: HangingBackend(), scratch: tmp.path("probe"), timeout: 2)
        #expect(Date().timeIntervalSince(start) < 15)
        #expect(r == .stuck(seconds: 2) && r.needsRepair && r.summary.contains("stuck"))
    }

    @Test("an unreachable network stops a session before it starts, with the repair hint")
    func errorText() {
        let e = MudroomError.networkUnreachable(NetworkProbe.Result.unreachable(code: "EHOSTUNREACH", proxy: "192.168.128.1:1").summary)
        #expect(e.description.contains("EHOSTUNREACH") && e.description.contains("mudroom setup --repair-network"))
    }
}
