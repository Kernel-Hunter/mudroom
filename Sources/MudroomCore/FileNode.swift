import CryptoKit
import Darwin
import Foundation

/// What lives at a path, reduced to the parts that matter for review and
/// conflict checks. Timestamps are ignored on purpose: an agent can set mtime
/// back, so every comparison is by content.
public enum FileNode: Codable, Equatable, Sendable {
    case absent
    case file(mode: UInt16, size: Int64, sha256: String)
    case symlink(target: String)
    case directory(mode: UInt16)
    /// FIFOs, sockets, device nodes. Never copied, only reported.
    case special

    public var kindName: String {
        switch self {
        case .absent: "absent"
        case .file: "file"
        case .symlink: "symlink"
        case .directory: "directory"
        case .special: "special"
        }
    }

    public var isDirectory: Bool {
        if case .directory = self { return true }
        return false
    }

    public var mode: UInt16? {
        switch self {
        case .file(let mode, _, _), .directory(let mode): mode
        default: nil
        }
    }

    public var size: Int64? {
        if case .file(_, let size, _) = self { return size }
        return nil
    }

    /// Reads the node at `url` without following a final symlink.
    public static func read(at url: URL) throws -> FileNode {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return .absent }
            throw MudroomError.posix("lstat", url.path, errno)
        }
        let mode = UInt16(st.st_mode & 0o7777)
        switch st.st_mode & S_IFMT {
        case S_IFREG:
            return .file(mode: mode, size: Int64(st.st_size), sha256: try sha256(of: url))
        case S_IFLNK:
            return .symlink(target: try readLink(url))
        case S_IFDIR:
            return .directory(mode: mode)
        default:
            return .special
        }
    }

    static func readLink(_ url: URL) throws -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(url.path, &buf, buf.count - 1)
        if n < 0 { throw MudroomError.posix("readlink", url.path, errno) }
        return String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A flat listing of a directory tree keyed by relative path ("src/main.swift").
public struct TreeSnapshot: Sendable {
    public var nodes: [String: FileNode]

    public init(nodes: [String: FileNode]) { self.nodes = nodes }

    /// Walks `root` without following symlinks. The root itself is not included.
    public static func scan(_ root: URL) throws -> TreeSnapshot {
        var nodes: [String: FileNode] = [:]
        try walk(root, relative: "", into: &nodes)
        return TreeSnapshot(nodes: nodes)
    }

    private static func walk(_ dir: URL, relative: String, into nodes: inout [String: FileNode]) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        for name in names {
            let rel = relative.isEmpty ? name : relative + "/" + name
            let url = dir.appendingPathComponent(name, isDirectory: false)
            let node = try FileNode.read(at: url)
            nodes[rel] = node
            if node.isDirectory {
                try walk(url, relative: rel, into: &nodes)
            }
        }
    }
}
