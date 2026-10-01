import Foundation

/// A destination host taken from a proxy request, validated and in its one
/// canonical spelling. The same string is used for the allowlist check, the
/// DNS lookup and the log, so what is checked is what gets connected to.
public enum ProxyHost: Hashable, Sendable, CustomStringConvertible {
    /// Lowercase letters, digits and hyphens in dot-separated labels, no
    /// trailing dot. Internationalized names arrive in their xn-- form.
    case name(String)
    /// An IPv4 or IPv6 literal.
    case ip(IPAddress)

    public var canonical: String {
        switch self {
        case .name(let n): n
        case .ip(let a): a.description
        }
    }

    public var description: String { canonical }

    /// The host as it goes in a Host header or URL authority (IPv6 in brackets).
    public var authority: String {
        if case .ip(let a) = self, a.isV6 { return "[\(a)]" }
        return canonical
    }
}

public enum HostName {
    public static let maxLength = 253
    public static let maxLabel = 63

    /// Parses a host name or IP literal. IPv6 literals are given without
    /// brackets. Rejects anything a resolver or URL parser could read in
    /// more than one way: NUL and other control characters, whitespace,
    /// percent-encoding, userinfo, empty or oversized labels, labels that
    /// start or end with a hyphen, raw non-ASCII (send the xn-- form), and
    /// numeric shorthands such as "127.1" or "0x7f.0.0.1".
    public static func parse(_ raw: String) -> Result<ProxyHost, HostNameError> {
        guard !raw.isEmpty else { return .failure(.empty) }
        if raw.contains(":") {
            // Only an IPv6 literal may contain a colon. No zone ids.
            guard raw.unicodeScalars.allSatisfy({ isHex($0) || $0 == ":" || $0 == "." }),
                  let a = IPAddress(raw), a.isV6 else { return .failure(.badCharacter) }
            return .success(.ip(a))
        }
        for s in raw.unicodeScalars {
            if s.value >= 0x80 { return .failure(.nonASCII) }
            guard isLDH(s) || s == "." else { return .failure(.badCharacter) }
        }
        var name = raw.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= maxLength else { return .failure(.tooLong) }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard !label.isEmpty else { return .failure(.emptyLabel) }
            guard label.utf8.count <= maxLabel else { return .failure(.tooLong) }
            guard label.first != "-", label.last != "-" else { return .failure(.hyphen) }
        }
        // A numeric last label means the resolver would read it as an
        // address. Accept only the plain dotted quad, in canonical form.
        if let last = labels.last, last.allSatisfy(\.isASCIIDigit) {
            guard labels.count == 4, labels.allSatisfy(isCanonicalOctet),
                  let a = IPAddress(name), !a.isV6 else { return .failure(.numeric) }
            return .success(.ip(a))
        }
        return .success(.name(name))
    }

    /// The host for display in logs: printable ASCII as is, everything else
    /// escaped, so "a\u{0}.b" shows up as "a\x00.b".
    public static func printable(_ raw: String, limit: Int = 255) -> String {
        var out = ""
        for b in raw.utf8.prefix(limit) {
            if b >= 0x21 && b < 0x7f && b != UInt8(ascii: "\\") {
                out.append(Character(Unicode.Scalar(b)))
            } else {
                out += String(format: "\\x%02x", b)
            }
        }
        return out
    }

    static func isLDH(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s) || s == "-"
    }

    static func isHex(_ s: Unicode.Scalar) -> Bool {
        ("a"..."f").contains(s) || ("A"..."F").contains(s) || ("0"..."9").contains(s)
    }

    static func isCanonicalOctet(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= 3, label.allSatisfy(\.isASCIIDigit),
              label == "0" || label.first != "0", let v = Int(label) else { return false }
        return v <= 255
    }
}

public enum HostNameError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty, badCharacter, nonASCII, tooLong, emptyLabel, hyphen, numeric

    public var description: String {
        switch self {
        case .empty: "empty host"
        case .badCharacter: "host contains characters that aren't allowed in a host name"
        case .nonASCII: "non-ASCII host name; send its xn-- (punycode) form"
        case .tooLong: "host name or label too long"
        case .emptyLabel: "host name has an empty label"
        case .hyphen: "host name label starts or ends with a hyphen"
        case .numeric: "numeric host that isn't a plain dotted-quad IPv4 address"
        }
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
