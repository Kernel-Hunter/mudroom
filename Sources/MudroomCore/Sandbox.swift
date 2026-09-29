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

    public init(name: String, image: String, workspace: URL, guestWorkspace: String = "/workspace",
                command: [String], environmentNames: [String] = [], interactive: Bool = true,
                tty: Bool = false, cpus: Int? = nil, memory: String? = nil) {
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
    }
}

public protocol SandboxBackend: Sendable {
    var name: String { get }
    /// Throws `MudroomError.backendUnavailable` with a human-readable reason.
    func checkAvailable() throws
    /// Runs the agent attached to this terminal and returns its exit status.
    func run(_ spec: SandboxSpec) throws -> Int32
    /// Builds an image from a Containerfile.
    func buildImage(containerfile: URL, context: URL, tag: String) throws
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
        args += ["--workdir", spec.guestWorkspace]
        for name in spec.environmentNames {
            // `-e NAME` makes `container` copy the value from its own
            // environment, so secrets never appear in argv or `ps`.
            args += ["--env", name]
        }
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

    public func buildImage(containerfile: URL, context: URL, tag: String) throws {
        try checkAvailable()
        let status = try ProcessRunner.runAttached(executable!, [
            "build", "--tag", tag, "--file", containerfile.path, context.path,
        ])
        if status != 0 { throw MudroomError.commandFailed("container build", status, "") }
    }
}
