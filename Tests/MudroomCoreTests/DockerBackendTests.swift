import Foundation
import Testing
@testable import MudroomCore

@Suite("Docker and Podman backend")
struct DockerBackendTests {
    let work = URL(fileURLWithPath: "/home/me/.local/share/mudroom/sessions/s1/work")
    let mac = DockerBackend.Host(isLinux: false, uid: 501, gid: 20, rootlessPodman: false)

    func spec(network: String? = nil) -> SandboxSpec {
        SandboxSpec(name: "mudroom-s1", image: "mudroom/agent-base:latest", workspace: work,
                    command: ["claude", "--dangerously-skip-permissions"], environmentNames: ["ANTHROPIC_API_KEY"],
                    interactive: true, tty: true,
                    mounts: [SandboxMount(source: URL(fileURLWithPath: "/h/agents/claude/home"), target: "/home/node/.claude")],
                    environment: ["HTTPS_PROXY": "http://172.19.0.2:3128"], network: network)
    }

    @Test("run mounts only work/ and the agent home, passes secrets by name, drops capabilities")
    func runArguments() {
        let args = DockerBackend.runArguments(for: spec(network: "mudroom-internal"), host: mac)
        #expect(args == [
            "run", "--rm", "--name", "mudroom-s1", "--label", DockerBackend.label, "--interactive", "--tty",
            "--mount", "type=bind,source=\(work.path),target=/workspace",
            "--mount", "type=bind,source=/h/agents/claude/home,target=/home/node/.claude",
            "--workdir", "/workspace",
            "--env", "ANTHROPIC_API_KEY",
            "--env", "HTTPS_PROXY=http://172.19.0.2:3128",
            "--network", "mudroom-internal",
            "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
            "mudroom/agent-base:latest", "claude", "--dangerously-skip-permissions",
        ])
        #expect(!args.contains { $0.contains("sk-") })
    }

    @Test("an OCI runtime and Linux user mapping are added when needed")
    func runtimeAndUser() {
        let linux = DockerBackend.Host(isLinux: true, uid: 1001, gid: 1001, rootlessPodman: false)
        let args = DockerBackend.runArguments(for: spec(), host: linux, ociRuntime: "runsc")
        #expect(args.contains("--runtime") && args[args.firstIndex(of: "--runtime")! + 1] == "runsc")
        #expect(args[args.firstIndex(of: "--user")! + 1] == "1001:1001")
        #expect(!args.contains("--network"))

        let uid1000 = DockerBackend.Host(isLinux: true, uid: 1000, gid: 1000, rootlessPodman: false)
        #expect(!DockerBackend.runArguments(for: spec(), host: uid1000).contains("--user"))
        let podman = DockerBackend.Host(isLinux: true, uid: 1001, gid: 1001, rootlessPodman: true)
        let pargs = DockerBackend.runArguments(for: spec(), host: podman)
        #expect(pargs.contains("keep-id") && !pargs.contains("--user"))
    }

    @Test("docker and podman network inspect output parse")
    func parseNetworks() {
        let docker = #"[{"Name":"mudroom-internal","Internal":true,"IPAM":{"Config":[{"Subnet":"fd00::/64"},{"Subnet":"172.19.0.0/16","Gateway":"172.19.0.1"}]}}]"#
        #expect(DockerBackend.parseNetwork(Data(docker.utf8)) ==
                SandboxNetwork(name: "mudroom-internal", hostOnly: true, gateway: "172.19.0.1", subnet: "172.19.0.0/16"))
        let bridge = #"[{"Name":"bridge","Internal":false,"IPAM":{"Config":[{"Subnet":"172.17.0.0/16","Gateway":"172.17.0.1"}]}}]"#
        #expect(DockerBackend.parseNetwork(Data(bridge.utf8))?.hostOnly == false)
        let podman = #"[{"name":"mudroom-internal","internal":true,"subnets":[{"subnet":"10.89.0.0/24","gateway":"10.89.0.1"}]}]"#
        #expect(DockerBackend.parseNetwork(Data(podman.utf8)) ==
                SandboxNetwork(name: "mudroom-internal", hostOnly: true, gateway: "10.89.0.1", subnet: "10.89.0.0/24"))
        #expect(DockerBackend.parseNetwork(Data("[]".utf8)) == nil)
    }

    @Test("the proxy forwarder runs locked down and only knows the host proxy")
    func sidecar() {
        let args = DockerBackend.sidecarArguments(name: "mudroom-proxy-1", image: "mudroom/agent-base:latest", bridge: "bridge",
                                                  hostAlias: "host.docker.internal", upstreamPort: 50123, addHostGateway: true)
        #expect(args.starts(with: ["run", "--detach", "--rm", "--name", "mudroom-proxy-1"]))
        #expect(args.contains("--read-only") && args.contains("ALL") && args.contains("no-new-privileges"))
        #expect(args.contains("host.docker.internal:host-gateway"))
        #expect(args.contains("MUDROOM_UPSTREAM_PORT=50123"))
        #expect(args[args.firstIndex(of: "--network")! + 1] == "bridge")
        #expect(DockerBackend.forwarderScript.contains("allowHalfOpen"))
    }

    @Test("missing CLI gives an install hint")
    func missingCLI() {
        #expect(throws: MudroomError.self) { try DockerBackend(flavor: .docker, executable: nil).checkAvailable() }
    }

    @Test("auto picks docker or podman when Apple container isn't usable, and keeps explicit choices")
    func autoChoice() {
        #expect(Backends.resolve(.docker, which: { _ in nil }) == .docker)
        #expect(Backends.resolve(.podman, which: { _ in nil }) == .podman)
        let onlyPodman = Backends.resolve(.auto) { $0 == "podman" ? "/usr/bin/podman" : nil }
        let onlyDocker = Backends.resolve(.auto) { $0 == "docker" ? "/usr/bin/docker" : nil }
        #expect(onlyPodman == .podman)
        #expect(onlyDocker == .docker)
        if !Backends.appleContainerSupported {
            #expect(Backends.resolve(.auto) { $0 == "container" ? "/x/container" : nil } != .apple)
        }
        #expect(Backends.defaultChoice(["MUDROOM_BACKEND": "Podman"]) == .podman)
        #expect(Backends.defaultChoice([:]) == .auto)
    }
}

/// A backend whose proxy goes through a forwarder, like Docker's sidecar.
final class SidecarFakeBackend: SandboxBackend, @unchecked Sendable {
    let name = "fake-docker"
    let tornDown = LockedBox(0)
    let listened = LockedBox<ProxyListen?>(nil)
    func checkAvailable() throws {}
    func run(_ spec: SandboxSpec) throws -> Int32 { 0 }
    func capture(_ spec: SandboxSpec) throws -> CapturedOutput { CapturedOutput(status: 0, stdout: "", stderr: "") }
    func buildImage(containerfile: URL, context: URL, tag: String) throws {}
    func hostOnlyNetwork() throws -> SandboxNetwork? {
        SandboxNetwork(name: "mudroom-internal", hostOnly: true, gateway: "172.19.0.1", subnet: "172.19.0.0/16")
    }
    func defaultNetwork() throws -> SandboxNetwork? {
        SandboxNetwork(name: "bridge", hostOnly: false, gateway: "172.17.0.1", subnet: "172.17.0.0/16")
    }
    func proxyListen(for plan: NetworkPlan) throws -> ProxyListen {
        let l = ProxyListen(bindHost: "127.0.0.1", clientSubnets: [], blockedSubnets: [plan.clientSubnet!])
        listened.value = l
        return l
    }
    func attachProxy(port: UInt16, plan: NetworkPlan) throws -> ProxyRoute {
        ProxyRoute(host: "172.19.0.2", port: 3128) { [tornDown] in tornDown.value += 1 }
    }
}

@Suite("Network setup with a forwarder")
struct ForwarderSetupTests {
    @Test("locked mode uses the backend's listen address and route, and tears the route down once")
    func route() throws {
        let backend = SidecarFakeBackend()
        let setup = try NetworkSetup(mode: .locked, allowlist: Allowlist(strings: ["api.anthropic.com"]), backend: backend, logURL: nil)
        #expect(setup.record.proxy == "http://172.19.0.2:3128")
        #expect(setup.environment["HTTPS_PROXY"] == "http://172.19.0.2:3128")
        #expect(setup.plan.vmNetwork == "mudroom-internal")
        #expect(backend.listened.value?.bindHost == "127.0.0.1")
        #expect(setup.proxy?.configuration.blockedSubnets == [IPv4Subnet("172.19.0.0/16")!])
        #expect(setup.proxy?.isLocalDestination(IPAddress("172.19.0.5")!) == true)
        setup.stop()
        setup.stop()
        #expect(backend.tornDown.value == 1)
    }
}
