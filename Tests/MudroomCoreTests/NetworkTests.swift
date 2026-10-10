#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif
import Foundation
import Testing
@testable import MudroomCore

@Suite("Allowlist")
struct AllowlistTests {
    @Test("exact hosts match case-insensitively, with or without a trailing dot")
    func exact() {
        let list = Allowlist(strings: ["api.anthropic.com"])
        #expect(list.allows("api.anthropic.com"))
        #expect(list.allows("API.Anthropic.COM"))
        #expect(list.allows("api.anthropic.com."))
        #expect(!list.allows("anthropic.com"))
        #expect(!list.allows("evil-api.anthropic.com"))
        #expect(!list.allows("api.anthropic.com.evil.net"))
    }

    @Test("wildcards match subdomains at any depth but not the bare domain")
    func wildcard() {
        let list = Allowlist(strings: ["*.githubusercontent.com"])
        #expect(list.allows("objects.githubusercontent.com"))
        #expect(list.allows("a.b.githubusercontent.com"))
        #expect(!list.allows("githubusercontent.com"))
        #expect(!list.allows("evilgithubusercontent.com"))
        #expect(!list.allows("githubusercontent.com.evil.net"))
    }

    @Test("bad patterns are rejected, duplicates dropped")
    func parsing() {
        #expect(HostPattern("") == nil)
        #expect(HostPattern("*") == nil)
        #expect(HostPattern("*.") == nil)
        #expect(HostPattern("a..b") == nil)
        #expect(HostPattern("http://x.com") == nil)
        #expect(HostPattern("x.com/path") == nil)
        #expect(HostPattern("  Pypi.ORG. ")?.value == "pypi.org")
        #expect(Allowlist(strings: ["a.com", "A.com", "b.com"]).strings == ["a.com", "b.com"])
        #expect(Allowlist(strings: []).allows("anything.com") == false)
    }

    @Test("project allowlist = agent defaults + optional registries + project hosts")
    func composition() {
        var config = ProjectConfig(projectPath: "/p")
        let claude = config.allowlist(agent: "claude")
        #expect(claude.allows("api.anthropic.com"))
        #expect(!claude.allows("api.openai.com"))
        #expect(!claude.allows("registry.npmjs.org"))
        #expect(config.allowlist(agent: "codex").allows("api.openai.com"))
        #expect(config.allowlist(agent: "gemini").allows("generativelanguage.googleapis.com"))
        #expect(config.allowlist(agent: nil).patterns.isEmpty)

        config.includePackageRegistries = true
        config.allow(HostPattern("example.org")!)
        let again = config.allow(HostPattern("example.org")!)
        #expect(!again)
        let list = config.allowlist(agent: "claude")
        #expect(list.allows("registry.npmjs.org"))
        #expect(list.allows("objects.githubusercontent.com"))
        #expect(list.allows("example.org"))

        config.includeAgentHosts = false
        #expect(!config.allowlist(agent: "claude").allows("api.anthropic.com"))
        let removed = config.disallow(HostPattern("example.org")!)
        #expect(removed)
        #expect(!config.allowlist(agent: "claude").allows("example.org"))
    }
}

@Suite("Config paths")
struct ConfigPathTests {
    @Test("project config lives in <store>/projects/<hash>.json, keyed by the resolved path")
    func projectConfig() throws {
        let tmp = try TempDir()
        let project = tmp.path("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let link = tmp.path("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)

        let store = ProjectConfigStore(store: SessionStore(root: tmp.path("store")))
        #expect(store.directory.path == tmp.path("store/projects").path)
        #expect(ProjectConfigStore.key(for: project.path) == ProjectConfigStore.key(for: link.path))
        #expect(ProjectConfigStore.key(for: project.path).count == 16)
        #expect(ProjectConfigStore.key(for: project.path) != ProjectConfigStore.key(for: tmp.path("other").path))

        // Defaults until saved.
        let fresh = try store.load(project.path)
        #expect(fresh.networkMode == .locked)
        #expect(fresh.snapshotMinutes == 5)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: project.path).path))

        try store.update(link.path) {
            $0.networkMode = .offline
            $0.allow(HostPattern("*.example.com")!)
        }
        let saved = try store.load(project.path)
        #expect(saved.networkMode == .offline)
        #expect(saved.allowedHosts == [HostPattern("*.example.com")!])
        #expect(FileManager.default.fileExists(atPath: store.url(for: project.path).path))
    }

    @Test("older config files without the newer keys still load")
    func tolerantDecode() throws {
        let json = #"{"projectPath": "/p", "allowedHosts": ["a.com"]}"#
        let c = try JSONDecoder().decode(ProjectConfig.self, from: Data(json.utf8))
        #expect(c.networkMode == .locked && c.includeAgentHosts && !c.includePackageRegistries)
        #expect(c.snapshotMinutes == 5 && c.snapshotLimit == 24)
    }

    @Test("agent homes live under <store>/agents/<id>/ and never point at the real ~/.claude")
    func agentHomes() throws {
        let store = SessionStore(root: URL(fileURLWithPath: "/tmp/mr-store"))
        let claude = try #require(AgentHome(store: store, agent: "claude"))
        #expect(claude.hostDirectory.path == "/tmp/mr-store/agents/claude/home")
        #expect(claude.guestPath == "/home/node/.claude")
        #expect(claude.environment["CLAUDE_CONFIG_DIR"] == "/home/node/.claude")
        #expect(AgentHome(store: store, agent: "codex")?.guestPath == "/home/node/.codex")
        #expect(AgentHome(store: store, agent: "gemini")?.guestPath == "/home/node/.gemini")
        #expect(AgentHome(store: store, agent: "custom") == nil)
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        for id in ["claude", "codex", "gemini"] {
            let h = try #require(AgentHome(store: store, agent: id))
            #expect(!h.hostDirectory.path.hasPrefix(realHome + "/."))
        }
    }

    @Test("presets are recognised from a session's agent name or command")
    func presetLookup() {
        #expect(AgentPreset.matching(agent: "Claude Code", command: [])?.id == "claude")
        #expect(AgentPreset.matching(agent: nil, command: ["/usr/bin/codex", "exec"])?.id == "codex")
        #expect(AgentPreset.matching(agent: "Custom: bash", command: ["bash"]) == nil)
    }
}

// MARK: - Proxy

/// A loopback HTTP server that answers every request with "hello" and keeps
/// what it received.
final class TestHTTPServer: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let received = LockedBox<[String]>([])
    private let stopped = LockedBox(false)
    var requests: [String] { received.value }

    init() throws {
        (fd, port) = try Sock.listen(host: "127.0.0.1", port: 0)
        let t = Thread { [self] in serve() }
        t.start()
    }

    private func serve() {
        while !stopped.value {
            guard Sock.waitReadable(fd, timeout: 0.1) else { continue }
            if stopped.value { return }
            guard let (conn, _) = Sock.accept(fd) else { continue }
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while buf.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = recv(conn, &chunk, chunk.count, 0)
                if n <= 0 { break }
                buf.append(contentsOf: chunk[0..<n])
            }
            if buf.range(of: Data("\r\n\r\n".utf8)) != nil {
                var r = received.value
                r.append(String(decoding: buf, as: UTF8.self))
                received.value = r
                _ = Sock.sendAll(conn, Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello".utf8))
            }
            close(conn)
        }
    }

    /// Stops accepting and closes the listening socket.
    func cancel() {
        guard !stopped.value else { return }
        stopped.value = true
        usleep(150_000)
        close(fd)
    }

    deinit { cancel() }
}

/// Blocking loopback client: sends `request`, optionally a second payload
/// after the first reply, and returns everything read until EOF.
func talk(port: UInt16, _ request: String, then second: String? = nil) throws -> String {
    let fd = Sock.make(AF_INET)
    guard fd >= 0 else { throw MudroomError.posix("socket", "", errno) }
    defer { close(fd) }
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard rc == 0 else { throw MudroomError.posix("connect", "127.0.0.1:\(port)", errno) }
    func send(_ s: String) { _ = s.withCString { MudroomCore.Sock.sendAll(fd, Data(bytes: $0, count: strlen($0))) } }
    func readSome() -> Data {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &buf, buf.count, 0)
        return n > 0 ? Data(buf[0..<n]) : Data()
    }
    send(request)
    var out = Data()
    if let second {
        // Wait for the proxy's reply to the first message, then send more.
        while out.range(of: Data("\r\n\r\n".utf8)) == nil {
            let d = readSome()
            if d.isEmpty { break }
            out.append(d)
        }
        send(second)
    }
    while true {
        let d = readSome()
        if d.isEmpty { break }
        out.append(d)
    }
    return String(decoding: out, as: UTF8.self)
}

@Suite("Egress proxy", .serialized)
struct EgressProxyTests {
    func makeProxy(_ hosts: [String], blockLocal: Bool = false, log: URL? = nil) throws -> EgressProxy {
        let proxy = EgressProxy(.init(allowlist: Allowlist(strings: hosts), logURL: log, bindHost: "127.0.0.1",
                                      blockLocalDestinations: blockLocal, connectTimeout: 3))
        try proxy.start()
        return proxy
    }

    /// Log lines are written when a connection closes, just after the reply.
    func waitForEntries(_ proxy: EgressProxy, _ n: Int) -> [NetworkLogEntry] {
        for _ in 0..<100 {
            let e = proxy.loggedEntries
            if e.count >= n { return e }
            usleep(20_000)
        }
        return proxy.loggedEntries
    }

    @Test("plain HTTP to an allowed host is forwarded in origin form with Connection: close")
    func plainAllowed() throws {
        let server = try TestHTTPServer()
        let tmp = try TempDir()
        let log = tmp.path("network.jsonl")
        let proxy = try makeProxy(["127.0.0.1"], log: log)
        defer { proxy.stop() }

        let reply = try talk(port: proxy.port,
            "GET http://127.0.0.1:\(server.port)/a/b?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nProxy-Connection: keep-alive\r\nUser-Agent: t\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 200 OK"))
        #expect(reply.hasSuffix("hello"))
        let seen = try #require(server.requests.first)
        #expect(seen.hasPrefix("GET /a/b?x=1 HTTP/1.1\r\n"))
        #expect(seen.contains("Connection: close"))
        #expect(!seen.lowercased().contains("proxy-connection"))
        #expect(seen.contains("User-Agent: t"))

        let entries = waitForEntries(proxy, 1)
        let e = try #require(entries.first)
        #expect(e.host == "127.0.0.1" && e.port == Int(server.port) && e.method == "GET" && e.allowed)
        #expect(e.bytesIn > 0 && e.bytesOut > 0 && e.reason == nil)
        proxy.stop()
        #expect(NetworkLog.read(log) == entries)
    }

    @Test("a host not on the allowlist gets 403 and nothing reaches it")
    func blocked() throws {
        let server = try TestHTTPServer()
        let proxy = try makeProxy(["api.anthropic.com"])
        defer { proxy.stop() }
        let reply = try talk(port: proxy.port, "GET http://127.0.0.1:\(server.port)/ HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(reply.contains("allowlist"))
        let connect = try talk(port: proxy.port, "CONNECT evil.example:443 HTTP/1.1\r\nHost: evil.example:443\r\n\r\n")
        #expect(connect.hasPrefix("HTTP/1.1 403"))
        usleep(200_000)
        #expect(server.requests.isEmpty)
        let entries = waitForEntries(proxy, 2)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { !$0.allowed })
        #expect(Set(entries.map(\.host)) == ["127.0.0.1", "evil.example"])
        #expect(entries.first { $0.host == "evil.example" }?.method == "CONNECT")
    }

    @Test("CONNECT to an allowed host opens a tunnel that carries bytes both ways")
    func connectTunnel() throws {
        let server = try TestHTTPServer()
        let proxy = try makeProxy(["127.0.0.1"])
        defer { proxy.stop() }
        let reply = try talk(port: proxy.port,
                             "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n\r\n",
                             then: "GET /tunneled HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 200 Connection Established\r\n\r\n"))
        #expect(reply.hasSuffix("hello"))
        #expect(server.requests.first?.hasPrefix("GET /tunneled HTTP/1.1") == true)
        let e = try #require(waitForEntries(proxy, 1).first)
        #expect(e.method == "CONNECT" && e.allowed && e.bytesIn >= 5)
    }

    @Test("an allowed name that resolves to a local address is refused")
    func localDestination() throws {
        let server = try TestHTTPServer()
        let proxy = try makeProxy(["localhost", "127.0.0.1"], blockLocal: true)
        defer { proxy.stop() }
        let reply = try talk(port: proxy.port, "CONNECT localhost:\(server.port) HTTP/1.1\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 403"))
        #expect(reply.contains("local address"))
        let e = try #require(waitForEntries(proxy, 1).first)
        #expect(!e.allowed && e.reason?.contains("local") == true)
        #expect(server.requests.isEmpty)
    }

    @Test("an allowed host that can't be reached gets 502")
    func unreachable() throws {
        // A port nothing listens on: bound but never listening, and held for
        // the whole test so a server started by a parallel test can't take it.
        let held = Sock.make(AF_INET)
        defer { close(held) }
        let bound = Sock.withSockaddr(IPAddress("127.0.0.1")!, port: 0) { bind(held, $0, $1) }
        try #require(bound == 0)
        let dead = Sock.localPort(held)
        let proxy = try makeProxy(["127.0.0.1"])
        defer { proxy.stop() }
        let reply = try talk(port: proxy.port, "CONNECT 127.0.0.1:\(dead) HTTP/1.1\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 502"))
        let e = try #require(waitForEntries(proxy, 1).first)
        #expect(e.allowed && e.reason?.hasPrefix("upstream") == true)
    }

    @Test("requests that aren't proxy requests are rejected")
    func malformed() throws {
        let proxy = try makeProxy(["127.0.0.1"])
        defer { proxy.stop() }
        #expect(try talk(port: proxy.port, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").hasPrefix("HTTP/1.1 400"))
        #expect(try talk(port: proxy.port, "GET https://127.0.0.1/ HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 400"))
        #expect(try talk(port: proxy.port, "CONNECT 127.0.0.1 HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 400"))
    }

    @Test("only loopback and the VM subnet may use the proxy")
    func clients() throws {
        let proxy = EgressProxy(.init(allowlist: Allowlist([]), clientSubnets: [IPv4Subnet("192.168.128.0/24")!]))
        func ep(_ s: String) -> IPAddress { IPAddress(s)! }
        #expect(proxy.isAllowedClient(ep("127.0.0.1")))
        #expect(proxy.isAllowedClient(ep("::1")))
        #expect(proxy.isAllowedClient(ep("192.168.128.7")))
        #expect(proxy.isAllowedClient(ep("::ffff:192.168.128.7")))
        #expect(!proxy.isAllowedClient(ep("192.168.0.20")))
        #expect(!proxy.isAllowedClient(ep("10.0.0.5")))
        #expect(proxy.isLocalDestination(ep("127.0.0.1")))
        #expect(proxy.isLocalDestination(ep("169.254.169.254")))
        #expect(proxy.isLocalDestination(ep("192.168.128.1")))
        #expect(proxy.isLocalDestination(ep("fe80::1")))
        #expect(!proxy.isLocalDestination(ep("160.79.104.10")))
        #expect(IPv4Subnet("10.1.2.3/8")?.description == "10.0.0.0/8")
        #expect(IPv4Subnet("nope") == nil)
    }

    @Test("the log summary puts blocked hosts first and totals bytes")
    func summary() {
        let t = Date(timeIntervalSince1970: 1000)
        let rows = NetworkLog.summarize([
            .init(time: t, host: "a.com", port: 443, method: "CONNECT", allowed: true, bytesOut: 10, bytesIn: 100),
            .init(time: t.addingTimeInterval(5), host: "a.com", port: 443, method: "CONNECT", allowed: true, bytesOut: 5, bytesIn: 50),
            .init(time: t, host: "b.com", port: 443, method: "CONNECT", allowed: false, reason: "not on this project's allowlist"),
        ])
        #expect(rows.map(\.host) == ["b.com", "a.com"])
        #expect(rows[1].count == 2 && rows[1].bytesIn == 150 && rows[1].bytesOut == 15)
        #expect(rows[1].last == t.addingTimeInterval(5))
        #expect(rows[0].reason != nil)
    }
}

@Test("logged destinations read as host:port, with IPv6 bracketed and no :0")
func endpointDisplay() {
    #expect(NetworkLog.endpoint("example.com", 443) == "example.com:443")
    #expect(NetworkLog.endpoint("::1", 443) == "[::1]:443")
    #expect(NetworkLog.endpoint("[::1]", 443) == "[::1]:443")
    #expect(NetworkLog.endpoint("example.com", 0) == "example.com")
    #expect(NetworkLog.endpoint("", 0) == "(no host)")
}
