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
    /// Where a stored agent token is looked up (`mudroom agent token`).
    public var tokenStore: AgentTokenStore?
    /// Check that the VM reaches the proxy before starting (locked mode).
    public var probeNetwork: Bool = false

    public init(tty: Bool, cpus: Int? = nil, memory: String? = nil,
                environmentNames: [String] = AgentEnvironment.present(), networkMode: NetworkMode? = nil,
                extraHosts: [HostPattern] = [], snapshotMinutes: Int? = nil, snapshotLimit: Int? = nil,
                commandOverride: [String]? = nil, persistAgentConfig: Bool = true, snapshots: Bool = true,
                tokenStore: AgentTokenStore? = nil) {
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
        self.tokenStore = tokenStore
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
                    "offline mode needs a host-only network, which this \(backend.name) version can't create")
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
    private let teardown = LockedBox<(@Sendable () -> Void)?>(nil)

    public init(mode: NetworkMode, allowlist: Allowlist, backend: SandboxBackend, logURL: URL?,
                hostServices: [UInt16: UInt16] = [:]) throws {
        plan = try NetworkPlan.make(mode: mode, allowlist: allowlist, backend: backend)
        var record = plan.record
        if mode == .locked, plan.proxyHost != nil {
            let listen = try backend.proxyListen(for: plan)
            let p = EgressProxy(.init(allowlist: plan.allowlist, logURL: logURL, bindHost: listen.bindHost,
                                      clientSubnets: listen.clientSubnets, blockedSubnets: listen.blockedSubnets,
                                      hostServices: hostServices))
            do {
                try p.start()
            } catch {
                throw MudroomError.backendUnavailable("the network proxy could not listen on \(listen.bindHost ?? "all addresses") for \(backend.name): \(error)")
            }
            let route: ProxyRoute
            do {
                route = try backend.attachProxy(port: p.port, plan: plan)
            } catch {
                p.stop()
                throw error
            }
            teardown.value = route.teardown
            proxy = p
            let url = "http://\(route.host):\(route.port)"
            record.proxy = url
            environment = NetworkPlan.proxyEnvironment(url)
        } else {
            proxy = nil
            environment = [:]
        }
        self.record = record
    }

    public func stop() {
        let t = teardown.value
        teardown.value = nil
        t?()
        proxy?.stop()
    }

    public var summary: [String] {
        switch record.mode {
        case .locked:
            var lines = ["network: locked (\(record.enforcement.title)), \(plan.allowlist.patterns.count) allowed hosts, proxy \(record.proxy ?? "-")"]
            if record.enforcement == .advisory {
                lines.append("warning: this runtime can't give the sandbox a host-only network, so a program that ignores the proxy settings can still connect directly")
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
        // Shell variables for agents that use many providers; the usual four
        // are passed to every agent as before.
        var passNames = options.environmentNames
        if preset?.isMultiProvider ?? true {
            passNames += AgentEnvironment.present(in: ProcessInfo.processInfo.environment, names: APIKeys.providers.map(\.variable))
                .filter { !passNames.contains($0) }
        }
        let secrets = SessionSecrets.resolve(preset: preset, store: options.tokenStore, passthrough: passNames)
        let keyNames = Set(passNames + secrets.keys)
        if options.commandOverride == nil,
           let why = AgentPreset.aiderModelProblem(command: s.command, keys: keyNames, workspace: handle.work) {
            throw MudroomError.invalid(why)
        }
        let allowlist = Allowlist(config.allowlist(agent: preset?.id, keys: keyNames.sorted()).patterns + options.extraHosts)
        let localModels = config.localModels && mode == .locked
        if config.localModels && mode != .locked {
            log("local models: only available in locked mode (they go through Mudroom's proxy)")
        }
        if options.probeNetwork && mode == .locked {
            let probe = NetworkProbe.check(backend: backend, store: store, image: s.image)
            if !probe.isOK {
                if probe.needsRepair { throw MudroomError.networkUnreachable(probe.summary) }
                log("network check: \(probe.summary)")
            }
        }
        let net = try NetworkSetup(mode: mode, allowlist: allowlist, backend: backend, logURL: handle.networkLog,
                                   hostServices: localModels ? Dictionary(uniqueKeysWithValues: NetworkDefaults.localModelPorts.keys.map { ($0, $0) }) : [:])
        defer { net.stop() }
        let record = net.record
        net.summary.forEach(log)
        if localModels { log("local models: Ollama and LM Studio on this Mac at http://\(NetworkDefaults.hostServiceName):11434 and :1234") }

        let runsSession = options.commandOverride == nil
        // Held by this process and inherited by the sandbox process, so the
        // session counts as running while either lives.
        var runnerLock: FileLock?
        if runsSession {
            guard let l = FileLock.tryAcquire(handle.runnerLockURL, inheritable: true) else {
                throw MudroomError.invalid("session \(s.id) is already running")
            }
            runnerLock = l
        }
        defer { runnerLock?.release() }

        var env = preset?.environment ?? [:]
        var mounts: [SandboxMount] = []
        var home: AgentHome?
        if options.persistAgentConfig, let id = preset?.id, let h = AgentHome(store: store, agent: id) {
            // A copy per session; only the login is carried back afterwards.
            h.adoptNewestCredentials(from: ((try? store.list()) ?? []).filter { $0.directory != handle.directory })
            mounts.append(try h.sessionCopy(for: handle))
            env.merge(h.environment) { _, new in new }
            home = h
        }
        env.merge(net.environment) { _, new in new }
        if localModels { env.merge(NetworkDefaults.localModelEnvironment) { _, new in new } }
        if !secrets.isEmpty {
            log("from \(options.tokenStore?.location ?? "the token store"): \(secrets.keys.sorted().joined(separator: ", "))")
        }
        if home != nil { prepareAgentCopy(handle: handle, preset: preset, secrets: secrets, passNames: passNames) }
        var handoff: AuthLinkHandoff?
        if options.tty, let h = try? AuthLinkHandoff(directory: handle.directory.appendingPathComponent("handoff")) {
            mounts.append(h.mount)
            env.merge(h.environment) { _, new in new }
            handoff = h
        }

        let spec = SandboxSpec(
            name: "mudroom-\(s.id)", image: s.image, workspace: handle.work,
            command: options.commandOverride ?? s.command,
            environmentNames: passNames, interactive: true, tty: options.tty,
            cpus: options.cpus, memory: options.memory, mounts: mounts, environment: env, network: net.plan.vmNetwork)
        var runSpec = spec
        runSpec.secretEnvironment = secrets
        let log = self.log
        handoff?.start { url in AuthLinkHandoff.deliver(url) { log($0) } }
        let backend = self.backend
        // A token refreshed mid-session reaches the shared sign-in right
        // away, not only when the session ends, so sessions started
        // meanwhile don't get one that was already rotated out.
        var credentialTimer: DispatchSourceTimer?
        if let home {
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now() + 15, repeating: 15)
            let copy = handle.agentHomeCopy
            t.setEventHandler { home.syncCredentials(from: copy) }
            t.resume()
            credentialTimer = t
        }
        defer {
            credentialTimer?.cancel()
            handoff?.stop()
            // If the runtime CLI went away but the sandbox didn't, stop it.
            if backend.isRunning(spec.name) { backend.stop(spec.name) }
            if let home, !home.syncBack(from: handle).isEmpty { log("kept the \(home.agent) sign-in from this session for later ones") }
        }

        var snapshotter: Snapshotter?
        if options.snapshots {
            let minutes = options.snapshotMinutes ?? config.snapshotMinutes
            let snap = Snapshotter(store: SnapshotStore(handle: handle), interval: TimeInterval(max(0, minutes) * 60),
                                   limit: options.snapshotLimit ?? config.snapshotLimit)
            snap.onError = { log("snapshot failed: \($0)") }
            snap.start()
            snapshotter = snap
        }

        if runsSession {
            handle.session.runnerPID = getpid()
            handle.session.started = Date()
            handle.session.network = record
            handle.session.backend = BackendChoice(backendName: backend.name)?.rawValue ?? backend.name
            try handle.setStatus(.running)
        }
        let status: Int32
        do {
            status = try backend.run(runSpec)
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

    /// First-run answers in the session's agent directory, so a signed-in
    /// agent starts without questions: Claude Code's API key approval (it
    /// remembers the key by its last 20 characters, as Claude Code itself
    /// does) and Gemini CLI's sign-in method.
    func prepareAgentCopy(handle: SessionHandle, preset: AgentPreset?, secrets: [String: String], passNames: [String]) {
        let dir = handle.agentHomeCopy
        switch preset?.id {
        case "claude":
            let key = secrets["ANTHROPIC_API_KEY"] ?? (passNames.contains("ANTHROPIC_API_KEY") ? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] : nil)
            guard let key, key.count > 20 else { return }
            AgentHome.updateJSON(dir.appendingPathComponent(".claude.json")) { c in
                var responses = c["customApiKeyResponses"] as? [String: Any] ?? [:]
                var approved = responses["approved"] as? [String] ?? []
                let tail = String(key.suffix(20))
                if !approved.contains(tail) { approved.append(tail) }
                responses["approved"] = approved
                c["customApiKeyResponses"] = responses
            }
        case "gemini":
            let hasOAuth = FileManager.default.fileExists(atPath: dir.appendingPathComponent("oauth_creds.json").path)
            let hasKey = secrets["GEMINI_API_KEY"] != nil || passNames.contains("GEMINI_API_KEY")
            // No update checks (npm) or usage statistics (play.googleapis.com):
            // the locked network blocks both, and they would show up as
            // blocked connections in every session.
            AgentHome.updateJSON(dir.appendingPathComponent("settings.json")) { c in
                var general = c["general"] as? [String: Any] ?? [:]
                for k in ["enableAutoUpdate", "enableAutoUpdateNotification"] where general[k] == nil { general[k] = false }
                c["general"] = general
                var privacy = c["privacy"] as? [String: Any] ?? [:]
                if privacy["usageStatisticsEnabled"] == nil { privacy["usageStatisticsEnabled"] = false }
                c["privacy"] = privacy
            }
            guard hasOAuth || hasKey else { return }
            AgentHome.updateJSON(dir.appendingPathComponent("settings.json")) { c in
                var security = c["security"] as? [String: Any] ?? [:]
                var auth = security["auth"] as? [String: Any] ?? [:]
                guard auth["selectedType"] == nil else { return }
                let type = hasOAuth ? "oauth-personal" : "gemini-api-key"
                auth["selectedType"] = type
                security["auth"] = auth
                c["security"] = security
                if c["selectedAuthType"] == nil { c["selectedAuthType"] = type }
            }
        default:
            break
        }
    }
}
