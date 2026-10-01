#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation


/// One line of `network.jsonl`: a proxied (or refused) connection.
public struct NetworkLogEntry: Codable, Sendable, Equatable {
    public var time: Date
    public var host: String
    public var port: Int
    /// "CONNECT" for HTTPS tunnels, else the HTTP method.
    public var method: String
    public var allowed: Bool
    /// Why it was refused or failed; nil for a normal allowed connection.
    public var reason: String?
    /// Bytes sent by the VM (after the proxy request) and bytes received.
    public var bytesOut: Int64
    public var bytesIn: Int64
    public var durationMs: Int

    public init(time: Date, host: String, port: Int, method: String, allowed: Bool, reason: String? = nil,
                bytesOut: Int64 = 0, bytesIn: Int64 = 0, durationMs: Int = 0) {
        self.time = time
        self.host = host
        self.port = port
        self.method = method
        self.allowed = allowed
        self.reason = reason
        self.bytesOut = bytesOut
        self.bytesIn = bytesIn
        self.durationMs = durationMs
    }
}

/// Reads and summarizes a session's network log.
public enum NetworkLog {
    /// Millisecond timestamps, so entries keep their order and duration.
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = enc.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }

    public static func read(_ url: URL) -> [NetworkLogEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = decoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(NetworkLogEntry.self, from: Data($0)) }
    }

    /// "0 B", "812 B", "4.1 KB", "2.3 MB".
    public static func byteString(_ n: Int64) -> String {
        if n < 1000 { return "\(n) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var v = Double(n) / 1000
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, units[i])
    }

    public struct HostSummary: Sendable, Equatable, Identifiable {
        public var id: String { "\(host):\(port):\(allowed)" }
        public var host: String
        public var port: Int
        public var allowed: Bool
        public var count: Int
        public var bytesOut: Int64
        public var bytesIn: Int64
        public var first: Date
        public var last: Date
        /// Most recent refusal or failure reason.
        public var reason: String?
    }

    /// One row per host, port and decision. Blocked rows first, then by volume.
    public static func summarize(_ entries: [NetworkLogEntry]) -> [HostSummary] {
        var rows: [String: HostSummary] = [:]
        for e in entries {
            let key = "\(e.host):\(e.port):\(e.allowed)"
            if var r = rows[key] {
                r.count += 1
                r.bytesOut += e.bytesOut
                r.bytesIn += e.bytesIn
                r.first = min(r.first, e.time)
                r.last = max(r.last, e.time)
                if e.reason != nil { r.reason = e.reason }
                rows[key] = r
            } else {
                rows[key] = HostSummary(host: e.host, port: e.port, allowed: e.allowed, count: 1, bytesOut: e.bytesOut,
                                        bytesIn: e.bytesIn, first: e.time, last: e.time, reason: e.reason)
            }
        }
        return rows.values.sorted {
            if $0.allowed != $1.allowed { return !$0.allowed }
            if $0.bytesIn + $0.bytesOut != $1.bytesIn + $1.bytesOut { return $0.bytesIn + $0.bytesOut > $1.bytesIn + $1.bytesOut }
            return $0.host < $1.host
        }
    }
}

/// An IPv4 network such as 192.168.128.0/24.
public struct IPv4Subnet: Sendable, Equatable, CustomStringConvertible {
    public let base: UInt32
    public let prefix: Int

    public init?(_ cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix),
              case .v4(let addr)? = IPAddress(String(parts[0])) else { return nil }
        self.prefix = prefix
        self.base = addr & Self.mask(prefix)
    }

    static func mask(_ prefix: Int) -> UInt32 { prefix == 0 ? 0 : UInt32.max << (32 - prefix) }

    /// True for an IPv4 address (or IPv4-mapped IPv6 address) in this network.
    public func contains(_ a: IPAddress) -> Bool {
        guard let v = a.asIPv4 else { return false }
        return v & Self.mask(prefix) == base
    }

    public var description: String {
        "\(IPAddress.v4(base))/\(prefix)"
    }
}

/// A small HTTP forward proxy for the sandbox: `CONNECT host:port` tunnels
/// (HTTPS) and absolute-URI requests (plain HTTP). Only hosts on the
/// allowlist get through; everything is logged to `network.jsonl`.
///
/// It runs inside `mudroom start` for the lifetime of the agent. With the
/// sandbox on a host-only (or internal) network it is the only way out.
///
/// Plain BSD sockets and one thread per connection, so it builds on macOS
/// and Linux alike. Agents open a few dozen connections, not thousands.
public final class EgressProxy: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var allowlist: Allowlist
        /// Where to append log lines; nil keeps them in memory only.
        public var logURL: URL?
        /// Address to listen on; nil listens on all addresses (the vmnet
        /// gateway address only exists while a VM is attached, so the proxy
        /// can't bind to it before the VM starts).
        public var bindHost: String?
        public var port: UInt16
        /// Clients allowed to use the proxy besides loopback, e.g. the VM
        /// network. Anyone else is disconnected without a reply.
        public var clientSubnets: [IPv4Subnet]
        /// Refuse upstream connections that resolve to loopback, link-local
        /// or the sandbox's own networks (`clientSubnets` and
        /// `blockedSubnets`), so an allowed name can't be pointed at
        /// services on the host.
        public var blockLocalDestinations: Bool
        /// More networks to refuse as destinations (e.g. a container
        /// runtime's internal network).
        public var blockedSubnets: [IPv4Subnet]
        public var connectTimeout: Int

        public init(allowlist: Allowlist, logURL: URL? = nil, bindHost: String? = nil, port: UInt16 = 0,
                    clientSubnets: [IPv4Subnet] = [], blockLocalDestinations: Bool = true,
                    blockedSubnets: [IPv4Subnet] = [], connectTimeout: Int = 15) {
            self.allowlist = allowlist
            self.logURL = logURL
            self.bindHost = bindHost
            self.port = port
            self.clientSubnets = clientSubnets
            self.blockLocalDestinations = blockLocalDestinations
            self.blockedSubnets = blockedSubnets
            self.connectTimeout = connectTimeout
        }
    }

    public let configuration: Configuration
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var wakeFDs: [Int32] = [-1, -1]
    private let acceptDone = DispatchSemaphore(value: 0)
    private var running = false
    private var active: [ObjectIdentifier: ProxyExchange] = [:]
    private var logHandle: FileHandle?
    private var entries: [NetworkLogEntry] = []
    private let encoder = NetworkLog.encoder()

    /// The port actually listened on (after `start`).
    public private(set) var port: UInt16 = 0

    public init(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Starts listening; returns once the port is known.
    public func start() throws {
        if let url = configuration.logURL {
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            logHandle = try FileHandle(forWritingTo: url)
            try logHandle?.seekToEnd()
        }
        let (fd, p) = try Sock.listen(host: configuration.bindHost, port: configuration.port)
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            close(fd)
            throw MudroomError.posix("pipe", "proxy", errno)
        }
        lock.withLock {
            listenFD = fd
            wakeFDs = fds
            port = p
            running = true
        }
        let wakeRead = fds[0]
        let t = Thread { [self] in acceptLoop(fd, wake: wakeRead) }
        t.name = "mudroom.proxy.accept"
        t.start()
    }

    /// Stops listening and closes open tunnels (they are logged as they close).
    public func stop() {
        let open: [ProxyExchange]
        let wasRunning: Bool = lock.withLock {
            let r = running
            running = false
            return r
        }
        guard wasRunning else { return }
        var b: UInt8 = 1
        _ = write(wakeFDs[1], &b, 1)
        acceptDone.wait()
        open = lock.withLock { Array(active.values) }
        for ex in open { ex.abort() }
        // Give the exchanges a moment to log themselves.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, lock.withLock({ !active.isEmpty }) { usleep(10_000) }
        lock.withLock {
            close(listenFD)
            close(wakeFDs[0])
            close(wakeFDs[1])
            listenFD = -1
            try? logHandle?.synchronize()
            try? logHandle?.close()
            logHandle = nil
        }
    }

    /// Log entries so far (for tests and live views).
    public var loggedEntries: [NetworkLogEntry] { lock.withLock { entries } }

    // MARK: Internals

    private func acceptLoop(_ fd: Int32, wake: Int32) {
        defer { acceptDone.signal() }
        while true {
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
            let n = poll(&fds, 2, -1)
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { return }
            guard fds[0].revents != 0, let (conn, peer) = Sock.accept(fd) else { continue }
            guard let peer, isAllowedClient(peer) else {
                close(conn)
                continue
            }
            let ex = ProxyExchange(proxy: self, client: conn)
            let accepted: Bool = lock.withLock {
                guard running else { return false }
                active[ObjectIdentifier(ex)] = ex
                return true
            }
            guard accepted else {
                close(conn)
                return
            }
            let t = Thread { ex.run() }
            t.name = "mudroom.proxy.conn"
            t.start()
        }
    }

    func finished(_ ex: ProxyExchange, entry: NetworkLogEntry?) {
        lock.withLock {
            active[ObjectIdentifier(ex)] = nil
            guard let entry else { return }
            entries.append(entry)
            if let h = logHandle, var line = try? encoder.encode(entry) {
                line.append(UInt8(ascii: "\n"))
                try? h.write(contentsOf: line)
            }
        }
    }

    func isAllowedClient(_ a: IPAddress) -> Bool {
        if a.isLoopback { return true }
        return configuration.clientSubnets.contains { $0.contains(a) }
    }

    /// True if an upstream address is on this host or a sandbox network.
    func isLocalDestination(_ a: IPAddress) -> Bool {
        guard configuration.blockLocalDestinations else { return false }
        if a.isLocal { return true }
        return (configuration.clientSubnets + configuration.blockedSubnets).contains { $0.contains(a) }
    }
}

/// A tiny thread-safe box for values set from callbacks.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// One client connection, handled start to finish on its own thread: read
/// the proxy request, decide, connect, then pipe bytes both ways.
final class ProxyExchange: @unchecked Sendable {
    unowned let proxy: EgressProxy
    let client: Int32
    private var upstream: Int32 = -1
    private let fdLock = NSLock()
    private var aborted = false
    let started = Date()
    var host = ""
    var port = 0
    var method = ""
    var allowed = false
    var bytesOut: Int64 = 0
    var bytesIn: Int64 = 0
    var failure: String?

    static let maxHeader = 64 * 1024
    static let headerTimeout: TimeInterval = 60

    init(proxy: EgressProxy, client: Int32) {
        self.proxy = proxy
        self.client = client
    }

    var isAborted: Bool { fdLock.withLock { aborted } }

    /// Called from `EgressProxy.stop`: unblocks any read or write.
    func abort() {
        fdLock.withLock {
            aborted = true
            shutdown(client, Int32(SHUT_RDWR))
            if upstream >= 0 { shutdown(upstream, Int32(SHUT_RDWR)) }
        }
    }

    func run() {
        var log = true
        defer {
            fdLock.withLock {
                close(client)
                if upstream >= 0 { close(upstream) }
                upstream = -1
            }
            let entry = log && !host.isEmpty ? NetworkLogEntry(
                // `allowed` is the policy decision; an allowed host whose
                // connection failed keeps allowed = true and gets a reason.
                time: Date(timeIntervalSince1970: (started.timeIntervalSince1970 * 1000).rounded() / 1000), host: host, port: port,
                method: method, allowed: allowed, reason: failure, bytesOut: bytesOut, bytesIn: bytesIn,
                durationMs: Int(Date().timeIntervalSince(started) * 1000)) : nil
            proxy.finished(self, entry: entry)
        }
        guard let (head, rest) = readHeader() else {
            log = false
            return
        }
        handle(head: head, rest: rest)
    }

    /// Reads up to the blank line. Nil if the client went away first.
    private func readHeader() -> (Data, Data)? {
        var header = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        let deadline = Date().addingTimeInterval(Self.headerTimeout)
        while true {
            if let end = header.range(of: Data("\r\n\r\n".utf8)) {
                return (header.subdata(in: header.startIndex..<end.lowerBound), header.subdata(in: end.upperBound..<header.endIndex))
            }
            if header.count > Self.maxHeader {
                reject(400, "request header too large")
                return nil
            }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 || isAborted { return nil }
            if !Sock.waitReadable(client, timeout: min(left, 1)) { continue }
            let n = recv(client, &buf, buf.count, 0)
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            if n <= 0 { return nil }
            header.append(contentsOf: buf[0..<n])
        }
    }

    private func handle(head: Data, rest: Data) {
        let text = String(decoding: head, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard requestLine.count == 3 else { return reject(400, "malformed request line") }
        method = requestLine[0].uppercased()
        let target = requestLine[1]
        let version = requestLine[2]

        var upstreamHead: Data?
        if method == "CONNECT" {
            guard let (h, p) = Self.splitHostPort(target, defaultPort: nil) else { return reject(400, "bad CONNECT target") }
            host = h
            port = p
        } else {
            guard let url = URL(string: target), let scheme = url.scheme?.lowercased(), scheme == "http",
                  let h = url.host, !h.isEmpty else {
                return reject(400, "only absolute http:// URLs and CONNECT are supported")
            }
            host = HostPattern.normalize(h.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
            port = url.port ?? 80
            // Origin-form request line, one request per connection: a client
            // can't reuse this upstream connection for a different host.
            var path = url.path.isEmpty ? "/" : url.path
            if let q = url.query { path += "?" + q }
            let dropped: Set<String> = ["proxy-connection", "proxy-authorization", "connection", "keep-alive"]
            var out = ["\(method) \(path) \(version)"]
            for line in lines where !line.isEmpty {
                let name = line.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                if !dropped.contains(name) { out.append(line) }
            }
            out.append("Connection: close")
            upstreamHead = Data((out.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        }

        guard proxy.configuration.allowlist.allows(host) else {
            return reject(403, "not on this project's allowlist")
        }
        guard (1...65535).contains(port) else { return reject(400, "bad port") }
        allowed = true
        connectUpstream(then: upstreamHead.map { $0 + rest } ?? rest)
    }

    static func splitHostPort(_ s: String, defaultPort: Int?) -> (String, Int)? {
        var hostPart = s
        var portPart: String?
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            hostPart = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            if after.hasPrefix(":") { portPart = String(after.dropFirst()) }
        } else if let colon = s.lastIndex(of: ":"), s.firstIndex(of: ":") == colon {
            hostPart = String(s[..<colon])
            portPart = String(s[s.index(after: colon)...])
        }
        let host = HostPattern.normalize(hostPart)
        guard !host.isEmpty else { return nil }
        if let portPart {
            guard let p = Int(portPart) else { return nil }
            return (host, p)
        }
        guard let d = defaultPort else { return nil }
        return (host, d)
    }

    private func connectUpstream(then initial: Data) {
        let addresses: [IPAddress]
        switch Sock.resolve(host) {
        case .success(let a): addresses = a
        case .failure(let e): return reject(502, "upstream: \(e)")
        }
        // Local addresses are refused before connecting, so nothing on the
        // host ever sees a connection for a name that points back at it.
        let candidates = addresses.filter { !proxy.isLocalDestination($0) }
        if candidates.isEmpty {
            allowed = false
            return reject(403, "resolves to a local address")
        }
        let timeout = TimeInterval(proxy.configuration.connectTimeout)
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Int32 = ECONNREFUSED
        var fd: Int32 = -1
        for a in candidates {
            let left = max(1, deadline.timeIntervalSinceNow)
            switch Sock.connect(a, port: UInt16(port), timeout: left, cancelled: { isAborted }) {
            case .success(let c): fd = c
            case .failure(let e): lastError = e.code
            }
            if fd >= 0 || isAborted || deadline.timeIntervalSinceNow <= 0 { break }
        }
        guard fd >= 0 else {
            if isAborted { failure = "proxy stopped"; return }
            return reject(502, "upstream: \(Sock.errorText(lastError))")
        }
        let stillOpen: Bool = fdLock.withLock {
            upstream = fd
            return !aborted
        }
        guard stillOpen else { return }

        if method == "CONNECT" {
            guard Sock.sendAll(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) else { return }
        }
        if !initial.isEmpty {
            bytesOut += Int64(initial.count)
            guard Sock.sendAll(fd, initial) else {
                failure = "upstream: write failed"
                return
            }
        }
        relay(fd)
    }

    /// Copies bytes both ways until both sides are done. When the server
    /// finishes, the client gets two seconds to close its side too.
    private func relay(_ up: Int32) {
        var clientOpen = true
        var upstreamOpen = true
        var upstreamDone: Date?
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while (clientOpen || upstreamOpen) && !isAborted {
            if let t = upstreamDone, Date().timeIntervalSince(t) >= 2 { break }
            var fds: [pollfd] = []
            if clientOpen { fds.append(pollfd(fd: client, events: Int16(POLLIN), revents: 0)) }
            if upstreamOpen { fds.append(pollfd(fd: up, events: Int16(POLLIN), revents: 0)) }
            let n = poll(&fds, nfds_t(fds.count), 250)
            if n < 0 && errno != EINTR { break }
            if n <= 0 { continue }
            for p in fds where p.revents != 0 {
                let fromClient = p.fd == client
                let got = recv(p.fd, &buf, buf.count, 0)
                if got < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                if got > 0 {
                    let data = Data(buf[0..<got])
                    if fromClient {
                        bytesOut += Int64(got)
                        if !Sock.sendAll(up, data) { return }
                    } else {
                        bytesIn += Int64(got)
                        if !Sock.sendAll(client, data) { return }
                    }
                } else if fromClient {
                    clientOpen = false
                    shutdown(up, Int32(SHUT_WR))
                } else {
                    upstreamOpen = false
                    shutdown(client, Int32(SHUT_WR))
                    upstreamDone = Date()
                }
            }
        }
    }

    private func reject(_ status: Int, _ reason: String) {
        failure = reason
        let phrase = [400: "Bad Request", 403: "Forbidden", 502: "Bad Gateway"][status] ?? "Error"
        let body = "mudroom: \(host.isEmpty ? "request" : "\(host):\(port)") refused: \(reason)\n"
        let resp = "HTTP/1.1 \(status) \(phrase)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = Sock.sendAll(client, Data(resp.utf8))
        shutdown(client, Int32(SHUT_WR))
        // Read what the client still sends before closing, so the close
        // doesn't turn into a reset that eats the reply.
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(1)
        while deadline.timeIntervalSinceNow > 0, !isAborted, Sock.waitReadable(client, timeout: deadline.timeIntervalSinceNow) {
            if recv(client, &buf, buf.count, 0) <= 0 { break }
        }
    }
}
