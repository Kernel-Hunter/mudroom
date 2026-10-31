#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// `mudroom update` for a Windows release zip unpacked by hand: download
/// the new zip, check its SHA-256 against what the release publishes,
/// unpack it next to the old files and swap them in, one rename each.
public enum ReleaseZipUpdate {
    /// Leftovers of a swap: Windows can rename a running mudroom.exe (and
    /// the DLLs it loaded) but not delete it, so the old files stay until
    /// the next update removes them.
    public static let oldSuffix = ".mudroom-old"
    /// Far more than a release zip (about 30 MB).
    static let maxZipBytes = 300 << 20

    public static func folderName(version: ReleaseVersion, arch: String) -> String {
        "mudroom-\(version)-windows-\(arch)"
    }

    public static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func downloadURL(version: ReleaseVersion, file: String) -> URL {
        URL(string: "https://github.com/\(UpdateCheck.repository)/releases/download/v\(version)/\(file)")!
    }

    /// The hash in a `.sha256` file ("<hex>  <name>"), if it names `file`.
    public static func parseChecksum(_ text: String, file: String) -> String? {
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard let hash = fields.first?.lowercased(), hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
        if fields.count > 1 {
            var name = fields[1]
            if name.hasPrefix("*") { name = name.dropFirst() }
            guard name == file else { return nil }
        }
        return hash
    }

    /// The SHA-256 GitHub computed for a release asset (the `digest` field
    /// of `releases/tags/<tag>`), if it lists one.
    public static func parseAssetDigest(_ data: Data, file: String) -> String? {
        struct Release: Decodable {
            struct Asset: Decodable {
                var name: String
                var digest: String?
            }
            var assets: [Asset]
        }
        guard let r = try? JSONDecoder().decode(Release.self, from: data),
              let digest = r.assets.first(where: { $0.name == file })?.digest, digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    /// Accepts the download only if at least one published hash exists and
    /// every published hash matches it.
    public static func checksumProblem(actual: String, published: [String]) -> String? {
        if published.isEmpty { return "the release publishes no SHA-256 for this zip, so it can't be checked; not installing it" }
        if let bad = published.first(where: { $0 != actual }) {
            return "checksum mismatch (the release says \(bad), the download is \(actual)); not installing it"
        }
        return nil
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Moves each file of `staged` into `directory`, setting the file it
    /// replaces aside as `<name>.mudroom-old`. If any step fails, every file
    /// already moved goes back and the error is thrown. Returns the names
    /// replaced or added.
    @discardableResult
    public static func swapIn(_ staged: URL, to directory: URL) throws -> [String] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: staged.path).sorted()
        // Folders in a release zip would be a different layout than the one
        // this knows how to replace.
        // Plain files only: a folder, link or junction (attributes are read
        // without following links) would be a layout this doesn't know.
        for name in names {
            let type = try fm.attributesOfItem(atPath: staged.appendingPathComponent(name).path)[.type] as? FileAttributeType
            guard type == .typeRegular else {
                throw MudroomError.invalid("unexpected entry \(TextLines.visible(name)) in the release zip (not a plain file)")
            }
        }
        var done: [(name: String, hadOld: Bool)] = []
        /// False if some file couldn't be put back; then its old copy is
        /// still `<name>.mudroom-old` and must not be cleaned up.
        func rollBack() -> Bool {
            var ok = true
            for step in done.reversed() {
                let target = directory.appendingPathComponent(step.name)
                if (try? moveFile(target, staged.appendingPathComponent(step.name))) == nil { ok = false }
                if step.hadOld, (try? moveFile(directory.appendingPathComponent(step.name + oldSuffix), target)) == nil { ok = false }
            }
            return ok
        }
        for name in names {
            let target = directory.appendingPathComponent(name)
            let old = directory.appendingPathComponent(name + oldSuffix)
            let hadOld = fm.fileExists(atPath: target.path)
            do {
                if hadOld {
                    if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
                    try moveFile(target, old)
                }
                do {
                    try moveFile(staged.appendingPathComponent(name), target)
                } catch {
                    if hadOld, (try? moveFile(old, target)) == nil { throw RollbackFailed(directory: directory) }
                    throw error
                }
            } catch let e as RollbackFailed {
                _ = rollBack()
                throw e
            } catch {
                guard rollBack() else { throw RollbackFailed(directory: directory) }
                throw MudroomError.invalid("couldn't replace \(name): \(MudroomError.message(error)). Nothing was changed.")
            }
            done.append((name, hadOld))
        }
        return names
    }

    /// A swap that failed and couldn't be fully undone. The old files are
    /// still there as `<name>.mudroom-old`; nothing deletes them.
    public struct RollbackFailed: Error, CustomStringConvertible {
        public let directory: URL
        public var description: String {
            "the update failed and not every file could be put back. The old files are in \(directory.path) "
                + "with \(ReleaseZipUpdate.oldSuffix) added to their names: rename them back, or install the zip again by hand"
        }
    }

    /// Deletes the `.mudroom-old` files a previous update left. Ones still
    /// in use (the running mudroom.exe on Windows) stay for next time.
    public static func removeLeftovers(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(oldSuffix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func moveFile(_ from: URL, _ to: URL) throws {
        #if os(Windows)
        if let e = WinFS.move(from.path, to.path) { throw Win32.error("MoveFileExW", from.path, e) }
        #else
        if rename(from.path, to.path) != 0 {
            throw MudroomError.posix("rename", from.path, errno)
        }
        #endif
    }

    /// Downloads, checks and installs `version` over the release zip in
    /// `directory`. `say` gets progress lines.
    public static func install(_ version: ReleaseVersion, into directory: URL, currentVersion: String,
                               arch: String = currentArch, say: (String) -> Void) throws {
        let folder = folderName(version: version, arch: arch)
        let zipName = folder + ".zip"
        let agent = "mudroom/\(currentVersion)"
        removeLeftovers(in: directory)

        // Unpacked inside the install folder, so every swap is a rename on
        // one volume.
        let staging = directory.appendingPathComponent(".mudroom-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var keepStaging = false
        defer { if !keepStaging { try? FileManager.default.removeItem(at: staging) } }

        say("Downloading \(zipName)")
        let zip: URL
        switch HTTPFetch.file(downloadURL(version: version, file: zipName), userAgent: agent, timeout: 600, limit: maxZipBytes) {
        case .success(let f): zip = f
        case .failure(let e): throw MudroomError.invalid("download failed: \(e)")
        }
        defer { try? FileManager.default.removeItem(at: zip) }

        var published: [String] = []
        if case .success(let file) = HTTPFetch.file(downloadURL(version: version, file: zipName + ".sha256"),
                                                    userAgent: agent, timeout: 60, limit: 4096) {
            defer { try? FileManager.default.removeItem(at: file) }
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            guard let hash = parseChecksum(text, file: zipName) else {
                throw MudroomError.invalid("\(zipName).sha256 on the release doesn't hold a SHA-256 for \(zipName); not installing it")
            }
            published.append(hash)
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(UpdateCheck.repository)/releases/tags/v\(version)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if case .success(let (200, data)) = HTTPFetch.data(request, timeout: 30, limit: 4 << 20),
           let digest = parseAssetDigest(data, file: zipName) {
            published.append(digest)
        }
        let actual = try sha256(of: zip)
        if let why = checksumProblem(actual: actual, published: published) { throw MudroomError.invalid(why) }
        say("SHA-256 ok (\(actual))")

        try extract(zip, into: staging)
        let unpacked = staging.appendingPathComponent(folder, isDirectory: true)
        let exe = unpacked.appendingPathComponent("mudroom.exe")
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw MudroomError.invalid("the zip doesn't contain \(folder)\\mudroom.exe; not installing it")
        }
        let out = try ProcessRunner.capture(exe.path, ["--version"], timeout: 60)
        let reported = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard out.status == 0, reported == version.description else {
            throw MudroomError.invalid("the new mudroom.exe says it is '\(TextLines.visible(String(reported.prefix(80))))', not \(version); not installing it")
        }

        say("Replacing the files in \(directory.path)")
        do {
            try swapIn(unpacked, to: directory)
        } catch let e as RollbackFailed {
            keepStaging = true
            throw e
        }
        removeLeftovers(in: directory)
    }

    /// Unpacks with Windows' own tar.exe (bsdtar), which refuses entries
    /// with absolute paths or `..`.
    static func extract(_ zip: URL, into dir: URL) throws {
        #if os(Windows)
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        let tar = root + "\\System32\\tar.exe"
        #else
        let tar = "/usr/bin/tar"
        #endif
        let out = try ProcessRunner.capture(tar, ["-xf", zip.path, "-C", dir.path], timeout: 300)
        guard out.status == 0 else {
            throw MudroomError.commandFailed("tar -xf", out.status, TextLines.visible(String(out.stderr.prefix(2000))))
        }
    }
}
