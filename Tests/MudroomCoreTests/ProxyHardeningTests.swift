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

/// Like `talk`, but sends raw bytes (NULs included).
func talkRaw(port: UInt16, _ bytes: [UInt8], then second: String? = nil, timeout: Int = 5) throws -> String {
    let fd = Sock.make(AF_INET)
    guard fd >= 0 else { throw MudroomError.posix("socket", "", errno) }
    defer { close(fd) }
    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard rc == 0 else { throw MudroomError.posix("connect", "127.0.0.1:\(port)", errno) }
    _ = Sock.sendAll(fd, Data(bytes))
    var out = Data()
    func readSome() -> Data {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &buf, buf.count, 0)
        return n > 0 ? Data(buf[0..<n]) : Data()
    }
    if let second {
        while out.range(of: Data("\r\n\r\n".utf8)) == nil {
            let d = readSome()
            if d.isEmpty { break }
            out.append(d)
        }
        _ = Sock.sendAll(fd, Data(second.utf8))
    }
    while true {
        let d = readSome()
        if d.isEmpty { break }
        out.append(d)
    }
    return String(decoding: out, as: UTF8.self)
}

@Suite("Host name validation")
struct HostNameTests {
    func ok(_ s: String) -> String? {
        if case .success(let h) = HostName.parse(s) { return h.canonical }
        return nil
    }

    @Test("names are lowercased LDH labels; one trailing dot is dropped")
    func names() {
        #expect(ok("API.Anthropic.COM") == "api.anthropic.com")
        #expect(ok("api.anthropic.com.") == "api.anthropic.com")
        #expect(ok("xn--bcher-kva.example") == "xn--bcher-kva.example")
        #expect(ok("localhost") == "localhost")
    }

    @Test("anything ambiguous is rejected: NUL, %, whitespace, controls, userinfo, empty labels, hyphens, non-ASCII")
    func rejects() {
        for bad in ["example.com\u{0}.githubusercontent.com", "example.com%00.x.com", "a b.com", "a\t.com", "a\r.com",
                    "user@x.com", "a..b", ".a.com", "a.com..", "-a.com", "a-.com", "a_b.com", "bücher.example",
                    "a/b", "a\\b", "", String(repeating: "a", count: 64) + ".com",
                    (0..<60).map { _ in "abcd" }.joined(separator: ".")] {
            #expect(ok(bad) == nil, "accepted \(bad.debugDescription)")
        }
    }

    @Test("numeric hosts: only canonical dotted quads are IPv4; shorthands are rejected")
    func numeric() {
        #expect(ok("127.0.0.1") == "127.0.0.1")
        #expect(ok("8.8.8.8") == "8.8.8.8")
        for bad in ["127.1", "2130706433", "0x7f.0.0.1", "0177.0.0.1", "127.000.0.1", "1.2.3.256", "1.2.3.4.5"] {
            #expect(ok(bad) == nil, "accepted \(bad)")
        }
        #expect(ok("::1") == "::1")
        #expect(ok("0:0:0:0:0:0:0:1") == "::1")
        #expect(ok("fe80::1%en0") == nil)
    }

    @Test("IP literals only match an exact IP pattern; wildcards never match addresses")
    func ipMatching() {
        let list = Allowlist(strings: ["*.githubusercontent.com", "10.0.0.5"])
        #expect(list.allows("10.0.0.5"))
        #expect(!list.allows("10.0.0.6"))
        #expect(!list.allows("example.com\u{0}.githubusercontent.com"))
        #expect(HostPattern("*.10.0.0.5") == nil)
        #expect(HostPattern("0:0::1")?.value == "::1")
    }
}

@Suite("Proxy request parsing")
struct ProxyRequestTests {
    func parse(_ s: String) -> Result<ProxyRequest, ProxyRequest.Failure> { ProxyRequest.parse(Data(s.utf8)) }

    @Test("CONNECT and absolute http:// requests parse to a canonical host")
    func good() throws {
        let c = try parse("CONNECT API.anthropic.com:443 HTTP/1.1\r\nHost: x\r\n").get()
        #expect(c.host == .name("api.anthropic.com") && c.port == 443 && c.isConnect)
        let v6 = try parse("CONNECT [::1]:8080 HTTP/1.1").get()
        #expect(v6.host == .ip(IPAddress("::1")!) && v6.port == 8080)
        let g = try parse("GET http://pypi.org?x=1 HTTP/1.1\r\nHost: evil\r\n").get()
        #expect(g.host == .name("pypi.org") && g.port == 80 && g.originTarget == "/?x=1")
    }

    @Test("smuggling attempts are refused before any lookup")
    func bad() {
        let attempts = [
            "CONNECT example.com\u{0}.githubusercontent.com:443 HTTP/1.1",
            "GET http://example.com%00.githubusercontent.com/ HTTP/1.1",
            "GET http://example.com%2e.githubusercontent.com/ HTTP/1.1",
            "GET http://user@pypi.org/ HTTP/1.1",
            "GET http://pypi.org:/ HTTP/1.1",
            "GET http://pypi.org/#x HTTP/1.1",
            "CONNECT pypi.org:+443 HTTP/1.1",
            "CONNECT pypi.org:99999 HTTP/1.1",
            "CONNECT ::1:443 HTTP/1.1",
            "CONNECT pypi.org :443 HTTP/1.1",
            "CONNECT  pypi.org:443 HTTP/1.1",
            "CONNECT pypi.org:443 HTTP/2.0",
            "CONNECT pypi.org:443 HTTP/1.1\r\n folded: header",
            "CONNECT pypi.org:443 HTTP/1.1\nHost: x",
            "CONNECT 127.1:443 HTTP/1.1",
        ]
        for a in attempts {
            if case .success(let r) = parse(a) { Issue.record("accepted \(a.debugDescription) as \(r.host)") }
        }
    }

    @Test("plain HTTP goes upstream with Host set to the checked target, not the client's")
    func hostRewrite() throws {
        let r = try parse("GET http://pypi.org:8080/simple HTTP/1.1\r\nHost: evil.example\r\nhost: also-evil\r\nAccept: */*\r\nProxy-Authorization: x\r\n").get()
        let head = String(decoding: r.upstreamHead(), as: UTF8.self)
        #expect(head.hasPrefix("GET /simple HTTP/1.1\r\nHost: pypi.org:8080\r\n"))
        #expect(!head.contains("evil"))
        #expect(head.contains("Accept: */*"))
        #expect(!head.lowercased().contains("proxy-authorization"))
        #expect(head.hasSuffix("Connection: close\r\n\r\n"))
    }
}

@Suite("Proxy hardening", .serialized)
struct ProxyHardeningTests {
    func proxy(_ hosts: [String], blockLocal: Bool, headerTimeout: TimeInterval = 10, maxConnections: Int = 256) throws -> EgressProxy {
        let p = EgressProxy(.init(allowlist: Allowlist(strings: hosts), bindHost: "127.0.0.1",
                                  blockLocalDestinations: blockLocal, connectTimeout: 3,
                                  headerTimeout: headerTimeout, maxConnections: maxConnections))
        try p.start()
        return p
    }

    @Test("a NUL in a CONNECT host is refused with 400 and nothing is connected (was C1)")
    func nulHostConnect() throws {
        let server = try TestHTTPServer()
        let p = try proxy(["*.allowed.test"], blockLocal: false)
        defer { p.stop() }
        let req = Array("CONNECT 127.0.0.1".utf8) + [0] + Array(".allowed.test:\(server.port) HTTP/1.1\r\n\r\n".utf8)
        let reply = try talkRaw(port: p.port, req, then: "GET /smuggled HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 400"), "\(reply.prefix(80).debugDescription)")
        usleep(200_000)
        #expect(server.requests.isEmpty)
        for _ in 0..<50 where p.loggedEntries.isEmpty { usleep(20_000) }
        let entry = p.loggedEntries.first
        #expect(entry?.allowed == false)
        #expect(entry?.host.contains("\\x00") == true)
    }

    @Test("%00 in a plain-HTTP URL host is refused (was C1)")
    func percentHost() throws {
        let server = try TestHTTPServer()
        let p = try proxy(["*.allowed.test"], blockLocal: false)
        defer { p.stop() }
        let reply = try talk(port: p.port, "GET http://127.0.0.1%00.allowed.test:\(server.port)/ HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 400"), "\(reply.prefix(80).debugDescription)")
        usleep(200_000)
        #expect(server.requests.isEmpty)
    }

    @Test("the client's Host header is replaced by the target's (was M6)")
    func hostHeaderRewritten() throws {
        let server = try TestHTTPServer()
        let p = try proxy(["127.0.0.1"], blockLocal: false)
        defer { p.stop() }
        _ = try talk(port: p.port, "GET http://127.0.0.1:\(server.port)/ HTTP/1.1\r\nHost: evil.example\r\n\r\n")
        let seen = try #require(server.requests.first)
        #expect(!seen.contains("evil.example"))
        #expect(seen.contains("Host: 127.0.0.1:\(server.port)\r\n"))
    }

    @Test("private, CGNAT, ULA and this machine's own addresses are refused destinations (was M6)")
    func privateRanges() {
        let p = EgressProxy(.init(allowlist: Allowlist(strings: ["192.168.1.50"]), clientSubnets: [IPv4Subnet("192.168.64.0/24")!]))
        func refused(_ s: String) -> Bool { p.isLocalDestination(IPAddress(s)!) }
        for a in ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "100.64.0.1", "198.18.0.1",
                  "fd00::1", "2001:db8::1", "::ffff:10.0.0.1", "64:ff9b::a00:1", "2002:a00:1::1", "2002:7f00:1::1",
                  "127.0.0.1", "0.0.0.0", "169.254.169.254", "224.0.0.1", "255.255.255.255", "::", "::1", "fe80::1",
                  "192.168.64.3"] {
            #expect(refused(a), "\(a) should be refused")
        }
        for a in ["160.79.104.10", "8.8.8.8", "172.32.0.1", "2606:4700:4700::1111"] {
            #expect(!refused(a), "\(a) should be allowed")
        }
        // A private address is reachable when that exact IP is allowlisted.
        #expect(!refused("192.168.1.50"))
        // Every non-loopback address of this machine is refused.
        for a in IPAddress.hostAddresses() { #expect(refused(a.description), "own address \(a)") }
    }

    @Test("a client that sends no request is cut off after the header timeout (was L1)")
    func headerTimeout() throws {
        let p = try proxy(["x.test"], blockLocal: true, headerTimeout: 1)
        defer { p.stop() }
        let t = Date()
        let reply = try talkRaw(port: p.port, [], timeout: 5)
        #expect(Date().timeIntervalSince(t) < 4)
        #expect(reply.hasPrefix("HTTP/1.1 408"))
    }

    @Test("connections over the cap are refused, and the proxy keeps serving after they go (was L1)")
    func connectionCap() throws {
        let server = try TestHTTPServer()
        let p = try proxy(["127.0.0.1"], blockLocal: false, headerTimeout: 3, maxConnections: 2)
        defer { p.stop() }
        var idle: [Int32] = []
        for _ in 0..<2 {
            if case .success(let fd) = Sock.connect(IPAddress("127.0.0.1")!, port: p.port, timeout: 2, cancelled: { false }) {
                idle.append(fd)
            }
        }
        usleep(200_000)
        let over = try talk(port: p.port, "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\n\r\n")
        #expect(over.hasPrefix("HTTP/1.1 503"))
        idle.forEach { close($0) }
        usleep(300_000)
        let again = try talk(port: p.port, "GET http://127.0.0.1:\(server.port)/ HTTP/1.1\r\n\r\n")
        #expect(again.hasPrefix("HTTP/1.1 200"))
    }

    @Test("a request head over 32 KB is refused")
    func headerSize() throws {
        let p = try proxy(["x.test"], blockLocal: true)
        defer { p.stop() }
        let reply = try talk(port: p.port, "GET http://x.test/ HTTP/1.1\r\nX-Big: " + String(repeating: "a", count: 40_000) + "\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 400"), "\(reply.prefix(80).debugDescription)")
    }
}

/// The original report's repro against the real internet. Opt in with
/// MUDROOM_NET_TESTS=1.
@Suite("Proxy against the internet", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MUDROOM_NET_TESTS"] == "1"))
struct ProxyInternetTests {
    @Test("example.com\\0.githubusercontent.com and %00 forms no longer reach example.com")
    func realBypass() throws {
        var config = ProjectConfig(projectPath: "/p")
        config.includePackageRegistries = true
        let list = config.allowlist(agent: "claude")
        let p = EgressProxy(.init(allowlist: list, bindHost: "127.0.0.1", blockLocalDestinations: true, connectTimeout: 5))
        try p.start()
        defer { p.stop() }
        let req = Array("CONNECT example.com".utf8) + [0] + Array(".githubusercontent.com:80 HTTP/1.1\r\n\r\n".utf8)
        let reply = try talkRaw(port: p.port, req, then: "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n", timeout: 8)
        #expect(reply.hasPrefix("HTTP/1.1 400") && !reply.contains("Example Domain"))
        let reply2 = try talkRaw(port: p.port, Array("GET http://example.com%00.githubusercontent.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8), timeout: 8)
        #expect(reply2.hasPrefix("HTTP/1.1 400") && !reply2.contains("Example Domain"))
    }
}
