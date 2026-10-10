#if os(Windows)
import WinSDK
import Foundation

// The Windows side of Cloner.swift. NTFS can't clone, so sessions there get
// plain copies; on ReFS (Dev Drives) files are block-cloned one by one.
// Windows 11 24H2 and later also block-clone inside CopyFile on their own.

extension Cloner {
    public static func clone(from source: URL, to destination: URL, allowClonefile: Bool = true) throws -> CloneResult {
        let blockClone = allowClonefile && WinFS.supportsBlockClone(source.path)
            && WinFS.volumeRoot(source.path) == WinFS.volumeRoot(destination.deletingLastPathComponent().path)
        var allCloned = blockClone
        var skipped: [SkippedEntry] = []
        do {
            try copyTree(Win32.path(source.path), Win32.path(destination.path), relative: "",
                         blockClone: blockClone, allCloned: &allCloned, skipped: &skipped)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return CloneResult(method: blockClone && allCloned ? .blockClone : .copy, skipped: skipped)
    }

    /// Copies a single file or symlink, trying a block clone first.
    static func cloneItem(from source: URL, to destination: URL) throws {
        if case .success(let st) = WinFS.lstat(source.path), st.kind == .symlink {
            let target = try WinFS.readLink(source.path)
            if let e = WinFS.symlink(target, at: destination.path) {
                throw Win32.error("CreateSymbolicLinkW", destination.path, e)
            }
            return
        }
        var cloned = true
        if let e = copyFile(source.path, destination.path, blockClone: WinFS.supportsBlockClone(source.path), allCloned: &cloned) {
            throw Win32.error("CopyFileW", destination.path, e)
        }
    }

    /// Recursive copy. Folders are listed through a handle opened without
    /// following links; links are recreated; regular files are copied
    /// (CopyFile keeps their modification time, which snapshots compare);
    /// anything else, and anything that can't be read, is recorded and
    /// left out.
    static func copyTree(_ src: String, _ dst: String, relative: String, blockClone: Bool, allCloned: inout Bool,
                         skipped: inout [SkippedEntry]) throws {
        if let e = WinFS.makeDirectory(dst) { throw Win32.error("CreateDirectoryW", dst, e) }
        let handle = WinFS.open(src, access: DWORD(FILE_LIST_DIRECTORY) | DWORD(SYNCHRONIZE), directory: true)
        guard let handle, let names = WinFS.list(handle) else {
            if let handle { CloseHandle(handle) }
            skipped.append(SkippedEntry(path: relative.isEmpty ? "." : relative + "/", reason: "folder can't be read"))
            return
        }
        CloseHandle(handle)
        for e in names.sorted(by: { $0.name < $1.name }) {
            let rel = relative.isEmpty ? e.name : relative + "/" + e.name
            let s = src + "\\" + e.name
            let d = dst + "\\" + e.name
            switch WinFS.kind(attributes: e.attributes, tag: e.tag) {
            case .directory:
                try copyTree(s, d, relative: rel, blockClone: blockClone, allCloned: &allCloned, skipped: &skipped)
            case .symlink:
                guard let target = try? WinFS.readLink(s) else {
                    skipped.append(SkippedEntry(path: rel, reason: "symlink can't be read"))
                    continue
                }
                if WinFS.symlink(target, at: d) != nil {
                    skipped.append(SkippedEntry(path: rel, reason: "symlink can't be created (needs Developer Mode or an administrator)"))
                }
            case .regular:
                if let err = copyFile(s, d, blockClone: blockClone, allCloned: &allCloned) {
                    let reason = err == DWORD(ERROR_ACCESS_DENIED) || err == DWORD(ERROR_SHARING_VIOLATION)
                        ? "permission denied" : Win32.message(err)
                    skipped.append(SkippedEntry(path: rel, reason: reason))
                    _ = WinFS.removeFile(d)
                }
            case .special:
                let reason = e.tag == WinFS.tagAFUnix ? "socket"
                    : e.tag == WinFS.tagMountPoint ? "junction" : "device or other special file"
                skipped.append(SkippedEntry(path: rel, reason: reason))
            }
        }
    }

    /// One regular file. Nil on success, else the Win32 error.
    static func copyFile(_ s: String, _ d: String, blockClone: Bool, allCloned: inout Bool) -> DWORD? {
        if blockClone {
            if WinFS.blockClone(s, d) { return nil }
            allCloned = false
        }
        let ok = Win32.withPath(s) { sp in Win32.withPath(d) { CopyFileW(sp, $0, true) } }
        return ok ? nil : GetLastError()
    }
}
#endif
