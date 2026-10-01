#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Per-run choices; anything left nil comes from the project config.
public struct RunOptions: Sendable {
    public var tty: Bool
    public var cpus: Int?
    public var memory: String?
    /// Credentials passed through by name.
    public var environmentNames: [String]
    public var networkMode: NetworkMode?
    /// Extra hosts for this run only.
    public var extraHosts: [HostPattern]
    public var snapshotMinutes: Int?
    public var snapshotLimit: Int?
    /// Run this instead of the session's command (used by `agent login`).
    public var commandOverride: [String]?
    /// Mount the agent's persistent config directory.
    public var persistAgentConfig: Bool
    /// Take snapshots (off for login runs, which don't touch work/).
    public var snapshots: Bool

    public init(tty: Bool, cpus: Int? = nil, memory: String? = nil,
                environmentNames: [String] = AgentEnvironment.present(), networkMode: NetworkMode? = nil,
                extraHosts: [HostPattern] = [], snapshotMinutes: Int? = nil, snapshotLimit: Int? = nil,
                commandOverride: [String]? = nil, persistAgentConfig: Bool = true, snapshots: Bool = true) {
        self.tty = tty
        self.cpus = cpus
        self.memory = memory
        self.environmentNames = environmentNames
        self.networkMode = networkMode
        self.extraHosts = extraHosts
        self.snapshotMinutes = snapshotMinutes
        self.snapshotLimit = snapshotLimit
        self.commandOverride = commandOverride
        self.persistAgentConfig = persistAgentConfig
        self.snapshots = snapshots
    }
}

/// How one run will reach the network, worked out before the VM starts.
public struct NetworkPlan: Sendable, Equatable {
    public var record: SessionNetwork
    public var vmNetwork: String?
    /// Where the VM reaches the proxy (the Mac's address on the VM network).
    public var proxyHost: String?
    public var clientSubnet: IPv4Subnet?
    public var allowlist: Allowlist

    /// Picks the VM network and proxy for a mode. Locked mode prefers a
    /// host-only network (enforced) and falls back to the NAT network with
    /// proxy variables only (advisory). Offline requires host-only.
    public static func make(mode: NetworkMode, allowlist: Allowlist, backend: SandboxBackend) throws -> NetworkPlan {
        switch mode {
        case .open:
            return NetworkPlan(record: SessionNetwork(mode: .open, enforcement: .none), vmNetwork: nil,
                               proxyHost: nil, clientSubnet: nil, allowlist: allowlist)
        case .offline:
            guard let net = try backend.hostOnlyNetwork() else {
                throw MudroomError.backendUnavailable(
                    "offline mode needs a host-only VM network, which this version of `container` can't create")
            }
            return NetworkPlan(record: SessionNetwork(mode: .offline, enforcement: .enforced, vmNetwork: net.name),
                               vmNetwork: net.name, proxyHost: nil, clientSubnet: nil, allowlist: allowlist)
        case .locked:
            if let net = try backend.hostOnlyNetwork() {
                return NetworkPlan(
                    record: SessionNetwork(mode: .locked, enforcement: .enforced, allowlist: allowlist.strings, vmNetwork: net.name),
                    vmNetwork: net.name, proxyHost: net.gateway, clientSubnet: IPv4Subnet(net.subnet), allowlist: allowlist)
            }
            guard let nat = try backend.defaultNetwork() else {
                throw MudroomError.backendUnavailable("couldn't find the VM network's address for the proxy")
            }
            return NetworkPlan(
                record: SessionNetwork(mode: .locked, enforcement: .advisory, allowlist: allowlist.strings),
                vmNetwork: nil, proxyHost: nat.gateway, clientSubnet: IPv4Subnet(nat.subnet), allowlist: allowlist)
        }
    }

    /// Proxy variables for the VM. Upper and lower case, since tools differ;
    /// NODE_USE_ENV_PROXY makes Node's built-in fetch use them too.
    public static func proxyEnvironment(_ url: String) -> [String: String] {
        let noProxy = "localhost,127.0.0.1,::1"
        return [
            "HTTP_PROXY": url, "HTTPS_PROXY": url, "http_proxy": url, "https_proxy": url,
            "ALL_PROXY": url, "all_proxy": url,
            "NO_PROXY": noProxy, "no_proxy": noProxy,
            "NODE_USE_ENV_PROXY": "1",
        ]
    }
}

/// A network plan with its proxy running: what a VM run needs.
public final class NetworkSetup: @unchecked Sendable {
    public let plan: NetworkPlan
    public let proxy: EgressProxy?
    public let record: SessionNetwork
    /// Proxy variables for the VM (empty unless locked).
    public let environment: [String: String]

    public init(mode: NetworkMode, allowlist: Allowlist, backend: SandboxBackend, logURL: URL?) throws {
        plan = try NetworkPlan.make(mode: mode, allowlist: allowlist, backend: backend)
        var record = plan.record
        if mode == .locked, let host = plan.proxyHost {
            let p = EgressProxy(.init(allowlist: plan.allowlist, logURL: logURL,
                                      clientSubnets: plan.clientSubnet.map { [$0] } ?? []))
            try p.start()
            proxy = p
            let url = "http://\(host):\(p.port)"
            record.proxy = url
            environment = NetworkPlan.proxyEnvironment(url)
        } else {
            proxy = nil
            environment = [:]
        }
        self.record = record
    }

    public func stop() { proxy?.stop() }

    public var summary: [String] {
        switch record.mode {
        case .locked:
            var lines = ["network: locked (\(record.enforcement.title)), \(plan.allowlist.patterns.count) allowed hosts, proxy \(record.proxy ?? "-")"]
            if record.enforcement == .advisory {
                lines.append("warning: this runtime can't give the VM a host-only network, so a program that ignores the proxy settings can still connect directly")
            }
            return lines
        case .open:
            return ["network: open. The VM has normal internet access and nothing is filtered or logged."]
        case .offline:
            return ["network: offline (no internet)"]
        }
    }
}

/// Runs the agent for a session that already has its clones: sets up the
/// network (proxy and allowlist), the agent's config directory and the
/// snapshot timer, and keeps session.json up to date.
public struct SessionRunner {
    public let backend: SandboxBackend
    public let store: SessionStore
    /// Progress lines ("network: locked, enforced ...").
    public var log: @Sendable (String) -> Void

    public init(backend: SandboxBackend = AppleContainerBackend(), store: SessionStore = .defaultStore(),
                log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.backend = backend
        self.store = store
        self.log = log
    }

    public struct Result: Sendable {
        public var status: Int32
        public var network: SessionNetwork
        public var connections: Int
        public var blocked: [String]
        public var finalSnapshot: Snapshot?
        public var snapshotCount: Int
    }

    public func run(_ handle: inout SessionHandle, options: RunOptions) throws -> Result {
        guard handle.hasClones else { throw MudroomError.invalid("session \(handle.session.id) was discarded") }
        let s = handle.session
        let preset = AgentPreset.matching(agent: s.agent, command: s.command)
        let config = try ProjectConfigStore(store: store).load(s.projectPath)
        let mode = options.networkMode ?? config.networkMode
        let allowlist = Allowlist(config.allowlist(agent: preset?.id).patterns + options.extraHosts)
        let net = try NetworkSetup(mode: mode, allowlist: allowlist, backend: backend, logURL: handle.networkLog)
        defer { net.stop() }
        let record = net.record
        net.summary.forEach(log)

        var env = preset?.environment ?? [:]
        var mounts: [SandboxMount] = []
        if options.persistAgentConfig, let id = preset?.id, let home = AgentHome(store: store, agent: id) {
            try home.create()
            mounts.append(home.mount)
            env.merge(home.environment) { _, new in new }
        }
        env.merge(net.environment) { _, new in new }

        let spec = SandboxSpec(
            name: "mudroom-\(s.id)", image: s.image, workspace: handle.work,
            command: options.commandOverride ?? s.command,
            environmentNames: options.environmentNames, interactive: true, tty: options.tty,
            cpus: options.cpus, memory: options.memory, mounts: mounts, environment: env, network: net.plan.vmNetwork)

        var snapshotter: Snapshotter?
        if options.snapshots {
            let minutes = options.snapshotMinutes ?? config.snapshotMinutes
            let snap = Snapshotter(store: SnapshotStore(handle: handle), interval: TimeInterval(max(0, minutes) * 60),
                                   limit: options.snapshotLimit ?? config.snapshotLimit)
            let log = self.log
            snap.onError = { log("snapshot failed: \($0)") }
            snap.start()
            snapshotter = snap
        }

        let runsSession = options.commandOverride == nil
        if runsSession {
            handle.session.runnerPID = getpid()
            handle.session.started = Date()
            handle.session.network = record
            try handle.setStatus(.running)
        }
        let status: Int32
        do {
            status = try backend.run(spec)
        } catch {
            _ = snapshotter?.finish()
            if runsSession {
                handle.session.runnerPID = nil
                handle.session.finished = Date()
                try? handle.setStatus(.finished, exitCode: -1)
            }
            throw error
        }
        let final = snapshotter?.finish()
        net.stop()
        if runsSession {
            handle.session.runnerPID = nil
            handle.session.finished = Date()
            try handle.setStatus(.finished, exitCode: status)
        }
        let entries = net.proxy?.loggedEntries ?? []
        return Result(status: status, network: record, connections: entries.count,
                      blocked: Array(Set(entries.filter { !$0.allowed }.map(\.host))).sorted(),
                      finalSnapshot: final, snapshotCount: SnapshotStore(handle: handle).list().count)
    }
}
