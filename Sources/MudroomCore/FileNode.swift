#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
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
    /// Something is there but couldn't be read: no permission, a name that
    /// isn't UTF-8, or it changed while being read. Shown, never applied.
    case unreadable(reason: String)

    public var kindName: String {
        switch self {
        case .absent: "absent"
        case .file: "file"
        case .symlink: "symlink"
        case .directory: "directory"
        case .special: "special"
        case .unreadable: "unreadable"
        }
    }

    public var isDirectory: Bool {
        if case .directory = self { return true }
        return false
    }

    public var isUnreadable: Bool {
        if case .unreadable = self { return true }
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

    public var sha256: String? {
        if case .file(_, _, let sha) = self { return sha }
        return nil
    }

    /// Reads the node at `url` without following a final symlink. A regular
    /// file is hashed through a descriptor opened with O_NOFOLLOW and
    /// O_NONBLOCK and checked to be the inode lstat saw, so a file swapped
    /// for a symlink or a FIFO in between is reported, not followed.
    public static func read(at url: URL) throws -> FileNode {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return .absent }
            if errno == EACCES || errno == EPERM { return .unreadable(reason: "permission denied") }
            throw MudroomError.posix("lstat", url.path, errno)
        }
        return node(st, regular: { SafeFS.hashFile(path: url.path, expect: st) }, link: { try readLink(url) })
    }

    static func node(_ st: stat, regular: () -> Result<String, SafeFS.ReadError>, link: () throws -> String) -> FileNode {
        let mode = UInt16(st.st_mode & 0o7777)
        switch st.st_mode & S_IFMT {
        case S_IFREG:
            switch regular() {
            case .success(let sha): return .file(mode: mode, size: Int64(st.st_size), sha256: sha)
            case .failure(let e): return .unreadable(reason: e.description)
            }
        case S_IFLNK:
            do { return .symlink(target: try link()) } catch { return .unreadable(reason: "can't read link") }
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
}

/// Reading files inside a tree the agent controls (work/, snapshots)
/// without being tricked by symlinks, FIFOs or swaps.
public enum SafeFS {
    public enum ReadError: Error, CustomStringConvertible, Equatable {
        case denied
        case changed
        case notRegular
        case io(Int32)

        public var description: String {
            switch self {
            case .denied: "permission denied"
            case .changed: "changed while being read"
            case .notRegular: "not a regular file"
            case .io(let e): String(cString: strerror(e))
            }
        }
    }

    static let chunk = 1 << 20

    static func sameInode(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }

    /// Opens a regular file by path without following a final symlink or
    /// blocking on a FIFO, and checks it is the inode `expect` describes.
    static func openRegular(path: String, expect: stat?) -> Result<Int32, ReadError> {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            switch errno {
            case EACCES, EPERM: return .failure(.denied)
            case ELOOP, ENOENT, ENOTDIR, ENXIO: return .failure(.changed)
            default: return .failure(.io(errno))
            }
        }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            return .failure(.notRegular)
        }
        if let expect, !sameInode(st, expect) {
            close(fd)
            return .failure(.changed)
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        return .success(fd)
    }

    static func hashFile(path: String, expect: stat?) -> Result<String, ReadError> {
        switch openRegular(path: path, expect: expect) {
        case .failure(let e): return .failure(e)
        case .success(let fd):
            defer { close(fd) }
            return hash(fd: fd)
        }
    }

    /// SHA-256 of everything readable from `fd`, through one reusable
    /// buffer (no per-chunk allocations that pile up).
    static func hash(fd: Int32) -> Result<String, ReadError> {
        var hasher = SHA256()
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buf.deallocate() }
        while true {
            let n = sysRead(fd, buf.baseAddress, chunk)
            if n < 0 {
                if errno == EINTR { continue }
                return .failure(.io(errno))
            }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buf[0..<n]))
        }
        return .success(hex(hasher.finalize()))
    }

    public static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for b in digest {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0xf)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Opens `relative` (a path inside `root`) for reading, refusing a
    /// symlink at any component, so a directory swapped for a symlink
    /// can't redirect the read outside the tree.
    public static func openBeneath(_ root: URL, _ relative: String) throws -> Int32 {
        var dir = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { throw MudroomError.posix("open", root.path, errno) }
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else {
            close(dir)
            throw MudroomError.invalid("bad path \(relative)")
        }
        for name in parts.dropLast() {
            let next = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let err = errno
            close(dir)
            guard next >= 0 else {
                throw err == ENOTDIR || err == ELOOP
                    ? MudroomError.invalid("\(relative): a parent folder was replaced by a symlink or file")
                    : MudroomError.posix("open", relative, err)
            }
            dir = next
        }
        defer { close(dir) }
        let fd = openat(dir, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw errno == ELOOP ? MudroomError.invalid("\(relative) is a symlink") : MudroomError.posix("open", relative, errno)
        }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw MudroomError.invalid("\(relative) is not a regular file")
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        return fd
    }

    /// Reads a file inside `root` (see `openBeneath`). At most `limit` bytes.
    public static func readBeneath(_ root: URL, _ relative: String, limit: Int = .max) throws -> Data {
        let fd = try openBeneath(root, relative)
        defer { close(fd) }
        return try readAll(fd, limit: limit)
    }

    static func readAll(_ fd: Int32, limit: Int) throws -> Data {
        var out = Data()
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 << 10, alignment: 16)
        defer { buf.deallocate() }
        while out.count < limit {
            let n = sysRead(fd, buf.baseAddress, min(buf.count, limit - out.count))
            if n < 0 {
                if errno == EINTR { continue }
                throw MudroomError.posix("read", "file", errno)
            }
            if n == 0 { break }
            out.append(buf.baseAddress!.assumingMemoryBound(to: UInt8.self), count: n)
        }
        return out
    }

    /// Copies a file from inside `root` (opened as in `openBeneath`) to
    /// `destination`, which must not exist, and returns the SHA-256 of the
    /// bytes now at `destination`. Uses a copy-on-write clone where it can.
    public static func copyBeneath(_ root: URL, _ relative: String, to destination: URL) throws -> String {
        let src = try openBeneath(root, relative)
        defer { close(src) }
        #if canImport(Darwin)
        if fclonefileat(src, AT_FDCWD, destination.path, 0) == 0 {
            switch hashFile(path: destination.path, expect: nil) {
            case .success(let sha): return sha
            case .failure(let e): throw MudroomError.invalid("\(destination.path): \(e)")
            }
        }
        #endif
        let dst = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard dst >= 0 else { throw MudroomError.posix("open", destination.path, errno) }
        defer { close(dst) }
        var hasher = SHA256()
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buf.deallocate() }
        while true {
            let n = sysRead(src, buf.baseAddress, chunk)
            if n < 0 {
                if errno == EINTR { continue }
                throw MudroomError.posix("read", relative, errno)
            }
            if n == 0 { break }
            let slice = UnsafeRawBufferPointer(rebasing: buf[0..<n])
            hasher.update(bufferPointer: slice)
            var off = 0
            while off < n {
                let w = write(dst, slice.baseAddress! + off, n - off)
                if w < 0 {
                    if errno == EINTR { continue }
                    throw MudroomError.posix("write", destination.path, errno)
                }
                off += w
            }
        }
        return hex(hasher.finalize())
    }
}

/// The C read(2), reachable from types that have their own `read`.
@inline(__always) func sysRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ n: Int) -> Int { read(fd, buf, n) }

/// A flat listing of a directory tree keyed by relative path ("src/main.swift").
public struct TreeSnapshot: Sendable {
    public var nodes: [String: FileNode]

    public init(nodes: [String: FileNode]) { self.nodes = nodes }

    /// Walks `root` without following symlinks. The root itself is not
    /// included. Directories are opened relative to their parent with
    /// O_NOFOLLOW; files are hashed in parallel, each checked to be the
    /// inode the walk saw. Anything that can't be read becomes an
    /// `unreadable` node instead of failing the whole scan.
    public static func scan(_ root: URL) throws -> TreeSnapshot {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw MudroomError.posix("open", root.path, errno) }
        var entries: [(String, FileNode)] = []
        var files: [(index: Int, path: String, st: stat)] = []
        walk(rootFD, relative: "", entries: &entries, files: &files)
        close(rootFD)

        // Hash regular files on all cores.
        if !files.isEmpty {
            let base = root.path
            var hashed = [FileNode?](repeating: nil, count: files.count)
            let workers = max(1, min(files.count, ProcessInfo.processInfo.activeProcessorCount * 2))
            hashed.withUnsafeMutableBufferPointer { out in
                let outBase = Unchecked(out.baseAddress!)
                files.withUnsafeBufferPointer { buf in
                    let list = Unchecked(buf)
                    DispatchQueue.concurrentPerform(iterations: workers) { w in
                        var i = w
                        while i < list.value.count {
                            let f = list.value[i]
                            let st = f.st
                            (outBase.value + i).pointee = FileNode.node(st, regular: {
                                SafeFS.hashFile(path: base + "/" + f.path, expect: st)
                            }, link: { "" })
                            i += workers
                        }
                    }
                }
            }
            for (k, f) in files.enumerated() { entries[f.index].1 = hashed[k]! }
        }
        return TreeSnapshot(nodes: Dictionary(entries, uniquingKeysWith: { a, _ in a }))
    }

    private static func walk(_ dirFD: Int32, relative: String, entries: inout [(String, FileNode)],
                             files: inout [(index: Int, path: String, st: stat)]) {
        guard let names = listDirectory(dirFD) else { return }
        for raw in names {
            guard let name = raw.name else {
                let rel = relative.isEmpty ? raw.lossy : relative + "/" + raw.lossy
                entries.append((rel, .unreadable(reason: "name is not valid UTF-8")))
                continue
            }
            let rel = relative.isEmpty ? name : relative + "/" + name
            var st = stat()
            if fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue } // gone since readdir
                entries.append((rel, .unreadable(reason: String(cString: strerror(errno)))))
                continue
            }
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                files.append((entries.count, rel, st))
                entries.append((rel, .absent)) // filled in after hashing
            case S_IFLNK:
                entries.append((rel, FileNode.node(st, regular: { .failure(.notRegular) }, link: { try readLinkAt(dirFD, name) })))
            case S_IFDIR:
                let child = openat(dirFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else {
                    let reason = errno == EACCES || errno == EPERM ? "permission denied" : "changed while being read"
                    entries.append((rel, .unreadable(reason: reason)))
                    continue
                }
                var cst = stat()
                guard fstat(child, &cst) == 0, SafeFS.sameInode(cst, st) else {
                    close(child)
                    entries.append((rel, .unreadable(reason: "permission denied")))
                    continue
                }
                entries.append((rel, .directory(mode: UInt16(st.st_mode & 0o7777))))
                walk(child, relative: rel, entries: &entries, files: &files)
                close(child)
            default:
                entries.append((rel, .special))
            }
        }
    }

    struct RawName {
        var name: String?
        var lossy: String
    }

    /// Entry names of an open directory (without . and ..), or nil if it
    /// can't be listed. Leaves `fd` open.
    static func listDirectory(_ fd: Int32) -> [RawName]? {
        let d = dup(fd)
        guard d >= 0 else { return nil }
        // dup shares the offset; start from the top.
        lseek(d, 0, SEEK_SET)
        guard let dir = fdopendir(d) else {
            close(d)
            return nil
        }
        defer { closedir(dir) }
        var out: [RawName] = []
        while let ent = readdir(dir) {
            let raw: (String?, String) = withUnsafePointer(to: &ent.pointee.d_name) { p in
                p.withMemoryRebound(to: CChar.self, capacity: 1) { c in
                    (String(validatingCString: c), String(cString: c))
                }
            }
            if raw.1 == "." || raw.1 == ".." { continue }
            out.append(RawName(name: raw.0, lossy: raw.1))
        }
        return out
    }

    static func readLinkAt(_ dirFD: Int32, _ name: String) throws -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlinkat(dirFD, name, &buf, buf.count - 1)
        if n < 0 { throw MudroomError.posix("readlink", name, errno) }
        return String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
