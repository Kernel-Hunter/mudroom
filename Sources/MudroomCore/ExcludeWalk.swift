#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

#if !os(Windows)
/// Removes excluded entries from a fresh whole-folder clone (APFS
/// clonefile, reflink), before session.json exists and so before any
/// sandbox can start on it. Symlinks are never followed.
enum ExcludeWalk {
    struct Entry {
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
    }

    /// Deletes every entry of `root` that `rules` exclude and returns what
    /// was removed. Throws if any folder can't be listed or any excluded
    /// entry can't be removed: the caller then drops the clone.
    static func prune(_ root: URL, rules: ExcludeRules) throws -> [ExcludedEntry] {
        var out: [ExcludedEntry] = []
        try walk(root.path, [], [], rules, &out)
        return out
    }

    private static func walk(_ dir: String, _ parts: [String], _ canonical: [String], _ rules: ExcludeRules,
                             _ out: inout [ExcludedEntry]) throws {
        let entries = try list(dir)
        for e in entries.sorted(by: { $0.name < $1.name }) {
            let path = dir + "/" + e.name
            let rel = parts + [e.name]
            let canon = canonical + [ExcludeRules.canonicalName(e.name)]
            if let pattern = rules.matchEntry(canon[...], isDirectory: e.isDirectory || e.isSymlink) {
                let files = e.isDirectory ? countFiles(path) : 1
                try removeEntry(path)
                out.append(ExcludedEntry(path: rel.joined(separator: "/") + (e.isDirectory ? "/" : ""), files: files, pattern: pattern))
            } else if e.isDirectory {
                try walk(path, rel, canon, rules, &out)
            }
        }
    }

    /// Entries of a folder with their type, from readdir (lstat when the
    /// file system doesn't say). A folder without read or search permission
    /// is opened for the listing and its mode put back after.
    static func list(_ dir: String) throws -> [Entry] {
        var d = opendir(dir)
        var restore: mode_t?
        if d == nil, errno == EACCES {
            var st = stat()
            if lstat(dir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, chmod(dir, (st.st_mode & 0o7777) | 0o700) == 0 {
                restore = st.st_mode & 0o7777
                d = opendir(dir)
            }
        }
        defer { if let restore { chmod(dir, restore) } }
        guard let d else { throw MudroomError.posix("opendir", dir, errno) }
        defer { closedir(d) }
        var out: [Entry] = []
        while true {
            errno = 0
            guard let ent = readdir(d) else {
                if errno != 0 { throw MudroomError.posix("readdir", dir, errno) }
                break
            }
            let name = withUnsafePointer(to: &ent.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            var type = Int32(ent.pointee.d_type)
            if type == Int32(DT_UNKNOWN) {
                var st = stat()
                guard lstat(dir + "/" + name, &st) == 0 else { throw MudroomError.posix("lstat", dir + "/" + name, errno) }
                switch st.st_mode & S_IFMT {
                case S_IFDIR: type = Int32(DT_DIR)
                case S_IFLNK: type = Int32(DT_LNK)
                default: type = Int32(DT_REG)
                }
            }
            out.append(Entry(name: name, isDirectory: type == Int32(DT_DIR), isSymlink: type == Int32(DT_LNK)))
        }
        return out
    }

    /// Non-folder entries under `dir`, for the summary. Best effort.
    static func countFiles(_ dir: String) -> Int {
        guard let entries = try? list(dir) else { return 0 }
        return entries.reduce(0) { $0 + ($1.isDirectory ? countFiles(dir + "/" + $1.name) : 1) }
    }

    /// Deletes a file, symlink or whole folder, making read-only folders
    /// (in the clone, which is ours) writable as needed.
    static func removeEntry(_ path: String) throws {
        if unlinkOrRemoveTree(path) { return }
        // The parent may be read-only: open it up for the removal only.
        let parent = (path as NSString).deletingLastPathComponent
        var st = stat()
        guard lstat(parent, &st) == 0 else { throw MudroomError.posix("lstat", parent, errno) }
        let mode = st.st_mode & 0o7777
        guard chmod(parent, mode | 0o700) == 0 else { throw MudroomError.posix("chmod", parent, errno) }
        defer { chmod(parent, mode) }
        guard unlinkOrRemoveTree(path) else { throw MudroomError.posix("remove", path, errno) }
    }

    private static func unlinkOrRemoveTree(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT }
        guard st.st_mode & S_IFMT == S_IFDIR else { return unlink(path) == 0 }
        chmod(path, 0o700)
        guard let entries = try? list(path) else { return false }
        for e in entries where !unlinkOrRemoveTree(path + "/" + e.name) { return false }
        return rmdir(path) == 0
    }
}
#endif
