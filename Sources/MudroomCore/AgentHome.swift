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
        // The claude.ai connectors (MCP through mcp-proxy.anthropic.com)
        // stay off too: the locked network blocks them, and Claude retries.
        case "claude": ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "ENABLE_CLAUDEAI_MCP_SERVERS": "false"]
        // Gemini CLI turns --yolo off in a folder it doesn't trust, and
        // headless runs (-p) refuse to start there; /workspace is a copy.
        case "gemini": ["NO_BROWSER": "true", "GEMINI_CLI_TRUST_WORKSPACE": "true"]
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
            // Whatever way the agent was signed in, skip Claude's first-run
            // screens: without hasCompletedOnboarding it asks to sign in again.
            try seedClaudeOnboarding()
            try Cloner.cloneTree(from: hostDirectory, to: copy)
            chmod(copy.path, 0o700)
        }
        return SandboxMount(source: copy, target: guestPath)
    }

    /// Carries credentials (and Claude's account keys) from a session's
    /// copy back to the shared directory. Files are read without
    /// following symlinks and must be JSON objects. Returns the files that
    /// changed the sign-in.
    @discardableResult
    public func syncBack(from handle: SessionHandle) -> [String] {
        let copy = handle.agentHomeCopy
        var updated = syncCredentials(from: copy)
        if agent == "claude",
           let data = try? SafeFS.readBeneath(copy, ".claude.json", limit: 8 << 20),
           let theirs = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let dest = hostDirectory.appendingPathComponent(".claude.json")
            var ours = ((try? Data(contentsOf: dest)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            var changed = false
            var accountChanged = false
            for key in Self.claudeAccountKeys {
                guard let v = theirs[key] else { continue }
                if let old = ours[key], NSDictionary(dictionary: [key: old]).isEqual(to: [key: v]) { continue }
                ours[key] = v
                changed = true
                if key == "oauthAccount" { accountChanged = true }
            }
            // Claude Code writes userID, theme and onboarding fields on every
            // first start; those are kept but are not a sign-in.
            if changed, let out = try? JSONSerialization.data(withJSONObject: ours, options: [.prettyPrinted, .sortedKeys]),
               (try? Self.writePrivate(out, to: dest)) != nil, accountChanged {
                updated.append(".claude.json")
            }
        }
        return updated
    }

    /// Copies the sign-in files from `directory` to the shared directory,
    /// but only ones newer than the shared copy. Claude rotates its refresh
    /// token, so an older file would undo a newer session's refresh and
    /// leave every later session signed out.
    @discardableResult
    func syncCredentials(from directory: URL) -> [String] {
        var updated: [String] = []
        for name in credentialFiles {
            guard let data = try? SafeFS.readBeneath(directory, name, limit: 1 << 20),
                  let theirs = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let dest = hostDirectory.appendingPathComponent(name)
            if let current = try? Data(contentsOf: dest) {
                if current == data { continue }
                let ours = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any]
                if let a = Self.expiry(theirs), let b = ours.flatMap(Self.expiry) {
                    if a <= b { continue }
                } else if Self.modified(directory.appendingPathComponent(name)) <= Self.modified(dest) {
                    continue
                }
            }
            if (try? Self.writePrivate(data, to: dest)) != nil { updated.append(name) }
        }
        return updated
    }

    /// Before a new session: takes the newest sign-in left in any other
    /// session's copy, running or not, in case it refreshed the token.
    public func adoptNewestCredentials(from sessions: [SessionHandle]) {
        for h in sessions where FileManager.default.fileExists(atPath: h.agentHomeCopy.path) {
            syncCredentials(from: h.agentHomeCopy)
        }
    }

    private static func expiry(_ json: [String: Any]) -> Double? {
        ((json["claudeAiOauth"] as? [String: Any])?["expiresAt"] as? NSNumber)?.doubleValue
    }

    private static func modified(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
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
