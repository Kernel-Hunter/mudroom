import Foundation

/// A quick check that a VM can reach Mudroom's proxy on the host. Locked
/// sessions have no other way out, and the VM network can get into a state
/// where the host address stops answering (EHOSTUNREACH to the gateway)
/// until the container system is restarted. Checked before a session
/// starts, so a broken network is fixed instead of starting a session that
/// can't reach its own API.
public enum NetworkProbe {
    public enum Result: Sendable, Equatable {
        case ok(proxy: String)
        /// No route to the host (EHOSTUNREACH, ENETUNREACH): repairable.
        case unreachable(code: String, proxy: String)
        /// Nothing answered in time: usually repairable too.
        case timeout(proxy: String)
        /// The host answered but refused the port; a firewall is the usual cause.
        case refused(proxy: String)
        /// The probe VM didn't run (no image, runtime stopped...).
        case failed(String)

        public var isOK: Bool { if case .ok = self { true } else { false } }

        /// True when restarting the container system is likely to fix it.
        public var needsRepair: Bool {
            switch self {
            case .unreachable, .timeout: true
            default: false
            }
        }

        public var summary: String {
            switch self {
            case .ok(let p): "the VM reaches the proxy at \(p)"
            case .unreachable(let code, let p): "the VM can't reach the Mac at \(p) (\(code))"
            case .timeout(let p): "the VM got no answer from the Mac at \(p)"
            case .refused(let p): "the Mac refused the VM's connection to \(p); a firewall may be blocking Mudroom"
            case .failed(let why): "the check couldn't run: \(why)"
            }
        }
    }

    static let marker = "MUDROOM_PROBE "

    /// Node script run in the VM: one TCP connection to the proxy.
    static func script(host: String, port: UInt16) -> String {
        """
        const s = require('net').connect({host: \(NetworkCheck.jsString(host)), port: \(port)});
        const t = setTimeout(() => { console.log('\(marker)timeout'); process.exit(0); }, 5000);
        s.on('connect', () => { clearTimeout(t); console.log('\(marker)ok'); s.destroy(); process.exit(0); });
        s.on('error', e => { clearTimeout(t); console.log('\(marker)' + (e.code || 'error')); process.exit(0); });
        """
    }

    /// Reads the probe VM's output.
    public static func classify(_ out: CapturedOutput, proxy: String) -> Result {
        let line = (out.stdout + "\n" + out.stderr).split(separator: "\n").last { $0.hasPrefix(marker) }
        guard let line else {
            let detail = (out.stderr + out.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(detail.isEmpty ? "exit status \(out.status)" : String(detail.suffix(400)))
        }
        let code = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        switch code {
        case "ok": return .ok(proxy: proxy)
        case "timeout", "ETIMEDOUT": return .timeout(proxy: proxy)
        case "ECONNREFUSED": return .refused(proxy: proxy)
        case "EHOSTUNREACH", "ENETUNREACH", "EHOSTDOWN", "ENETDOWN": return .unreachable(code: code, proxy: proxy)
        default: return .unreachable(code: code, proxy: proxy)
        }
    }

    /// Starts a proxy the way a locked session does and checks a VM can
    /// connect to it. Takes a few seconds (one small VM).
    public static func run(backend: SandboxBackend, image: String = AgentBaseImage.tag, scratch: URL) -> Result {
        do {
            try backend.checkAvailable()
            let net = try NetworkSetup(mode: .locked, allowlist: Allowlist(strings: []), backend: backend, logURL: nil)
            defer { net.stop() }
            guard let proxy = net.record.proxy, let url = URLComponents(string: proxy), let host = url.host,
                  let port = url.port else {
                // No proxy (this runtime has no host network): nothing to check.
                return .ok(proxy: "none")
            }
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let spec = SandboxSpec(name: "mudroom-probe-\(UInt16.random(in: 0...0xffff))", image: image, workspace: scratch,
                                   command: ["node", "-e", script(host: host, port: UInt16(port))],
                                   interactive: false, tty: false, environment: net.environment, network: net.plan.vmNetwork)
            return classify(try backend.capture(spec), proxy: "\(host):\(port)")
        } catch {
            return .failed("\(error)")
        }
    }

    // MARK: Recent results

    struct Record: Codable {
        var time: Date
        var ok: Bool
        var summary: String
    }

    static func recordURL(_ store: SessionStore) -> URL {
        store.root.appendingPathComponent("state", isDirectory: true).appendingPathComponent("network-probe.json")
    }

    public static func remember(_ result: Result, store: SessionStore, now: Date = Date()) {
        let url = recordURL(store)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = Record(time: now, ok: result.isOK, summary: result.summary)
        if let data = try? JSONEncoder().encode(r) { try? data.write(to: url, options: .atomic) }
    }

    /// True if a probe passed within `seconds` (the app checks right before
    /// it opens Terminal; the session then doesn't check again).
    public static func passedRecently(store: SessionStore, within seconds: TimeInterval = 90, now: Date = Date()) -> Bool {
        guard let data = try? Data(contentsOf: recordURL(store)), let r = try? JSONDecoder().decode(Record.self, from: data) else {
            return false
        }
        return r.ok && now.timeIntervalSince(r.time) >= -5 && now.timeIntervalSince(r.time) <= seconds
    }

    /// Probes unless one passed a moment ago, and remembers the result.
    public static func check(backend: SandboxBackend, store: SessionStore, image: String = AgentBaseImage.tag) -> Result {
        if passedRecently(store: store) { return .ok(proxy: "checked a moment ago") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mudroom-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let r = run(backend: backend, image: image, scratch: scratch)
        remember(r, store: store)
        return r
    }
}

/// Fixes the VM network by restarting Apple's container system (and, if
/// that isn't enough, recreating Mudroom's host-only network).
public enum NetworkRepair {
    public typealias Runner = (_ arguments: [String]) throws -> CapturedOutput

    /// Mudroom containers that are running now (sessions, logins, checks),
    /// from `container list --format json`.
    public static func runningMudroomContainers(_ json: Data) -> [String] {
        guard let arr = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
        return arr.compactMap { o -> String? in
            let config = o["configuration"] as? [String: Any]
            let id = (config?["id"] as? String) ?? (o["id"] as? String)
            let state = (o["status"] as? String) ?? ((o["status"] as? [String: Any])?["state"] as? String)
            guard let id, id.hasPrefix("mudroom-"), state == nil || state == "running" else { return nil }
            return id
        }.sorted()
    }

    public static func running(_ run: Runner) -> [String] {
        guard let out = try? run(["list", "--format", "json"]), out.status == 0 else { return [] }
        return runningMudroomContainers(Data(out.stdout.utf8))
    }

    /// `container system start` with the default kernel installed without
    /// asking, when this version has the flag.
    public static func startArguments(help: String) -> [String] {
        help.contains("--enable-kernel-install") ? ["system", "start", "--enable-kernel-install"] : ["system", "start"]
    }

    public enum Step: Sendable, Equatable {
        case stopping, starting, recreatingNetwork, checking
    }

    /// Restarts the container system and probes again; recreates the
    /// host-only network if the first restart didn't help. Refuses while
    /// Mudroom containers run, unless `force`.
    public static func repair(run: Runner, force: Bool = false, progress: (Step) -> Void = { _ in },
                              probe: () -> NetworkProbe.Result) throws -> NetworkProbe.Result {
        let busy = running(run)
        if !busy.isEmpty && !force {
            throw MudroomError.invalid("these Mudroom containers are still running and would be stopped: \(busy.joined(separator: ", ")). Finish those sessions first.")
        }
        progress(.stopping)
        _ = try run(["system", "stop"])
        progress(.starting)
        let help = (try? run(["system", "start", "--help"]))?.stdout ?? ""
        let started = try run(startArguments(help: help))
        if started.status != 0 {
            throw MudroomError.commandFailed("container system start", started.status, started.stderr + started.stdout)
        }
        progress(.checking)
        var result = probe()
        if result.needsRepair {
            progress(.recreatingNetwork)
            _ = try run(["network", "delete", AppleContainerBackend.networkName])
            progress(.checking)
            result = probe()
        }
        return result
    }

    /// The runner for the real `container` CLI.
    public static func containerRunner(_ exe: String) -> Runner {
        { args in try ProcessRunner.capture(exe, args) }
    }
}
