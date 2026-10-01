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

/// One allowlist entry: an exact host ("api.anthropic.com"), a wildcard
/// suffix ("*.githubusercontent.com", which matches subdomains only, not the
/// bare domain), or an IP literal, which only ever matches that address.
public struct HostPattern: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String

    public init?(_ raw: String) {
        let v = Self.normalize(raw)
        guard !v.isEmpty else { return nil }
        let wildcard = v.hasPrefix("*.")
        let body = wildcard ? String(v.dropFirst(2)) : v
        // Same rules as hosts in proxy requests, so a pattern can never be
        // something a request can't spell.
        guard case .success(let host) = HostName.parse(body) else { return nil }
        if wildcard {
            guard case .name(let n) = host else { return nil }
            value = "*." + n
        } else {
            value = host.canonical
        }
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

    /// Trims whitespace and lowercases. For patterns typed by a person;
    /// proxy requests go through `HostName.parse` instead.
    public static func normalize(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func matches(_ host: ProxyHost) -> Bool {
        switch host {
        case .ip(let a):
            return !isWildcard && IPAddress(value) == a
        case .name(let n):
            if isWildcard {
                let suffix = String(value.dropFirst(1)) // ".example.com"
                return n.hasSuffix(suffix) && n.count > suffix.count
            }
            return n == value
        }
    }

    /// Parses `host` first; anything that isn't a valid host never matches.
    public func matches(_ host: String) -> Bool {
        guard case .success(let h) = HostName.parse(host) else { return false }
        return matches(h)
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

    public func allows(_ host: ProxyHost) -> Bool {
        patterns.contains { $0.matches(host) }
    }

    public func allows(_ host: String) -> Bool {
        guard case .success(let h) = HostName.parse(host) else { return false }
        return allows(h)
    }

    /// True when `address` itself is on the list as an IP literal: the only
    /// way a private address can be reached.
    public func listsAddress(_ address: IPAddress) -> Bool {
        patterns.contains { !$0.isWildcard && IPAddress($0.value) == address }
    }

    /// The first pattern that lets `host` through, for logs.
    public func match(for host: String) -> HostPattern? {
        guard case .success(let h) = HostName.parse(host) else { return nil }
        return patterns.first { $0.matches(h) }
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
        // Its model catalog; providers come from the keys that are set.
        case "opencode":
            ["models.dev"]
        default:
            []
        }
    }

    /// Hosts for the API keys that are set. Agents tied to one provider
    /// already have theirs; agents that work with many (and custom
    /// commands) get each provider whose key is set.
    public static func keyHosts(forAgent id: String?, keys: some Sequence<String>) -> [String] {
        let preset = id.flatMap { AgentPreset.find($0) }
        guard preset?.isMultiProvider ?? true else { return [] }
        return APIKeys.hosts(for: keys)
    }

    /// The name a VM uses for services on the Mac (local models). The proxy
    /// answers for it and connects to 127.0.0.1 itself, only on the ports
    /// in `localModelPorts`.
    public static let hostServiceName = "host.mudroom.internal"
    /// Ollama and LM Studio.
    public static let localModelPorts: [UInt16: String] = [11434: "Ollama", 1234: "LM Studio"]

    /// Variables pointing agents at local models through the proxy.
    public static var localModelEnvironment: [String: String] {
        let ollama = "http://\(hostServiceName):11434"
        let lmstudio = "http://\(hostServiceName):1234/v1"
        return ["OLLAMA_HOST": ollama, "OLLAMA_API_BASE": ollama,
                "LM_STUDIO_API_BASE": lmstudio, "LMSTUDIO_BASE_URL": lmstudio,
                "LM_STUDIO_API_KEY": "lm-studio"]
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
