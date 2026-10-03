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

@Suite("Agent tokens and sign-in")
struct AgentAuthTests {
    @Test("tokens are stored 0600 and passed to the sandbox by name only, never in argv")
    func tokenByName() throws {
        let tmp = try TempDir()
        let tokens = FileTokenStore(root: tmp.url)
        try tokens.write("claude", "sk-ant-oat01-SECRETSECRETSECRET")
        var st = stat()
        #expect(stat(tokens.url("claude").path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect(try tokens.read("claude") == "sk-ant-oat01-SECRETSECRETSECRET")

        var spec = SandboxSpec(name: "s", image: "i", workspace: tmp.url, command: ["claude"])
        spec.secretEnvironment = ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-SECRETSECRETSECRET"]
        for args in [AppleContainerBackend.runArguments(for: spec),
                     DockerBackend.runArguments(for: spec, host: .init(isLinux: true, uid: 1000, gid: 1000, rootlessPodman: false))] {
            #expect(!args.joined(separator: " ").contains("SECRET"))
            #expect(args.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        }
        // The value reaches the child through its environment.
        let out = try ProcessRunner.capture("/usr/bin/env", [], environment: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-SECRETSECRETSECRET"])
        #expect(out.stdout.contains("CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-SECRETSECRETSECRET"))
        #expect(try tokens.delete("claude"))
        #expect(try tokens.read("claude") == nil)
        #expect(!(try tokens.delete("claude")))
    }

    @Test("a pasted token that the terminal wrapped is put back together")
    func clean() {
        #expect(AgentToken.clean("  sk-ant-oat01-abc\n  │ def_ghi-jkl │\n") == "sk-ant-oat01-abcdef_ghi-jkl")
        #expect(AgentToken.problem("sk-ant-oat01-" + String(repeating: "a", count: 40), agent: "claude") == nil)
        #expect(AgentToken.problem("hello", agent: "claude") != nil)
        #expect(AgentToken.problem(String(repeating: "a", count: 40), agent: "claude") != nil)
        #expect(AgentToken.variable(for: "claude") == "CLAUDE_CODE_OAUTH_TOKEN")
    }

    @Test("a Claude sign-in link with a callback inside the sandbox becomes the manual-code link")
    func claudeLink() throws {
        let raw = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A41679%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile&code_challenge=abc&code_challenge_method=S256&state=xyz"
        let url = try #require(AuthLinkHandoff.prepare(raw))
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(q["redirect_uri"] == "https://platform.claude.com/oauth/code/callback")
        #expect(q["code_challenge_method"] == "S256" && q["state"] == "xyz" && q["code_challenge"] == "abc")
        #expect(url.absoluteString.contains("redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback"))
        // Only https sign-in pages we know are ever opened.
        #expect(AuthLinkHandoff.prepare("https://evil.example/oauth/authorize") == nil)
        #expect(AuthLinkHandoff.prepare("http://claude.ai/oauth/authorize") == nil)
        #expect(AuthLinkHandoff.prepare("https://claude.ai:444/x") == nil)
        #expect(AuthLinkHandoff.prepare("https://auth.openai.com/authorize?redirect_uri=http://localhost:1455/cb") == nil)
        #expect(AuthLinkHandoff.prepare("https://auth.openai.com/codex/device") != nil)
    }

    @Test("the BROWSER script's links reach the host watcher")
    func handoff() throws {
        let tmp = try TempDir()
        let h = try AuthLinkHandoff(directory: tmp.path("handoff"))
        #expect(h.environment["BROWSER"] == "/opt/mudroom/open-url")
        let got = LockedBox<[URL]>([])
        h.start { got.value = got.value + [$0] }
        let urls = tmp.path("handoff/urls")
        let line = "https://claude.ai/oauth/authorize?state=1\nhttps://evil.example/\n"
        let fh = try FileHandle(forWritingTo: urls)
        try fh.write(contentsOf: Data(line.utf8))
        try fh.close()
        for _ in 0..<40 where got.value.isEmpty { usleep(50_000) }
        h.stop()
        #expect(got.value.map(\.host) == ["claude.ai"])
    }

    @Test("a session's agent home is a copy; only the sign-in is carried back")
    func agentHomeCopy() throws {
        let f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        let home = try #require(AgentHome(store: f.store, agent: "claude"))
        try home.create()
        try write(#"{"theme":"dark","mcpServers":{}}"#, to: home.hostDirectory.appendingPathComponent(".claude.json"))
        let mount = try home.sessionCopy(for: f.handle)
        #expect(mount.source == f.handle.agentHomeCopy && mount.target == "/home/node/.claude")
        // Claude's first-run screens are marked done, or it asks to sign in again.
        let seeded = try read(f.handle.agentHomeCopy.appendingPathComponent(".claude.json"))
        #expect(seeded.contains("\"hasCompletedOnboarding\" : true") && seeded.contains("\"mcpServers\""))
        // The session signs in, and also plants a hook and an MCP server.
        try write(#"{"claudeAiOauth":{"accessToken":"t"}}"#, to: f.handle.agentHomeCopy.appendingPathComponent(".credentials.json"))
        try write(#"{"hooks":{"Stop":[{"command":"evil"}]}}"#, to: f.handle.agentHomeCopy.appendingPathComponent("settings.json"))
        try write(#"{"theme":"dark","oauthAccount":{"email":"a@b"},"mcpServers":{"x":{"command":"evil"}}}"#,
                  to: f.handle.agentHomeCopy.appendingPathComponent(".claude.json"))
        let updated = home.syncBack(from: f.handle)
        #expect(Set(updated) == [".credentials.json", ".claude.json"])
        #expect(home.hasCredentials)
        #expect(try !read(home.hostDirectory.appendingPathComponent("settings.json")).contains("evil"))
        let shared = try read(home.hostDirectory.appendingPathComponent(".claude.json"))
        #expect(shared.contains("oauthAccount") && !shared.contains("evil"))
        // A session that only wrote Claude's first-start fields didn't sign in.
        let f3 = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        _ = try home.sessionCopy(for: f3.handle)
        try write(#"{"theme":"light","userID":"u1","oauthAccount":{"email":"a@b"}}"#,
                  to: f3.handle.agentHomeCopy.appendingPathComponent(".claude.json"))
        #expect(home.syncBack(from: f3.handle).isEmpty)
        // A symlinked credentials file in the copy is not followed.
        let f2 = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        _ = try home.sessionCopy(for: f2.handle)
        try FileManager.default.removeItem(at: f2.handle.agentHomeCopy.appendingPathComponent(".credentials.json"))
        symlink("/etc/passwd", f2.handle.agentHomeCopy.appendingPathComponent(".credentials.json").path)
        #expect(home.syncBack(from: f2.handle).isEmpty)
    }

    @Test("a rotated Claude token wins over an older one, in both directions")
    func newestCredentialsWin() throws {
        let f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        let home = try #require(AgentHome(store: f.store, agent: "claude"))
        try home.create()
        let shared = home.hostDirectory.appendingPathComponent(".credentials.json")
        func creds(_ token: String, _ exp: Int) -> String { #"{"claudeAiOauth":{"refreshToken":"\#(token)","expiresAt":\#(exp)}}"# }
        try write(creds("old", 100), to: shared)
        _ = try home.sessionCopy(for: f.handle)
        // Another session refreshed: its copy has the newer token.
        let f2 = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        _ = try home.sessionCopy(for: f2.handle)
        try write(creds("new", 200), to: f2.handle.agentHomeCopy.appendingPathComponent(".credentials.json"))
        home.adoptNewestCredentials(from: [f.handle, f2.handle])
        #expect(try read(shared).contains("new"))
        // The first session ends later with its stale copy: not carried back.
        #expect(home.syncBack(from: f.handle).isEmpty)
        #expect(try read(shared).contains("new"))
    }

    @Test("Gemini CLI trusts /workspace and makes no update or usage-statistics calls")
    func geminiFirstRun() throws {
        // Without the trust variable, --yolo is turned off and -p refuses to run.
        #expect(AgentPreset.gemini.environment["GEMINI_CLI_TRUST_WORKSPACE"] == "true")
        let f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        let home = try #require(AgentHome(store: f.store, agent: "gemini"))
        _ = try home.sessionCopy(for: f.handle)
        // Even before any sign-in: these calls would only be blocked.
        SessionRunner(store: f.store).prepareAgentCopy(handle: f.handle, preset: .gemini, secrets: [:], passNames: [])
        let settings = try read(f.handle.agentHomeCopy.appendingPathComponent("settings.json"))
        #expect(settings.contains(#""enableAutoUpdate" : false"#) && settings.contains(#""enableAutoUpdateNotification" : false"#))
        #expect(settings.contains(#""usageStatisticsEnabled" : false"#) && !settings.contains("selectedType"))
        SessionRunner(store: f.store).prepareAgentCopy(handle: f.handle, preset: .gemini, secrets: ["GEMINI_API_KEY": "k"], passNames: [])
        #expect(try read(f.handle.agentHomeCopy.appendingPathComponent("settings.json")).contains("gemini-api-key"))
    }
}
