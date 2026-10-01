#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Agents Mudroom knows how to start. Each runs in auto-approve mode: that is
/// the point of the sandbox, the review happens afterwards.
public struct AgentPreset: Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let command: [String]
    /// Environment variable the agent reads its key from, shown as a hint.
    public let credential: String?

    public init(id: String, name: String, command: [String], credential: String?) {
        self.id = id
        self.name = name
        self.command = command
        self.credential = credential
    }

    public static let claude = AgentPreset(
        id: "claude", name: "Claude Code", command: ["claude", "--dangerously-skip-permissions"],
        credential: "ANTHROPIC_API_KEY")
    public static let codex = AgentPreset(
        id: "codex", name: "Codex", command: ["codex", "--dangerously-bypass-approvals-and-sandbox"],
        credential: "OPENAI_API_KEY")
    public static let gemini = AgentPreset(
        id: "gemini", name: "Gemini CLI", command: ["gemini", "--yolo"], credential: "GEMINI_API_KEY")

    /// Aider: changes stay uncommitted (the review is the commit), no
    /// update checks, analytics or .gitignore edits.
    public static let aider = AgentPreset(
        id: "aider", name: "Aider",
        command: ["aider", "--yes-always", "--no-auto-commits", "--no-gitignore", "--no-check-update",
                  "--analytics-disable", "--no-show-release-notes"],
        credential: nil)
    public static let opencode = AgentPreset(id: "opencode", name: "opencode", command: ["opencode"], credential: nil)

    public static let all: [AgentPreset] = [.claude, .codex, .gemini, .opencode, .aider]

    /// Splits a custom command line on whitespace, honoring simple quotes.
    public static func parseCommand(_ line: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
            } else if ch.isWhitespace {
                if hasToken || !current.isEmpty { args.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(ch)
            }
        }
        if hasToken || !current.isEmpty { args.append(current) }
        return args
    }
}
