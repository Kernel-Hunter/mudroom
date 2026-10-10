#if os(Windows)
import WinSDK
import Foundation

// Windows has no POSIX file API worth the name (the C runtime's takes
// paths in the ANSI code page and its `rename` won't replace a file), so
// MudroomCore's file and process code has Windows versions built on these.

/// Win32 helpers shared by the Windows code paths.
enum Win32 {
    /// A path for the wide-character APIs: backslashes, and the `\\?\`
    /// prefix on long absolute paths so the 260-character limit doesn't
    /// apply.
    static func path(_ p: String) -> String {
        var s = p.replacingOccurrences(of: "/", with: "\\")
        // "/C:/x", as some file URLs spell it.
        if s.hasPrefix("\\"), isDrivePath(s.dropFirst()) { s.removeFirst() }
        if s.utf16.count >= 240, isDrivePath(Substring(s)) { s = #"\\?\"# + s }
        return s
    }

    /// "C:\..." or "C:/...".
    static func isDrivePath(_ s: Substring) -> Bool {
        let c = Array(s.utf16.prefix(3))
        guard c.count == 3 else { return false }
        let letter = c[0] | 0x20
        return letter >= 0x61 && letter <= 0x7A && c[1] == 0x3A && (c[2] == 0x5C || c[2] == 0x2F)
    }

    static func withPath<R>(_ p: String, _ body: (UnsafePointer<WCHAR>) throws -> R) rethrows -> R {
        try path(p).withCString(encodedAs: UTF16.self, body)
    }

    static func withWide<R>(_ s: String, _ body: (UnsafePointer<WCHAR>) throws -> R) rethrows -> R {
        try s.withCString(encodedAs: UTF16.self, body)
    }

    /// The system's text for a Win32 error code.
    static func message(_ code: DWORD) -> String {
        var buffer: UnsafeMutablePointer<WCHAR>?
        let flags = DWORD(FORMAT_MESSAGE_ALLOCATE_BUFFER) | DWORD(FORMAT_MESSAGE_FROM_SYSTEM) | DWORD(FORMAT_MESSAGE_IGNORE_INSERTS)
        let n = withUnsafeMutablePointer(to: &buffer) {
            FormatMessageW(flags, nil, code, 0, UnsafeMutableRawPointer($0).assumingMemoryBound(to: WCHAR.self), 0, nil)
        }
        guard n > 0, let buffer else { return "Windows error \(code)" }
        defer { LocalFree(UnsafeMutableRawPointer(buffer)) }
        return String(decoding: UnsafeBufferPointer(start: buffer, count: Int(n)), as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func error(_ call: String, _ path: String, _ code: DWORD) -> MudroomError {
        .invalid("\(call)(\(path)) failed: \(message(code))")
    }

    /// The errno value closest to a Win32 error, for code that reports
    /// POSIX errors.
    static func errno(for code: DWORD) -> Int32 {
        switch Int(code) {
        case Int(ERROR_FILE_NOT_FOUND), Int(ERROR_PATH_NOT_FOUND), Int(ERROR_INVALID_NAME), Int(ERROR_BAD_PATHNAME): ENOENT
        case Int(ERROR_ACCESS_DENIED), Int(ERROR_SHARING_VIOLATION), Int(ERROR_LOCK_VIOLATION): EACCES
        case Int(ERROR_ALREADY_EXISTS), Int(ERROR_FILE_EXISTS): EEXIST
        case Int(ERROR_DIR_NOT_EMPTY): ENOTEMPTY
        case Int(ERROR_DIRECTORY): ENOTDIR
        case Int(ERROR_PRIVILEGE_NOT_HELD): EPERM
        case Int(ERROR_NOT_SAME_DEVICE): EXDEV
        case Int(ERROR_DISK_FULL), Int(ERROR_HANDLE_DISK_FULL): ENOSPC
        case Int(ERROR_NOT_SUPPORTED): ENOTSUP
        default: EIO
        }
    }

    static let invalidHandle = INVALID_HANDLE_VALUE

    /// A file time (100 ns since 1601) as seconds since 1970.
    static func date(_ ft: FILETIME) -> Date {
        let ticks = Int64(ft.dwHighDateTime) << 32 | Int64(ft.dwLowDateTime)
        return Date(timeIntervalSince1970: Double(ticks - 116_444_736_000_000_000) / 10_000_000)
    }
}

/// What a path is, as far as Mudroom cares, without following a final
/// link: Windows' version of lstat.
struct WinStat {
    enum Kind { case regular, directory, symlink, special }
    var kind: Kind
    var size: Int64
    /// Last write time, 100 ns ticks since 1601.
    var mtime: Int64
    var attributes: DWORD
    var reparseTag: DWORD
}

enum WinFS {
    // Reparse tags (winnt.h) Mudroom tells apart.
    static let tagSymlink: DWORD = 0xA000_000C
    static let tagLXSymlink: DWORD = 0xA000_001D
    static let tagMountPoint: DWORD = 0xA000_0003
    static let tagAFUnix: DWORD = 0x8000_0023
    /// Set on tags whose reparse point stands for another file (links).
    static let nameSurrogate: DWORD = 0x2000_0000

    static let fsctlGetReparsePoint: DWORD = 0x0009_00A8
    static let fsctlDuplicateExtents: DWORD = 0x0009_8344
    static let invalidAttributes = DWORD.max

    /// Windows has no permission bits: every file reads as 0644 and every
    /// folder as 0755, so the diff never shows a mode change.
    static let fileMode: UInt16 = 0o644
    static let directoryMode: UInt16 = 0o755

    static func kind(attributes: DWORD, tag: DWORD) -> WinStat.Kind {
        if attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
            if tag == tagSymlink || tag == tagLXSymlink { return .symlink }
            // Junctions and other links, and Unix sockets.
            if tag & nameSurrogate != 0 || tag == tagAFUnix { return .special }
            // Anything else (OneDrive placeholders, deduplicated files) is
            // an ordinary file or folder with extra data attached.
        }
        if attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 { return .directory }
        if attributes & DWORD(FILE_ATTRIBUTE_DEVICE) != 0 { return .special }
        return .regular
    }

    /// lstat: nil and the Win32 error if the path can't be read.
    static func lstat(_ path: String) -> Result<WinStat, DWORD> {
        var data = WIN32_FILE_ATTRIBUTE_DATA()
        let ok = Win32.withPath(path) { GetFileAttributesExW($0, GetFileExInfoStandard, &data) }
        guard ok else { return .failure(GetLastError()) }
        var tag: DWORD = 0
        if data.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
            var find = WIN32_FIND_DATAW()
            let h = Win32.withPath(path) { FindFirstFileW($0, &find) }
            if let h, h != INVALID_HANDLE_VALUE {
                tag = find.dwReserved0
                FindClose(h)
            }
        }
        return .success(WinStat(
            kind: kind(attributes: data.dwFileAttributes, tag: tag),
            size: Int64(data.nFileSizeHigh) << 32 | Int64(data.nFileSizeLow),
            mtime: Int64(data.ftLastWriteTime.dwHighDateTime) << 32 | Int64(data.ftLastWriteTime.dwLowDateTime),
            attributes: data.dwFileAttributes, reparseTag: tag))
    }

    /// Opens a path without following a final link. `directory` is needed
    /// to open folders.
    static func open(_ path: String, access: DWORD, directory: Bool = false) -> HANDLE? {
        var flags = DWORD(FILE_FLAG_OPEN_REPARSE_POINT)
        if directory { flags |= DWORD(FILE_FLAG_BACKUP_SEMANTICS) }
        let share = DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE)
        let h = Win32.withPath(path) { CreateFileW($0, access, share, nil, DWORD(OPEN_EXISTING), flags, nil) }
        guard let h, h != INVALID_HANDLE_VALUE else { return nil }
        return h
    }

    /// Kind and reparse tag of an open handle.
    static func info(_ h: HANDLE) -> (attributes: DWORD, tag: DWORD)? {
        var info = FILE_ATTRIBUTE_TAG_INFO()
        guard GetFileInformationByHandleEx(h, FileAttributeTagInfo, &info, DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size)) else {
            return nil
        }
        return (info.FileAttributes, info.ReparseTag)
    }

    static func size(_ h: HANDLE) -> Int64? {
        var size = LARGE_INTEGER()
        guard GetFileSizeEx(h, &size) else { return nil }
        return size.QuadPart
    }

    /// The path Windows resolved an open handle to ("\\?\C:\..."), for
    /// checking that no folder on the way was a link.
    static func finalPath(_ h: HANDLE) -> String? {
        var buf = [WCHAR](repeating: 0, count: 1024)
        var n = GetFinalPathNameByHandleW(h, &buf, DWORD(buf.count), DWORD(FILE_NAME_NORMALIZED) | DWORD(VOLUME_NAME_DOS))
        if n >= DWORD(buf.count) {
            buf = [WCHAR](repeating: 0, count: Int(n) + 1)
            n = GetFinalPathNameByHandleW(h, &buf, DWORD(buf.count), DWORD(FILE_NAME_NORMALIZED) | DWORD(VOLUME_NAME_DOS))
        }
        guard n > 0, n < DWORD(buf.count) else { return nil }
        return String(decoding: buf[0..<Int(n)], as: UTF16.self)
    }

    /// The final path of a folder (see `finalPath`).
    static func finalPath(ofDirectory path: String) -> String? {
        guard let h = open(path, access: 0, directory: true) else { return nil }
        defer { CloseHandle(h) }
        return finalPath(h)
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        a.count == b.count && a.lowercased() == b.lowercased()
    }

    /// Opens `relative` ("a/b/c") inside `root` (a final path, see
    /// `finalPath`) without following links at any level: the last part is
    /// opened as itself, and Windows' resolved path must be exactly
    /// root + relative, so a folder on the way swapped for a junction or a
    /// symlink is caught.
    static func openBeneath(root: String, _ relative: String, directory: Bool) -> Result<HANDLE, SafeFS.ReadError> {
        let expected = relative.isEmpty ? root : root + "\\" + relative.replacingOccurrences(of: "/", with: "\\")
        guard let h = open(expected, access: directory ? DWORD(FILE_LIST_DIRECTORY) | DWORD(SYNCHRONIZE) : DWORD(GENERIC_READ),
                           directory: directory) else {
            let e = GetLastError()
            switch Int(e) {
            case Int(ERROR_ACCESS_DENIED), Int(ERROR_SHARING_VIOLATION): return .failure(.denied)
            case Int(ERROR_FILE_NOT_FOUND), Int(ERROR_PATH_NOT_FOUND), Int(ERROR_DIRECTORY), Int(ERROR_CANT_ACCESS_FILE): return .failure(.changed)
            default: return .failure(.io(Int32(bitPattern: e)))
            }
        }
        guard let (attrs, tag) = info(h) else {
            CloseHandle(h)
            return .failure(.io(Int32(bitPattern: GetLastError())))
        }
        let k = kind(attributes: attrs, tag: tag)
        guard k == (directory ? .directory : .regular) else {
            CloseHandle(h)
            return .failure(k == .symlink ? .changed : .notRegular)
        }
        guard let final = finalPath(h), samePath(final, expected) else {
            CloseHandle(h)
            return .failure(.changed)
        }
        if !directory && attrs & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
            // A placeholder or deduplicated file: read its data, not the
            // reparse point, through a second handle on the same path.
            CloseHandle(h)
            let share = DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE)
            let h2 = Win32.withPath(expected) {
                CreateFileW($0, DWORD(GENERIC_READ), share, nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_SEQUENTIAL_SCAN), nil)
            }
            guard let h2, h2 != INVALID_HANDLE_VALUE else { return .failure(.changed) }
            return .success(h2)
        }
        return .success(h)
    }

    /// Reads up to `limit` bytes, handing each chunk to `body`.
    static func readChunks(_ h: HANDLE, limit: Int = .max, chunk: Int = 1 << 20,
                           _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buf.deallocate() }
        var total = 0
        while total < limit {
            var got: DWORD = 0
            let want = DWORD(min(chunk, limit - total))
            guard ReadFile(h, buf.baseAddress, want, &got, nil) else {
                throw Win32.error("ReadFile", "file", GetLastError())
            }
            if got == 0 { break }
            total += Int(got)
            try body(UnsafeRawBufferPointer(rebasing: buf[0..<Int(got)]))
        }
    }

    static func writeAll(_ h: HANDLE, _ data: UnsafeRawBufferPointer) -> Bool {
        var off = 0
        while off < data.count {
            var put: DWORD = 0
            let n = DWORD(min(data.count - off, 1 << 30))
            guard WriteFile(h, data.baseAddress! + off, n, &put, nil), put > 0 else { return false }
            off += Int(put)
        }
        return true
    }

    /// One directory entry, as `list` returns it.
    struct Entry {
        var name: String
        var attributes: DWORD
        var tag: DWORD
        var size: Int64
        var mtime: Int64
    }

    /// Names in an open folder (without . and ..), read through the handle
    /// so a folder swapped for a link after it was opened can't redirect
    /// the listing. Nil if it can't be listed.
    static func list(_ dir: HANDLE) -> [Entry]? {
        var out: [Entry] = []
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 8)
        defer { buf.deallocate() }
        var first = true
        while true {
            let cls = first ? FileFullDirectoryRestartInfo : FileFullDirectoryInfo
            first = false
            guard GetFileInformationByHandleEx(dir, cls, buf.baseAddress, DWORD(buf.count)) else {
                return GetLastError() == DWORD(ERROR_NO_MORE_FILES) ? out : nil
            }
            // FILE_FULL_DIR_INFO, read by offset: NextEntryOffset 0,
            // LastWriteTime 24, EndOfFile 40, FileAttributes 56,
            // FileNameLength 60, EaSize (the reparse tag for reparse
            // points) 64, FileName 68.
            var off = 0
            while true {
                let p = UnsafeRawPointer(buf.baseAddress! + off)
                let next = Int(p.loadUnaligned(as: UInt32.self))
                let attrs = p.loadUnaligned(fromByteOffset: 56, as: UInt32.self)
                let nameBytes = Int(p.loadUnaligned(fromByteOffset: 60, as: UInt32.self))
                let units = (0..<(nameBytes / 2)).map { p.loadUnaligned(fromByteOffset: 68 + 2 * $0, as: UInt16.self) }
                let name = String(decoding: units, as: UTF16.self)
                if name != "." && name != ".." {
                    out.append(Entry(name: name, attributes: DWORD(attrs),
                                     tag: DWORD(p.loadUnaligned(fromByteOffset: 64, as: UInt32.self)),
                                     size: p.loadUnaligned(fromByteOffset: 40, as: Int64.self),
                                     mtime: p.loadUnaligned(fromByteOffset: 24, as: Int64.self)))
                }
                if next == 0 { break }
                off += next
            }
        }
    }

    /// The target of a symlink (an NTFS symlink, or a Linux one written
    /// through WSL or Docker Desktop's file sharing).
    static func readLink(_ path: String) throws -> String {
        guard let h = open(path, access: 0, directory: true) else {
            throw Win32.error("CreateFileW", path, GetLastError())
        }
        defer { CloseHandle(h) }
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        var got: DWORD = 0
        guard DeviceIoControl(h, fsctlGetReparsePoint, nil, 0, &buf, DWORD(buf.count), &got, nil), got >= 8 else {
            throw Win32.error("readlink", path, GetLastError())
        }
        return try buf.withUnsafeBytes { raw -> String in
            let tag = raw.loadUnaligned(as: UInt32.self)
            let dataLength = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt16.self))
            func u16(_ at: Int) -> Int { Int(raw.loadUnaligned(fromByteOffset: at, as: UInt16.self)) }
            func text(_ start: Int, _ bytes: Int) -> String {
                let units = (0..<(bytes / 2)).map { raw.loadUnaligned(fromByteOffset: start + 2 * $0, as: UInt16.self) }
                return String(decoding: units, as: UTF16.self)
            }
            switch DWORD(tag) {
            case tagSymlink:
                // SubstituteName and PrintName offsets/lengths at 8..15,
                // flags at 16, names from 20.
                let base = 20
                let print = text(base + u16(12), u16(14))
                if !print.isEmpty { return print }
                var sub = text(base + u16(8), u16(10))
                if sub.hasPrefix(#"\??\"#) { sub.removeFirst(4) }
                return sub
            case tagLXSymlink:
                // A version number, then the target in UTF-8.
                let start = 12
                let end = min(8 + dataLength, Int(got))
                guard end >= start else { throw MudroomError.invalid("\(path): unreadable link") }
                return String(decoding: raw[start..<end], as: UTF8.self)
            default:
                throw MudroomError.invalid("\(path) is not a symlink")
            }
        }
    }

    /// Creates a symlink, unprivileged where Developer Mode allows it.
    /// Linux-style targets get backslashes.
    static func symlink(_ target: String, at link: String) -> DWORD? {
        let t = target.replacingOccurrences(of: "/", with: "\\")
        var flags = DWORD(0x2) // SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
        // A link to a folder must say so when it is created.
        let parent = (link as NSString).deletingLastPathComponent
        let resolved = t.hasPrefix("\\") || (t.count > 1 && Array(t)[1] == ":") ? t : parent + "\\" + t
        if case .success(let st) = lstat(resolved), st.kind == .directory { flags |= DWORD(0x1) }
        let ok = Win32.withPath(link) { l in Win32.withWide(t) { CreateSymbolicLinkW(l, $0, flags) } }
        return ok != 0 ? nil : GetLastError()
    }

    /// Removes a file or a link, clearing the read-only flag that would
    /// otherwise stop it. Nil on success, else the Win32 error.
    static func removeFile(_ path: String) -> DWORD? {
        if Win32.withPath(path, { DeleteFileW($0) }) { return nil }
        var e = GetLastError()
        if e == DWORD(ERROR_ACCESS_DENIED), case .success(let st) = lstat(path) {
            if st.attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 && st.kind != .directory {
                // A link to a folder is removed like a folder.
                if Win32.withPath(path, { RemoveDirectoryW($0) }) { return nil }
                e = GetLastError()
            } else if st.attributes & DWORD(FILE_ATTRIBUTE_READONLY) != 0 {
                _ = Win32.withPath(path) { SetFileAttributesW($0, st.attributes & ~DWORD(FILE_ATTRIBUTE_READONLY)) }
                if Win32.withPath(path, { DeleteFileW($0) }) { return nil }
                e = GetLastError()
            }
        }
        return e
    }

    /// rename(2): replaces a file at `to`, on the same volume.
    static func move(_ from: String, _ to: String) -> DWORD? {
        let ok = Win32.withPath(from) { f in
            Win32.withPath(to) { MoveFileExW(f, $0, DWORD(MOVEFILE_REPLACE_EXISTING)) }
        }
        return ok ? nil : GetLastError()
    }

    static func makeDirectory(_ path: String) -> DWORD? {
        Win32.withPath(path) { CreateDirectoryW($0, nil) } ? nil : GetLastError()
    }

    static func removeDirectory(_ path: String) -> DWORD? {
        Win32.withPath(path) { RemoveDirectoryW($0) } ? nil : GetLastError()
    }

    /// The root of the volume `path` is on ("C:\", or a mount point).
    static func volumeRoot(_ path: String) -> String? {
        var buf = [WCHAR](repeating: 0, count: 1024)
        guard Win32.withPath(path, { GetVolumePathNameW($0, &buf, DWORD(buf.count)) }) else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }, as: UTF16.self)
    }

    /// True on volumes that can share blocks between files (ReFS, which
    /// Dev Drives use).
    static func supportsBlockClone(_ path: String) -> Bool {
        guard let root = volumeRoot(path) else { return false }
        var flags: DWORD = 0
        let ok = Win32.withWide(root) { GetVolumeInformationW($0, nil, 0, nil, nil, &flags, nil, 0) }
        return ok && flags & 0x0800_0000 != 0 // FILE_SUPPORTS_BLOCK_REFCOUNTING
    }

    /// DUPLICATE_EXTENTS_DATA.
    private struct DuplicateExtents {
        var file: HANDLE?
        var sourceOffset: Int64
        var targetOffset: Int64
        var byteCount: Int64
    }

    /// Copies a regular file by sharing its blocks (ReFS block cloning,
    /// FSCTL_DUPLICATE_EXTENTS_TO_FILE): instant, and no extra disk until
    /// one copy changes. `to` must not exist. False, with nothing left at
    /// `to`, if the volume or the file doesn't allow it.
    static func blockClone(_ from: String, _ to: String) -> Bool {
        guard let root = volumeRoot(from) else { return false }
        var sectorsPerCluster: DWORD = 0, bytesPerSector: DWORD = 0, free: DWORD = 0, total: DWORD = 0
        guard Win32.withWide(root, { GetDiskFreeSpaceW($0, &sectorsPerCluster, &bytesPerSector, &free, &total) }) else { return false }
        let cluster = Int64(sectorsPerCluster) * Int64(bytesPerSector)
        guard cluster > 0, let src = open(from, access: DWORD(GENERIC_READ)) else { return false }
        defer { CloseHandle(src) }
        guard let (attrs, tag) = info(src), kind(attributes: attrs, tag: tag) == .regular,
              attrs & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0, let size = size(src) else { return false }
        let dst = Win32.withPath(to) {
            CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let dst, dst != INVALID_HANDLE_VALUE else { return false }
        var ok = true
        var got: DWORD = 0
        if attrs & DWORD(FILE_ATTRIBUTE_SPARSE_FILE) != 0 {
            // Both files must be sparse, or neither.
            ok = DeviceIoControl(dst, 0x0009_00C4 /* FSCTL_SET_SPARSE */, nil, 0, nil, 0, &got, nil)
        }
        if ok {
            var eof = FILE_END_OF_FILE_INFO()
            eof.EndOfFile.QuadPart = size
            ok = SetFileInformationByHandle(dst, FileEndOfFileInfo, &eof, DWORD(MemoryLayout<FILE_END_OF_FILE_INFO>.size))
        }
        // At most 4 GB per call, in whole clusters; the last one may run
        // past the end of the file.
        let step = (Int64(1) << 31) / cluster * cluster
        var offset: Int64 = 0
        while ok && offset < size {
            let count = min(step, (size - offset + cluster - 1) / cluster * cluster)
            var request = DuplicateExtents(file: src, sourceOffset: offset, targetOffset: offset, byteCount: count)
            ok = DeviceIoControl(dst, fsctlDuplicateExtents, &request, DWORD(MemoryLayout<DuplicateExtents>.size), nil, 0, &got, nil)
            offset += count
        }
        if ok {
            // Keep the modification time; snapshots compare it.
            var created = FILETIME(), accessed = FILETIME(), written = FILETIME()
            if GetFileTime(src, &created, &accessed, &written) { _ = SetFileTime(dst, &created, &accessed, &written) }
        }
        CloseHandle(dst)
        if !ok { _ = removeFile(to) }
        return ok
    }

    /// File id and volume serial: two paths that give the same pair are
    /// the same file (stat's st_dev and st_ino).
    static func identity(_ path: String) -> (UInt32, UInt64)? {
        guard let h = open(path, access: 0, directory: true) else { return nil }
        defer { CloseHandle(h) }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(h, &info) else { return nil }
        return (info.dwVolumeSerialNumber, UInt64(info.nFileIndexHigh) << 32 | UInt64(info.nFileIndexLow))
    }
}

// POSIX names used across MudroomCore that the Windows C runtime doesn't
// have, so shared code reads the same on every platform.
let SIGKILL: Int32 = 9
let SIGHUP: Int32 = 1
let SIGQUIT: Int32 = 3
typealias mode_t = UInt16
typealias pid_t = Int32

/// kill(2) as far as Windows has one: signal 0 asks whether the process is
/// still running; any other signal ends it at once (TerminateProcess),
/// with the signal number as its exit status.
@discardableResult
func kill(_ pid: pid_t, _ sig: Int32) -> Int32 {
    let access = sig == 0 ? DWORD(PROCESS_QUERY_LIMITED_INFORMATION) : DWORD(PROCESS_TERMINATE) | DWORD(PROCESS_QUERY_LIMITED_INFORMATION)
    guard let h = OpenProcess(access, false, DWORD(bitPattern: pid)) else { return failed(GetLastError()) }
    defer { CloseHandle(h) }
    if sig == 0 {
        var code: DWORD = 0
        guard GetExitCodeProcess(h, &code) else { return failed(GetLastError()) }
        return code == 259 /* STILL_ACTIVE */ ? 0 : failed(DWORD(ERROR_INVALID_PARAMETER))
    }
    return TerminateProcess(h, UINT(sig)) ? 0 : failed(GetLastError())
}

@discardableResult
func usleep(_ microseconds: UInt32) -> Int32 {
    Sleep(DWORD(max(1, microseconds / 1000)))
    return 0
}

/// Sets errno from the last Win32 error and returns -1, the way the POSIX
/// call it stands in for fails.
private func failed(_ code: DWORD) -> Int32 {
    errno = Win32.errno(for: code)
    return -1
}

// String-path stand-ins for the POSIX calls. They take precedence over
// the C runtime's narrow-character ones, which read paths in the ANSI code
// page.
func rename(_ from: String, _ to: String) -> Int32 { WinFS.move(from, to).map(failed) ?? 0 }
func unlink(_ path: String) -> Int32 { WinFS.removeFile(path).map(failed) ?? 0 }
func rmdir(_ path: String) -> Int32 { WinFS.removeDirectory(path).map(failed) ?? 0 }
func mkdir(_ path: String, _ mode: mode_t) -> Int32 { WinFS.makeDirectory(path).map(failed) ?? 0 }
func symlink(_ target: String, _ link: String) -> Int32 { WinFS.symlink(target, at: link).map(failed) ?? 0 }
/// No permission bits on Windows; folders and files are private to the
/// user by the ACLs they inherit from the user's profile.
@discardableResult
func chmod(_ path: String, _ mode: mode_t) -> Int32 { 0 }
#endif
