#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// An IPv4 or IPv6 address. Parsed with inet_pton, so it works the same on
/// macOS and Linux without Network.framework.
public enum IPAddress: Hashable, Sendable, CustomStringConvertible {
    /// Host byte order.
    case v4(UInt32)
    /// 16 bytes, network order.
    case v6([UInt8])

    public init?(_ string: String) {
        var a4 = in_addr()
        if inet_pton(AF_INET, string, &a4) == 1 {
            self = .v4(UInt32(bigEndian: a4.s_addr))
            return
        }
        var a6 = in6_addr()
        if inet_pton(AF_INET6, string, &a6) == 1 {
            self = .v6(withUnsafeBytes(of: &a6) { Array($0) })
            return
        }
        return nil
    }

    /// The address in a sockaddr (AF_INET or AF_INET6), or nil for other families.
    init?(_ sa: UnsafePointer<sockaddr>) {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            let v = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            self = .v4(UInt32(bigEndian: v))
        case AF_INET6:
            var a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            self = .v6(withUnsafeBytes(of: &a) { Array($0) })
        default:
            return nil
        }
    }

    /// The IPv4 address inside an IPv4-mapped IPv6 address (::ffff:a.b.c.d).
    public var asIPv4: UInt32? {
        switch self {
        case .v4(let v): return v
        case .v6(let b):
            guard b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff else { return nil }
            return b[12...].reduce(0) { ($0 << 8) | UInt32($1) }
        }
    }

    public var isLoopback: Bool {
        if let v = asIPv4 { return v >> 24 == 127 }
        if case .v6(let b) = self { return b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1 }
        return false
    }

    /// Loopback, link-local, multicast, unspecified, "this network" (0/8),
    /// or for IPv6 also unique-local (fc00::/7).
    public var isLocal: Bool {
        if let v = asIPv4 {
            let first = v >> 24
            return first == 127 || first == 0 || v >> 16 == 0xa9fe || first >= 224 && first <= 239
        }
        guard case .v6(let b) = self else { return false }
        if b.allSatisfy({ $0 == 0 }) || isLoopback { return true }
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true } // fe80::/10
        if b[0] & 0xfe == 0xfc { return true }                  // fc00::/7
        return b[0] == 0xff                                     // multicast
    }

    public var description: String {
        switch self {
        case .v4(let v):
            return "\(v >> 24).\((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
        case .v6(var b):
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            _ = b.withUnsafeMutableBytes { inet_ntop(AF_INET6, $0.baseAddress, &buf, socklen_t(buf.count)) }
            return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}

/// An errno value as an Error.
struct Errno: Error {
    let code: Int32
}

/// Thin wrappers over BSD sockets that read the same on macOS and Linux.
enum Sock {
    #if os(Linux)
    static let stream = Int32(SOCK_STREAM.rawValue)
    static let noSignal = Int32(MSG_NOSIGNAL)
    #else
    static let stream = SOCK_STREAM
    static let noSignal: Int32 = 0
    #endif

    /// A stream socket that never raises SIGPIPE.
    static func make(_ family: Int32) -> Int32 {
        let fd = socket(family, stream, 0)
        #if canImport(Darwin)
        if fd >= 0 {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        #endif
        return fd
    }

    static func setNonBlocking(_ fd: Int32, _ on: Bool) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, on ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
    }

    /// Listens on `host` (an IP literal) or, with nil, on every address
    /// (IPv6 dual-stack where available, else IPv4). Returns (fd, port).
    static func listen(host: String?, port: UInt16) throws -> (Int32, UInt16) {
        let address = try host.map { h -> IPAddress in
            guard let a = IPAddress(h) else { throw MudroomError.invalid("not an IP address: \(h)") }
            return a
        }
        var candidates: [IPAddress] = address.map { [$0] } ?? [.v6([UInt8](repeating: 0, count: 16)), .v4(0)]
        var lastError: Int32 = 0
        while !candidates.isEmpty {
            let a = candidates.removeFirst()
            let family = a.isV6 ? AF_INET6 : AF_INET
            let fd = make(family)
            guard fd >= 0 else { lastError = errno; continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            if a.isV6 && host == nil {
                var zero: Int32 = 0
                setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
            }
            let rc = withSockaddr(a, port: port) { bind(fd, $0, $1) }
            if rc != 0 || cListen(fd, 128) != 0 {
                lastError = errno
                close(fd)
                continue
            }
            return (fd, localPort(fd))
        }
        throw MudroomError.posix("listen", host ?? "*", lastError)
    }

    static func localPort(_ fd: Int32) -> UInt16 {
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard rc == 0 else { return 0 }
        return withUnsafePointer(to: &ss) { p -> UInt16 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                switch Int32(sa.pointee.sa_family) {
                case AF_INET: return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
                case AF_INET6: return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
                default: return 0
                }
            }
        }
    }

    /// Accepts one connection; returns the fd and the peer address.
    static func accept(_ fd: Int32) -> (Int32, IPAddress?)? {
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let c = withUnsafeMutablePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { cAccept(fd, $0, &len) }
        }
        guard c >= 0 else { return nil }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let peer = withUnsafePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { IPAddress($0) } }
        return (c, peer)
    }

    static func withSockaddr<R>(_ a: IPAddress, port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        switch a {
        case .v4(let v):
            var sin = sockaddr_in()
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = port.bigEndian
            sin.sin_addr.s_addr = v.bigEndian
            return withUnsafePointer(to: &sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        case .v6(let b):
            var sin6 = sockaddr_in6()
            sin6.sin6_family = sa_family_t(AF_INET6)
            sin6.sin6_port = port.bigEndian
            withUnsafeMutableBytes(of: &sin6.sin6_addr) { dst in b.withUnsafeBytes { dst.copyMemory(from: $0) } }
            return withUnsafePointer(to: &sin6) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
    }

    /// Resolves a host name (or IP literal) to addresses, in resolver order.
    static func resolve(_ host: String) -> Result<[IPAddress], MudroomError> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = stream
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &res)
        guard rc == 0, let first = res else {
            return .failure(.invalid("DNS: \(String(cString: gai_strerror(rc)))"))
        }
        defer { freeaddrinfo(first) }
        var out: [IPAddress] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if let sa = ai.pointee.ai_addr, let a = IPAddress(UnsafePointer(sa)), !out.contains(a) { out.append(a) }
            p = ai.pointee.ai_next
        }
        return .success(out)
    }

    /// Connects with a timeout. Returns a blocking fd, or the errno.
    static func connect(_ a: IPAddress, port: UInt16, timeout: TimeInterval, cancelled: () -> Bool) -> Result<Int32, Errno> {
        let fd = make(a.isV6 ? AF_INET6 : AF_INET)
        guard fd >= 0 else { return .failure(Errno(code: errno)) }
        setNonBlocking(fd, true)
        let rc = withSockaddr(a, port: port) { cConnect(fd, $0, $1) }
        if rc != 0 && errno != EINPROGRESS {
            let e = errno
            close(fd)
            return .failure(Errno(code: e))
        }
        if rc != 0 {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if cancelled() {
                    close(fd)
                    return .failure(Errno(code: ECANCELED))
                }
                let left = deadline.timeIntervalSinceNow
                if left <= 0 {
                    close(fd)
                    return .failure(Errno(code: ETIMEDOUT))
                }
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let n = poll(&p, 1, Int32(min(left, 0.25) * 1000) + 1)
                if n > 0 { break }
                if n < 0 && errno != EINTR {
                    let e = errno
                    close(fd)
                    return .failure(Errno(code: e))
                }
            }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 {
                close(fd)
                return .failure(Errno(code: err))
            }
        }
        setNonBlocking(fd, false)
        return .success(fd)
    }

    /// Writes all of `data`; false if the peer went away.
    static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = send(fd, p, left, noSignal)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                left -= n
                p += n
            }
            return true
        }
    }

    /// Waits up to `timeout` seconds for `fd` to be readable (or closed).
    static func waitReadable(_ fd: Int32, timeout: TimeInterval) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let n = poll(&p, 1, Int32(timeout * 1000))
        return n > 0
    }

    static func errorText(_ code: Int32) -> String { String(cString: strerror(code)) }
}

extension IPAddress {
    var isV6: Bool { if case .v6 = self { return true } else { return false } }
}

// `listen`, `accept` and `connect` are also names in `Sock`; these reach the
// C functions.
@inline(__always) private func cListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
@inline(__always) private func cAccept(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>, _ len: UnsafeMutablePointer<socklen_t>) -> Int32 {
    accept(fd, addr, len)
}
@inline(__always) private func cConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    connect(fd, addr, len)
}
