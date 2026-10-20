import Foundation
import Testing
@testable import MudroomCore

@Suite("Guest firewall")
struct GuestFirewallTests {
    @Test("the rules allow loopback and TCP to the proxy, and reject the rest")
    func rules() throws {
        let f = try #require(GuestFirewall(proxyHost: "192.168.128.1", port: 51234))
        let r = f.rules
        #expect(r.contains("table inet mudroom {"))
        #expect(r.contains("type filter hook output priority 0; policy drop;"))
        #expect(r.contains("type filter hook input priority 0; policy drop;"))
        #expect(r.contains("type filter hook forward priority 0; policy drop;"))
        #expect(r.contains(#"oif "lo" accept"#))
        #expect(r.contains("ip daddr 192.168.128.1 tcp dport 51234 accept"))
        #expect(r.contains("reject with icmpx type admin-prohibited"))
        // Inbound: only replies (and loopback).
        #expect(r.contains("ct state established,related accept"))
        // Exactly one non-loopback accept on the way out.
        let accepts = r.split(separator: "\n").filter { $0.contains("accept") && $0.contains("daddr") }
        #expect(accepts.count == 1)

        let v6 = try #require(GuestFirewall(proxyHost: "fd00::1", port: 3128))
        #expect(v6.rules.contains("ip6 daddr fd00::1 tcp dport 3128 accept"))

        let closed = GuestFirewall.closed.rules
        #expect(!closed.contains("daddr") && closed.contains("policy drop") && closed.contains(#"oif "lo" accept"#))
    }

    @Test("only an IP address and a real port make it into the rules")
    func validation() {
        #expect(GuestFirewall(proxyHost: "host.docker.internal", port: 80) == nil)
        #expect(GuestFirewall(proxyHost: "192.168.128.1 tcp dport 0-65535", port: 80) == nil)
        #expect(GuestFirewall(proxyHost: "192.168.128.1; flush ruleset", port: 80) == nil)
        #expect(GuestFirewall(proxyHost: "192.168.128.1", port: 0) == nil)
        #expect(GuestFirewall(proxyHost: "0300.0250.0200.01", port: 80) == nil)
    }

    @Test("a firewalled run starts as root in sh, then runs the image's entrypoint and the command")
    func runArguments() throws {
        let work = URL(fileURLWithPath: "/tmp/s1/work")
        var spec = SandboxSpec(name: "mudroom-s1", image: "mudroom/agent-base:latest", workspace: work,
                               command: ["claude", "--dangerously-skip-permissions"], interactive: true, tty: true,
                               environment: ["HTTPS_PROXY": "http://192.168.128.1:51234"], network: "mudroom-hostonly")
        let plain = AppleContainerBackend.runArguments(for: spec)
        #expect(!plain.contains("--cap-add") && !plain.contains("--entrypoint") && !plain.contains("--user"))

        let f = try #require(GuestFirewall(proxyHost: "192.168.128.1", port: 51234))
        spec.firewall = f
        let image = GuestFirewall.ImageConfig(user: "node", entrypoint: ["docker-entrypoint.sh"], cmd: ["bash"], setsHome: true)
        let args = AppleContainerBackend.runArguments(for: spec, image: image)
        let i = try #require(args.firstIndex(of: "mudroom/agent-base:latest"))
        let before = Array(args[..<i]), after = Array(args[(i + 1)...])
        #expect(before.starts(with: ["run", "--rm", "--name", "mudroom-s1", "--user", "0:0", "--cap-add", "CAP_NET_ADMIN",
                                     "--entrypoint", "/bin/sh"]))
        #expect(before.contains("--network") && before.contains("mudroom-hostonly"))
        #expect(after == ["-c", GuestFirewall.script, "mudroom-firewall", f.rules, "node", "", "0", "--",
                          "docker-entrypoint.sh", "claude", "--dangerously-skip-permissions"])
        // Only CAP_NET_ADMIN is added, nothing else.
        #expect(args.filter { $0 == "--cap-add" }.count == 1)

        // No command: the image's CMD. A group and no HOME in the image.
        spec.command = []
        let other = GuestFirewall.ImageConfig(user: "1001:staff", entrypoint: [], cmd: ["/bin/sh"], setsHome: false)
        let a2 = AppleContainerBackend.runArguments(for: spec, image: other)
        #expect(Array(a2.suffix(5)) == ["1001", "staff", "1", "--", "/bin/sh"])

        // Without the image's config it still never runs unfirewalled.
        let a3 = AppleContainerBackend.runArguments(for: spec)
        #expect(a3.contains("--cap-add") && a3.contains(GuestFirewall.script))
    }

    @Test("user strings split into user and group")
    func splitUser() {
        #expect(GuestFirewall.splitUser("node") == ("node", ""))
        #expect(GuestFirewall.splitUser("1000:1000") == ("1000", "1000"))
        #expect(GuestFirewall.splitUser("") == ("", ""))
        #expect(GuestFirewall.splitUser("app:") == ("app", ""))
    }

    @Test("the image's user, entrypoint and CMD come from container image inspect")
    func imageConfig() throws {
        let json = #"""
        [{"id": "x", "variants": [
          {"platform": {"os": "linux", "architecture": "amd64"},
           "config": {"config": {"User": "wrong", "Cmd": ["x"]}}},
          {"platform": {"os": "linux", "architecture": "arm64"},
           "config": {"config": {"User": "node", "Entrypoint": ["docker-entrypoint.sh"], "Cmd": ["bash"],
                                 "Env": ["PATH=/usr/bin", "HOME=/home/node"]}}}
        ]}]
        """#
        let c = try #require(GuestFirewall.parseImageConfig(Data(json.utf8)))
        #expect(c == GuestFirewall.ImageConfig(user: "node", entrypoint: ["docker-entrypoint.sh"], cmd: ["bash"], setsHome: true))

        let alpine = #"[{"variants": [{"platform": {"os": "linux", "architecture": "arm64", "variant": "v8"}, "config": {"config": {"Cmd": ["/bin/sh"], "Env": ["PATH=/bin"]}}}]}]"#
        #expect(GuestFirewall.parseImageConfig(Data(alpine.utf8)) == GuestFirewall.ImageConfig(cmd: ["/bin/sh"]))
        #expect(GuestFirewall.parseImageConfig(Data("[]".utf8)) == nil)
        #expect(GuestFirewall.parseImageConfig(Data("not json".utf8)) == nil)
    }

    /// A VM backend whose host network is loopback, so the proxy can start.
    final class FirewallBackend: SandboxBackend, @unchecked Sendable {
        let name = "fake-vm"
        let usesGuestFirewall: Bool
        var captured: [SandboxSpec] = []
        var stderr = ""
        init(firewall: Bool) { usesGuestFirewall = firewall }
        func checkAvailable() throws {}
        func run(_ spec: SandboxSpec) throws -> Int32 { 0 }
        func capture(_ spec: SandboxSpec) throws -> CapturedOutput {
            captured.append(spec)
            return CapturedOutput(status: GuestFirewall.failureStatus, stdout: "", stderr: stderr)
        }
        func buildImage(containerfile: URL, context: URL, tag: String) throws {}
        func hostOnlyNetwork() throws -> SandboxNetwork? {
            SandboxNetwork(name: "n", hostOnly: true, gateway: "127.0.0.1", subnet: "127.0.0.0/8")
        }
        func defaultNetwork() throws -> SandboxNetwork? { nil }
    }

    @Test("locked and offline setups carry a firewall on VM backends; open and Docker-style ones don't")
    func networkSetup() throws {
        let vm = FirewallBackend(firewall: true)
        let locked = try NetworkSetup(mode: .locked, allowlist: Allowlist(strings: ["example.com"]), backend: vm, logURL: nil)
        defer { locked.stop() }
        let port = try #require(locked.proxy?.port)
        #expect(locked.firewall == GuestFirewall(proxyHost: "127.0.0.1", port: port))
        #expect(locked.record.guestFirewall == true)
        #expect(locked.summary.contains { $0.contains("only the proxy port") })

        let offline = try NetworkSetup(mode: .offline, allowlist: Allowlist(strings: []), backend: vm, logURL: nil)
        #expect(offline.firewall == .closed && offline.record.guestFirewall == true)

        let open = try NetworkSetup(mode: .open, allowlist: Allowlist(strings: []), backend: vm, logURL: nil)
        #expect(open.firewall == nil && open.record.guestFirewall == nil)

        let docker = FirewallBackend(firewall: false)
        let dl = try NetworkSetup(mode: .locked, allowlist: Allowlist(strings: []), backend: docker, logURL: nil)
        defer { dl.stop() }
        #expect(dl.firewall == nil && dl.record.guestFirewall == nil)
    }

    @Test("the probe runs behind the firewall, and a firewall failure stops the session instead of asking for a repair")
    func probe() throws {
        let tmp = try TempDir()
        let vm = FirewallBackend(firewall: true)
        vm.stderr = "\(GuestFirewall.failureMarker)this image has no nft (the nftables package). The agent was not started.\n"
        let r = NetworkProbe.run(backend: vm, scratch: tmp.path("probe"))
        #expect(vm.captured.first?.firewall != nil)
        guard case .firewall(let why) = r else { Issue.record("expected a firewall failure, got \(r)"); return }
        #expect(why.contains("no nft"))
        #expect(!r.isOK && !r.needsRepair && r.summary.contains("firewall"))
    }

    @Test("sessions recorded before the firewall still load")
    func oldRecord() throws {
        let old = #"{"mode":"locked","enforcement":"enforced","allowlist":[],"proxy":"http://192.168.128.1:1"}"#
        let n = try JSONDecoder().decode(SessionNetwork.self, from: Data(old.utf8))
        #expect(n.guestFirewall == nil)
    }

    #if !os(Windows)
    /// Runs the setup script with fake `nft` and `setpriv` on PATH.
    func runScript(nft: String?, setpriv: Bool = true, in tmp: TempDir) throws -> (CapturedOutput, String) {
        let bin = tmp.path("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func tool(_ name: String, _ body: String) throws {
            let u = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: u)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        let log = tmp.path("calls").path
        if let nft { try tool("nft", "echo \"nft $*\" >> '\(log)'; cat >/dev/null; \(nft)") }
        if setpriv { try tool("setpriv", "echo \"setpriv $*\" >> '\(log)'; exit 0") }
        for t in ["id", "cut", "cat"] {
            if let p = ProcessRunner.which(t) { try? FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent(t).path, withDestinationPath: p) }
        }
        let f = GuestFirewall.closed
        let args = f.arguments(image: .init(user: "nosuchuser-mudroom", entrypoint: [], cmd: [], setsHome: true),
                               command: ["touch", tmp.path("agent-ran").path])
        let out = try ProcessRunner.capture("/bin/sh", args, environment: ["PATH": bin.path])
        let calls = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return (out, calls)
    }

    @Test("the setup script refuses to start the agent without nft, setpriv or loaded rules")
    func failClosed() throws {
        for (nft, setpriv, reason) in [(nil, true, "no nft"), ("exit 0", false, "no setpriv"),
                                       ("exit 1", true, "could not be loaded")] as [(String?, Bool, String)] {
            let tmp = try TempDir()
            let (out, _) = try runScript(nft: nft, setpriv: setpriv, in: tmp)
            #expect(out.status == GuestFirewall.failureStatus)
            #expect(out.stderr.contains(GuestFirewall.failureMarker) && out.stderr.contains(reason))
            #expect(out.stderr.contains("The agent was not started"))
            #expect(!FileManager.default.fileExists(atPath: tmp.path("agent-ran").path))
        }
        // `nft -f` succeeds but the table isn't there afterwards.
        let tmp = try TempDir()
        let (out, _) = try runScript(nft: #"case "$1" in list) exit 1;; esac; exit 0"#, in: tmp)
        #expect(out.status == GuestFirewall.failureStatus && out.stderr.contains("not in place"))
    }

    @Test("with the rules loaded, the command runs through setpriv with no capabilities")
    func dropsPrivileges() throws {
        let tmp = try TempDir()
        let (out, calls) = try runScript(nft: "exit 0", in: tmp)
        #expect(out.status == 0, "\(out.stderr)")
        let lines = calls.split(separator: "\n").map(String.init)
        #expect(lines.first == "nft -f -")
        #expect(lines.contains("nft list table inet mudroom"))
        let setpriv = try #require(lines.last)
        for flag in ["--reuid=nosuchuser-mudroom", "--regid=0", "--clear-groups", "--inh-caps=-all",
                     "--bounding-set=-all", "--no-new-privs", "-- touch"] {
            #expect(setpriv.contains(flag), "\(setpriv) lacks \(flag)")
        }
    }
    #endif
}
