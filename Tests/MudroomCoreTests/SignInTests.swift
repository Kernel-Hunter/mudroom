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

/// A made-up token of the real shape (sk-ant-oat01- plus 95 characters).
let fakeToken = "sk-ant-oat01-" + String(repeating: "Ab3_x-Yz9Q", count: 9) + "QwErTAA"

@Suite("Claude token capture")
struct TokenCaptureTests {
    @Test("the token is found in plain output")
    func plain() {
        let out = "✓ Long-lived authentication token created successfully!\n\nYour OAuth token (valid for 1 year):\n\n\(fakeToken)\n\nStore this token securely.\n"
        #expect(SetupTokenCapture.extract(out) == fakeToken)
    }

    @Test("ANSI colors, cursor moves, OSC titles and CRLF around the token are ignored")
    func ansi() {
        let out = "\u{1B}]0;claude\u{07}\u{1B}[2K\u{1B}[1G\u{1B}[32m✓\u{1B}[39m Token:\r\n\u{1B}[1m\(fakeToken.prefix(30))\u{1B}[22m\u{1B}[0m\(fakeToken.dropFirst(30))\u{1B}[0m\r\n\u{1B}[?25h"
        #expect(SetupTokenCapture.extract(out) == fakeToken)
    }

    @Test("a token the terminal wrapped (with indent or a box border) is put back together")
    func wrapped() {
        let a = fakeToken.prefix(60), b = fakeToken.dropFirst(60)
        #expect(SetupTokenCapture.extract("Token:\n  \(a)\n  \(b)\n\nStore it securely") == fakeToken)
        #expect(SetupTokenCapture.extract("│ \(a) │\n│ \(b) │\n") == fakeToken)
        // A full-length token is not glued to the next line.
        #expect(SetupTokenCapture.extract("\(fakeToken)\nNext") == fakeToken)
    }

    @Test("redrawn frames: the longest (complete) copy wins; nothing token-like gives nil")
    func frames() {
        #expect(SetupTokenCapture.extract("\(fakeToken.prefix(50))\u{1B}[2K\r\(fakeToken)\n") == fakeToken)
        #expect(SetupTokenCapture.extract("Opening browser to sign in…\nhttps://claude.ai/oauth/authorize?code=true") == nil)
        #expect(SetupTokenCapture.extract("sk-ant-oat01-short") == nil)
    }

    @Test("readable output hides tokens and drops escape codes and repeated lines")
    func readable() {
        let raw = Data("\u{1B}[33mWaiting…\u{1B}[0m\r\nWaiting…\nYour token:\n\(fakeToken)\nsk-proj-\(String(repeating: "a", count: 30))\n".utf8)
        let lines = ConsoleText.lines(raw)
        #expect(lines == ["Waiting…", "Your token:", "[token hidden]"])
        #expect(!lines.joined().contains("sk-ant"))
        #expect(ConsoleText.redact("key sk-ant-api03-abcdefgh end") == "key [token hidden] end")
    }

    @Test("links and device codes are picked out of agent output")
    func linksAndCodes() {
        let out = "1. Open \u{1B}[4mhttps://auth.openai.com/codex/device\u{1B}[0m.\n2. Enter this code: \u{1B}[1mABCD-EFG12\u{1B}[0m (expires 2026-1001)\n"
        #expect(ConsoleText.links(out) == ["https://auth.openai.com/codex/device"])
        #expect(ConsoleText.deviceCode(out) == "ABCD-EFG12")
        #expect(ConsoleText.deviceCode("nothing here 1234-5678") == nil)
    }
}

@Suite("Host agent detection")
struct HostDetectionTests {
    @Test("claude is found in the usual places first, then PATH, then the login shell's PATH")
    func findClaude() {
        let home = "/Users/u"
        func find(_ present: Set<String>, path: String? = nil, login: String? = nil) -> String? {
            HostCLI.findClaude(home: home, isExecutable: { present.contains($0) }, loginShellPath: { login }, path: path)
        }
        #expect(find(["/Users/u/.local/bin/claude", "/opt/homebrew/bin/claude"]) == "/Users/u/.local/bin/claude")
        #expect(find(["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]) == "/opt/homebrew/bin/claude")
        #expect(find(["/usr/local/bin/claude"]) == "/usr/local/bin/claude")
        #expect(find(["/Users/u/.claude/local/claude"]) == "/Users/u/.claude/local/claude")
        #expect(find(["/x/bin/claude"], path: "/usr/bin:/x/bin") == "/x/bin/claude")
        #expect(find(["/nvm/bin/claude"], path: "/usr/bin", login: "/usr/bin:/nvm/bin") == "/nvm/bin/claude")
        // Relative PATH entries are ignored.
        #expect(find(["bin/claude"], path: "bin") == nil)
        #expect(find([], path: "/usr/bin", login: "/bin") == nil)
    }

    @Test("an existing Codex login is copied 0600 into Mudroom's agent directory; junk is refused")
    func importCodex() throws {
        let tmp = try TempDir()
        let home = tmp.path("home")
        let store = SessionStore(root: tmp.path("store"))
        let login = try #require(HostLogin.forAgent("codex", home: home))
        #expect(!login.isAvailable)
        try write(#"{"tokens":{"refresh_token":"r"}}"#, to: home.appendingPathComponent(".codex/auth.json"))
        #expect(login.isAvailable)
        let agentHome = try #require(AgentHome(store: store, agent: "codex"))
        #expect(try login.importInto(agentHome) == ["auth.json"])
        #expect(agentHome.hasCredentials)
        var st = stat()
        #expect(stat(agentHome.hostDirectory.appendingPathComponent("auth.json").path, &st) == 0 && st.st_mode & 0o777 == 0o600)

        try write("not json", to: home.appendingPathComponent(".codex/auth.json"))
        #expect(throws: MudroomError.self) { try login.importInto(agentHome) }
        // A symlink is not followed.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".codex/auth.json"))
        symlink(tmp.path("elsewhere").path, home.appendingPathComponent(".codex/auth.json").path)
        #expect(throws: MudroomError.self) { try login.importInto(agentHome) }
    }

    @Test("a Gemini login import also sets the sign-in method, so the first run doesn't ask")
    func importGemini() throws {
        let tmp = try TempDir()
        let home = tmp.path("home")
        try write(#"{"refresh_token":"r"}"#, to: home.appendingPathComponent(".gemini/oauth_creds.json"))
        let agentHome = try #require(AgentHome(store: SessionStore(root: tmp.path("store")), agent: "gemini"))
        #expect(try HostLogin.forAgent("gemini", home: home)!.importInto(agentHome) == ["oauth_creds.json"])
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: agentHome.hostDirectory.appendingPathComponent("settings.json"))) as? [String: Any]
        #expect(settings?["selectedAuthType"] as? String == "oauth-personal")
        #expect(((settings?["security"] as? [String: Any])?["auth"] as? [String: Any])?["selectedType"] as? String == "oauth-personal")
    }

    @Test("Claude's first-run screens are marked done without overwriting existing settings")
    func seedClaude() throws {
        let tmp = try TempDir()
        let h = try #require(AgentHome(store: SessionStore(root: tmp.path("store")), agent: "claude"))
        try h.create()
        try write(#"{"theme":"light","userID":"u1"}"#, to: h.hostDirectory.appendingPathComponent(".claude.json"))
        try h.seedClaudeOnboarding()
        let c = try JSONSerialization.jsonObject(with: Data(contentsOf: h.hostDirectory.appendingPathComponent(".claude.json"))) as? [String: Any]
        #expect(c?["theme"] as? String == "light" && c?["userID"] as? String == "u1")
        #expect(c?["hasCompletedOnboarding"] as? Bool == true && c?["bypassPermissionsModeAccepted"] as? Bool == true)
        #expect(((c?["projects"] as? [String: Any])?["/workspace"] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true)
    }
}
