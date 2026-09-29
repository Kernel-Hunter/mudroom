import Foundation
import Network

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
              let addr = IPv4Address(String(parts[0])) else { return nil }
        self.prefix = prefix
        self.base = Self.value(addr) & Self.mask(prefix)
    }

    static func mask(_ prefix: Int) -> UInt32 { prefix == 0 ? 0 : UInt32.max << (32 - prefix) }

    static func value(_ a: IPv4Address) -> UInt32 {
        a.rawValue.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public func contains(_ a: IPv4Address) -> Bool { Self.value(a) & Self.mask(prefix) == base }

    public var description: String {
        let b = base
        return "\(b >> 24).\((b >> 16) & 0xff).\((b >> 8) & 0xff).\(b & 0xff)/\(prefix)"
    }
}

/// A small HTTP forward proxy for the VM: `CONNECT host:port` tunnels (HTTPS)
/// and absolute-URI requests (plain HTTP). Only hosts on the allowlist get
/// through; everything is logged to `network.jsonl`.
///
/// It runs inside `mudroom start` for the lifetime of the agent. With the VM
/// on a host-only network it is the only way out.
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
        /// or the VM's own network, so an allowed name can't be pointed at
        /// services on the Mac.
        public var blockLocalDestinations: Bool
        public var connectTimeout: Int

        public init(allowlist: Allowlist, logURL: URL? = nil, bindHost: String? = nil, port: UInt16 = 0,
                    clientSubnets: [IPv4Subnet] = [], blockLocalDestinations: Bool = true, connectTimeout: Int = 15) {
            self.allowlist = allowlist
            self.logURL = logURL
            self.bindHost = bindHost
            self.port = port
            self.clientSubnets = clientSubnets
            self.blockLocalDestinations = blockLocalDestinations
            self.connectTimeout = connectTimeout
        }
    }

    public let configuration: Configuration
    let queue = DispatchQueue(label: "mudroom.proxy")
    private var listener: NWListener?
    private var active: [ObjectIdentifier: ProxyExchange] = [:]
    private var logHandle: FileHandle?
    private(set) var entries: [NetworkLogEntry] = []
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
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            logHandle = try FileHandle(forWritingTo: url)
            try logHandle?.seekToEnd()
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let host = configuration.bindHost {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: configuration.port) ?? .any)
        }
        let listener: NWListener
        if configuration.bindHost == nil, configuration.port != 0, let p = NWEndpoint.Port(rawValue: configuration.port) {
            listener = try NWListener(using: params, on: p)
        } else {
            listener = try NWListener(using: params)
        }
        let ready = DispatchSemaphore(value: 0)
        let failure = LockedBox<Error?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e):
                failure.value = e
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 10) == .timedOut {
            listener.cancel()
            throw MudroomError.invalid("the network proxy did not start listening")
        }
        if let e = failure.value {
            listener.cancel()
            throw MudroomError.invalid("the network proxy could not listen: \(e)")
        }
        self.listener = listener
        port = listener.port?.rawValue ?? 0
    }

    /// Stops listening and closes open tunnels (they are logged as they close).
    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for ex in active.values { ex.finish(reason: nil) }
            active.removeAll()
            try? logHandle?.synchronize()
            try? logHandle?.close()
            logHandle = nil
        }
    }

    /// Log entries so far (for tests and live views).
    public var loggedEntries: [NetworkLogEntry] { queue.sync { entries } }

    // MARK: Internals (all on `queue`)

    private func accept(_ conn: NWConnection) {
        guard isAllowedClient(conn.endpoint) else {
            conn.cancel()
            return
        }
        let ex = ProxyExchange(proxy: self, client: conn)
        active[ObjectIdentifier(ex)] = ex
        ex.start()
    }

    func finished(_ ex: ProxyExchange, entry: NetworkLogEntry?) {
        active[ObjectIdentifier(ex)] = nil
        guard let entry else { return }
        entries.append(entry)
        if let h = logHandle, var line = try? encoder.encode(entry) {
            line.append(UInt8(ascii: "\n"))
            try? h.write(contentsOf: line)
        }
    }

    func isAllowedClient(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        var v4: IPv4Address?
        switch host {
        case .ipv4(let a): v4 = a
        case .ipv6(let a):
            if a.isLoopback { return true }
            v4 = a.asIPv4
        default: return false
        }
        guard let a = v4 else { return false }
        if a.isLoopback { return true }
        return configuration.clientSubnets.contains { $0.contains(a) }
    }

    /// True if an upstream address is on this Mac or the VM network.
    func isLocalDestination(_ endpoint: NWEndpoint?) -> Bool {
        guard configuration.blockLocalDestinations else { return false }
        guard case .hostPort(let host, _)? = endpoint else { return false }
        switch host {
        case .ipv4(let a):
            return Self.isLocal(a) || configuration.clientSubnets.contains { $0.contains(a) }
        case .ipv6(let a):
            if let m = a.asIPv4 { return Self.isLocal(m) || configuration.clientSubnets.contains { $0.contains(m) } }
            return a.isLoopback || a.isLinkLocal || a.isAny || a.rawValue.first.map { $0 & 0xfe == 0xfc } == true
        default:
            return false
        }
    }

    static func isLocal(_ a: IPv4Address) -> Bool {
        a.isLoopback || a.isLinkLocal || a.isMulticast || a == IPv4Address.any || a.rawValue.first == 0
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

/// One client connection: read the proxy request, decide, then pipe bytes.
final class ProxyExchange: @unchecked Sendable {
    unowned let proxy: EgressProxy
    let client: NWConnection
    var upstream: NWConnection?
    let started = Date()
    var header = Data()
    var host = ""
    var port = 0
    var method = ""
    var allowed = false
    var bytesOut: Int64 = 0
    var bytesIn: Int64 = 0
    var done = false
    var clientClosed = false
    var upstreamClosed = false
    var failure: String?

    static let maxHeader = 64 * 1024
    var queue: DispatchQueue { proxy.queue }

    init(proxy: EgressProxy, client: NWConnection) {
        self.proxy = proxy
        self.client = client
    }

    func start() {
        client.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: finish(reason: failure)
            default: break
            }
        }
        client.start(queue: queue)
        readHeader()
    }

    private func readHeader() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
            if done { return }
            if let data { header.append(data) }
            if let end = header.range(of: Data("\r\n\r\n".utf8)) {
                let head = header.subdata(in: header.startIndex..<end.lowerBound)
                let rest = header.subdata(in: end.upperBound..<header.endIndex)
                handle(head: head, rest: rest)
            } else if header.count > Self.maxHeader {
                reject(400, "request header too large")
            } else if isComplete || error != nil {
                finish(reason: nil, log: false)
            } else {
                readHeader()
            }
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
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = proxy.configuration.connectTimeout
        let params = NWParameters(tls: nil, tcp: tcp)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return reject(400, "bad port") }
        let up = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        upstream = up
        up.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                if proxy.isLocalDestination(up.currentPath?.remoteEndpoint) {
                    allowed = false
                    up.cancel()
                    upstream = nil
                    return reject(403, "resolves to a local address")
                }
                if method == "CONNECT" {
                    client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in })
                }
                if !initial.isEmpty {
                    bytesOut += Int64(initial.count)
                    up.send(content: initial, completion: .contentProcessed { _ in })
                }
                pump(from: client, to: up, outbound: true)
                pump(from: up, to: client, outbound: false)
            case .waiting(let e), .failed(let e):
                // .waiting means no route or no DNS answer; don't hang.
                if bytesIn == 0 && bytesOut <= Int64(initial.count) && failure == nil && !upstreamClosed {
                    upstream = nil
                    up.cancel()
                    reject(502, "upstream: \(e)")
                } else {
                    finish(reason: "upstream: \(e)")
                }
            default:
                break
            }
        }
        up.start(queue: queue)
    }

    private func pump(from src: NWConnection, to dst: NWConnection, outbound: Bool) {
        src.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if done { return }
            if let data, !data.isEmpty {
                if outbound { bytesOut += Int64(data.count) } else { bytesIn += Int64(data.count) }
                dst.send(content: data, completion: .contentProcessed { [self] sendError in
                    if sendError != nil { return finish(reason: nil) }
                    if isComplete { halfClose(dst, outbound: outbound) } else { pump(from: src, to: dst, outbound: outbound) }
                })
                return
            }
            if isComplete || error != nil {
                halfClose(dst, outbound: outbound)
            } else {
                pump(from: src, to: dst, outbound: outbound)
            }
        }
    }

    private func halfClose(_ dst: NWConnection, outbound: Bool) {
        if outbound { clientClosed = true } else { upstreamClosed = true }
        dst.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        if clientClosed && upstreamClosed { finish(reason: nil) }
        // When the server is done, the client doesn't need to keep sending.
        if upstreamClosed && !clientClosed {
            queue.asyncAfter(deadline: .now() + 2) { [self] in finish(reason: nil) }
        }
    }

    private func reject(_ status: Int, _ reason: String) {
        failure = reason
        let phrase = [400: "Bad Request", 403: "Forbidden", 502: "Bad Gateway"][status] ?? "Error"
        let body = "mudroom: \(host.isEmpty ? "request" : "\(host):\(port)") refused: \(reason)\n"
        let resp = "HTTP/1.1 \(status) \(phrase)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        client.send(content: Data(resp.utf8), contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { [self] _ in finish(reason: reason) })
    }

    func finish(reason: String?, log: Bool = true) {
        if done { return }
        done = true
        client.cancel()
        upstream?.cancel()
        let entry = log && !host.isEmpty ? NetworkLogEntry(
            // `allowed` is the policy decision; an allowed host whose
            // connection failed keeps allowed = true and gets a reason.
            time: Date(timeIntervalSince1970: (started.timeIntervalSince1970 * 1000).rounded() / 1000), host: host, port: port, method: method, allowed: allowed,
            reason: reason ?? failure, bytesOut: bytesOut, bytesIn: bytesIn,
            durationMs: Int(Date().timeIntervalSince(started) * 1000)) : nil
        proxy.finished(self, entry: entry)
    }
}
