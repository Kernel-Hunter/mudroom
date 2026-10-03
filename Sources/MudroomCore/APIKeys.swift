import Foundation

/// Model-provider API keys kept by Mudroom (Keychain on macOS, 0600 files
/// elsewhere). Sessions get them as environment variables, by name only:
/// the value never goes on a command line.
public enum APIKeys {
    public struct Provider: Sendable, Equatable, Identifiable {
        public var id: String { variable }
        public let variable: String
        public let name: String
        /// Hosts allowed in locked mode once this key is set.
        public let hosts: [String]
    }

    public static let providers: [Provider] = [
        Provider(variable: "ANTHROPIC_API_KEY", name: "Anthropic", hosts: ["api.anthropic.com"]),
        Provider(variable: "OPENAI_API_KEY", name: "OpenAI", hosts: ["api.openai.com"]),
        Provider(variable: "GEMINI_API_KEY", name: "Google Gemini", hosts: ["generativelanguage.googleapis.com"]),
        Provider(variable: "OPENROUTER_API_KEY", name: "OpenRouter", hosts: ["openrouter.ai"]),
        Provider(variable: "DEEPSEEK_API_KEY", name: "DeepSeek", hosts: ["api.deepseek.com"]),
        Provider(variable: "GROQ_API_KEY", name: "Groq", hosts: ["api.groq.com"]),
        Provider(variable: "MISTRAL_API_KEY", name: "Mistral", hosts: ["api.mistral.ai"]),
        Provider(variable: "TOGETHER_API_KEY", name: "Together AI", hosts: ["api.together.xyz"]),
        Provider(variable: "FIREWORKS_API_KEY", name: "Fireworks", hosts: ["api.fireworks.ai"]),
        Provider(variable: "XAI_API_KEY", name: "xAI", hosts: ["api.x.ai"]),
    ]

    public static func provider(_ variable: String) -> Provider? { providers.first { $0.variable == variable } }

    /// Store account for a key. Agent tokens use the bare agent id.
    static let prefix = "env."

    public static func account(_ variable: String) -> String { prefix + variable }

    /// Upper-case letters, digits and underscores, not starting with a
    /// digit, at most 64 long. Names the agent's own variables (and a few
    /// that would change how the VM behaves) are refused.
    public static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), let first = name.unicodeScalars.first,
              !("0"..."9").contains(first),
              name.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" })
        else { return false }
        return !reserved.contains(name) && !name.hasPrefix("MUDROOM_")
    }

    static let reserved: Set<String> = [
        "PATH", "HOME", "USER", "SHELL", "TERM", "BROWSER", "LD_PRELOAD", "LD_LIBRARY_PATH", "NODE_OPTIONS",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "NODE_USE_ENV_PROXY", "CLAUDE_CONFIG_DIR", "CODEX_HOME",
        "CLAUDE_CODE_OAUTH_TOKEN",
    ]

    /// Names of the keys in the store, sorted.
    public static func storedNames(_ store: AgentTokenStore) -> [String] {
        ((try? store.accounts()) ?? []).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            .filter(isValidName).sorted()
    }

    public static func read(_ name: String, from store: AgentTokenStore) throws -> String? {
        try store.read(account(name))
    }

    public static func write(_ name: String, _ value: String, to store: AgentTokenStore) throws {
        guard isValidName(name) else { throw MudroomError.invalid("\(name) is not a usable variable name (A-Z, 0-9 and _)") }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, v.count <= 8192, !v.contains(where: { $0.isNewline }) else {
            throw MudroomError.invalid("that doesn't look like an API key")
        }
        try store.write(account(name), v)
    }

    @discardableResult
    public static func delete(_ name: String, from store: AgentTokenStore) throws -> Bool {
        try store.delete(account(name))
    }

    /// Hosts to allow for the keys that are set (stored or in the shell).
    public static func hosts(for names: some Sequence<String>) -> [String] {
        var out: [String] = []
        for n in names { for h in provider(n)?.hosts ?? [] where !out.contains(h) { out.append(h) } }
        return out
    }
}

extension AgentPreset {
    /// The API key variables this agent uses, or nil for any of them
    /// (agents that work with many providers, and custom commands).
    public var apiKeys: [String]? {
        switch id {
        case "claude": ["ANTHROPIC_API_KEY"]
        case "codex": ["OPENAI_API_KEY"]
        case "gemini": ["GEMINI_API_KEY"]
        default: nil
        }
    }

    /// True for agents that can talk to many providers.
    public var isMultiProvider: Bool { apiKeys == nil }

    /// Keys Aider picks its default model from when no model is given.
    static let aiderDefaultModelKeys = ["OPENROUTER_API_KEY", "ANTHROPIC_API_KEY", "DEEPSEEK_API_KEY", "OPENAI_API_KEY",
                                        "GEMINI_API_KEY", "VERTEXAI_PROJECT"]
    /// Aider's own switches that choose a model.
    static let aiderModelFlags: Set<String> = ["--opus", "--sonnet", "--haiku", "--4", "-4", "--4o", "--mini", "--4-turbo",
                                               "--35turbo", "--deepseek", "--o1-mini", "--o1-preview"]

    /// Why Aider can't start, or nil. With no model and none of the keys
    /// it picks one from, Aider offers an OpenRouter sign-in (accepted by
    /// --yes-always) and waits five minutes for a callback on the VM's
    /// localhost that no browser can reach. A project .aider.conf.yml or
    /// .env may name a model or key, so those are left to Aider.
    public static func aiderModelProblem(command: [String], keys: Set<String>, workspace: URL) -> String? {
        guard let exe = command.first, URL(fileURLWithPath: exe).lastPathComponent == "aider" else { return nil }
        if command.dropFirst().contains(where: { $0 == "--model" || $0.hasPrefix("--model=") || aiderModelFlags.contains($0) }) { return nil }
        if aiderDefaultModelKeys.contains(where: keys.contains) { return nil }
        for f in [".aider.conf.yml", ".env"] where FileManager.default.fileExists(atPath: workspace.appendingPathComponent(f).path) {
            return nil
        }
        return """
            Aider has no model: no --model, and none of the keys it picks one from \
            (\(aiderDefaultModelKeys.dropLast().joined(separator: ", "))) reaches the session. It would wait five \
            minutes for an OpenRouter sign-in that can't finish inside the VM. Add a key (mudroom keys set \
            OPENROUTER_API_KEY), or name a model, e.g. with local models on: aider --model ollama_chat/qwen2.5:7b-instruct
            """
    }
}

/// The secrets a session gets, worked out from what is stored and what the
/// shell already passes through.
public enum SessionSecrets {
    /// Variable name -> value. `passthrough` are names already passed from
    /// the shell (those win; they are not duplicated). A Claude sign-in
    /// token keeps a stored ANTHROPIC_API_KEY out, since Claude Code would
    /// otherwise stop to ask which one to use.
    public static func resolve(preset: AgentPreset?, store: AgentTokenStore?, passthrough: [String]) -> [String: String] {
        guard let store else { return [:] }
        var out: [String: String] = [:]
        if let id = preset?.id, let name = AgentToken.variable(for: id), !passthrough.contains(name),
           let token = try? store.read(id), !token.isEmpty {
            out[name] = token
        }
        let wanted = preset?.apiKeys
        for name in APIKeys.storedNames(store) {
            if let wanted, !wanted.contains(name) { continue }
            if passthrough.contains(name) || out[name] != nil { continue }
            if name == "ANTHROPIC_API_KEY", out["CLAUDE_CODE_OAUTH_TOKEN"] != nil || passthrough.contains("CLAUDE_CODE_OAUTH_TOKEN") { continue }
            if let v = try? APIKeys.read(name, from: store), !v.isEmpty { out[name] = v }
        }
        return out
    }
}
