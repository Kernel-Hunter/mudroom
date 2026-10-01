#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

public enum CloneMethod: String, Codable, Sendable {
    /// APFS copy-on-write clone (macOS): instant, no extra disk until files diverge.
    case clonefile
    /// Copy-on-write reflink (Linux, btrfs or XFS), via `cp --reflink=always`.
    case reflink
    /// Plain recursive copy, used when the volume can't clone (ext4, non-APFS,
    /// or a different volume than the session store).
    case copy

    /// True for the copy-on-write methods.
    public var isClone: Bool { self != .copy }

    /// "APFS clone", "reflink clone" or "copied".
    public var label: String {
        switch self {
        case .clonefile: "APFS clone"
        case .reflink: "reflink clone"
        case .copy: "copied"
        }
    }
}

public enum Cloner {
    /// Clones `source` (a directory) to `destination`, which must not exist.
    /// Tries a copy-on-write clone first (clonefile(2) on macOS, a reflink on
    /// Linux) and falls back to a regular copy that keeps modes and symlinks.
    @discardableResult
    public static func cloneTree(from source: URL, to destination: URL, allowClonefile: Bool = true) throws -> CloneMethod {
        #if canImport(Darwin)
        if allowClonefile {
            if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 {
                return .clonefile
            }
            let err = errno
            // ENOTSUP: filesystem can't clone. EXDEV: different volumes.
            guard err == ENOTSUP || err == EXDEV || err == EOPNOTSUPP else {
                throw MudroomError.posix("clonefile", source.path, err)
            }
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return .copy
        #else
        if allowClonefile, try copyWithCP(["--reflink=always"], source, destination) {
            return .reflink
        }
        if try copyWithCP([], source, destination) { return .copy }
        try FileManager.default.copyItem(at: source, to: destination)
        return .copy
        #endif
    }

    /// Copies a single file or symlink, trying a clone first.
    static func cloneItem(from source: URL, to destination: URL) throws {
        #if canImport(Darwin)
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        #endif
        try FileManager.default.copyItem(at: source, to: destination)
    }

    #if !canImport(Darwin)
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
