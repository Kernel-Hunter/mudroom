import Darwin
import Foundation

public enum CloneMethod: String, Codable, Sendable {
    /// APFS copy-on-write clone: instant, no extra disk until files diverge.
    case clonefile
    /// Plain recursive copy, used when the volume can't clone (non-APFS, or a
    /// different volume than the session store).
    case copy
}

public enum Cloner {
    /// Clones `source` (a directory) to `destination`, which must not exist.
    /// Tries clonefile(2) first and falls back to a regular copy.
    @discardableResult
    public static func cloneTree(from source: URL, to destination: URL, allowClonefile: Bool = true) throws -> CloneMethod {
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
    }

    /// Copies a single file or symlink, trying a clone first.
    static func cloneItem(from source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
