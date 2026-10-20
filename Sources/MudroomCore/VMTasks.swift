import Foundation

/// Signs an agent in once, inside a VM, into its persistent config directory.
public enum AgentLogin {
    public static func run(_ preset: AgentPreset, store: SessionStore, backend: SandboxBackend,
                           image: String = AgentBaseImage.tag, tty: Bool,
                           log: @escaping @Sendable (String) -> Void = { print($0) }) throws -> Int32 {
        try backend.checkAvailable()
        guard let home = AgentHome(store: store, agent: preset.id) else {
            throw MudroomError.invalid("\(preset.name) has no persistent config directory")
        }
        try home.create()
        // An empty scratch workspace: login never sees a project.
        let scratch = home.hostDirectory.deletingLastPathComponent().appendingPathComponent("login-workspace", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let allowlist = ProjectConfig(projectPath: "/").allowlist(agent: preset.id)
        let logURL = home.hostDirectory.deletingLastPathComponent().appendingPathComponent("login-network.jsonl")
        let net = try NetworkSetup(mode: .locked, allowlist: allowlist, backend: backend, logURL: logURL)
        defer { net.stop() }
        net.summary.forEach(log)
        log("config directory: \(home.hostDirectory.path) -> \(home.guestPath)")

        var env = preset.environment
        env.merge(home.environment) { _, n in n }
        env.merge(net.environment) { _, n in n }
        var mounts = [home.mount]
        // The sign-in link goes straight to the browser on the host.
        let handoff = tty ? try? AuthLinkHandoff(directory: home.hostDirectory.deletingLastPathComponent().appendingPathComponent("handoff")) : nil
        if let handoff {
            mounts.append(handoff.mount)
            env.merge(handoff.environment) { _, n in n }
            handoff.start { url in AuthLinkHandoff.deliver(url) { log($0) } }
        }
        defer { handoff?.stop() }
        var spec = SandboxSpec(name: "mudroom-login-\(preset.id)-\(UInt16.random(in: 0...0xffff))", image: image,
                               workspace: scratch, command: preset.loginCommand, environmentNames: [],
                               interactive: true, tty: tty, mounts: mounts, environment: env,
                               network: net.plan.vmNetwork)
        spec.firewall = net.firewall
        let status = try backend.run(spec)
        if status == 0 && !home.hasCredentials && preset.id != "gemini" {
            log("warning: the login finished but no credentials were saved in \(home.hostDirectory.path)")
        }
        return status
    }
}

/// Starts a sandbox with a project's network setup and tries to get out: through
/// the proxy to an allowed and a blocked host, and around it (DNS, direct
/// TCP to an IP, IPv6, UDP). Shows what the isolation actually does.
public enum NetworkCheck {
    public struct Outcome: Sendable, Equatable {
        public var name: String
        public var detail: String
        public var result: String
        /// True if this worked, i.e. traffic got through.
        public var connected: Bool
        /// Whether it should get through in this mode.
        public var expected: Bool?
    }

    public struct Report: Sendable {
        public var network: SessionNetwork
        public var outcomes: [Outcome]
        public var log: [NetworkLogEntry]
        public var matchesExpectation: Bool { outcomes.allSatisfy { $0.expected == nil || $0.expected == $0.connected } }
    }

    /// `hostPort`: a port Mudroom listens on, on all of the host's
    /// interfaces, for the check; nil probes 7000 instead (often AirPlay
    /// Receiver on a Mac). `firewall`: also try to remove the VM firewall
    /// as the sandbox's user.
    static func script(allowed: String, blocked: String, gateway: String?, hostPort: UInt16? = nil,
                       firewall: Bool = false) -> String {
        """
        const net = require('net'), dns = require('dns'), dgram = require('dgram');
        const proxy = process.env.HTTPS_PROXY;
        const ALLOWED = \(jsString(allowed)), BLOCKED = \(jsString(blocked)), GATEWAY = \(jsString(gateway ?? ""));
        const HOSTPORT = \(hostPort ?? 0), FIREWALL = \(firewall);
        const out = [];
        const add = (name, detail, result, connected) => out.push({name, detail, result, connected});
        function tcp(host, port, ms = 5000) {
          return new Promise(r => {
            const s = net.connect({host, port}); const t = setTimeout(() => { s.destroy(); r(['timeout', false]); }, ms);
            s.on('connect', () => { clearTimeout(t); s.destroy(); r(['connected', true]); });
            s.on('error', e => { clearTimeout(t); r([e.code || String(e), e.code === 'ECONNREFUSED' ? 'refused' : false]); });
          });
        }
        function viaProxy(host) {
          return new Promise(r => {
            if (!proxy) return r(['no proxy configured', null]);
            const u = new URL(proxy); const s = net.connect(+u.port, u.hostname); let buf = '';
            const t = setTimeout(() => { s.destroy(); r(['timeout', false]); }, 10000);
            s.on('connect', () => s.write(`CONNECT ${host}:443 HTTP/1.1\\r\\nHost: ${host}:443\\r\\n\\r\\n`));
            s.on('data', d => { buf += d; if (buf.includes('\\r\\n')) { clearTimeout(t); s.destroy();
              const line = buf.split('\\r\\n')[0]; r([line, / 200 /.test(line)]); } });
            s.on('error', e => { clearTimeout(t); r([e.code || String(e), false]); });
          });
        }
        async function get(url) {
          try { const res = await fetch(url, {signal: AbortSignal.timeout(12000), redirect: 'manual'}); return [`HTTP ${res.status}`, true]; }
          catch (e) { return [String((e.cause && (e.cause.code || e.cause.message)) || e.message), false]; }
        }
        function lookup(h) {
          return new Promise(r => {
            const t = setTimeout(() => r(['timeout', false]), 5000);
            dns.lookup(h, (e, a) => { clearTimeout(t); r(e ? [e.code, false] : [a, true]); });
          });
        }
        function udpDNS(ip) {
          return new Promise(r => {
            const s = dgram.createSocket('udp4'); const t = setTimeout(() => { s.close(); r(['no reply', false]); }, 4000);
            const q = Buffer.from('abcd01000001000000000000076578616d706c6503636f6d0000010001', 'hex');
            s.on('message', () => { clearTimeout(t); s.close(); r(['reply', true]); });
            s.on('error', e => { clearTimeout(t); s.close(); r([e.code, false]); });
            s.send(q, 53, ip);
          });
        }
        (async () => {
          let [res, ok] = await viaProxy(ALLOWED); add('proxy-allowed', `CONNECT ${ALLOWED}:443 via proxy`, res, ok);
          [res, ok] = await get(`https://${ALLOWED}/`); add('https-allowed', `HTTPS GET https://${ALLOWED}/ (proxy variables, if set)`, res, ok);
          [res, ok] = await viaProxy(BLOCKED); add('proxy-blocked', `CONNECT ${BLOCKED}:443 via proxy`, res, ok);
          [res, ok] = await get(`https://${BLOCKED}/`); add('https-blocked', `HTTPS GET https://${BLOCKED}/ (proxy variables, if set)`, res, ok);
          [res, ok] = await lookup(BLOCKED); add('dns', `resolve ${BLOCKED} in the sandbox`, res, ok);
          [res, ok] = await tcp('1.1.1.1', 443); add('direct-ipv4', 'TCP 1.1.1.1:443, ignoring the proxy', res, ok === true);
          [res, ok] = await tcp('2606:4700:4700::1111', 443); add('direct-ipv6', 'TCP [2606:4700:4700::1111]:443, ignoring the proxy', res, ok === true);
          [res, ok] = await udpDNS('8.8.8.8'); add('direct-udp', 'UDP DNS query to 8.8.8.8:53', res, ok);
          if (GATEWAY && HOSTPORT) { [res, ok] = await tcp(GATEWAY, HOSTPORT, 3000);
            add('mac-services', `TCP ${GATEWAY}:${HOSTPORT} (a port Mudroom opened on all of the host's interfaces)`, res, ok === true || ok === 'refused'); }
          else if (GATEWAY) { [res, ok] = await tcp(GATEWAY, 7000, 3000);
            add('mac-services', `TCP ${GATEWAY}:7000 (the host on the sandbox network; macOS often listens on 7000)`, res, ok === true || ok === 'refused'); }
          if (FIREWALL) {
            const r = require('child_process').spawnSync('nft', ['flush', 'ruleset'], {encoding: 'utf8'});
            const msg = r.error ? (r.error.code || String(r.error)) : r.status === 0 ? 'flushed' : ((r.stderr || '').trim().split('\\n')[0] || `exit ${r.status}`);
            add('firewall-flush', 'nft flush ruleset as the sandbox user', msg, !r.error && r.status === 0);
            if (GATEWAY && HOSTPORT) { [res, ok] = await tcp(GATEWAY, HOSTPORT, 3000);
              add('mac-services-after-flush', `TCP ${GATEWAY}:${HOSTPORT} again, after that`, res, ok === true || ok === 'refused'); }
          }
          // Exit now: a fetch aborted by its timeout can leave its tunnel
          // to the forwarder open (seen with Podman on Windows, where the
          // forwarder can't reach the proxy), and Node would wait for it.
          process.stdout.write('MUDROOM_CHECK ' + JSON.stringify(out) + '\\n', () => process.exit(0));
        })();
        """
    }

    static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    /// Which outcomes should connect in each mode. Reaching the host itself
    /// is judged only behind a VM firewall; otherwise it's a known
    /// limitation (see README) and only reported.
    static func expectation(_ name: String, _ network: SessionNetwork) -> Bool? {
        switch (network.mode, name) {
        case (_, "mac-services"), (_, "mac-services-after-flush"), (_, "firewall-flush"):
            return network.guestFirewall == true ? false : nil
        // The runtime's NAT network may have no IPv6 route at all.
        case (.open, "proxy-allowed"), (.open, "proxy-blocked"), (.open, "direct-ipv6"): return nil
        case (.open, _): return true
        case (.offline, _): return false
        case (.locked, "proxy-allowed"), (.locked, "https-allowed"): return true
        case (.locked, "direct-ipv6"), (.locked, "direct-udp"), (.locked, "dns"), (.locked, "direct-ipv4"):
            return network.enforcement == .enforced ? false : nil
        case (.locked, _): return false
        }
    }

    /// How long the check's container may take. Each probe in the script
    /// gives up on its own within seconds (about a minute in all), so this
    /// only trips when the runtime itself is stuck. Starting the container
    /// is slow on a Podman machine (a passing open check took 72 seconds on
    /// GitHub's Windows runner), hence the margin.
    public static let timeout: TimeInterval = 300

    public static func run(mode: NetworkMode, allowlist: Allowlist, backend: SandboxBackend,
                           image: String = AgentBaseImage.tag, blocked: String = "example.com",
                           scratch: URL, timeout: TimeInterval = NetworkCheck.timeout) throws -> Report {
        try backend.checkAvailable()
        let allowed = allowlist.patterns.first { !$0.isWildcard }?.value ?? "api.anthropic.com"
        let list = mode == .locked && allowlist.patterns.isEmpty ? Allowlist(strings: [allowed]) : allowlist
        let net = try NetworkSetup(mode: mode, allowlist: list, backend: backend, logURL: nil)
        defer { net.stop() }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // The host as the sandbox network sees it. Docker's internal network
        // has no host address, so probe the default bridge's gateway.
        let gateway = [net.plan.proxyHost, (try? backend.hostOnlyNetwork())?.map(\.gateway),
                       (try? backend.defaultNetwork())?.map(\.gateway)]
            .compactMap { $0 }.first { !$0.isEmpty }
        // Something listening on all of the host's interfaces, as a dev
        // server bound to 0.0.0.0 would. Not on Windows, where a new
        // listener can bring up a firewall prompt.
        #if os(Windows)
        let listener: HostListener? = nil
        #else
        let listener = mode == .open ? nil : try? HostListener()
        #endif
        defer { listener?.close() }
        var spec = SandboxSpec(name: "mudroom-check-\(UInt16.random(in: 0...0xffff))", image: image, workspace: scratch,
                               command: ["node", "-e", script(allowed: allowed, blocked: blocked,
                                                              gateway: mode == .open ? nil : gateway,
                                                              hostPort: listener?.port, firewall: net.firewall != nil)],
                               interactive: false, tty: false, environment: net.environment, network: net.plan.vmNetwork)
        spec.firewall = net.firewall
        // As in NetworkProbe: a stuck runtime would otherwise leave the
        // check waiting for good, with nothing on screen.
        spec.timeout = timeout
        let output = try backend.capture(spec)
        if output.timedOut {
            backend.stop(spec.name)
            throw MudroomError.backendUnavailable(
                "the network check's container didn't finish within \(Int(timeout)) seconds; \(backend.name) seems stuck (`\(backend.stopHint(spec.name))` stops it if it is still there)")
        }
        if net.firewall != nil, let refusal = output.stderr.split(separator: "\n").last(where: { $0.hasPrefix(GuestFirewall.failureMarker) }) {
            throw MudroomError.backendUnavailable("the firewall inside the VM couldn't be set up: " + refusal.dropFirst(GuestFirewall.failureMarker.count))
        }
        guard let line = output.stdout.split(separator: "\n").last(where: { $0.hasPrefix("MUDROOM_CHECK ") }),
              let arr = try? JSONSerialization.jsonObject(with: Data(line.dropFirst("MUDROOM_CHECK ".count).utf8)) as? [[String: Any]]
        else {
            throw MudroomError.commandFailed("network check in the VM", output.status, output.stderr + output.stdout)
        }
        let outcomes = arr.map { o in
            let name = o["name"] as? String ?? "?"
            return Outcome(name: name, detail: o["detail"] as? String ?? "", result: o["result"] as? String ?? "",
                           connected: o["connected"] as? Bool ?? false, expected: expectation(name, net.record))
        }
        net.stop()
        return Report(network: net.record, outcomes: outcomes, log: net.proxy?.loggedEntries ?? [])
    }
}

/// A TCP port open on all of the host's addresses for the network check.
/// Connections are left in the backlog: a completed handshake is all the
/// check looks for.
final class HostListener {
    let fd: Int32
    let port: UInt16

    init() throws {
        (fd, port) = try Sock.listen(host: nil, port: 0)
    }

    func close() { Sock.close(fd) }
}
