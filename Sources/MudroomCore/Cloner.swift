#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif
import Foundation

public enum CloneMethod: String, Codable, Sendable {
    /// APFS copy-on-write clone (macOS): instant, no extra disk until files diverge.
    case clonefile
    /// Copy-on-write reflink (Linux, btrfs or XFS), via `cp --reflink=always`.
    case reflink
    /// Block cloning (Windows, ReFS and Dev Drives): files share blocks
    /// until one of them changes.
    case blockClone
    /// Plain recursive copy, used when the volume can't clone (ext4, non-APFS,
    /// or a different volume than the session store), or when the project
    /// holds something a clone can't take (unreadable files, sockets).
    case copy

    /// True for the copy-on-write methods.
    public var isClone: Bool { self != .copy }

    /// "APFS clone", "reflink clone", "block clone" or "copied".
    public var label: String {
        switch self {
        case .clonefile: "APFS clone"
        case .reflink: "reflink clone"
        case .blockClone: "block clone"
        case .copy: "copied"
        }
    }
}

/// Something the copy left out.
public struct SkippedEntry: Codable, Sendable, Equatable, CustomStringConvertible {
    public var path: String
    public var reason: String
    public var description: String { "\(path) (\(reason))" }
}

public struct CloneResult: Sendable {
    public var method: CloneMethod
    /// Sockets, FIFOs, devices and unreadable entries that weren't copied.
    public var skipped: [SkippedEntry]
    /// Entries left out because they match an exclude pattern.
    public var excluded: [ExcludedEntry] = []

    public init(method: CloneMethod, skipped: [SkippedEntry], excluded: [ExcludedEntry] = []) {
        self.method = method
        self.skipped = skipped
        self.excluded = excluded
    }
}

public enum Cloner {
    /// Clones `source` (a directory) to `destination`, which must not exist.
    /// Tries a copy-on-write clone first (clonefile(2) on macOS, a reflink on
    /// Linux, block cloning on Windows) and falls back to a copy that keeps modes, mtimes and symlinks
    /// and leaves out what it can't copy (see `CloneResult.skipped`).
    @discardableResult
    public static func cloneTree(from source: URL, to destination: URL, allowClonefile: Bool = true) throws -> CloneMethod {
        try clone(from: source, to: destination, allowClonefile: allowClonefile).method
    }

    #if !os(Windows)
    /// With `exclude`, entries it matches are left out: a copy skips them,
    /// and a whole-folder clone (clonefile, reflink) has them deleted before
    /// this returns. If that fails the clone is removed and this throws.
    public static func clone(from source: URL, to destination: URL, allowClonefile: Bool = true,
                             exclude: ExcludeRules = .empty) throws -> CloneResult {
        var whole: CloneMethod?
        #if canImport(Darwin)
        if allowClonefile {
            if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 {
                whole = .clonefile
            } else {
                // ENOTSUP / EXDEV: can't clone here. EACCES and friends: something
                // inside can't be read. Either way, copy what can be copied.
                try? FileManager.default.removeItem(at: destination)
            }
        }
        #else
        if allowClonefile, try copyWithCP(["--reflink=always"], source, destination) {
            whole = .reflink
        }
        #endif
        if let whole {
            guard !exclude.isEmpty else { return CloneResult(method: whole, skipped: []) }
            do {
                return CloneResult(method: whole, skipped: [], excluded: try ExcludeWalk.prune(destination, rules: exclude))
            } catch {
                try? ExcludeWalk.removeEntry(destination.path)
                throw error
            }
        }
        var skipped: [SkippedEntry] = []
        var excluded: [ExcludedEntry] = []
        do {
            try copyTree(source, destination, relative: "", canonical: [], exclude: exclude, skipped: &skipped, excluded: &excluded)
        } catch {
            try? ExcludeWalk.removeEntry(destination.path)
            throw error
        }
        return CloneResult(method: .copy, skipped: skipped, excluded: excluded)
    }

    /// Copies a single file or symlink, trying a clone first.
    static func cloneItem(from source: URL, to destination: URL) throws {
        #if canImport(Darwin)
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        #endif
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Recursive copy. Regular files are cloned per file where possible
    /// (same APFS volume), else copied; symlinks are recreated; anything
    /// else, and anything that can't be read, is recorded and left out.
    static func copyTree(_ src: URL, _ dst: URL, relative: String, skipped: inout [SkippedEntry]) throws {
        var excluded: [ExcludedEntry] = []
        try copyTree(src, dst, relative: relative, canonical: [], exclude: .empty, skipped: &skipped, excluded: &excluded)
    }

    /// `canonical` is `relative`'s components as `ExcludeRules` compares them.
    static func copyTree(_ src: URL, _ dst: URL, relative: String, canonical: [String], exclude: ExcludeRules,
                         skipped: inout [SkippedEntry], excluded: inout [ExcludedEntry]) throws {
        var st = stat()
        guard lstat(src.path, &st) == 0 else { throw MudroomError.posix("lstat", src.path, errno) }
        guard mkdir(dst.path, 0o700) == 0 else { throw MudroomError.posix("mkdir", dst.path, errno) }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: src.path)
        } catch {
            skipped.append(SkippedEntry(path: relative.isEmpty ? "." : relative + "/", reason: "folder can't be read"))
            chmod(dst.path, mode_t(st.st_mode & 0o7777))
            return
        }
        for name in names.sorted() {
            let rel = relative.isEmpty ? name : relative + "/" + name
            let s = src.appendingPathComponent(name)
            let d = dst.appendingPathComponent(name)
            var est = stat()
            guard lstat(s.path, &est) == 0 else {
                skipped.append(SkippedEntry(path: rel, reason: String(cString: strerror(errno))))
                continue
            }
            let type = est.st_mode & S_IFMT
            let canon = exclude.isEmpty ? [] : canonical + [ExcludeRules.canonicalName(name)]
            if !exclude.isEmpty,
               let pattern = exclude.matchEntry(canon[...], isDirectory: type == S_IFDIR || type == S_IFLNK) {
                let isDir = type == S_IFDIR
                excluded.append(ExcludedEntry(path: rel + (isDir ? "/" : ""), files: isDir ? ExcludeWalk.countFiles(s.path) : 1,
                                              pattern: pattern))
                continue
            }
            switch type {
            case S_IFDIR:
                try copyTree(s, d, relative: rel, canonical: canon, exclude: exclude, skipped: &skipped, excluded: &excluded)
            case S_IFLNK:
                guard let target = try? FileNode.readLink(s), symlink(target, d.path) == 0 else {
                    skipped.append(SkippedEntry(path: rel, reason: "symlink can't be read"))
                    continue
                }
                setTimes(d, est, followLinks: false)
            case S_IFREG:
                if !copyFile(s, d, est) {
                    skipped.append(SkippedEntry(path: rel, reason: errno == EACCES || errno == EPERM ? "permission denied" : String(cString: strerror(errno))))
                    try? FileManager.default.removeItem(at: d)
                }
            case S_IFSOCK:
                skipped.append(SkippedEntry(path: rel, reason: "socket"))
            case S_IFIFO:
                skipped.append(SkippedEntry(path: rel, reason: "fifo"))
            default:
                skipped.append(SkippedEntry(path: rel, reason: "device or other special file"))
            }
        }
        chmod(dst.path, mode_t(st.st_mode & 0o7777))
        setTimes(dst, st, followLinks: true)
    }

    /// One regular file, mode and times kept. False (errno set) on failure.
    static func copyFile(_ s: URL, _ d: URL, _ st: stat) -> Bool {
        #if canImport(Darwin)
        if clonefile(s.path, d.path, UInt32(CLONE_NOFOLLOW)) == 0 { return true }
        #endif
        let src = open(s.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard src >= 0 else { return false }
        defer { close(src) }
        let dst = open(d.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard dst >= 0 else { return false }
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buf.deallocate() }
        var ok = true
        loop: while true {
            let n = sysRead(src, buf.baseAddress, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                ok = false
                break
            }
            if n == 0 { break }
            var off = 0
            while off < n {
                let w = write(dst, buf.baseAddress! + off, n - off)
                if w < 0 {
                    if errno == EINTR { continue }
                    ok = false
                    break loop
                }
                off += w
            }
        }
        let saved = errno
        fchmod(dst, mode_t(st.st_mode & 0o7777))
        close(dst)
        if ok { setTimes(d, st, followLinks: true) }
        errno = saved
        return ok
    }

    /// Copies atime and mtime (the snapshot fingerprint uses mtimes).
    static func setTimes(_ url: URL, _ st: stat, followLinks: Bool) {
        #if canImport(Darwin)
        let times = [st.st_atimespec, st.st_mtimespec]
        #else
        let times = [st.st_atim, st.st_mtim]
        #endif
        times.withUnsafeBufferPointer {
            _ = utimensat(AT_FDCWD, url.path, $0.baseAddress, followLinks ? 0 : AT_SYMLINK_NOFOLLOW)
        }
    }
    #endif

    #if !canImport(Darwin) && !os(Windows)
    /// `cp -a` keeps modes, timestamps and symlinks (the snapshot fingerprint
    /// relies on mtimes). Returns false if cp is missing or failed, after
    /// removing anything it left behind.
    static func copyWithCP(_ extra: [String], _ source: URL, _ destination: URL) throws -> Bool {
        guard let cp = ["/bin/cp", "/usr/bin/cp"].first(where: FileManager.default.isExecutableFile) else { return false }
        let out = try ProcessRunner.capture(cp, ["-a", "--no-target-directory"] + extra + [source.path, destination.path])
        if out.status == 0 { return true }
        try? FileManager.default.removeItem(at: destination)
        return false
    }
    #endif
}
