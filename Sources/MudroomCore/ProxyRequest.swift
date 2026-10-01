import Foundation

/// A parsed proxy request head: `CONNECT host:port` or an absolute-form
/// `http://` request. Parsing is strict on purpose; anything a resolver,
/// URL parser or upstream server might read differently is refused.
struct ProxyRequest: Equatable {
    var method: String
    var host: ProxyHost
    var port: Int
    var version: String
    /// Plain HTTP only: the request target in origin form ("/a?b").
    var originTarget: String?
    /// Header lines as received, in order (plain HTTP only uses them).
    var headerLines: [String]

    var isConnect: Bool { method == "CONNECT" }

    struct Failure: Error, Equatable {
        var reason: String
        /// The host as sent, escaped for the log, when one was found.
        var rawHost: String?
        var port: Int?
        var method: String?
    }

    static let maxHeaderLines = 100

    static func parse(_ head: Data) -> Result<ProxyRequest, Failure> {
        parseHead(head).mapError { f in
            guard f.rawHost == nil else { return f }
            // Keep the attempted target for the log, escaped.
            var g = f
            let firstLine = head.prefix { $0 != 0x0D && $0 != 0x0A }
            let parts = firstLine.split(separator: 0x20, maxSplits: 2)
            if parts.count >= 2 {
                g.method = g.method ?? String(decoding: parts[0].prefix(16), as: UTF8.self).filter { $0.isLetter }
                g.rawHost = HostName.printable(String(decoding: parts[1], as: UTF8.self))
            }
            return g
        }
    }

    static func parseHead(_ head: Data) -> Result<ProxyRequest, Failure> {
        // Visible ASCII, tab and CRLF line breaks only (bytes >= 0x80 are
        // allowed in header values). No NUL, no bare CR or LF.
        var i = head.startIndex
        while i < head.endIndex {
            let b = head[i]
            if b == 0x0D {
                let n = head.index(after: i)
                guard n < head.endIndex, head[n] == 0x0A else { return .failure(Failure(reason: "bare CR in request")) }
                i = head.index(after: n)
                continue
            }
            if b == 0x0A { return .failure(Failure(reason: "bare LF in request")) }
            if (b < 0x20 && b != 0x09) || b == 0x7F { return .failure(Failure(reason: "control character in request")) }
            i = head.index(after: i)
        }
        let text = String(decoding: head, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        guard requestLine.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
            return .failure(Failure(reason: "non-ASCII request line"))
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return .failure(Failure(reason: "malformed request line")) }
        let method = parts[0], target = parts[1], version = parts[2]
        guard !method.isEmpty, method.unicodeScalars.allSatisfy(isTokenChar) else {
            return .failure(Failure(reason: "bad method"))
        }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            return .failure(Failure(reason: "unsupported HTTP version", method: method))
        }
        guard lines.count <= maxHeaderLines else { return .failure(Failure(reason: "too many header lines", method: method)) }
        for line in lines where !line.isEmpty {
            // No obsolete line folding, and every line is "name: value".
            guard let first = line.unicodeScalars.first, first != " ", first != "\t",
                  let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line[..<colon].unicodeScalars.allSatisfy(isTokenChar) else {
                return .failure(Failure(reason: "malformed header line", method: method))
            }
        }
        let headerLines = lines.filter { !$0.isEmpty }

        if method == "CONNECT" {
            switch authority(target, defaultPort: nil) {
            case .failure(let f):
                return .failure(Failure(reason: "bad CONNECT target: \(f.reason)", rawHost: f.rawHost, port: f.port, method: method))
            case .success(let (host, port)):
                return .success(ProxyRequest(method: method, host: host, port: port, version: version,
                                             originTarget: nil, headerLines: headerLines))
            }
        }

        // Absolute form: http://authority[/path][?query]. No fragments.
        let scheme = "http://"
        guard target.count > scheme.count, target.prefix(scheme.count).lowercased() == scheme else {
            return .failure(Failure(reason: "only absolute http:// URLs and CONNECT are supported", method: method))
        }
        let rest = target.dropFirst(scheme.count)
        guard !rest.contains("#") else { return .failure(Failure(reason: "fragment in request target", method: method)) }
        let end = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
        let auth = String(rest[..<end])
        var path = String(rest[end...])
        if path.isEmpty { path = "/" } else if path.hasPrefix("?") { path = "/" + path }
        switch authority(auth, defaultPort: 80) {
        case .failure(let f):
            return .failure(Failure(reason: "bad URL host: \(f.reason)", rawHost: f.rawHost, port: f.port, method: method))
        case .success(let (host, port)):
            return .success(ProxyRequest(method: method, host: host, port: port, version: version,
                                         originTarget: path, headerLines: headerLines))
        }
    }

    /// "host:port", "[v6]:port" or (with a default port) just the host.
    static func authority(_ s: String, defaultPort: Int?) -> Result<(ProxyHost, Int), Failure> {
        if s.contains("@") { return .failure(Failure(reason: "userinfo is not allowed", rawHost: HostName.printable(s))) }
        if s.contains("%") { return .failure(Failure(reason: "percent-encoding is not allowed", rawHost: HostName.printable(s))) }
        var hostPart = s
        var portPart: String?
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return .failure(Failure(reason: "unclosed [", rawHost: HostName.printable(s))) }
            hostPart = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            if after.hasPrefix(":") {
                portPart = String(after.dropFirst())
            } else if !after.isEmpty {
                return .failure(Failure(reason: "junk after ]", rawHost: HostName.printable(s)))
            }
            guard hostPart.contains(":") else { return .failure(Failure(reason: "brackets need an IPv6 address", rawHost: HostName.printable(hostPart))) }
        } else if let colon = s.firstIndex(of: ":") {
            guard s.lastIndex(of: ":") == colon else {
                return .failure(Failure(reason: "IPv6 addresses need brackets", rawHost: HostName.printable(s)))
            }
            hostPart = String(s[..<colon])
            portPart = String(s[s.index(after: colon)...])
        }
        let port: Int
        if let portPart {
            guard !portPart.isEmpty, portPart.count <= 5, portPart.allSatisfy(\.isASCIIDigit),
                  let p = Int(portPart), (1...65535).contains(p) else {
                return .failure(Failure(reason: "bad port", rawHost: HostName.printable(hostPart)))
            }
            port = p
        } else if let d = defaultPort {
            port = d
        } else {
            return .failure(Failure(reason: "missing port", rawHost: HostName.printable(hostPart)))
        }
        switch HostName.parse(hostPart) {
        case .success(let h): return .success((h, port))
        case .failure(let e): return .failure(Failure(reason: e.description, rawHost: HostName.printable(hostPart), port: port))
        }
    }

    static func isTokenChar(_ s: Unicode.Scalar) -> Bool {
        HostName.isLDH(s) || "!#$&'*+.^_`|~".unicodeScalars.contains(s)
    }

    /// The head sent upstream for plain HTTP: origin-form request line, hop
    /// by hop and proxy headers dropped, Host set to the checked target
    /// (whatever the client sent), and one request per connection.
    func upstreamHead() -> Data {
        let dropped: Set<String> = ["proxy-connection", "proxy-authorization", "connection", "keep-alive", "host", "upgrade", "te"]
        var out = ["\(method) \(originTarget ?? "/") \(version)"]
        out.append("Host: " + host.authority + (port == 80 ? "" : ":\(port)"))
        for line in headerLines {
            let name = line.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
            if !dropped.contains(name) { out.append(line) }
        }
        out.append("Connection: close")
        return Data((out.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}
