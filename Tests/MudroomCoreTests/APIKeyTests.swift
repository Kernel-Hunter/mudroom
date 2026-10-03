#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import Testing
@testable import MudroomCore

@Suite("API keys")
struct APIKeyTests {
    @Test("variable names: upper-case, digits, underscores; system and Mudroom names refused")
    func names() {
        for ok in ["OPENROUTER_API_KEY", "MY_KEY2", "_X"] { #expect(APIKeys.isValidName(ok), "\(ok)") }
        for bad in ["", "lower", "1ABC", "A-B", "A B", "PATH", "HTTPS_PROXY", "LD_PRELOAD", "MUDROOM_HOME", "CLAUDE_CODE_OAUTH_TOKEN",
                    String(repeating: "A", count: 65)] {
            #expect(!APIKeys.isValidName(bad), "\(bad)")
        }
    }

    @Test("keys are stored by name and listed without reading values")
    func store() throws {
        let tmp = try TempDir()
        let tokens = FileTokenStore(root: tmp.url)
        try APIKeys.write("OPENROUTER_API_KEY", "  sk-or-v1-abc123  \n", to: tokens)
        try APIKeys.write("GROQ_API_KEY", "gsk_123", to: tokens)
        try tokens.write("claude", fakeToken)
        #expect(APIKeys.storedNames(tokens) == ["GROQ_API_KEY", "OPENROUTER_API_KEY"])
        #expect(try APIKeys.read("OPENROUTER_API_KEY", from: tokens) == "sk-or-v1-abc123")
        #expect(tokens.contains("claude") && tokens.contains("env.GROQ_API_KEY") && !tokens.contains("codex"))
        #expect(throws: MudroomError.self) { try APIKeys.write("bad name", "v", to: tokens) }
        #expect(throws: MudroomError.self) { try APIKeys.write("X_KEY", "two\nlines", to: tokens) }
        #expect(try APIKeys.delete("GROQ_API_KEY", from: tokens))
        #expect(APIKeys.storedNames(tokens) == ["OPENROUTER_API_KEY"])
    }

    @Test("sessions get keys by name only: the right ones per agent, shell values win, no values in argv")
    func injection() throws {
        let tmp = try TempDir()
        let tokens = FileTokenStore(root: tmp.url)
        try tokens.write("claude", fakeToken)
        try APIKeys.write("ANTHROPIC_API_KEY", "sk-ant-api03-STOREDKEYSTOREDKEY", to: tokens)
        try APIKeys.write("OPENROUTER_API_KEY", "sk-or-v1-STOREDVALUE", to: tokens)
        try APIKeys.write("OPENAI_API_KEY", "sk-proj-STOREDOPENAI", to: tokens)

        // Claude: its token, and not the stored Anthropic key (Claude Code would ask which to use).
        let claude = SessionSecrets.resolve(preset: .claude, store: tokens, passthrough: [])
        #expect(claude == ["CLAUDE_CODE_OAUTH_TOKEN": fakeToken])
        // Codex: only the OpenAI key.
        #expect(SessionSecrets.resolve(preset: .codex, store: tokens, passthrough: []).keys.sorted() == ["OPENAI_API_KEY"])
        // Aider: every provider key; one set in the shell is passed from there instead.
        let aider = SessionSecrets.resolve(preset: .aider, store: tokens, passthrough: ["OPENAI_API_KEY"])
        #expect(aider.keys.sorted() == ["ANTHROPIC_API_KEY", "OPENROUTER_API_KEY"])
        #expect(SessionSecrets.resolve(preset: .aider, store: nil, passthrough: []).isEmpty)

        var spec = SandboxSpec(name: "s", image: "i", workspace: tmp.url, command: ["aider"], environmentNames: ["OPENAI_API_KEY"])
        spec.secretEnvironment = aider
        for args in [AppleContainerBackend.runArguments(for: spec),
                     DockerBackend.runArguments(for: spec, host: .init(isLinux: true, uid: 1000, gid: 1000, rootlessPodman: false))] {
            let line = args.joined(separator: " ")
            #expect(!line.contains("STORED") && !line.contains("sk-"))
            for name in ["OPENROUTER_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"] { #expect(args.contains(name)) }
        }
    }

    @Test("a provider's hosts are allowed once its key is set, for agents that use many providers")
    func autoGroups() {
        let c = ProjectConfig(projectPath: "/p")
        let keys = ["OPENROUTER_API_KEY", "DEEPSEEK_API_KEY", "SOME_CUSTOM_KEY"]
        let aider = c.allowlist(agent: "aider", keys: keys)
        #expect(aider.allows("openrouter.ai") && aider.allows("api.deepseek.com"))
        #expect(!aider.allows("api.groq.com") && !aider.allows("api.x.ai"))
        #expect(c.allowlist(agent: "opencode", keys: ["XAI_API_KEY"]).allows("api.x.ai"))
        #expect(c.allowlist(agent: "opencode", keys: []).allows("models.dev"))
        // opencode 1.18 fetches its model catalog from here.
        #expect(c.allowlist(agent: "opencode", keys: []).allows("models.opencode.ai"))
        #expect(c.allowlist(agent: nil, keys: ["GROQ_API_KEY"]).allows("api.groq.com"))
        // Single-provider agents keep their own hosts only.
        let claude = c.allowlist(agent: "claude", keys: keys)
        #expect(claude.allows("api.anthropic.com") && !claude.allows("openrouter.ai"))
        // Agent hosts switched off: no provider hosts either.
        var off = c
        off.includeAgentHosts = false
        #expect(!off.allowlist(agent: "aider", keys: keys).allows("openrouter.ai"))
        // Every known provider has a host.
        for p in APIKeys.providers { #expect(!p.hosts.isEmpty && p.hosts.allSatisfy { HostPattern($0) != nil }) }
    }

    @Test("sign-in status comes from Mudroom's own stores, without reading secrets")
    func signInStatus() throws {
        let tmp = try TempDir()
        let store = SessionStore(root: tmp.path("store"))
        let tokens = FileTokenStore(root: tmp.path("tokens"))
        #expect(!SignInStatus.check(.claude, store: store, tokens: tokens, environment: [:]).isSignedIn)
        #expect(!SignInStatus.check(.aider, store: store, tokens: tokens, environment: [:]).isSignedIn)
        try tokens.write("claude", fakeToken)
        #expect(SignInStatus.check(.claude, store: store, tokens: tokens, environment: [:]).method == "Claude account")
        try APIKeys.write("OPENROUTER_API_KEY", "v", to: tokens)
        #expect(SignInStatus.check(.aider, store: store, tokens: tokens, environment: [:]).method == "OpenRouter key")
        #expect(SignInStatus.check(.gemini, store: store, tokens: tokens, environment: ["GEMINI_API_KEY": "x"]).method == "API key")
        let codexHome = try #require(AgentHome(store: store, agent: "codex"))
        try write("{}", to: codexHome.hostDirectory.appendingPathComponent("auth.json"))
        #expect(SignInStatus.check(.codex, store: store, tokens: tokens, environment: [:]).method == "ChatGPT login")
    }

    @Test("Aider with no model and no key it picks one from is stopped before it waits on an OpenRouter login")
    func aiderNeedsModel() throws {
        let tmp = try TempDir()
        let aider = AgentPreset.aider.command
        #expect(AgentPreset.aiderModelProblem(command: aider, keys: [], workspace: tmp.url) != nil)
        // Keys Aider can't pick a default from don't help either.
        #expect(AgentPreset.aiderModelProblem(command: aider, keys: ["GROQ_API_KEY"], workspace: tmp.url) != nil)
        #expect(AgentPreset.aiderModelProblem(command: aider, keys: ["OPENROUTER_API_KEY"], workspace: tmp.url) == nil)
        #expect(AgentPreset.aiderModelProblem(command: aider + ["--model", "ollama_chat/q"], keys: [], workspace: tmp.url) == nil)
        #expect(AgentPreset.aiderModelProblem(command: aider + ["--model=ollama_chat/q"], keys: [], workspace: tmp.url) == nil)
        #expect(AgentPreset.aiderModelProblem(command: ["opencode"], keys: [], workspace: tmp.url) == nil)
        // A project config may name the model.
        try write("model: ollama_chat/q\n", to: tmp.path(".aider.conf.yml"))
        #expect(AgentPreset.aiderModelProblem(command: aider, keys: [], workspace: tmp.url) == nil)
    }
}
