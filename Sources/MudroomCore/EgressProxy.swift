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

    /// How a logged destination is shown: "example.com:443", "[::1]:443".
    /// A request that never named a host shows as "(no host)", and a
    /// missing port is left off rather than shown as ":0".
    public static func endpoint(_ host: String, _ port: Int) -> String {
        guard !host.isEmpty else { return "(no host)" }
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return port > 0 ? "\(h):\(port)" : h
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
        /// Refuse upstream connections to addresses that aren't on the public
        /// internet: loopback, link-local, multicast, this machine's own
        /// addresses, the sandbox's networks (`clientSubnets` and
        /// `blockedSubnets`), and private ranges (RFC 1918, CGNAT, ULA...).
        /// A private address is reachable only when that exact IP is on the
        /// allowlist. Checked after DNS, on the address actually connected to.
        public var blockLocalDestinations: Bool
        /// More networks to refuse as destinations (e.g. a container
        /// runtime's internal network).
        public var blockedSubnets: [IPv4Subnet]
        public var connectTimeout: Int
        /// Seconds a client gets to send its request head.
        public var headerTimeout: TimeInterval
        /// Open connections at most; more are closed straight away.
        public var maxConnections: Int
        /// Services on this machine the VM may use, by the port it asks for
        /// on `NetworkDefaults.hostServiceName` -> the port on 127.0.0.1.
        /// The proxy picks the destination itself, so no other local port
        /// (and no other address) becomes reachable. Empty = none.
        public var hostServices: [UInt16: UInt16]

        public init(allowlist: Allowlist, logURL: URL? = nil, bindHost: String? = nil, port: UInt16 = 0,
                    clientSubnets: [IPv4Subnet] = [], blockLocalDestinations: Bool = true,
                    blockedSubnets: [IPv4Subnet] = [], connectTimeout: Int = 15,
                    headerTimeout: TimeInterval = 10, maxConnections: Int = 256,
                    hostServices: [UInt16: UInt16] = [:]) {
            self.allowlist = allowlist
            self.logURL = logURL
            self.bindHost = bindHost
            self.port = port
            self.clientSubnets = clientSubnets
            self.blockLocalDestinations = blockLocalDestinations
            self.blockedSubnets = blockedSubnets
            self.connectTimeout = connectTimeout
            self.headerTimeout = headerTimeout
            self.maxConnections = maxConnections
            self.hostServices = hostServices
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
    private var ownAddresses: (Set<IPAddress>, Date) = ([], .distantPast)

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
        Self.raiseFileLimit()
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
            let accepted: Bool? = lock.withLock {
                guard running else { return false }
                guard active.count < configuration.maxConnections else { return nil }
                active[ObjectIdentifier(ex)] = ex
                return true
            }
            guard let accepted else {
                // Over the cap: refuse without a thread.
                Sock.setNonBlocking(conn, true)
                _ = Sock.sendAll(conn, Data("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
                close(conn)
                continue
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

    /// True if an upstream address must not be connected to (see
    /// `blockLocalDestinations`).
    func isLocalDestination(_ a: IPAddress) -> Bool {
        destinationRefusal(a) != nil
    }

    /// Why an upstream address is refused, or nil if it may be used.
    func destinationRefusal(_ a: IPAddress) -> String? {
        guard configuration.blockLocalDestinations else { return nil }
        if a.isLocal { return "resolves to a local address (\(a))" }
        if (configuration.clientSubnets + configuration.blockedSubnets).contains(where: { $0.contains(a) }) {
            return "resolves to a sandbox network address (\(a))"
        }
        let mapped = a.embeddedIPv4.map(IPAddress.v4)
        let own = hostAddresses()
        if own.contains(a) || mapped.map(own.contains) == true { return "resolves to an address of this machine (\(a))" }
        if a.isPrivate && !configuration.allowlist.listsAddress(a) {
            return "resolves to a private network address (\(a)); allow that exact IP to reach it"
        }
        return nil
    }

    /// This machine's addresses, re-read every few seconds (networks come
    /// and go while a session runs).
    func hostAddresses() -> Set<IPAddress> {
        lock.withLock {
            if ownAddresses.1.timeIntervalSinceNow < -5 { ownAddresses = (IPAddress.hostAddresses(), Date()) }
            return ownAddresses.0
        }
    }

    /// One thread and two descriptors per connection: make sure the cap,
    /// not the descriptor limit, is what runs out first.
    static func raiseFileLimit() {
        #if canImport(Glibc)
        let resource = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
        #else
        let resource = RLIMIT_NOFILE
        #endif
        var rl = rlimit()
        guard getrlimit(resource, &rl) == 0 else { return }
        let want = rlim_t(min(UInt64(rl.rlim_max), 10240))
        if rl.rlim_cur < want {
            rl.rlim_cur = want
            _ = setrlimit(resource, &rl)
        }
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
    var destination: ProxyHost?

    static let maxHeader = 32 * 1024

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
        let deadline = Date().addingTimeInterval(proxy.configuration.headerTimeout)
        while true {
            if let end = header.range(of: Data("\r\n\r\n".utf8)), end.lowerBound - header.startIndex <= Self.maxHeader {
                return (header.subdata(in: header.startIndex..<end.lowerBound), header.subdata(in: end.upperBound..<header.endIndex))
            }
            if header.count > Self.maxHeader {
                reject(400, "request header too large")
                return nil
            }
            let left = deadline.timeIntervalSinceNow
            if isAborted { return nil }
            if left <= 0 {
                reject(408, "no request within \(Int(proxy.configuration.headerTimeout)) s")
                return nil
            }
            if !Sock.waitReadable(client, timeout: min(left, 1)) { continue }
            let n = recv(client, &buf, buf.count, 0)
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            if n <= 0 { return nil }
            header.append(contentsOf: buf[0..<n])
        }
    }

    private func handle(head: Data, rest: Data) {
        let req: ProxyRequest
        switch ProxyRequest.parse(head) {
        case .failure(let f):
            if let raw = f.rawHost {
                host = raw
                port = f.port ?? 0
                method = f.method ?? ""
            }
            return reject(400, f.reason)
        case .success(let r):
            req = r
        }
        method = req.method
        host = req.host.canonical
        port = req.port
        destination = req.host
        if case .name(NetworkDefaults.hostServiceName) = req.host {
            // A service on this Mac (local models): the proxy connects to
            // loopback itself, and only on the ports set up for it.
            guard let target = proxy.configuration.hostServices[UInt16(clamping: req.port)] else {
                let what = proxy.configuration.hostServices.isEmpty
                    ? "turn on Local models for this project to reach Ollama or LM Studio on the Mac"
                    : "only " + proxy.configuration.hostServices.keys.sorted().map(String.init).joined(separator: " and ") + " are open on the Mac"
                return reject(403, what)
            }
            allowed = true
            var local = req
            local.host = .name("localhost")
            local.port = Int(target)
            return connectUpstream(then: req.isConnect ? rest : local.upstreamHead() + rest,
                                   fixed: (.v4(0x7F00_0001), target))
        }
        guard proxy.configuration.allowlist.allows(req.host) else {
            return reject(403, "not on this project's allowlist")
        }
        allowed = true
        connectUpstream(then: req.isConnect ? rest : req.upstreamHead() + rest)
    }

    private func connectUpstream(then initial: Data, fixed: (IPAddress, UInt16)? = nil) {
        if let (a, p) = fixed {
            switch Sock.connect(a, port: p, timeout: TimeInterval(proxy.configuration.connectTimeout), cancelled: { isAborted }) {
            case .success(let c):
                return connected(c, initial: initial)
            case .failure(let e):
                return reject(502, "nothing answers on port \(p) on the Mac (\(Sock.errorText(e.code)))")
            }
        }
        let addresses: [IPAddress]
        switch destination {
        case .ip(let a)?:
            addresses = [a]
        case .name(let n)?:
            switch Sock.resolve(n) {
            case .success(let a): addresses = a
            case .failure(let e): return reject(502, "upstream: \(e)")
            }
        case nil:
            return reject(400, "no destination")
        }
        // Checked on the resolved addresses, and the connection goes to the
        // address that was checked: a name re-pointed between the check and
        // the connect (DNS rebinding) can't slip through.
        var refusal: String?
        let candidates = addresses.filter { a in
            guard let why = proxy.destinationRefusal(a) else { return true }
            refusal = refusal ?? why
            return false
        }
        if candidates.isEmpty {
            allowed = false
            return reject(403, refusal ?? "no usable address")
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
        connected(fd, initial: initial)
    }

    private func connected(_ fd: Int32, initial: Data) {
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
        let phrase = [400: "Bad Request", 403: "Forbidden", 408: "Request Timeout", 502: "Bad Gateway"][status] ?? "Error"
        let body = "mudroom: \(host.isEmpty ? "request" : NetworkLog.endpoint(host, port)) refused: \(reason)\n"
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
