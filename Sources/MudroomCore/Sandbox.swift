#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Everything a backend needs to start the agent.
public struct SandboxSpec: Sendable, Equatable {
    public var name: String
    public var image: String
    /// Host directory mounted read-write into the guest. Always a session's
    /// `work/` clone, never the real project.
    public var workspace: URL
    public var guestWorkspace: String
    public var command: [String]
    /// Names of host environment variables to pass through. Values are never
    /// put on the command line; the backend inherits them.
    public var environmentNames: [String]
    public var interactive: Bool
    public var tty: Bool
    public var cpus: Int?
    public var memory: String?
    /// Extra read-write mounts (agent config directories).
    public var mounts: [SandboxMount]
    /// Non-secret variables set by value (proxy settings, agent switches).
    public var environment: [String: String]
    /// Network to attach to; nil uses the runtime's default (NAT, full access).
    public var network: String?
    /// Secrets Mudroom itself holds (a stored agent token), by variable
    /// name. Only the names go on the command line (`--env NAME`); the
    /// values are set in the runtime CLI's own environment, never in argv.
    public var secretEnvironment: [String: String] = [:]
    /// For `capture`: stop the sandbox after this many seconds.
    public var timeout: TimeInterval?

    /// Every name passed with `--env NAME`.
    public var passedNames: [String] {
        environmentNames + secretEnvironment.keys.sorted().filter { !environmentNames.contains($0) }
    }

    public init(name: String, image: String, workspace: URL, guestWorkspace: String = "/workspace",
                command: [String], environmentNames: [String] = [], interactive: Bool = true,
                tty: Bool = false, cpus: Int? = nil, memory: String? = nil,
                mounts: [SandboxMount] = [], environment: [String: String] = [:], network: String? = nil) {
        self.name = name
        self.image = image
        self.workspace = workspace
        self.guestWorkspace = guestWorkspace
        self.command = command
        self.environmentNames = environmentNames
        self.interactive = interactive
        self.tty = tty
        self.cpus = cpus
        self.memory = memory
        self.mounts = mounts
        self.environment = environment
        self.network = network
    }
}

public struct SandboxMount: Sendable, Equatable {
    public var source: URL
    public var target: String
    public var readOnly: Bool

    public init(source: URL, target: String, readOnly: Bool = false) {
        self.source = source
        self.target = target
        self.readOnly = readOnly
    }
}

/// A VM network as the runtime reports it.
public struct SandboxNetwork: Sendable, Equatable {
    public var name: String
    /// True for a host-only network: the VM can reach the Mac (the gateway)
    /// and nothing else.
    public var hostOnly: Bool
    public var gateway: String
    public var subnet: String
}

/// Where the proxy on the host listens, and who may use it.
public struct ProxyListen: Sendable, Equatable {
    /// nil listens on every address.
    public var bindHost: String?
    public var clientSubnets: [IPv4Subnet]
    /// Networks the proxy must never connect to (besides the client ones).
    public var blockedSubnets: [IPv4Subnet]

    public init(bindHost: String?, clientSubnets: [IPv4Subnet], blockedSubnets: [IPv4Subnet] = []) {
        self.bindHost = bindHost
        self.clientSubnets = clientSubnets
        self.blockedSubnets = blockedSubnets
    }
}

/// The address the sandbox uses for the proxy, and how to tear down
/// whatever the backend started to provide it.
public struct ProxyRoute: Sendable {
    public var host: String
    public var port: UInt16
    public var teardown: (@Sendable () -> Void)?

    public init(host: String, port: UInt16, teardown: (@Sendable () -> Void)? = nil) {
        self.host = host
        self.port = port
        self.teardown = teardown
    }
}

public protocol SandboxBackend: Sendable {
    /// "apple-container", "docker" or "podman".
    var name: String { get }
    /// Throws `MudroomError.backendUnavailable` with a human-readable reason.
    func checkAvailable() throws
    /// Runs the agent attached to this terminal and returns its exit status.
    func run(_ spec: SandboxSpec) throws -> Int32
    /// Runs a non-interactive command and captures its output.
    func capture(_ spec: SandboxSpec) throws -> CapturedOutput
    /// Builds an image from a Containerfile.
    func buildImage(containerfile: URL, context: URL, tag: String) throws
    /// Returns (creating it if needed) the host-only network Mudroom uses for
    /// locked and offline sessions, or nil if the runtime can't make one.
    func hostOnlyNetwork() throws -> SandboxNetwork?
    /// The runtime's default (NAT) network, used to find the address a VM
    /// on it reaches the Mac at.
    func defaultNetwork() throws -> SandboxNetwork?
    /// Where to run the proxy for a locked plan.
    func proxyListen(for plan: NetworkPlan) throws -> ProxyListen
    /// Makes the proxy (already listening on `port`) reachable from the
    /// sandbox network and returns the address to put in HTTPS_PROXY.
    func attachProxy(port: UInt16, plan: NetworkPlan) throws -> ProxyRoute
    /// True if a container with this name is running.
    func isRunning(_ name: String) -> Bool
    /// Stops a container (best effort).
    func stop(_ name: String)
    /// The command a person would run to stop it.
    func stopHint(_ name: String) -> String
    /// Labels of a local image, or nil if there is no such image.
    func imageLabels(_ tag: String) -> [String: String]?
    /// Builds an image with labels, handing each output line to `onLine`.
    func buildImage(containerfile: URL, context: URL, tag: String, labels: [String: String],
                    onLine: @escaping @Sendable (String) -> Void) throws
}

extension SandboxBackend {
    /// VM backends: listen everywhere, accept only the VM network, and let
    /// the VM reach the proxy at the network's gateway (the host).
    public func proxyListen(for plan: NetworkPlan) throws -> ProxyListen {
        ProxyListen(bindHost: nil, clientSubnets: plan.clientSubnet.map { [$0] } ?? [])
    }

    public func attachProxy(port: UInt16, plan: NetworkPlan) throws -> ProxyRoute {
        guard let host = plan.proxyHost else { throw MudroomError.invalid("no proxy address for this network") }
        return ProxyRoute(host: host, port: port)
    }

    public func isRunning(_ name: String) -> Bool { false }
    public func stop(_ name: String) {}
    public func stopHint(_ name: String) -> String { "stop the container \(name)" }
    public func imageLabels(_ tag: String) -> [String: String]? { nil }
    public func buildImage(containerfile: URL, context: URL, tag: String, labels: [String: String],
                           onLine: @escaping @Sendable (String) -> Void) throws {
        try buildImage(containerfile: containerfile, context: context, tag: tag)
    }
}

public enum AgentEnvironment {
    /// Credentials the agents need. Passed through only when set on the host.
    public static let passthrough = [
        "ANTHROPIC_API_KEY",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "OPENAI_API_KEY",
        "GEMINI_API_KEY",
    ]

    public static func present(in env: [String: String] = ProcessInfo.processInfo.environment,
                               names: [String] = passthrough) -> [String] {
        names.filter { env[$0].map { !$0.isEmpty } ?? false }
    }

    /// Credential and provider-key variables that are set in the terminal
    /// the app starts sessions in (a zsh login shell that also reads
    /// ~/.zshrc, as `TerminalLauncher` writes it). An app opened from the
    /// Finder doesn't have them in its own environment. Names only: no
    /// value leaves the shell. Empty if the shell takes longer than
    /// `timeout`.
    public static func terminalNames(shell: String = "/bin/zsh", timeout: TimeInterval = 5,
                                     environment: [String: String] = [:]) -> [String] {
        let names = (passthrough + APIKeys.providers.map(\.variable)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let script = "[[ -f ~/.zshrc ]] && source ~/.zshrc >/dev/null 2>&1; for n in \(names.joined(separator: " ")); do [[ -n ${(P)n} ]] && print -r -- $n; done; true"
        guard FileManager.default.isExecutableFile(atPath: shell),
              let out = try? ProcessRunner.capture(shell, ["-l", "-c", script], environment: environment, timeout: timeout), out.status == 0 else { return [] }
        let set = Set(out.stdout.split(whereSeparator: \.isNewline).map(String.init))
        return names.filter(set.contains)
    }
}

/// Runs the agent through Apple's `container` CLI (github.com/apple/container),
/// which starts each container in its own lightweight Linux VM.
public struct AppleContainerBackend: SandboxBackend {
    public let name = "apple-container"
    public let executable: String?

    public init(executable: String? = ProcessRunner.which("container")) {
        self.executable = executable
    }

    public static let defaultImage = AgentBaseImage.tag

    public func checkAvailable() throws {
        guard let exe = executable else {
            throw MudroomError.backendUnavailable(
                "the `container` CLI was not found. Install it with `brew install container`, then run `container system start`.")
        }
        let current = try ProcessRunner.capture(exe, ["system", "status"], timeout: 30)
        if current.timedOut {
            throw MudroomError.backendUnavailable(
                "the VM runtime isn't answering (`container system status` hung for 30 seconds). Repair it with `mudroom setup --repair-network` or the Repair button in Setup.")
        }
        if current.status == 0 { return }
        // The services stop after a reboot or `container system stop`.
        // Starting them takes a few seconds, so do it rather than fail.
        FileHandle.standardError.write(Data("mudroom: starting the VM runtime...\n".utf8))
        let help = (try? ProcessRunner.capture(exe, ["system", "start", "--help"], timeout: 15))?.stdout ?? ""
        let started = try ProcessRunner.capture(exe, NetworkRepair.startArguments(help: help), timeout: 120)
        let status = try ProcessRunner.capture(exe, ["system", "status"], timeout: 30)
        if status.status != 0 {
            let detail = (started.stderr + started.stdout + status.stderr + status.stdout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MudroomError.backendUnavailable(
                "container services are not running and could not be started (\(detail)). Open Mudroom > Setup and click Start.")
        }
    }

    /// The exact `container run` arguments for a spec. Kept separate so it can
    /// be unit tested without a VM.
    public static func runArguments(for spec: SandboxSpec) -> [String] {
        var args = ["run", "--rm", "--name", spec.name]
        if spec.interactive { args.append("--interactive") }
        if spec.tty { args.append("--tty") }
        args += ["--mount", "type=bind,source=\(spec.workspace.path),target=\(spec.guestWorkspace)"]
        for m in spec.mounts {
            args += ["--mount", "type=bind,source=\(m.source.path),target=\(m.target)" + (m.readOnly ? ",readonly" : "")]
        }
        args += ["--workdir", spec.guestWorkspace]
        for name in spec.passedNames {
            // `-e NAME` makes `container` copy the value from its own
            // environment, so secrets never appear in argv or `ps`.
            args += ["--env", name]
        }
        for key in spec.environment.keys.sorted() {
            args += ["--env", "\(key)=\(spec.environment[key]!)"]
        }
        if let network = spec.network { args += ["--network", network] }
        if let cpus = spec.cpus { args += ["--cpus", String(cpus)] }
        if let memory = spec.memory { args += ["--memory", memory] }
        args.append(spec.image)
        args += spec.command
        return args
    }

    public func run(_ spec: SandboxSpec) throws -> Int32 {
        try checkAvailable()
        return try ProcessRunner.runAttached(executable!, Self.runArguments(for: spec), environment: spec.secretEnvironment)
    }

    public func isRunning(_ name: String) -> Bool {
        guard let exe = executable, let out = try? ProcessRunner.capture(exe, ["inspect", name], timeout: 30), out.status == 0 else { return false }
        return Self.parseRunning(Data(out.stdout.utf8))
    }

    /// `container inspect` JSON: [{"status": {"state": "running"}}] (or a
    /// plain "running" string in older releases).
    public static func parseRunning(_ data: Data) -> Bool {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return arr.contains { o in
            if let s = o["status"] as? String { return s == "running" }
            return (o["status"] as? [String: Any])?["state"] as? String == "running"
        }
    }

    /// Stops and removes the container. `run --rm` removes it on its own,
    /// except when the `container run` process was killed; then it stays
    /// behind, stopped.
    public func stop(_ name: String) {
        guard let exe = executable else { return }
        _ = try? ProcessRunner.capture(exe, ["stop", name], timeout: 30)
        _ = try? ProcessRunner.capture(exe, ["rm", name], timeout: 30)
    }

    public func stopHint(_ name: String) -> String { "container stop \(name)" }

    public static let networkName = "mudroom-hostonly"

    public func hostOnlyNetwork() throws -> SandboxNetwork? {
        try checkAvailable()
        let exe = executable!
        if let net = try inspectNetwork(Self.networkName, exe) { return net.hostOnly ? net : nil }
        let created = try ProcessRunner.capture(exe, [
            "network", "create", "--internal", "--label", "io.github.kernel-hunter.mudroom=1", Self.networkName,
        ])
        if created.status != 0 {
            // Older runtimes without --internal: no host-only networks.
            if (created.stderr + created.stdout).contains("internal") { return nil }
            // Lost a race with another `mudroom start`: fine if it exists now.
            if let net = try inspectNetwork(Self.networkName, exe) { return net.hostOnly ? net : nil }
            throw MudroomError.commandFailed("container network create", created.status, created.stderr)
        }
        return try inspectNetwork(Self.networkName, exe).flatMap { $0.hostOnly ? $0 : nil }
    }

    public func defaultNetwork() throws -> SandboxNetwork? {
        try checkAvailable()
        return try inspectNetwork("default", executable!)
    }

    func inspectNetwork(_ name: String, _ exe: String) throws -> SandboxNetwork? {
        let out = try ProcessRunner.capture(exe, ["network", "inspect", name])
        guard out.status == 0 else { return nil }
        return Self.parseNetwork(Data(out.stdout.utf8))
    }

    /// Parses `container network inspect` JSON.
    public static func parseNetwork(_ data: Data) -> SandboxNetwork? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let obj = arr.first,
              let config = obj["configuration"] as? [String: Any], let status = obj["status"] as? [String: Any],
              let name = (config["name"] as? String) ?? (obj["id"] as? String),
              let gateway = status["ipv4Gateway"] as? String, let subnet = status["ipv4Subnet"] as? String
        else { return nil }
        return SandboxNetwork(name: name, hostOnly: (config["mode"] as? String) == "hostOnly",
                              gateway: gateway, subnet: subnet)
    }

    public func capture(_ spec: SandboxSpec) throws -> CapturedOutput {
        try checkAvailable()
        return try ProcessRunner.capture(executable!, ["run", "--progress", "none"] + Self.runArguments(for: spec).dropFirst(),
                                         environment: spec.secretEnvironment, timeout: spec.timeout)
    }

    public func buildImage(containerfile: URL, context: URL, tag: String) throws {
        try checkAvailable()
        let status = try ProcessRunner.runAttached(executable!, [
            "build", "--tag", tag, "--file", containerfile.path, context.path,
        ])
        if status != 0 { throw MudroomError.commandFailed("container build", status, "") }
    }

    public func buildImage(containerfile: URL, context: URL, tag: String, labels: [String: String],
                           onLine: @escaping @Sendable (String) -> Void) throws {
        try checkAvailable()
        var args = ["build", "--progress", "plain", "--tag", tag]
        for k in labels.keys.sorted() { args += ["--label", "\(k)=\(labels[k]!)"] }
        args += ["--file", containerfile.path, context.path]
        let r = try ProcessRunner.stream(executable!, args, onLine: onLine)
        if r.status != 0 { throw MudroomError.commandFailed("container build", r.status, r.tail.suffix(12).joined(separator: "\n")) }
    }

    public func imageLabels(_ tag: String) -> [String: String]? {
        guard let exe = executable, let out = try? ProcessRunner.capture(exe, ["image", "inspect", tag]), out.status == 0 else { return nil }
        return AgentBaseImage.parseLabels(Data(out.stdout.utf8))
    }
}
