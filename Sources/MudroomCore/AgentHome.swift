import Foundation

/// A per-agent config directory that outlives sessions, so a login done once
/// keeps working:
///
///     <store>/agents/<id>/home   ->   /home/node/.claude   (Claude Code)
///                                     /home/node/.codex    (Codex)
///                                     /home/node/.gemini   (Gemini CLI)
///
/// It is Mudroom's own directory. The user's real ~/.claude (and friends) is
/// never mounted: a session can read and change this copy, and nothing else.
public struct AgentHome: Sendable, Equatable {
    public let agent: String
    public let hostDirectory: URL
    public let guestPath: String
    /// Variables that point the agent at `guestPath`.
    public let environment: [String: String]

    public init?(store: SessionStore, agent: String) {
        let guest: String
        var env: [String: String] = [:]
        switch agent {
        case "claude":
            guest = "/home/node/.claude"
            // Keeps .claude.json inside the mounted directory too.
            env["CLAUDE_CONFIG_DIR"] = guest
        case "codex":
            guest = "/home/node/.codex"
            env["CODEX_HOME"] = guest
        case "gemini":
            guest = "/home/node/.gemini"
        default:
            return nil
        }
        self.agent = agent
        hostDirectory = store.root
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(agent, isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
        guestPath = guest
        environment = env
    }

    public func create() throws {
        try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        chmod(hostDirectory.path, 0o700)
    }

    public var mount: SandboxMount { SandboxMount(source: hostDirectory, target: guestPath) }

    /// True once the directory holds anything (a login, settings, history).
    public var isPopulated: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: hostDirectory.path)) ?? []).contains { $0 != ".DS_Store" }
    }
}

extension AgentPreset {
    /// Command that signs the agent in from inside the VM. The flows print a
    /// URL to open on the Mac and take a code back (or use a device code), so
    /// no browser or callback port is needed in the VM.
    public var loginCommand: [String] {
        switch id {
        case "claude": ["claude", "auth", "login"]
        case "codex": ["codex", "login", "--device-auth"]
        // Gemini CLI signs in from its first-run screen; NO_BROWSER makes it
        // print the URL and ask for the code.
        case "gemini": ["gemini"]
        default: command
        }
    }

    /// Non-secret variables set in the VM for this agent.
    public var environment: [String: String] {
        switch id {
        // No auto-updater, telemetry or error reporting: fewer hosts to allow.
        case "claude": ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]
        case "gemini": ["NO_BROWSER": "true"]
        default: [:]
        }
    }

    public static func find(_ id: String) -> AgentPreset? {
        all.first { $0.id == id || $0.name.lowercased() == id.lowercased() }
    }

    /// The preset a session was started with, from its recorded agent name
    /// or, failing that, the command's program name.
    public static func matching(agent: String?, command: [String]) -> AgentPreset? {
        if let agent, let p = all.first(where: { $0.name == agent }) { return p }
        guard let exe = command.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) else { return nil }
        return all.first { $0.command.first == exe }
    }
}
