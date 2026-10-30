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

/// Runs `body` on its own thread after `seconds` (not on a dispatch queue,
/// which other tests running in parallel can keep busy).
func later(_ seconds: TimeInterval, _ body: @escaping @Sendable () -> Void) {
    Thread {
        Thread.sleep(forTimeInterval: seconds)
        body()
    }.start()
}

@Suite("Connection watcher")
struct ConnectionWatchTests {
    @Test("the proxy's address is spelled the way /proc/net/tcp and tcp6 print a remote end")
    func procNetAddresses() throws {
        // What Linux printed in the VM for a connection to 127.0.0.1:3128.
        #expect(ConnectionWatch.procNetAddresses(.v4(0x7F00_0001), port: 3128)
            == ["0100007F:0C38", "0000000000000000FFFF00000100007F:0C38"])
        let gw = try #require(IPAddress("192.168.128.1"))
        #expect(ConnectionWatch.procNetAddresses(gw, port: 51234) == ["0180A8C0:C822", "0000000000000000FFFF00000180A8C0:C822"])
        let lo6 = try #require(IPAddress("::1"))
        #expect(ConnectionWatch.procNetAddresses(lo6, port: 80) == ["00000000000000000000000001000000:0050"])
        let fd = try #require(IPAddress("fd00::1:2"))
        #expect(ConnectionWatch.procNetAddresses(fd, port: 443) == ["000000FD000000000000000002000100:01BB"])
    }

    @Test("a watcher needs an IP address, a port and a hex token; its arguments are shell-safe")
    func watchConfig() throws {
        let token = ConnectionWatch.newToken()
        #expect(token.count == 32 && ConnectionWatch.isToken(token))
        #expect(token != ConnectionWatch.newToken())
        #expect(ConnectionWatch(token: token, proxyHost: "host.docker.internal", port: 3128) == nil)
        #expect(ConnectionWatch(token: token, proxyHost: "192.168.128.1", port: 0) == nil)
        #expect(ConnectionWatch(token: "not a token; rm -rf /", proxyHost: "192.168.128.1", port: 1) == nil)
        let w = try #require(ConnectionWatch(token: token, proxyHost: "192.168.128.1", port: 51234))
        #expect(w.arguments == ["192.168.128.1", "51234", "0180A8C0:C822", "0000000000000000FFFF00000180A8C0:C822"])
        for a in w.arguments {
            #expect(a.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }, "\(a)")
        }
    }

    @Test("watcher lines parse to a port, pid and command lines; anything else is dropped")
    func parseLines() throws {
        let r = try #require(ConnectionOrigin.parse("40312\t57\tcurl -sI https://github.com\tbash -c curl -sI https://github.com\tclaude"))
        #expect(r.port == 40312)
        #expect(r.origin == ConnectionOrigin(pid: 57, commands: ["curl -sI https://github.com", "bash -c curl -sI https://github.com", "claude"]))
        let gone = try #require(ConnectionOrigin.parse("40313\t-"))
        #expect(gone.port == 40313 && gone.origin == nil)
        for bad in ["", "x\t1\tcurl", "0\t1\tcurl", "70000\t1\tcurl", "40312", "40312\t0\tcurl", "40312\tabc\tcurl", "MUDROOM-WATCH x"] {
            #expect(ConnectionOrigin.parse(Substring(bad)) == nil, "\(bad)")
        }
        // At most 8 command lines, each cut to 256 characters.
        let long = (0..<20).map { _ in String(repeating: "a", count: 1000) }.joined(separator: "\t")
        let capped = try #require(ConnectionOrigin.parse(Substring("1\t2\t" + long))?.origin)
        #expect(capped.commands.count == 8 && capped.commands.allSatisfy { $0.count == 256 })
    }

    @Test("command lines lose control characters and bidi overrides (they end up in a terminal)")
    func cleaning() {
        #expect(ConnectionOrigin.clean("curl \u{1b}]0;pwned\u{07}\u{1b}[2J x") == "curl ]0;pwned [2J x")
        #expect(ConnectionOrigin.clean("evil\u{202e}gnp.exe") == "evil gnp.exe")
        #expect(ConnectionOrigin.clean("a\u{85}b\u{7f}c") == "a b c")
        #expect(ConnectionOrigin.clean("  node   server.js  ") == "node server.js")
        #expect(ConnectionOrigin.clean("naïve café") == "naïve café")
    }

    @Test("a record is matched by port and arrival time, closest to when the connection started")
    func matching() {
        let o = ConnectionOrigins()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let a = ConnectionOrigin(pid: 10, commands: ["git fetch"])
        let b = ConnectionOrigin(pid: 20, commands: ["npm install"])
        o.add(40000, a, at: t0)
        // The same port again, much later: another connection.
        o.add(40000, b, at: t0.addingTimeInterval(120))
        #expect(o.find(port: 40000, start: t0, end: t0.addingTimeInterval(5))?.origin == a)
        #expect(o.find(port: 40000, start: t0.addingTimeInterval(119.9), end: t0.addingTimeInterval(121))?.origin == b)
        // A long connection: its record came right after it started.
        #expect(o.find(port: 40000, start: t0.addingTimeInterval(-0.05), end: t0.addingTimeInterval(3600))?.origin == a)
        // Nothing for another port, or for a connection long after both.
        #expect(o.find(port: 40001, start: t0, end: t0.addingTimeInterval(5)) == nil)
        #expect(o.find(port: 40000, start: t0.addingTimeInterval(30), end: t0.addingTimeInterval(31)) == nil)
        // Seen, but its process was gone: a record without an origin.
        o.add(40002, nil, at: t0)
        let gone = o.find(port: 40002, start: t0, end: t0.addingTimeInterval(1))
        #expect(gone != nil && gone?.origin == nil)
    }

    @Test("waiting for a record returns as soon as it arrives, or at the deadline")
    func waiting() {
        let o = ConnectionOrigins()
        let start = Date()
        later(0.1) { o.add(41000, ConnectionOrigin(pid: 5, commands: ["curl"])) }
        let r = o.wait(port: 41000, start: start, deadline: start.addingTimeInterval(2))
        #expect(r?.origin?.pid == 5)
        #expect(Date().timeIntervalSince(start) < 1.5)
        let before = Date()
        #expect(o.wait(port: 41001, start: before, deadline: before.addingTimeInterval(0.2)) == nil)
        #expect(Date().timeIntervalSince(before) >= 0.19)
    }

    @Test("records are capped, oldest first, and per port")
    func limits() {
        let o = ConnectionOrigins(limit: 10)
        let t = Date()
        for p in 1...30 { o.add(UInt16(p), ConnectionOrigin(pid: p, commands: ["x"]), at: t) }
        #expect(o.find(port: 1, start: t, end: t) == nil)
        #expect(o.find(port: 30, start: t, end: t)?.origin?.pid == 30)
        for i in 0..<10 { o.add(500, ConnectionOrigin(pid: i + 1, commands: ["y"]), at: t.addingTimeInterval(Double(i))) }
        // Only the last few for one port are kept.
        #expect(o.find(port: 500, start: t, end: t.addingTimeInterval(1)) == nil)
        #expect(o.find(port: 500, start: t.addingTimeInterval(9), end: t.addingTimeInterval(9))?.origin?.pid == 10)
    }

    @Test("a stream of watcher lines fills the table; partial lines wait for the rest")
    func consume() {
        let o = ConnectionOrigins()
        var chunks = [Data("100\t1\tcu".utf8), Data("rl\n200\t-\n300\tjunk\n".utf8), Data("400\t4\tgit\n".utf8)]
        o.consume { chunks.isEmpty ? nil : chunks.removeFirst() }
        let now = Date()
        #expect(o.find(port: 100, start: now, end: now)?.origin?.commands == ["curl"])
        #expect(o.find(port: 200, start: now, end: now) != nil)
        #expect(o.find(port: 300, start: now, end: now) == nil)
        #expect(o.find(port: 400, start: now, end: now)?.origin?.pid == 4)
    }
}

@Suite("Network log with processes")
struct NetworkLogProcessTests {
    @Test("logs written before the watcher existed still load, without processes")
    func oldLog() throws {
        let tmp = try TempDir()
        let url = tmp.path("network.jsonl")
        let old = """
        {"allowed":true,"bytesIn":6120,"bytesOut":1003,"durationMs":727,"host":"github.com","method":"CONNECT","port":443,"time":"2026-10-01T10:00:00.123Z"}
        {"allowed":false,"bytesIn":0,"bytesOut":0,"durationMs":3,"host":"example.com","method":"CONNECT","port":443,"reason":"not on this project's allowlist","time":"2026-10-01T10:00:01Z"}

        """
        try old.write(to: url, atomically: true, encoding: .utf8)
        let entries = NetworkLog.read(url)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.pid == nil && $0.command == nil && $0.parents == nil })
        #expect(!NetworkLog.hasProcesses(entries))
        #expect(NetworkLog.summarize(entries).allSatisfy { $0.programs.isEmpty })
        // Old sessions have no processWatch either.
        let rec = #"{"mode":"locked","enforcement":"enforced","allowlist":[],"guestFirewall":true}"#
        #expect(try JSONDecoder().decode(SessionNetwork.self, from: Data(rec.utf8)).processWatch == nil)
    }

    @Test("new entries carry pid, command and parents; entries without them leave the keys out")
    func newFields() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let e = NetworkLogEntry(time: t, host: "github.com", port: 443, method: "CONNECT", allowed: true,
                                origin: ConnectionOrigin(pid: 57, commands: ["curl -sI https://github.com", "bash", "claude"]))
        #expect(e.pid == 57 && e.command == "curl -sI https://github.com" && e.parents == ["bash", "claude"])
        let line = NetworkLog.jsonLine(e)
        #expect(line.contains(#""pid":57"#) && line.contains(#""parents":["bash","claude"]"#))
        let back = try NetworkLog.decoder().decode(NetworkLogEntry.self, from: Data(line.utf8))
        #expect(back == e)

        let plain = NetworkLogEntry(time: t, host: "github.com", port: 443, method: "CONNECT", allowed: true)
        let plainLine = NetworkLog.jsonLine(plain)
        #expect(!plainLine.contains("pid") && !plainLine.contains("command") && !plainLine.contains("parents"))
        // The agent itself: no parents.
        let top = NetworkLogEntry(time: t, host: "api.anthropic.com", port: 443, method: "CONNECT", allowed: true,
                                  origin: ConnectionOrigin(pid: 1, commands: ["claude"]))
        #expect(top.parents == nil && top.command == "claude")
    }

    @Test("program names: the script for interpreters, the module for python -m, the shell for -c")
    func programNames() {
        let cases: [(String, String)] = [
            ("curl -sI https://github.com", "curl"),
            ("/usr/lib/git-core/git-remote-https origin https://github.com/x/y", "git-remote-https"),
            ("node /usr/local/bin/npm install", "npm"),
            ("node /usr/local/lib/node_modules/npm/bin/npm-cli.js install", "npm-cli"),
            ("npm install left-pad", "npm"),
            ("node --no-warnings /usr/local/bin/claude", "claude"),
            ("node -e fetch('https://x')", "node"),
            ("/opt/uv/python/cpython-3.12/bin/python3.12 -m pip install requests", "pip"),
            ("python3 -c import urllib.request", "python3"),
            ("python3 manage.py runserver", "manage"),
            ("bash -c curl https://x", "bash"),
            ("bash /workspace/inside.sh", "inside"),
            ("/usr/bin/env FOO=1 node app.js", "app"),
            ("", "?"),
        ]
        for (command, name) in cases {
            #expect(NetworkLog.programName(command) == name, "\(command)")
        }
    }

    @Test("command and program columns: shortened, cut to width, honest about unknowns")
    func labels() {
        let t = Date()
        var e = NetworkLogEntry(time: t, host: "pypi.org", port: 443, method: "CONNECT", allowed: true,
                                origin: ConnectionOrigin(pid: 58, commands: ["/opt/uv/python/cpython-3.12/bin/python3 -c import urllib.request; print(1)", "bash /workspace/x.sh"]))
        #expect(NetworkLog.commandLabel(e) == "[58] python3 -c import urllib.request; print(1)")
        #expect(NetworkLog.commandLabel(e, width: 20) == "[58] python3 -c i...")
        #expect(NetworkLog.commandLabel(e, width: 20).count == 20)
        #expect(NetworkLog.programChain(e) == "x > python3")
        e.pid = nil
        e.command = nil
        e.parents = nil
        #expect(NetworkLog.commandLabel(e) == "unknown")
        #expect(NetworkLog.programChain(e) == nil)
        #expect(NetworkLog.shortCommand("/a/b/c") == "c")
        #expect(NetworkLog.shortCommand("/a/b/ x") == "/a/b/ x")
        #expect(NetworkLog.shortCommand("curl /a/b") == "curl /a/b")

        func entry(_ cmd: String?) -> NetworkLogEntry {
            NetworkLogEntry(time: t, host: "github.com", port: 443, method: "CONNECT", allowed: true,
                            origin: cmd.map { ConnectionOrigin(pid: 2, commands: [$0]) })
        }
        let rows = NetworkLog.summarize([entry("git fetch"), entry("curl x"), entry("git pull"), entry(nil), entry(nil)])
        #expect(rows.count == 1)
        #expect(rows[0].programs == ["git", "curl"] && rows[0].unattributed == 2)
        #expect(NetworkLog.programsLabel(rows[0]) == "git, curl and 2 unknown")
        let one = NetworkLog.summarize([entry("npm install")])[0]
        #expect(NetworkLog.programsLabel(one) == "npm")
        let none = NetworkLog.summarize([entry(nil)])[0]
        #expect(NetworkLog.programsLabel(none) == "unknown")
        let many = NetworkLog.summarize(["a", "b", "c", "d", "e"].map { entry($0) })[0]
        #expect(NetworkLog.programsLabel(many) == "a, b, c and 2 more")
    }
}

@Suite("Proxy with a connection watcher", .serialized)
struct ProxyWatchTests {
    func open(_ port: UInt16) throws -> Int32 {
        switch Sock.connect(.v4(0x7F00_0001), port: port, timeout: 5, cancelled: { false }) {
        case .success(let fd): return fd
        case .failure(let e): throw MudroomError.invalid("connect: \(Sock.errorText(e.code))")
        }
    }

    func readToEnd(_ fd: Int32, timeout: TimeInterval = 5) -> String {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while Sock.waitReadable(fd, timeout: timeout) {
            guard let n = Sock.receive(fd, &buf) else { continue }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return String(decoding: out, as: UTF8.self)
    }

    func send(_ fd: Int32, _ s: String) { _ = Sock.sendAll(fd, Data(s.utf8)) }

    func proxy(token: String?, proxyLine: Bool = false) throws -> EgressProxy {
        let p = EgressProxy(.init(allowlist: Allowlist(strings: ["allowed.test"]), bindHost: "127.0.0.1", connectTimeout: 2,
                                  watchToken: token, acceptsProxyLine: proxyLine))
        try p.start()
        return p
    }

    func waitForEntries(_ p: EgressProxy, _ n: Int) {
        for _ in 0..<150 where p.loggedEntries.count < n { usleep(20_000) }
    }

    @Test("a refused connection waits for the watcher's report and is logged with its process")
    func refusedIsAttributed() throws {
        let token = ConnectionWatch.newToken()
        let p = try proxy(token: token)
        defer { p.stop() }
        let watcher = try open(p.port)
        defer { Sock.close(watcher) }
        send(watcher, "MUDROOM-WATCH \(token)\r\n\r\n")

        let client = try open(p.port)
        defer { Sock.close(client) }
        let source = Sock.localPort(client)
        // The report comes 100 ms later, as it would from a watcher that
        // polls; the refusal is held until it is in.
        later(0.1) { self.send(watcher, "\(source)\t42\tcurl -sI https://blocked.test\u{1b}[31m\tbash -c curl\tclaude\n") }
        let started = Date()
        send(client, "CONNECT blocked.test:443 HTTP/1.1\r\nHost: blocked.test:443\r\n\r\n")
        let reply = readToEnd(client)
        #expect(reply.hasPrefix("HTTP/1.1 403"))
        #expect(Date().timeIntervalSince(started) < ProxyExchange.refusalHold + 0.4)
        waitForEntries(p, 1)
        let e = try #require(p.loggedEntries.first)
        #expect(e.host == "blocked.test" && !e.allowed)
        #expect(e.pid == 42)
        #expect(e.command == "curl -sI https://blocked.test [31m")
        #expect(e.parents == ["bash -c curl", "claude"])
        // The watcher's own connection is never a log entry.
        #expect(p.loggedEntries.count == 1)
    }

    @Test("without a report the entry has no process, and the refusal waits no longer than the hold")
    func unreported() throws {
        let token = ConnectionWatch.newToken()
        let p = try proxy(token: token)
        defer { p.stop() }
        let client = try open(p.port)
        defer { Sock.close(client) }
        let started = Date()
        send(client, "CONNECT blocked.test:443 HTTP/1.1\r\n\r\n")
        #expect(readToEnd(client).hasPrefix("HTTP/1.1 403"))
        let took = Date().timeIntervalSince(started)
        #expect(took >= ProxyExchange.refusalHold - 0.05 && took < ProxyExchange.refusalHold + 0.5)
        waitForEntries(p, 1)
        let e = try #require(p.loggedEntries.first)
        #expect(e.pid == nil && e.command == nil)
    }

    @Test("without a watcher, nothing waits and nothing is added")
    func noWatcher() throws {
        let p = try proxy(token: nil)
        defer { p.stop() }
        let client = try open(p.port)
        defer { Sock.close(client) }
        let started = Date()
        send(client, "CONNECT blocked.test:443 HTTP/1.1\r\n\r\n")
        #expect(readToEnd(client).hasPrefix("HTTP/1.1 403"))
        #expect(Date().timeIntervalSince(started) < 0.3)
        // A watcher greeting is just a bad request then.
        let fake = try open(p.port)
        defer { Sock.close(fake) }
        send(fake, "MUDROOM-WATCH 0123456789abcdef0123456789abcdef\r\n\r\n")
        #expect(readToEnd(fake).hasPrefix("HTTP/1.1 400"))
    }

    @Test("a program that doesn't know the token can't report processes")
    func wrongToken() throws {
        let p = try proxy(token: ConnectionWatch.newToken())
        defer { p.stop() }
        let fake = try open(p.port)
        defer { Sock.close(fake) }
        send(fake, "MUDROOM-WATCH \(ConnectionWatch.newToken())\r\n\r\n1234\t1\tinnocent\n")
        #expect(readToEnd(fake).hasPrefix("HTTP/1.1 403"))
        let now = Date()
        #expect(p.origins?.find(port: 1234, start: now, end: now) == nil)
        #expect(p.loggedEntries.isEmpty)
    }

    @Test("behind a forwarder, the PROXY line's source port is the one matched")
    func proxyLine() throws {
        let token = ConnectionWatch.newToken()
        let p = try proxy(token: token, proxyLine: true)
        defer { p.stop() }
        let watcher = try open(p.port)
        defer { Sock.close(watcher) }
        send(watcher, "PROXY TCP4 172.18.0.3 172.18.0.2 39001 3128\r\nMUDROOM-WATCH \(token)\r\n\r\n")
        send(watcher, "40404\t77\tnpm install\tclaude\n")
        let client = try open(p.port)
        defer { Sock.close(client) }
        send(client, "PROXY TCP4 172.18.0.3 172.18.0.2 40404 3128\r\nCONNECT blocked.test:443 HTTP/1.1\r\n\r\n")
        #expect(readToEnd(client).hasPrefix("HTTP/1.1 403"))
        waitForEntries(p, 1)
        let e = try #require(p.loggedEntries.first)
        #expect(e.host == "blocked.test" && e.pid == 77 && e.command == "npm install")

        #expect(ProxyExchange.splitProxyLine(Data("PROXY TCP4 1.2.3.4 5.6.7.8 4000 3128\r\nCONNECT a:1 HTTP/1.1".utf8))?.0 == 4000)
        #expect(ProxyExchange.splitProxyLine(Data("PROXY UNKNOWN\r\nCONNECT a:1 HTTP/1.1".utf8))?.0 == nil)
        #expect(ProxyExchange.splitProxyLine(Data("PROXY UNKNOWN\r\nCONNECT a:1 HTTP/1.1".utf8))?.1 == Data("CONNECT a:1 HTTP/1.1".utf8))
        #expect(ProxyExchange.splitProxyLine(Data("CONNECT a:1 HTTP/1.1".utf8)) == nil)
        #expect(ProxyExchange.splitProxyLine(Data(("PROXY " + String(repeating: "x", count: 200) + "\r\nGET").utf8)) == nil)
    }

    @Test("Docker's forwarder sends a PROXY line the proxy understands", .enabled(if: ProcessRunner.which("node") != nil))
    func forwarder() throws {
        let token = ConnectionWatch.newToken()
        let p = try proxy(token: token, proxyLine: true)
        defer { p.stop() }
        // Run the forwarder's script on loopback; it listens on the sidecar port.
        let script = DockerBackend.forwarderScript
        guard let node = ProcessRunner.which("node"),
              let probe = try? Sock.listen(host: "127.0.0.1", port: DockerBackend.sidecarPort) else { return }
        Sock.close(probe.0)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: node)
        proc.arguments = ["-e", script]
        proc.environment = ["MUDROOM_UPSTREAM_HOST": "127.0.0.1", "MUDROOM_UPSTREAM_PORT": "\(p.port)",
                            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin"]
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        defer { proc.terminate() }
        var forwarderUp = false
        for _ in 0..<100 where !forwarderUp {
            if case .success(let fd) = Sock.connect(.v4(0x7F00_0001), port: DockerBackend.sidecarPort, timeout: 1, cancelled: { false }) {
                Sock.close(fd)
                forwarderUp = true
            } else {
                usleep(50_000)
            }
        }
        try #require(forwarderUp)
        let watcher = try open(DockerBackend.sidecarPort)
        defer { Sock.close(watcher) }
        send(watcher, "MUDROOM-WATCH \(token)\r\n\r\n")
        let client = try open(DockerBackend.sidecarPort)
        defer { Sock.close(client) }
        send(watcher, "\(Sock.localPort(client))\t9\tgit fetch\n")
        send(client, "CONNECT blocked.test:443 HTTP/1.1\r\n\r\n")
        #expect(readToEnd(client).hasPrefix("HTTP/1.1 403"))
        // The probe connection above logs nothing; the client's is the only entry.
        waitForEntries(p, 1)
        let e = try #require(p.loggedEntries.first { $0.host == "blocked.test" })
        #expect(e.pid == 9 && e.command == "git fetch")
    }
}

@Suite("Starting the watcher")
struct WatcherStartTests {
    /// A VM backend whose host network is loopback, and that runs watchers.
    final class WatchingBackend: SandboxBackend, @unchecked Sendable {
        let name = "fake-vm"
        let usesGuestFirewall = true
        let watchesConnections: Bool
        init(watches: Bool) { watchesConnections = watches }
        func checkAvailable() throws {}
        func run(_ spec: SandboxSpec) throws -> Int32 { 0 }
        func capture(_ spec: SandboxSpec) throws -> CapturedOutput { CapturedOutput(status: 0, stdout: "", stderr: "") }
        func buildImage(containerfile: URL, context: URL, tag: String) throws {}
        func hostOnlyNetwork() throws -> SandboxNetwork? {
            SandboxNetwork(name: "n", hostOnly: true, gateway: "127.0.0.1", subnet: "127.0.0.0/8")
        }
        func defaultNetwork() throws -> SandboxNetwork? { nil }
    }

    @Test("sessions ask for a watcher; setups give one only in locked mode on backends that run it")
    func setup() throws {
        let vm = WatchingBackend(watches: true)
        let locked = try NetworkSetup(mode: .locked, allowlist: Allowlist(strings: []), backend: vm, logURL: nil, watchConnections: true)
        defer { locked.stop() }
        let w = try #require(locked.watch)
        #expect(w.proxyPort == locked.proxy?.port && "\(w.proxyAddress)" == "127.0.0.1")
        #expect(locked.proxy?.configuration.watchToken == w.token)
        #expect(locked.record.processWatch == true)

        let notAsked = try NetworkSetup(mode: .locked, allowlist: Allowlist(strings: []), backend: vm, logURL: nil)
        defer { notAsked.stop() }
        #expect(notAsked.watch == nil && notAsked.record.processWatch == nil && notAsked.proxy?.configuration.watchToken == nil)

        let cannot = try NetworkSetup(mode: .locked, allowlist: Allowlist(strings: []), backend: WatchingBackend(watches: false),
                                      logURL: nil, watchConnections: true)
        defer { cannot.stop() }
        #expect(cannot.watch == nil && cannot.record.processWatch == nil)

        let offline = try NetworkSetup(mode: .offline, allowlist: Allowlist(strings: []), backend: vm, logURL: nil, watchConnections: true)
        #expect(offline.watch == nil)
    }

    @Test("with a watcher, the VM gets the two capabilities it needs and the firewall script gets --watch")
    func runArguments() throws {
        let token = ConnectionWatch.newToken()
        let fw = try #require(GuestFirewall(proxyHost: "192.168.128.1", port: 51234))
        let watch = try #require(ConnectionWatch(token: token, proxyHost: "192.168.128.1", port: 51234))
        var spec = SandboxSpec(name: "mudroom-s1", image: "img", workspace: URL(fileURLWithPath: "/tmp/w"), command: ["claude"])
        spec.firewall = fw
        let image = GuestFirewall.ImageConfig(user: "node", entrypoint: [], cmd: [], setsHome: true)
        let without = AppleContainerBackend.runArguments(for: spec, image: image)
        #expect(!without.contains("CAP_SYS_PTRACE") && !without.contains("--watch"))

        spec.connectionWatch = watch
        let args = AppleContainerBackend.runArguments(for: spec, image: image)
        #expect(args.filter { $0 == "--cap-add" }.count == 3)
        #expect(args.contains("CAP_SYS_PTRACE") && args.contains("CAP_DAC_READ_SEARCH") && args.contains("CAP_NET_ADMIN"))
        let i = try #require(args.firstIndex(of: "--watch"))
        #expect(args[i + 1] == ConnectionWatch.script)
        #expect(args[i + 2] == ([token] + watch.arguments).joined(separator: " "))
        #expect(Array(args[(i + 3)...]) == ["--", "claude"])

        // Offline (no proxy): never a watcher.
        spec.firewall = .closed
        let offline = AppleContainerBackend.runArguments(for: spec, image: image)
        #expect(!offline.contains("--watch") && !offline.contains("CAP_SYS_PTRACE"))
    }

    @Test("Docker starts the watcher with exec, with the token and script passed by name only")
    func dockerExec() throws {
        let token = ConnectionWatch.newToken()
        let watch = try #require(ConnectionWatch(token: token, proxyHost: "172.18.0.2", port: 3128))
        let args = DockerBackend.watcherArguments(container: "mudroom-s1", watch: watch)
        #expect(args.starts(with: ["exec", "--detach", "--env", "MUDROOM_WATCH_TOKEN", "--env", "MUDROOM_WATCH", "mudroom-s1", "bash", "-c"]))
        #expect(Array(args.suffix(5)) == ["172.18.0.2", "3128", "1", "020012AC:0C38", "0000000000000000FFFF0000020012AC:0C38"])
        #expect(!args.joined(separator: " ").contains(token))
        #expect(DockerBackend(flavor: .docker, executable: nil).watchesConnections)
        #expect(DockerBackend.forwarderScript.contains("PROXY TCP4"))
    }

    #if !os(Windows)
    @Test("the firewall script starts the watcher as root with two capabilities, and keeps the token from the agent")
    func scriptStartsWatcher() throws {
        guard let bash = ProcessRunner.which("bash") else { return }
        let tmp = try TempDir()
        let bin = tmp.path("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = tmp.path("calls").path
        func tool(_ name: String, _ body: String) throws {
            let u = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: u)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        try tool("nft", "cat >/dev/null; exit 0")
        try tool("setpriv", "echo \"setpriv token=${MUDROOM_WATCH_TOKEN:-none} script=${MUDROOM_WATCH:+set} $*\" >> '\(log)'; exit 0")
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("bash").path, withDestinationPath: bash)
        for t in ["id", "cut", "cat"] {
            if let p = ProcessRunner.which(t) { try? FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent(t).path, withDestinationPath: p) }
        }
        let token = ConnectionWatch.newToken()
        let fw = try #require(GuestFirewall(proxyHost: "127.0.0.1", port: 3128))
        let watch = try #require(ConnectionWatch(token: token, proxyHost: "127.0.0.1", port: 3128))
        let args = fw.arguments(image: .init(user: "nosuchuser-mudroom", setsHome: true), command: ["true"], watch: watch)
        let out = try ProcessRunner.capture("/bin/sh", args, environment: ["PATH": bin.path])
        #expect(out.status == 0, "\(out.stderr)")
        var lines: [String] = []
        for _ in 0..<100 {
            lines = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            if lines.count >= 2 { break }
            usleep(20_000)
        }
        let watcher = try #require(lines.first { $0.contains("mudroom-watch") })
        #expect(watcher.contains("token=\(token) script=set"))
        #expect(watcher.contains("--bounding-set=-all,+sys_ptrace,+dac_read_search --no-new-privs -- bash -c eval \"$MUDROOM_WATCH\" mudroom-watch 127.0.0.1 3128"))
        #expect(watcher.hasSuffix("0100007F:0C38 0000000000000000FFFF00000100007F:0C38"))
        #expect(!watcher.contains("--reuid"))
        let agent = try #require(lines.first { $0.contains("--reuid") })
        #expect(agent.contains("token=none script= "))
        #expect(agent.contains("--bounding-set=-all") && agent.hasSuffix("-- true"))

        // Without bash the agent still starts, with no watcher.
        try FileManager.default.removeItem(at: bin.appendingPathComponent("bash"))
        try? FileManager.default.removeItem(atPath: log)
        let out2 = try ProcessRunner.capture("/bin/sh", args, environment: ["PATH": bin.path])
        #expect(out2.status == 0)
        usleep(200_000)
        let calls = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        #expect(!calls.contains("mudroom-watch") && calls.contains("--reuid"))
    }

    @Test("the watcher script is valid bash", .enabled(if: ProcessRunner.which("bash") != nil))
    func scriptParses() throws {
        let out = try ProcessRunner.capture(ProcessRunner.which("bash")!, ["-n", "-c", ConnectionWatch.script])
        #expect(out.status == 0, "\(out.stderr)")
    }
    #endif
}
