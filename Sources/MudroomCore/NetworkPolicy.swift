import Foundation

/// How a session reaches the network.
public enum NetworkMode: String, Codable, Sendable, CaseIterable {
    /// Host-only VM network; the only way out is Mudroom's proxy, which lets
    /// through the hosts on the allowlist.
    case locked
    /// Normal outbound access, no proxy, nothing logged.
    case open
    /// Host-only VM network and no proxy: no internet at all.
    case offline

    public var title: String {
        switch self {
        case .locked: "Locked"
        case .open: "Open"
        case .offline: "Offline"
        }
    }
}

/// Whether blocked traffic is actually impossible, or only unlikely.
public enum NetworkEnforcement: String, Codable, Sendable {
    /// The VM has no route out; the proxy is the only exit.
    case enforced
    /// The VM has a normal route out. Proxy variables are set, so well-behaved
    /// tools go through the allowlist, but a program can connect directly.
    case advisory
    /// No filtering at all (open mode).
    case none

    public var title: String {
        switch self {
        case .enforced: "enforced"
        case .advisory: "proxy-enforced (advisory)"
        case .none: "not filtered"
        }
    }
}

/// One allowlist entry: an exact host ("api.anthropic.com") or a wildcard
/// suffix ("*.githubusercontent.com", which matches subdomains only, not the
/// bare domain).
public struct HostPattern: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String

    public init?(_ raw: String) {
        let v = Self.normalize(raw)
        guard !v.isEmpty else { return nil }
        let body = v.hasPrefix("*.") ? String(v.dropFirst(2)) : v
        // Hostname characters only, at least one label, no empty labels. IP
        // literals are allowed (digits and dots, or bracketless IPv6).
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.:")
        guard !body.isEmpty, body.unicodeScalars.allSatisfy(allowed.contains),
              !body.hasPrefix("."), !body.hasSuffix("."), !body.contains("..") else { return nil }
        value = v
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let p = HostPattern(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad host pattern \(raw)"))
        }
        self = p
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }

    public var description: String { value }
    public var isWildcard: Bool { value.hasPrefix("*.") }

    /// Lowercases, trims whitespace and a trailing dot.
    public static func normalize(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    public func matches(_ host: String) -> Bool {
        let h = Self.normalize(host)
        if isWildcard {
            let suffix = String(value.dropFirst(1)) // ".example.com"
            return h.hasSuffix(suffix) && h.count > suffix.count
        }
        return h == value
    }
}

public struct Allowlist: Sendable, Equatable {
    public var patterns: [HostPattern]

    public init(_ patterns: [HostPattern]) {
        var seen = Set<HostPattern>()
        self.patterns = patterns.filter { seen.insert($0).inserted }
    }

    public init(strings: [String]) {
        self.init(strings.compactMap(HostPattern.init))
    }

    public func allows(_ host: String) -> Bool {
        patterns.contains { $0.matches(host) }
    }

    /// The first pattern that lets `host` through, for logs.
    public func match(for host: String) -> HostPattern? {
        patterns.first { $0.matches(host) }
    }

    public var strings: [String] { patterns.map(\.value) }
}

/// Hosts each agent needs, and optional groups a project can switch on.
public enum NetworkDefaults {
    /// Model API plus the hosts its sign-in and token refresh talk to.
    /// Telemetry and error reporting hosts are left out on purpose; see
    /// `AgentPreset.environment` for the switches that turn those off.
    public static func hosts(forAgent id: String?) -> [String] {
        switch id {
        case "claude":
            ["api.anthropic.com", "console.anthropic.com", "platform.claude.com", "claude.ai"]
        case "codex":
            ["api.openai.com", "chatgpt.com", "auth.openai.com"]
        case "gemini":
            ["generativelanguage.googleapis.com", "cloudcode-pa.googleapis.com",
             "oauth2.googleapis.com", "www.googleapis.com"]
        default:
            []
        }
    }

    /// npm, PyPI and GitHub (clone, release downloads, raw files).
    public static let packageRegistries = [
        "registry.npmjs.org",
        "pypi.org",
        "files.pythonhosted.org",
        "github.com",
        "codeload.github.com",
        "*.githubusercontent.com",
    ]
}
