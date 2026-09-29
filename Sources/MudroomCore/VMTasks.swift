import Foundation

/// Signs an agent in once, inside a VM, into its persistent config directory.
public enum AgentLogin {
    public static func run(_ preset: AgentPreset, store: SessionStore, backend: SandboxBackend,
                           image: String = AgentBaseImage.tag, tty: Bool,
                           log: @Sendable (String) -> Void = { print($0) }) throws -> Int32 {
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
        let spec = SandboxSpec(name: "mudroom-login-\(preset.id)-\(UInt16.random(in: 0...0xffff))", image: image,
                               workspace: scratch, command: preset.loginCommand, environmentNames: [],
                               interactive: true, tty: tty, mounts: [home.mount], environment: env,
                               network: net.plan.vmNetwork)
        return try backend.run(spec)
    }
}

/// Boots a VM with a project's network setup and tries to get out: through
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

    static func script(allowed: String, blocked: String, gateway: String?) -> String {
        """
        const net = require('net'), dns = require('dns'), dgram = require('dgram');
        const proxy = process.env.HTTPS_PROXY;
        const ALLOWED = \(jsString(allowed)), BLOCKED = \(jsString(blocked)), GATEWAY = \(jsString(gateway ?? ""));
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
        function lookup(h) { return new Promise(r => dns.lookup(h, (e, a) => r(e ? [e.code, false] : [a, true]))); }
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
          [res, ok] = await lookup(BLOCKED); add('dns', `resolve ${BLOCKED} in the VM`, res, ok);
          [res, ok] = await tcp('1.1.1.1', 443); add('direct-ipv4', 'TCP 1.1.1.1:443, ignoring the proxy', res, ok === true);
          [res, ok] = await tcp('2606:4700:4700::1111', 443); add('direct-ipv6', 'TCP [2606:4700:4700::1111]:443, ignoring the proxy', res, ok === true);
          [res, ok] = await udpDNS('8.8.8.8'); add('direct-udp', 'UDP DNS query to 8.8.8.8:53', res, ok);
          if (GATEWAY) { [res, ok] = await tcp(GATEWAY, 7000, 3000);
            add('mac-services', `TCP ${GATEWAY}:7000 (a port macOS often listens on)`, res, ok === true || ok === 'refused'); }
          console.log('MUDROOM_CHECK ' + JSON.stringify(out));
        })();
        """
    }

    static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    /// Which outcomes should connect in each mode. Reaching the Mac itself is
    /// reported but not judged: it's a known limitation (see README).
    static func expectation(_ name: String, _ network: SessionNetwork) -> Bool? {
        switch (network.mode, name) {
        case (_, "mac-services"): return nil
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

    public static func run(mode: NetworkMode, allowlist: Allowlist, backend: SandboxBackend,
                           image: String = AgentBaseImage.tag, blocked: String = "example.com",
                           scratch: URL) throws -> Report {
        try backend.checkAvailable()
        let allowed = allowlist.patterns.first { !$0.isWildcard }?.value ?? "api.anthropic.com"
        let list = mode == .locked && allowlist.patterns.isEmpty ? Allowlist(strings: [allowed]) : allowlist
        let net = try NetworkSetup(mode: mode, allowlist: list, backend: backend, logURL: nil)
        defer { net.stop() }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let gateway = net.plan.proxyHost ?? (try? backend.hostOnlyNetwork())?.map(\.gateway) ?? nil
        let spec = SandboxSpec(name: "mudroom-check-\(UInt16.random(in: 0...0xffff))", image: image, workspace: scratch,
                               command: ["node", "-e", script(allowed: allowed, blocked: blocked,
                                                              gateway: mode == .open ? nil : gateway)],
                               interactive: false, tty: false, environment: net.environment, network: net.plan.vmNetwork)
        let output = try backend.capture(spec)
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
