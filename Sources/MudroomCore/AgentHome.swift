#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
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
        // History files go to the home directory, not the project copy.
        case "aider": ["AIDER_CHAT_HISTORY_FILE": "/home/node/.aider.chat.history.md",
                       "AIDER_INPUT_HISTORY_FILE": "/home/node/.aider.input.history"]
        // No self-update, no LSP downloads, and tools run without asking
        // (the review happens afterwards).
        case "opencode": ["OPENCODE_DISABLE_AUTOUPDATE": "1", "OPENCODE_DISABLE_LSP_DOWNLOAD": "true",
                          "OPENCODE_CONFIG_CONTENT": #"{"autoupdate":false,"permission":{"edit":"allow","bash":"allow","webfetch":"allow"}}"#]
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

extension AgentHome {
    /// Files that hold the sign-in. Only these are carried back from a
    /// session's copy (token refreshes, a login done inside a session).
    public var credentialFiles: [String] {
        switch agent {
        case "claude": [".credentials.json"]
        case "codex": ["auth.json"]
        case "gemini": ["oauth_creds.json", "google_accounts.json"]
        default: []
        }
    }

    /// Account keys of Claude Code's .claude.json carried back too (so a
    /// login sticks), and nothing else from it: MCP servers, hooks and
    /// project settings a session writes stay in that session.
    static let claudeAccountKeys = ["oauthAccount", "hasCompletedOnboarding", "lastOnboardingVersion", "userID",
                                    "theme", "hasAvailableSubscription"]

    /// True if a login has been stored in the shared directory.
    public var hasCredentials: Bool {
        credentialFiles.contains { FileManager.default.fileExists(atPath: hostDirectory.appendingPathComponent($0).path) }
    }

    /// The copy of this directory a session runs with: `<session>/agent-home`,
    /// cloned from the shared one the first time. What a session writes
    /// there (settings, hooks, MCP servers, history) never reaches other
    /// sessions or projects.
    public func sessionCopy(for handle: SessionHandle) throws -> SandboxMount {
        let copy = handle.agentHomeCopy
        if !FileManager.default.fileExists(atPath: copy.path) {
            try create()
            try Cloner.cloneTree(from: hostDirectory, to: copy)
            chmod(copy.path, 0o700)
        }
        return SandboxMount(source: copy, target: guestPath)
    }

    /// Carries credentials (and Claude's account keys) from a session's
    /// copy back to the shared directory. Files are read without
    /// following symlinks and must be JSON objects.
    @discardableResult
    public func syncBack(from handle: SessionHandle) -> [String] {
        let copy = handle.agentHomeCopy
        var updated: [String] = []
        for name in credentialFiles {
            guard let data = try? SafeFS.readBeneath(copy, name, limit: 1 << 20),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { continue }
            let dest = hostDirectory.appendingPathComponent(name)
            if (try? Data(contentsOf: dest)) == data { continue }
            if (try? Self.writePrivate(data, to: dest)) != nil { updated.append(name) }
        }
        if agent == "claude",
           let data = try? SafeFS.readBeneath(copy, ".claude.json", limit: 8 << 20),
           let theirs = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let dest = hostDirectory.appendingPathComponent(".claude.json")
            var ours = ((try? Data(contentsOf: dest)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            var changed = false
            for key in Self.claudeAccountKeys {
                guard let v = theirs[key] else { continue }
                if let old = ours[key], NSDictionary(dictionary: [key: old]).isEqual(to: [key: v]) { continue }
                ours[key] = v
                changed = true
            }
            if changed, let out = try? JSONSerialization.data(withJSONObject: ours, options: [.prettyPrinted, .sortedKeys]),
               (try? Self.writePrivate(out, to: dest)) != nil {
                updated.append(".claude.json")
            }
        }
        return updated
    }

    static func writePrivate(_ data: Data, to dest: URL) throws {
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".mudroom-\(UUID().uuidString.prefix(8))")
        try data.write(to: tmp)
        chmod(tmp.path, 0o600)
        guard rename(tmp.path, dest.path) == 0 else {
            unlink(tmp.path)
            throw MudroomError.posix("rename", dest.path, errno)
        }
    }
}
