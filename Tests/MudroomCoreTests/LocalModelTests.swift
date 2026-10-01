#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import Testing
@testable import MudroomCore

@Suite("Local models", .serialized)
struct LocalModelTests {
    func proxy(_ services: [UInt16: UInt16]) throws -> EgressProxy {
        let p = EgressProxy(.init(allowlist: Allowlist(strings: ["api.anthropic.com"]), bindHost: "127.0.0.1",
                                  connectTimeout: 3, hostServices: services))
        try p.start()
        return p
    }

    @Test("the proxy forwards host.mudroom.internal:11434 to the Mac's loopback, Host rewritten")
    func forwards() throws {
        let server = try TestHTTPServer()
        let p = try proxy([11434: server.port])
        defer { p.stop() }
        let reply = try talk(port: p.port,
            "GET http://host.mudroom.internal:11434/api/tags HTTP/1.1\r\nHost: host.mudroom.internal:11434\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 200 OK") && reply.hasSuffix("hello"))
        let seen = try #require(server.requests.first)
        #expect(seen.hasPrefix("GET /api/tags HTTP/1.1\r\n"))
        #expect(seen.contains("Host: localhost:\(server.port)\r\n"))
        #expect(!seen.contains("host.mudroom.internal"))
        // CONNECT works too (some clients tunnel).
        let tunnel = try talk(port: p.port, "CONNECT host.mudroom.internal:11434 HTTP/1.1\r\n\r\n",
                              then: "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(tunnel.hasPrefix("HTTP/1.1 200 Connection Established") && tunnel.hasSuffix("hello"))
        let log = p.loggedEntries
        #expect(log.first?.host == "host.mudroom.internal" && log.first?.port == 11434 && log.first?.allowed == true)
    }

    @Test("other ports on the Mac, and loopback by any other name, stay closed")
    func otherPortsClosed() throws {
        let server = try TestHTTPServer()
        let p = try proxy([11434: server.port])
        defer { p.stop() }
        for target in ["host.mudroom.internal:22", "host.mudroom.internal:\(server.port)", "localhost:\(server.port)",
                       "127.0.0.1:\(server.port)"] {
            let reply = try talk(port: p.port, "GET http://\(target)/ HTTP/1.1\r\nHost: \(target)\r\n\r\n")
            #expect(reply.hasPrefix("HTTP/1.1 403"), "\(target): \(reply.prefix(60))")
        }
        #expect(server.requests.isEmpty)
    }

    @Test("with Local models off, host.mudroom.internal is refused with a hint")
    func offByDefault() throws {
        let server = try TestHTTPServer()
        let p = try proxy([:])
        defer { p.stop() }
        let reply = try talk(port: p.port, "GET http://host.mudroom.internal:11434/ HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 403") && reply.contains("Local models"))
        #expect(server.requests.isEmpty)
    }

    @Test("a closed local port gives 502 with a readable reason")
    func nothingListening() throws {
        let (fd, port) = try Sock.listen(host: "127.0.0.1", port: 0)
        close(fd)
        let p = try proxy([1234: port])
        defer { p.stop() }
        let reply = try talk(port: p.port, "GET http://host.mudroom.internal:1234/v1/models HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 502") && reply.contains("nothing answers"))
    }

    @Test("the project setting decodes from older files and sets the agents' variables")
    func config() throws {
        let old = #"{"projectPath":"/p","networkMode":"locked"}"#
        #expect(try JSONDecoder().decode(ProjectConfig.self, from: Data(old.utf8)).localModels == false)
        let env = NetworkDefaults.localModelEnvironment
        #expect(env["OLLAMA_HOST"] == "http://host.mudroom.internal:11434")
        #expect(env["OLLAMA_API_BASE"] == "http://host.mudroom.internal:11434")
        #expect(env["LM_STUDIO_API_BASE"] == "http://host.mudroom.internal:1234/v1")
        // The name isn't something NO_PROXY would send around the proxy.
        #expect(!NetworkPlan.proxyEnvironment("http://x:1")["NO_PROXY"]!.contains("mudroom"))
    }
}
