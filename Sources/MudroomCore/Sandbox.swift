import Darwin
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

public protocol SandboxBackend: Sendable {
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
}

public enum AgentEnvironment {
    /// Credentials the agents need. Passed through only when set on the host.
    public static let passthrough = [
        "ANTHROPIC_API_KEY",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "OPENAI_API_KEY",
        "GEMINI_API_KEY",
    ]

    public static func present(in env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        passthrough.filter { env[$0].map { !$0.isEmpty } ?? false }
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
        let status = try ProcessRunner.capture(exe, ["system", "status"])
        if status.status != 0 {
            let detail = (status.stderr + status.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MudroomError.backendUnavailable(
                "container services are not running (\(detail)). Start them with `container system start`.")
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
        for name in spec.environmentNames {
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
        return try ProcessRunner.runAttached(executable!, Self.runArguments(for: spec))
    }

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
        return try ProcessRunner.capture(executable!, ["run", "--progress", "none"] + Self.runArguments(for: spec).dropFirst())
    }

    public func buildImage(containerfile: URL, context: URL, tag: String) throws {
        try checkAvailable()
        let status = try ProcessRunner.runAttached(executable!, [
            "build", "--tag", tag, "--file", containerfile.path, context.path,
        ])
        if status != 0 { throw MudroomError.commandFailed("container build", status, "") }
    }
}
