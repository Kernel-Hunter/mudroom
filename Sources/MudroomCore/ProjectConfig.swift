#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Per-project settings, kept outside the project so an agent can't edit
/// them: `<store>/projects/<hash>.json`.
public struct ProjectConfig: Codable, Sendable, Equatable {
    public var projectPath: String
    public var networkMode: NetworkMode
    /// Hosts added for this project, on top of the agent's defaults.
    public var allowedHosts: [HostPattern]
    /// Include the agent's own API and sign-in hosts.
    public var includeAgentHosts: Bool
    /// Include npm, PyPI and GitHub.
    public var includePackageRegistries: Bool
    /// Minutes between snapshots of work/ while the agent runs; 0 turns the
    /// timer off (a snapshot is still taken when the agent exits).
    public var snapshotMinutes: Int
    public var snapshotLimit: Int
    /// Let the VM use Ollama (11434) and LM Studio (1234) on this Mac,
    /// through the proxy, as http://host.mudroom.internal:<port>. Locked
    /// mode only.
    public var localModels: Bool

    public init(projectPath: String, networkMode: NetworkMode = .locked, allowedHosts: [HostPattern] = [],
                includeAgentHosts: Bool = true, includePackageRegistries: Bool = false,
                snapshotMinutes: Int = 5, snapshotLimit: Int = 24, localModels: Bool = false) {
        self.projectPath = projectPath
        self.networkMode = networkMode
        self.allowedHosts = allowedHosts
        self.includeAgentHosts = includeAgentHosts
        self.includePackageRegistries = includePackageRegistries
        self.snapshotMinutes = snapshotMinutes
        self.snapshotLimit = snapshotLimit
        self.localModels = localModels
    }

    // Missing keys fall back to defaults, so older files keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectPath = try c.decode(String.self, forKey: .projectPath)
        networkMode = try c.decodeIfPresent(NetworkMode.self, forKey: .networkMode) ?? .locked
        allowedHosts = try c.decodeIfPresent([HostPattern].self, forKey: .allowedHosts) ?? []
        includeAgentHosts = try c.decodeIfPresent(Bool.self, forKey: .includeAgentHosts) ?? true
        includePackageRegistries = try c.decodeIfPresent(Bool.self, forKey: .includePackageRegistries) ?? false
        snapshotMinutes = try c.decodeIfPresent(Int.self, forKey: .snapshotMinutes) ?? 5
        snapshotLimit = try c.decodeIfPresent(Int.self, forKey: .snapshotLimit) ?? 24
        localModels = try c.decodeIfPresent(Bool.self, forKey: .localModels) ?? false
    }

    /// The hosts a session of `agent` (a preset id) may reach. `keys` are
    /// the API key variables set for it; their providers' hosts are added
    /// for agents that use many providers.
    public func allowlist(agent: String?, keys: [String] = []) -> Allowlist {
        var hosts: [String] = []
        if includeAgentHosts {
            hosts += NetworkDefaults.hosts(forAgent: agent)
            hosts += NetworkDefaults.keyHosts(forAgent: agent, keys: keys)
        }
        if includePackageRegistries { hosts += NetworkDefaults.packageRegistries }
        return Allowlist(Allowlist(strings: hosts).patterns + allowedHosts)
    }

    /// Adds a host; returns false if it was already covered.
    @discardableResult
    public mutating func allow(_ pattern: HostPattern) -> Bool {
        guard !allowedHosts.contains(pattern) else { return false }
        allowedHosts.append(pattern)
        return true
    }

    @discardableResult
    public mutating func disallow(_ pattern: HostPattern) -> Bool {
        let before = allowedHosts.count
        allowedHosts.removeAll { $0 == pattern }
        return allowedHosts.count != before
    }
}

public struct ProjectConfigStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public init(store: SessionStore) {
        self.init(directory: store.root.appendingPathComponent("projects", isDirectory: true))
    }

    public static func key(for projectPath: String) -> String {
        let path = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().standardizedFileURL.path
        return SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func url(for projectPath: String) -> URL {
        directory.appendingPathComponent(Self.key(for: projectPath) + ".json")
    }

    /// The saved config, or defaults if there is none yet.
    public func load(_ projectPath: String) throws -> ProjectConfig {
        let path = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().standardizedFileURL.path
        let url = url(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return ProjectConfig(projectPath: path) }
        return try JSONDecoder().decode(ProjectConfig.self, from: Data(contentsOf: url))
    }

    public func save(_ config: ProjectConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).writeAtomically(to: url(for: config.projectPath))
    }

    /// Load, change, save.
    @discardableResult
    public func update(_ projectPath: String, _ body: (inout ProjectConfig) throws -> Void) throws -> ProjectConfig {
        var config = try load(projectPath)
        try body(&config)
        try save(config)
        return config
    }
}
