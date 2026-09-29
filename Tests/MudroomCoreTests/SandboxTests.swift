import Foundation
import Testing
@testable import MudroomCore

@Suite("Sandbox backend")
struct SandboxTests {
    @Test("container run arguments mount only work/ and pass env by name")
    func runArguments() {
        let work = URL(fileURLWithPath: "/Users/me/Library/Application Support/Mudroom/sessions/s1/work")
        let spec = SandboxSpec(
            name: "mudroom-s1", image: "mudroom/agent-base:latest", workspace: work,
            command: ["claude", "--dangerously-skip-permissions"],
            environmentNames: ["ANTHROPIC_API_KEY"], interactive: true, tty: true)
        let args = AppleContainerBackend.runArguments(for: spec)
        #expect(args == [
            "run", "--rm", "--name", "mudroom-s1", "--interactive", "--tty",
            "--mount", "type=bind,source=\(work.path),target=/workspace",
            "--workdir", "/workspace",
            "--env", "ANTHROPIC_API_KEY",
            "mudroom/agent-base:latest", "claude", "--dangerously-skip-permissions",
        ])
        #expect(args.filter { $0.hasPrefix("--mount") || $0.hasPrefix("type=") }.count == 2)
    }

    @Test("only set, non-empty credentials are passed through")
    func environment() {
        let env = ["ANTHROPIC_API_KEY": "x", "OPENAI_API_KEY": "", "HOME": "/h", "GEMINI_API_KEY": "y"]
        #expect(AgentEnvironment.present(in: env) == ["ANTHROPIC_API_KEY", "GEMINI_API_KEY"])
    }

    @Test("missing CLI gives an install hint")
    func missingCLI() {
        let backend = AppleContainerBackend(executable: nil)
        #expect(throws: MudroomError.self) { try backend.checkAvailable() }
    }

    @Test("embedded Containerfile matches images/agent-base/Containerfile")
    func containerfileInSync() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let onDisk = try String(contentsOf: repo.appendingPathComponent("images/agent-base/Containerfile"), encoding: .utf8)
        #expect(onDisk == AgentBaseImage.containerfile)
    }
}
