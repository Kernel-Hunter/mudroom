#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Runs the agent in a Docker or Podman container.
///
/// Isolation is a container, not a VM: on Linux the agent shares the host
/// kernel. Docker Desktop (and Podman machine) on macOS and Windows run the
/// containers inside a Linux VM. Pass `ociRuntime: "runsc"` (gVisor) or a
/// Kata runtime for a stronger boundary where they are installed.
///
/// Networks:
/// - open: the runtime's default bridge.
/// - offline: `mudroom-internal`, created with `network create --internal`.
///   No route out at all.
/// - locked: the same internal network, plus a small forwarder container
///   ("sidecar") attached to both the internal network and the default
///   bridge. The sidecar only forwards TCP to Mudroom's proxy on the host,
///   which applies the allowlist and logs. The agent has no other way out.
public struct DockerBackend: SandboxBackend {
    public enum Flavor: String, Sendable, CaseIterable {
        case docker
        case podman
    }

    public let flavor: Flavor
    public let executable: String?
    /// OCI runtime for `run --runtime`, e.g. "runsc" for gVisor.
    public var ociRuntime: String?
    /// Image for the proxy forwarder; it needs `node`.
    public var sidecarImage: String = AgentBaseImage.tag

    public var name: String { flavor.rawValue }

    public static let networkName = "mudroom-internal"
    public static let label = "io.github.kernel-hunter.mudroom=1"
    /// Port the sidecar listens on inside the internal network.
    public static let sidecarPort: UInt16 = 3128

    /// Finds the `docker` or `podman` CLI on PATH.
    public init(flavor: Flavor = .docker, ociRuntime: String? = nil) {
        self.init(flavor: flavor, executable: ProcessRunner.which(flavor.rawValue), ociRuntime: ociRuntime)
    }

    /// Uses this CLI; nil means it isn't installed.
    public init(flavor: Flavor, executable: String?, ociRuntime: String? = nil) {
        self.flavor = flavor
        self.executable = executable
        self.ociRuntime = ociRuntime
    }

    // MARK: Availability

    public func checkAvailable() throws {
        guard let exe = executable else {
            switch flavor {
            case .docker:
                throw MudroomError.backendUnavailable(
                    "the `docker` CLI was not found. Install Docker Engine (Linux) or Docker Desktop, or use --backend podman.")
            case .podman:
                throw MudroomError.backendUnavailable("the `podman` CLI was not found. Install Podman, or use --backend docker.")
            }
        }
        let out = try ProcessRunner.capture(exe, ["info", "--format", "{{json .}}"])
        if out.status != 0 {
            let detail = (out.stderr + out.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            let hint = flavor == .docker
                ? "Start the Docker daemon (or Docker Desktop) first."
                : "On macOS, start the Podman VM with `podman machine start`."
            throw MudroomError.backendUnavailable("\(name) is not reachable (\(detail)). \(hint)")
        }
    }

    /// True for rootless Podman, which needs `--userns keep-id` so files in
    /// /workspace stay owned by the host user.
    var isRootlessPodman: Bool {
        flavor == .podman && getuid() != 0
    }

    // MARK: Running

    /// Host details that change the `run` arguments.
    public struct Host: Sendable, Equatable {
        public var isLinux: Bool
        public var uid: UInt32
        public var gid: UInt32
        public var rootlessPodman: Bool

        public init(isLinux: Bool, uid: UInt32, gid: UInt32, rootlessPodman: Bool) {
            self.isLinux = isLinux
            self.uid = uid
            self.gid = gid
            self.rootlessPodman = rootlessPodman
        }

        public static func current(_ backend: DockerBackend) -> Host {
            #if os(Linux)
            let linux = true
            #else
            let linux = false
            #endif
            return Host(isLinux: linux, uid: getuid(), gid: getgid(), rootlessPodman: backend.isRootlessPodman)
        }
    }

    /// The exact `docker run` arguments for a spec. Kept separate so it can
    /// be unit tested without a daemon.
    public static func runArguments(for spec: SandboxSpec, host: Host, ociRuntime: String? = nil) -> [String] {
        var args = ["run", "--rm", "--name", spec.name, "--label", label]
        if spec.interactive { args.append("--interactive") }
        if spec.tty { args.append("--tty") }
        args += ["--mount", "type=bind,source=\(spec.workspace.path),target=\(spec.guestWorkspace)"]
        for m in spec.mounts {
            args += ["--mount", "type=bind,source=\(m.source.path),target=\(m.target)" + (m.readOnly ? ",readonly" : "")]
        }
        args += ["--workdir", spec.guestWorkspace]
        for name in spec.environmentNames {
            // `--env NAME` copies the value from the CLI's own environment,
            // so secrets never appear in argv or `ps`.
            args += ["--env", name]
        }
        for key in spec.environment.keys.sorted() {
            args += ["--env", "\(key)=\(spec.environment[key]!)"]
        }
        if let network = spec.network { args += ["--network", network] }
        if let cpus = spec.cpus { args += ["--cpus", String(cpus)] }
        if let memory = spec.memory { args += ["--memory", memory] }
        if let ociRuntime { args += ["--runtime", ociRuntime] }
        // A container shares the kernel on Linux: take away what the agent
        // doesn't need. The image runs as an unprivileged user anyway.
        args += ["--cap-drop", "ALL", "--security-opt", "no-new-privileges"]
        if host.rootlessPodman {
            args += ["--userns", "keep-id"]
        } else if host.isLinux && host.uid != 1000 && host.uid != 0 {
            // Bind mounts keep numeric owners on Linux. The image's user is
            // uid 1000; run as the host user instead so work/ stays yours.
            args += ["--user", "\(host.uid):\(host.gid)"]
        }
        args.append(spec.image)
        args += spec.command
        return args
    }

    public func run(_ spec: SandboxSpec) throws -> Int32 {
        try checkAvailable()
        try ensureImage(spec.image)
        return try ProcessRunner.runAttached(executable!, Self.runArguments(for: spec, host: .current(self), ociRuntime: ociRuntime))
    }

    public func capture(_ spec: SandboxSpec) throws -> CapturedOutput {
        try checkAvailable()
        try ensureImage(spec.image)
        return try ProcessRunner.capture(executable!, Self.runArguments(for: spec, host: .current(self), ociRuntime: ociRuntime))
    }

    /// Mudroom's own image is never on a registry; say how to build it
    /// instead of letting `run` try to pull it.
    func ensureImage(_ image: String) throws {
        guard image == AgentBaseImage.tag else { return }
        let out = try ProcessRunner.capture(executable!, ["image", "inspect", image])
        if out.status != 0 {
            throw MudroomError.backendUnavailable(
                "\(image) is not built for \(name) yet. Run `mudroom image build --backend \(name)` first.")
        }
    }

    public func buildImage(containerfile: URL, context: URL, tag: String) throws {
        try checkAvailable()
        let status = try ProcessRunner.runAttached(executable!, [
            "build", "--tag", tag, "--file", containerfile.path, context.path,
        ])
        if status != 0 { throw MudroomError.commandFailed("\(name) build", status, "") }
    }

    // MARK: Networks

    public func hostOnlyNetwork() throws -> SandboxNetwork? {
        try checkAvailable()
        let exe = executable!
        if let net = try inspectNetwork(Self.networkName, exe) { return net.hostOnly ? net : nil }
        let created = try ProcessRunner.capture(exe, ["network", "create", "--internal", "--label", Self.label, Self.networkName])
        if created.status != 0, try inspectNetwork(Self.networkName, exe) == nil {
            throw MudroomError.commandFailed("\(name) network create", created.status, created.stderr)
        }
        return try inspectNetwork(Self.networkName, exe).flatMap { $0.hostOnly ? $0 : nil }
    }

    public func defaultNetwork() throws -> SandboxNetwork? {
        try checkAvailable()
        return try inspectNetwork(flavor == .docker ? "bridge" : "podman", executable!)
    }

    func inspectNetwork(_ name: String, _ exe: String) throws -> SandboxNetwork? {
        let out = try ProcessRunner.capture(exe, ["network", "inspect", name])
        guard out.status == 0 else { return nil }
        return Self.parseNetwork(Data(out.stdout.utf8))
    }

    /// Parses `docker network inspect` or `podman network inspect` JSON.
    /// `hostOnly` is the network's internal flag.
    public static func parseNetwork(_ data: Data) -> SandboxNetwork? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let obj = arr.first else { return nil }
        // Docker: Name, Internal, IPAM.Config[{Subnet, Gateway}].
        if let name = obj["Name"] as? String {
            let configs = ((obj["IPAM"] as? [String: Any])?["Config"] as? [[String: Any]]) ?? []
            let v4 = configs.first { ($0["Subnet"] as? String).map { IPv4Subnet($0) != nil } ?? false }
            return SandboxNetwork(name: name, hostOnly: obj["Internal"] as? Bool ?? false,
                                  gateway: v4?["Gateway"] as? String ?? "", subnet: v4?["Subnet"] as? String ?? "")
        }
        // Podman: name, internal, subnets[{subnet, gateway}].
        if let name = obj["name"] as? String {
            let subnets = (obj["subnets"] as? [[String: Any]]) ?? []
            let v4 = subnets.first { ($0["subnet"] as? String).map { IPv4Subnet($0) != nil } ?? false }
            return SandboxNetwork(name: name, hostOnly: obj["internal"] as? Bool ?? false,
                                  gateway: v4?["gateway"] as? String ?? "", subnet: v4?["subnet"] as? String ?? "")
        }
        return nil
    }

    // MARK: Proxy

    /// The name the sidecar uses for the host.
    var hostAlias: String { flavor == .docker ? "host.docker.internal" : "host.containers.internal" }

    /// On macOS the runtime is a VM (Docker Desktop, Podman machine, colima)
    /// that forwards `host.docker.internal` to the Mac's loopback, so the
    /// proxy listens on 127.0.0.1 only. On Linux the sidecar reaches the
    /// host at the default bridge's gateway, so the proxy listens there and
    /// accepts only that bridge.
    public func proxyListen(for plan: NetworkPlan) throws -> ProxyListen {
        let blocked = plan.clientSubnet.map { [$0] } ?? []
        #if os(Linux)
        guard let bridge = try defaultNetwork(), !bridge.gateway.isEmpty, let subnet = IPv4Subnet(bridge.subnet) else {
            throw MudroomError.backendUnavailable("couldn't read the \(name) default network's gateway for the proxy")
        }
        return ProxyListen(bindHost: bridge.gateway, clientSubnets: [subnet], blockedSubnets: blocked)
        #else
        return ProxyListen(bindHost: "127.0.0.1", clientSubnets: [], blockedSubnets: blocked)
        #endif
    }

    /// Node one-liner for the sidecar: accept on 3128, pipe each connection
    /// to the host proxy. Half-closes pass through.
    static let forwarderScript = """
    const net = require('net');
    const [host, port] = [process.env.MUDROOM_UPSTREAM_HOST, +process.env.MUDROOM_UPSTREAM_PORT];
    net.createServer({allowHalfOpen: true}, c => {
      const u = net.connect({host, port, allowHalfOpen: true});
      c.pipe(u); u.pipe(c);
      c.on('error', () => u.destroy()); u.on('error', () => c.destroy());
    }).listen(\(sidecarPort), '0.0.0.0', () => console.log('mudroom-forwarder ready'));
    """

    /// Arguments for the sidecar container (before it joins the internal network).
    public static func sidecarArguments(name: String, image: String, bridge: String, hostAlias: String,
                                        upstreamPort: UInt16, addHostGateway: Bool) -> [String] {
        var args = ["run", "--detach", "--rm", "--name", name, "--label", label, "--network", bridge,
                    "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--read-only",
                    "--memory", "128m", "--pids-limit", "64"]
        if addHostGateway { args += ["--add-host", "\(hostAlias):host-gateway"] }
        args += ["--env", "MUDROOM_UPSTREAM_HOST=\(hostAlias)", "--env", "MUDROOM_UPSTREAM_PORT=\(upstreamPort)",
                 image, "node", "-e", forwarderScript]
        return args
    }

    public func attachProxy(port: UInt16, plan: NetworkPlan) throws -> ProxyRoute {
        guard let internalNet = plan.vmNetwork else {
            throw MudroomError.invalid("locked mode on \(name) needs the internal network")
        }
        let exe = executable!
        try ensureImage(sidecarImage)
        guard let bridge = try defaultNetwork() else {
            throw MudroomError.backendUnavailable("couldn't find the \(name) default network")
        }
        let sidecar = "mudroom-proxy-\(String(UInt32.random(in: 0...UInt32.max), radix: 16))"
        #if os(Linux)
        // Docker on Linux has no host.docker.internal unless asked; Podman
        // always adds host.containers.internal.
        let addHostGateway = flavor == .docker
        #else
        let addHostGateway = false
        #endif
        let started = try ProcessRunner.capture(exe, Self.sidecarArguments(
            name: sidecar, image: sidecarImage, bridge: bridge.name, hostAlias: hostAlias,
            upstreamPort: port, addHostGateway: addHostGateway))
        guard started.status == 0 else {
            throw MudroomError.commandFailed("\(name) run (proxy forwarder)", started.status, started.stderr)
        }
        let teardown: @Sendable () -> Void = { _ = try? ProcessRunner.capture(exe, ["rm", "--force", sidecar]) }
        do {
            let joined = try ProcessRunner.capture(exe, ["network", "connect", internalNet, sidecar])
            guard joined.status == 0 else {
                throw MudroomError.commandFailed("\(name) network connect", joined.status, joined.stderr)
            }
            let ip = try sidecarAddress(sidecar, network: internalNet, exe)
            try waitForSidecar(sidecar, exe)
            return ProxyRoute(host: ip, port: Self.sidecarPort, teardown: teardown)
        } catch {
            teardown()
            throw error
        }
    }

    func sidecarAddress(_ container: String, network: String, _ exe: String) throws -> String {
        let out = try ProcessRunner.capture(exe, ["inspect", "--format", "{{json .NetworkSettings.Networks}}", container])
        guard out.status == 0, let nets = try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any],
              let entry = nets[network] as? [String: Any], let ip = entry["IPAddress"] as? String, !ip.isEmpty else {
            throw MudroomError.commandFailed("\(name) inspect (proxy forwarder address)", out.status, out.stderr + out.stdout)
        }
        return ip
    }

    func waitForSidecar(_ container: String, _ exe: String) throws {
        for _ in 0..<100 {
            let logs = try ProcessRunner.capture(exe, ["logs", container])
            if logs.stdout.contains("mudroom-forwarder ready") { return }
            if logs.status != 0 {
                throw MudroomError.commandFailed("proxy forwarder", logs.status, logs.stderr)
            }
            usleep(100_000)
        }
        throw MudroomError.backendUnavailable("the proxy forwarder container did not start in 10 seconds")
    }
}
