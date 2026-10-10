#if os(Windows)
import Crypto
import WinSDK
import Foundation

// The Windows side of FileNode.swift. Links are never followed: files and
// folders are opened as themselves (FILE_FLAG_OPEN_REPARSE_POINT), folders
// are listed through their handle, and every open is checked against the
// path Windows resolved, so a folder swapped for a junction or a symlink
// partway through is reported instead of read.

extension FileNode {
    /// Reads the node at `url` without following a final link.
    public static func read(at url: URL) throws -> FileNode {
        switch WinFS.lstat(url.path) {
        case .failure(let e):
            switch Int(e) {
            case Int(ERROR_FILE_NOT_FOUND), Int(ERROR_PATH_NOT_FOUND), Int(ERROR_DIRECTORY), Int(ERROR_INVALID_NAME):
                return .absent
            case Int(ERROR_ACCESS_DENIED):
                return .unreadable(reason: "permission denied")
            default:
                throw Win32.error("GetFileAttributesExW", url.path, e)
            }
        case .success(let st):
            switch st.kind {
            case .regular:
                switch SafeFS.hashFile(path: url.path) {
                case .success(let (sha, size)): return .file(mode: WinFS.fileMode, size: size, sha256: sha)
                case .failure(let e): return .unreadable(reason: e.description)
                }
            case .directory:
                return .directory(mode: WinFS.directoryMode)
            case .symlink:
                do { return .symlink(target: try readLink(url)) } catch { return .unreadable(reason: "can't read link") }
            case .special:
                return .special
            }
        }
    }

    static func readLink(_ url: URL) throws -> String {
        try WinFS.readLink(url.path)
    }
}

extension SafeFS {
    /// SHA-256 and size of a regular file, opened without following a
    /// link.
    static func hashFile(path: String) -> Result<(String, Int64), ReadError> {
        let parent = (path as NSString).deletingLastPathComponent
        guard let root = WinFS.finalPath(ofDirectory: parent) else { return .failure(.changed) }
        return hashFile(root: root, (path as NSString).lastPathComponent)
    }

    static func hashFile(root: String, _ relative: String) -> Result<(String, Int64), ReadError> {
        switch WinFS.openBeneath(root: root, relative, directory: false) {
        case .failure(let e): return .failure(e)
        case .success(let h):
            defer { CloseHandle(h) }
            var hasher = SHA256()
            var size: Int64 = 0
            do {
                try WinFS.readChunks(h) { chunk in
                    hasher.update(bufferPointer: chunk)
                    size += Int64(chunk.count)
                }
            } catch {
                return .failure(.io(Int32(bitPattern: GetLastError())))
            }
            return .success((hex(hasher.finalize()), size))
        }
    }

    static func checkedParts(_ relative: String) throws -> String {
        let parts = relative.split(separator: "/")
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains("."),
              !parts.contains(where: { $0.contains("\\") || $0.contains(":") }) else {
            throw MudroomError.invalid("bad path \(relative)")
        }
        return parts.joined(separator: "/")
    }

    static func openBeneath(_ root: URL, _ relative: String) throws -> HANDLE {
        let rel = try checkedParts(relative)
        guard let base = WinFS.finalPath(ofDirectory: root.path) else {
            throw Win32.error("CreateFileW", root.path, GetLastError())
        }
        switch WinFS.openBeneath(root: base, rel, directory: false) {
        case .success(let h): return h
        case .failure(.changed): throw MudroomError.invalid("\(relative): it, or a folder it is in, was replaced by a link or removed")
        case .failure(.notRegular): throw MudroomError.invalid("\(relative) is not a regular file")
        case .failure(let e): throw MudroomError.invalid("\(relative): \(e)")
        }
    }

    /// Reads a file inside `root`, refusing a link at any level. At most
    /// `limit` bytes.
    public static func readBeneath(_ root: URL, _ relative: String, limit: Int = .max) throws -> Data {
        let h = try openBeneath(root, relative)
        defer { CloseHandle(h) }
        var out = Data()
        try WinFS.readChunks(h, limit: limit, chunk: 256 << 10) { out.append(contentsOf: $0) }
        return out
    }

    /// Copies a file from inside `root` (opened as in `readBeneath`) to
    /// `destination`, which must not exist, and returns the SHA-256 of the
    /// bytes now at `destination`.
    public static func copyBeneath(_ root: URL, _ relative: String, to destination: URL) throws -> String {
        let src = try openBeneath(root, relative)
        defer { CloseHandle(src) }
        let dst = Win32.withPath(destination.path) {
            CreateFileW($0, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let dst, dst != INVALID_HANDLE_VALUE else {
            throw Win32.error("CreateFileW", destination.path, GetLastError())
        }
        defer { CloseHandle(dst) }
        var hasher = SHA256()
        try WinFS.readChunks(src) { chunk in
            hasher.update(bufferPointer: chunk)
            guard WinFS.writeAll(dst, chunk) else { throw Win32.error("WriteFile", destination.path, GetLastError()) }
        }
        return hex(hasher.finalize())
    }
}

extension TreeSnapshot {
    /// Walks `root` without following links. The root itself is not
    /// included. Each folder is opened as itself, checked to be where the
    /// walk expects it, and listed through its handle; files are hashed in
    /// parallel, opened the same way. Anything that can't be read becomes
    /// an `unreadable` node instead of failing the whole scan.
    public static func scan(_ root: URL) throws -> TreeSnapshot {
        guard let base = WinFS.finalPath(ofDirectory: root.path) else {
            throw Win32.error("CreateFileW", root.path, GetLastError())
        }
        var entries: [(String, FileNode)] = []
        var files: [(index: Int, path: String)] = []
        guard case .success(let rootHandle) = WinFS.openBeneath(root: base, "", directory: true) else {
            throw MudroomError.invalid("\(root.path) is not a folder that can be read")
        }
        walk(rootHandle, base: base, relative: "", entries: &entries, files: &files)
        CloseHandle(rootHandle)

        if !files.isEmpty {
            var hashed = [FileNode?](repeating: nil, count: files.count)
            let workers = max(1, min(files.count, ProcessInfo.processInfo.activeProcessorCount * 2))
            hashed.withUnsafeMutableBufferPointer { out in
                let outBase = Unchecked(out.baseAddress!)
                files.withUnsafeBufferPointer { buf in
                    let list = Unchecked(buf)
                    DispatchQueue.concurrentPerform(iterations: workers) { w in
                        var i = w
                        while i < list.value.count {
                            let node: FileNode = switch SafeFS.hashFile(root: base, list.value[i].path) {
                            case .success(let (sha, size)): .file(mode: WinFS.fileMode, size: size, sha256: sha)
                            case .failure(let e): .unreadable(reason: e.description)
                            }
                            (outBase.value + i).pointee = node
                            i += workers
                        }
                    }
                }
            }
            for (k, f) in files.enumerated() { entries[f.index].1 = hashed[k]! }
        }
        return TreeSnapshot(nodes: Dictionary(entries, uniquingKeysWith: { a, _ in a }))
    }

    private static func walk(_ dir: HANDLE, base: String, relative: String, entries: inout [(String, FileNode)],
                             files: inout [(index: Int, path: String)]) {
        guard let list = WinFS.list(dir) else { return }
        for e in list.sorted(by: { $0.name < $1.name }) {
            let rel = relative.isEmpty ? e.name : relative + "/" + e.name
            switch WinFS.kind(attributes: e.attributes, tag: e.tag) {
            case .regular:
                files.append((entries.count, rel))
                entries.append((rel, .absent)) // filled in after hashing
            case .symlink:
                let path = base + "\\" + rel.replacingOccurrences(of: "/", with: "\\")
                entries.append((rel, (try? WinFS.readLink(path)).map { .symlink(target: $0) } ?? .unreadable(reason: "can't read link")))
            case .directory:
                switch WinFS.openBeneath(root: base, rel, directory: true) {
                case .success(let child):
                    entries.append((rel, .directory(mode: WinFS.directoryMode)))
                    walk(child, base: base, relative: rel, entries: &entries, files: &files)
                    CloseHandle(child)
                case .failure(let err):
                    entries.append((rel, .unreadable(reason: err == .denied ? "permission denied" : "changed while being read")))
                }
            case .special:
                entries.append((rel, .special))
            }
        }
    }
}
#endif
