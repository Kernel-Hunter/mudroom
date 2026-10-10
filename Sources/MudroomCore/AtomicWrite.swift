import Foundation

extension Data {
    /// Writes to a temporary file next to `url`, then renames it over `url`,
    /// as `.atomic` does. On Windows the rename goes through `WinFS.move`,
    /// which waits out an antivirus scan or the search indexer holding the
    /// old file open instead of failing the write.
    func writeAtomically(to url: URL) throws {
        #if os(Windows)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try write(to: tmp, options: .withoutOverwriting)
        if let e = WinFS.move(tmp.path, url.path) {
            _ = WinFS.removeFile(tmp.path)
            throw Win32.error("MoveFileExW", url.path, e)
        }
        #else
        try write(to: url, options: .atomic)
        #endif
    }
}
