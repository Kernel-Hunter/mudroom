#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if canImport(Security)
import Security
#endif
import Foundation

/// A long-lived agent credential kept by Mudroom (for Claude Code, the
/// output of `claude setup-token`), passed to sessions by variable name.
public protocol AgentTokenStore: Sendable {
    func read(_ agent: String) throws -> String?
    func write(_ agent: String, _ token: String) throws
    /// True if there was one to delete.
    func delete(_ agent: String) throws -> Bool
    /// Where it is kept, for messages.
    var location: String { get }
    /// Every stored name (agent ids and `env.NAME` API keys). Values are
    /// not read, so on macOS this never asks for Keychain access.
    func accounts() throws -> [String]
    /// True if something is stored under this name, without reading it.
    func contains(_ agent: String) -> Bool
}

extension AgentTokenStore {
    public func accounts() throws -> [String] { [] }
    public func contains(_ agent: String) -> Bool { ((try? accounts()) ?? []).contains(agent) }
}

public enum AgentToken {
    public static let keychainService = "io.github.kernel-hunter.mudroom"

    /// The variable each agent reads its token from.
    public static func variable(for agent: String) -> String? {
        switch agent {
        case "claude": "CLAUDE_CODE_OAUTH_TOKEN"
        case "codex": "OPENAI_API_KEY"
        case "gemini": "GEMINI_API_KEY"
        default: nil
        }
    }

    /// The macOS Keychain on macOS, else a 0600 file in the data directory.
    public static func defaultStore(_ store: SessionStore) -> AgentTokenStore {
        #if canImport(Security) && os(macOS)
        if ProcessInfo.processInfo.environment["MUDROOM_TOKEN_STORE"] != "file" { return KeychainTokenStore() }
        #endif
        return FileTokenStore(root: store.root)
    }

    /// Keeps only characters tokens and API keys use, so a paste that the
    /// terminal wrapped (newlines, spaces, box-drawing borders) still
    /// gives the token.
    public static func clean(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { s in
            ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s) || s == "-" || s == "_" || s == "."
        }.map(Character.init))
    }

    /// A sanity check on what was pasted, or nil if it looks fine.
    public static func problem(_ token: String, agent: String) -> String? {
        if token.count < 20 { return "that is too short to be a token" }
        if agent == "claude" && !token.hasPrefix("sk-ant-") {
            return "Claude tokens start with sk-ant- (run `claude setup-token` and paste what it prints)"
        }
        return nil
    }
}

/// `<data dir>/agents/<id>/token`, mode 0600, in a 0700 directory.
public struct FileTokenStore: AgentTokenStore {
    public let root: URL

    public init(root: URL) { self.root = root }

    func url(_ agent: String) -> URL {
        root.appendingPathComponent("agents", isDirectory: true).appendingPathComponent(agent, isDirectory: true)
            .appendingPathComponent("token")
    }

    public var location: String { root.appendingPathComponent("agents/<agent>/token").path }

    public func read(_ agent: String) throws -> String? {
        let u = url(agent)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        let fd = open(u.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MudroomError.posix("open", u.path, errno) }
        defer { close(fd) }
        let t = String(decoding: try SafeFS.readAll(fd, limit: 64 << 10), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public func write(_ agent: String, _ token: String) throws {
        let u = url(agent)
        let dir = u.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o700)
        let tmp = dir.appendingPathComponent(".token-\(UUID().uuidString.prefix(8))")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MudroomError.posix("open", tmp.path, errno) }
        let bytes = Array((token + "\n").utf8)
        let n = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard n == bytes.count, rename(tmp.path, u.path) == 0 else {
            unlink(tmp.path)
            throw MudroomError.posix("write", u.path, errno)
        }
    }

    public func accounts() throws -> [String] {
        let dir = root.appendingPathComponent("agents", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: url($0).path) }.sorted()
    }

    public func delete(_ agent: String) throws -> Bool {
        let u = url(agent)
        guard FileManager.default.fileExists(atPath: u.path) else { return false }
        try FileManager.default.removeItem(at: u)
        return true
    }
}

#if canImport(Security) && os(macOS)
/// A generic password in the login keychain: service
/// io.github.kernel-hunter.mudroom, account = agent id. Written with
/// SecItemAdd, so the token never goes through a command line.
public struct KeychainTokenStore: AgentTokenStore {
    public init() {}

    public var location: String { "the macOS Keychain (\(AgentToken.keychainService))" }

    func query(_ agent: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AgentToken.keychainService,
         kSecAttrAccount as String: agent]
    }

    public func read(_ agent: String) throws -> String? {
        var q = query(agent)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Self.error("read", status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ agent: String, _ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query(agent) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Self.error("update", status) }
        var add = query(agent)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = agent.hasPrefix(APIKeys.prefix) ? "Mudroom \(agent.dropFirst(APIKeys.prefix.count))" : "Mudroom \(agent) token"
        let s2 = SecItemAdd(add as CFDictionary, nil)
        guard s2 == errSecSuccess else { throw Self.error("add", s2) }
    }

    public func accounts() throws -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: AgentToken.keychainService,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = out as? [[String: Any]] else { throw Self.error("list", status) }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    public func contains(_ agent: String) -> Bool {
        var q = query(agent)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    public func delete(_ agent: String) throws -> Bool {
        let status = SecItemDelete(query(agent) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Self.error("delete", status) }
        return true
    }

    static func error(_ what: String, _ status: OSStatus) -> MudroomError {
        let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return .invalid("Keychain \(what) failed: \(msg)")
    }
}
#endif
