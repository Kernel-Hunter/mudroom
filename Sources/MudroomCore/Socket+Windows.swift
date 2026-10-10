#if os(Windows)
import WinSDK
import Foundation

/// Winsock versions of the socket wrappers in Socket.swift. Sockets are
/// handles on Windows; they are kept as Int32 like descriptors elsewhere,
/// which is safe because Windows keeps handle values within 32 bits so
/// 32- and 64-bit processes can share them.
enum Sock {
    static let stream = Int32(SOCK_STREAM)

    /// Winsock needs starting once per process.
    static let started: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()

    static func handle(_ fd: Int32) -> SOCKET { SOCKET(UInt(bitPattern: Int(fd))) }

    static func descriptor(_ s: SOCKET) -> Int32 {
        s == INVALID_SOCKET ? -1 : Int32(truncatingIfNeeded: Int(bitPattern: UInt(s)))
    }

    static var lastError: Int32 { WSAGetLastError() }

    static func make(_ family: Int32) -> Int32 {
        _ = started
        return descriptor(wsSocket(family, stream))
    }

    static func setNonBlocking(_ fd: Int32, _ on: Bool) {
        var mode: u_long = on ? 1 : 0
        _ = ioctlsocket(handle(fd), FIONBIO, &mode)
    }

    static func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) {
        var v = value
        _ = withUnsafePointer(to: &v) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4) { setsockopt(handle(fd), level, name, $0, 4) }
        }
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
            let fd = make(a.isV6 ? AF_INET6 : AF_INET)
            guard fd >= 0 else { lastError = Self.lastError; continue }
            // Not SO_REUSEADDR: on Windows it lets another program take
            // over the port. Exclusive use is what the proxy wants.
            setOption(fd, Int32(SOL_SOCKET), ~Int32(SO_REUSEADDR), 1) // SO_EXCLUSIVEADDRUSE
            if a.isV6 && host == nil {
                setOption(fd, Int32(IPPROTO_IPV6.rawValue), Int32(IPV6_V6ONLY), 0)
            }
            let rc = withSockaddr(a, port: port) { bind(handle(fd), $0, $1) }
            if rc != 0 || wsListen(handle(fd), 128) != 0 {
                lastError = Self.lastError
                close(fd)
                continue
            }
            return (fd, localPort(fd))
        }
        throw MudroomError.invalid("listen(\(host ?? "*")) failed: \(errorText(lastError))")
    }

    static func localPort(_ fd: Int32) -> UInt16 {
        var ss = sockaddr_storage()
        var len = Int32(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(handle(fd), $0, &len) }
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
        var len = Int32(MemoryLayout<sockaddr_storage>.size)
        let c = withUnsafeMutablePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { wsAccept(handle(fd), $0, &len) }
        }
        guard c != INVALID_SOCKET else { return nil }
        let peer = withUnsafePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { IPAddress($0) } }
        return (descriptor(c), peer)
    }

    static func withSockaddr<R>(_ a: IPAddress, port: UInt16, _ body: (UnsafePointer<sockaddr>, Int32) -> R) -> R {
        switch a {
        case .v4(let v):
            var sin = sockaddr_in()
            sin.sin_family = ADDRESS_FAMILY(AF_INET)
            sin.sin_port = port.bigEndian
            sin.sin_addr.S_un.S_addr = v.bigEndian
            return withUnsafePointer(to: &sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, Int32(MemoryLayout<sockaddr_in>.size)) }
            }
        case .v6(let b):
            var sin6 = sockaddr_in6()
            sin6.sin6_family = ADDRESS_FAMILY(AF_INET6)
            sin6.sin6_port = port.bigEndian
            withUnsafeMutableBytes(of: &sin6.sin6_addr) { dst in b.withUnsafeBytes { dst.copyMemory(from: $0) } }
            return withUnsafePointer(to: &sin6) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, Int32(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
    }

    /// Resolves a host name (or IP literal) to addresses, in resolver order.
    static func resolve(_ host: String) -> Result<[IPAddress], MudroomError> {
        _ = started
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = stream
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &res)
        guard rc == 0, let first = res else {
            return .failure(.invalid("DNS: \(errorText(rc))"))
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

    /// Connects with a timeout. Returns a blocking socket, or the Winsock
    /// error.
    static func connect(_ a: IPAddress, port: UInt16, timeout: TimeInterval, cancelled: () -> Bool) -> Result<Int32, Errno> {
        let fd = make(a.isV6 ? AF_INET6 : AF_INET)
        guard fd >= 0 else { return .failure(Errno(code: lastError)) }
        setNonBlocking(fd, true)
        let rc = withSockaddr(a, port: port) { wsConnect(handle(fd), $0, $1) }
        if rc != 0 && lastError != WSAEWOULDBLOCK {
            let e = lastError
            close(fd)
            return .failure(Errno(code: e))
        }
        if rc != 0 {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if cancelled() {
                    close(fd)
                    return .failure(Errno(code: WSAECONNABORTED))
                }
                let left = deadline.timeIntervalSinceNow
                if left <= 0 {
                    close(fd)
                    return .failure(Errno(code: WSAETIMEDOUT))
                }
                // select, not WSAPoll: older Windows 10 builds' WSAPoll never
                // reports a failed connect.
                var writable = fd_set()
                writable.fd_count = 1
                writable.fd_array.0 = handle(fd)
                var failed = writable
                let ms = Int32(min(left, 0.25) * 1000) + 1
                var tv = timeval(tv_sec: 0, tv_usec: ms * 1000)
                let n = select(0, nil, &writable, &failed, &tv)
                if n == SOCKET_ERROR {
                    let e = lastError
                    close(fd)
                    return .failure(Errno(code: e))
                }
                if n == 0 { continue }
                if failed.fd_count > 0 {
                    var err: Int32 = 0
                    var len = Int32(4)
                    _ = withUnsafeMutablePointer(to: &err) {
                        $0.withMemoryRebound(to: CChar.self, capacity: 4) { getsockopt(handle(fd), SOL_SOCKET, SO_ERROR, $0, &len) }
                    }
                    close(fd)
                    return .failure(Errno(code: err != 0 ? err : WSAECONNREFUSED))
                }
                break
            }
        }
        setNonBlocking(fd, false)
        return .success(fd)
    }

    /// Writes all of `data`; false if the peer went away.
    static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return true }
            var left = raw.count
            while left > 0 {
                let n = send(handle(fd), p, Int32(min(left, 1 << 30)), 0)
                if n == SOCKET_ERROR {
                    if lastError == WSAEINTR || lastError == WSAEWOULDBLOCK { continue }
                    return false
                }
                left -= Int(n)
                p += Int(n)
            }
            return true
        }
    }

    /// Waits up to `timeout` seconds for `fd` to be readable (or closed).
    static func waitReadable(_ fd: Int32, timeout: TimeInterval) -> Bool {
        (poll([fd], timeoutMs: Int32(timeout * 1000)) ?? [false])[0]
    }

    static func errorText(_ code: Int32) -> String { Win32.message(DWORD(bitPattern: code)) }

    static func close(_ fd: Int32) { _ = closesocket(handle(fd)) }

    /// recv into `buf`: bytes read, 0 when the peer closed its side, or
    /// negative on an error. Nil when there is nothing to read after all.
    static func receive(_ fd: Int32, _ buf: inout [UInt8]) -> Int? {
        let n = buf.withUnsafeMutableBytes {
            recv(handle(fd), $0.baseAddress!.assumingMemoryBound(to: CChar.self), Int32($0.count), 0)
        }
        if n == SOCKET_ERROR && (lastError == WSAEINTR || lastError == WSAEWOULDBLOCK) { return nil }
        return Int(n)
    }

    static func shutdown(_ fd: Int32, both: Bool = false) {
        _ = wsShutdown(handle(fd), both ? Int32(SD_BOTH) : Int32(SD_SEND))
    }

    /// Waits up to `timeoutMs` (-1: forever) for any of `fds` to be
    /// readable or closed. One flag per socket; nil if WSAPoll failed.
    static func poll(_ fds: [Int32], timeoutMs: Int32) -> [Bool]? {
        var p = fds.map { WSAPOLLFD(fd: handle($0), events: Int16(POLLRDNORM), revents: 0) }
        let n = WSAPoll(&p, ULONG(p.count), timeoutMs)
        if n == SOCKET_ERROR { return lastError == WSAEINTR ? fds.map { _ in false } : nil }
        return p.map { $0.revents != 0 }
    }

    /// Two connected loopback sockets: a byte sent with `wake` on the
    /// second makes the first readable. (WSAPoll only takes sockets, so a
    /// pipe won't do.)
    static func wakePair() throws -> (Int32, Int32) {
        let (listener, port) = try listen(host: "127.0.0.1", port: 0)
        defer { close(listener) }
        guard case .success(let writer) = connect(.v4(0x7F00_0001), port: port, timeout: 5, cancelled: { false }),
              let (reader, _) = accept(listener) else {
            throw MudroomError.invalid("couldn't make the proxy's wake-up sockets: \(errorText(lastError))")
        }
        return (reader, writer)
    }

    static func wake(_ fd: Int32) {
        _ = sendAll(fd, Data([1]))
    }
}

// `socket`, `listen`, `accept`, `connect` and `shutdown` are also names in
// `Sock`; these reach the Winsock functions.
private func wsSocket(_ family: Int32, _ type: Int32) -> SOCKET { socket(family, type, 0) }
private func wsListen(_ s: SOCKET, _ backlog: Int32) -> Int32 { listen(s, backlog) }
private func wsAccept(_ s: SOCKET, _ addr: UnsafeMutablePointer<sockaddr>, _ len: UnsafeMutablePointer<Int32>) -> SOCKET {
    accept(s, addr, len)
}
private func wsConnect(_ s: SOCKET, _ addr: UnsafePointer<sockaddr>, _ len: Int32) -> Int32 { connect(s, addr, len) }
private func wsShutdown(_ s: SOCKET, _ how: Int32) -> Int32 { shutdown(s, how) }

extension IPAddress {
    /// This machine's addresses: what its own name resolves to (every
    /// interface's address on Windows), and the loopback addresses.
    public static func hostAddresses() -> Set<IPAddress> {
        var out: Set<IPAddress> = [.v4(0x7F00_0001), .v6([UInt8](repeating: 0, count: 15) + [1])]
        var name = [CChar](repeating: 0, count: 256)
        guard Sock.started, gethostname(&name, Int32(name.count)) == 0 else { return out }
        if case .success(let list) = Sock.resolve(String(cString: name)) { out.formUnion(list) }
        return out
    }
}
#endif
