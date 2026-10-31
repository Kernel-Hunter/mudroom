#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// A release version, `major.minor.patch` with an optional pre-release part
/// (`0.6.0-rc.1`), ordered the way semver orders them. Build metadata
/// (`+...`) is accepted and ignored.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot-separated pre-release identifiers; empty for a normal release.
    public let prerelease: [String]

    /// Parses "1.2.3", "v1.2.3" or "1.2.3-beta.2". Anything else (extra
    /// parts, leading zeros, odd characters, absurd lengths) is nil, so a
    /// version read from the network is safe to print.
    public init?(_ text: String) {
        var s = Substring(text)
        if s.hasPrefix("v") { s = s.dropFirst() }
        guard !s.isEmpty, s.count <= 64,
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "+") }) else { return nil }
        if let plus = s.firstIndex(of: "+") {
            let build = s[s.index(after: plus)...]
            guard !build.isEmpty, !build.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty) else { return nil }
            s = s[..<plus]
        }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            let ids = s[s.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
            for id in ids {
                guard !id.isEmpty else { return nil }
                if id.allSatisfy(\.isNumber), id.count > 1, id.first == "0" { return nil }
                pre.append(String(id))
            }
            s = s[..<dash]
        }
        let core = s.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in core {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy(\.isNumber),
                  part == "0" || part.first != "0", let n = Int(part) else { return nil }
            numbers.append(n)
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
        prerelease = pre
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // A pre-release comes before its release.
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true      // numbers sort before words
            case (nil, _?): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// What GitHub says the latest release is.
public struct LatestRelease: Equatable, Sendable {
    public let version: ReleaseVersion

    public init(version: ReleaseVersion) { self.version = version }

    /// The release page, built from the version rather than taken from the
    /// response, so the only thing printed from the network is a checked
    /// version number.
    public var pageURL: String { UpdateCheck.releasePage(version) }
}

public enum UpdateCheck {
    public static let repository = "Kernel-Hunter/mudroom"
    /// The one request the update check makes: GitHub's latest release,
    /// which leaves out drafts and pre-releases.
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// Responses bigger than this are not a release record.
    static let maxResponseBytes = 1 << 20

    public static func releasePage(_ v: ReleaseVersion) -> String {
        "https://github.com/\(repository)/releases/tag/v\(v)"
    }

    /// Reads a `releases/latest` response. Nil for anything that isn't a
    /// published, final release with a version tag.
    public static func parseLatest(_ data: Data) -> LatestRelease? {
        struct Release: Decodable {
            var tag_name: String
            var draft: Bool?
            var prerelease: Bool?
        }
        guard data.count <= maxResponseBytes,
              let r = try? JSONDecoder().decode(Release.self, from: data),
              r.draft != true, r.prerelease != true,
              let v = ReleaseVersion(r.tag_name), !v.isPrerelease else { return nil }
        return LatestRelease(version: v)
    }

    public enum CheckError: Error, CustomStringConvertible, Equatable {
        case network(String)
        case status(Int)
        case unreadable

        public var description: String {
            switch self {
            case .network(let why): return "couldn't reach GitHub: \(why)"
            case .status(let code): return "GitHub answered with HTTP \(code)"
            case .unreadable: return "GitHub's answer wasn't a release"
            }
        }
    }

    /// Asks GitHub for the latest release. No cookies, no cache, no
    /// credentials; the only thing sent besides the URL is a User-Agent
    /// with Mudroom's version, which GitHub's API requires.
    public static func fetchLatest(from url: URL = latestReleaseURL, currentVersion: String,
                                   timeout: TimeInterval) -> Result<LatestRelease, CheckError> {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("mudroom/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return HTTPFetch.data(request, timeout: timeout, limit: maxResponseBytes).flatMap { status, data in
            guard status == 200 else { return .failure(.status(status)) }
            guard let latest = parseLatest(data) else { return .failure(.unreadable) }
            return .success(latest)
        }
    }
}

/// Plain HTTPS GETs for the update check and `mudroom update`: an
/// ephemeral session (nothing stored, no cookies), HTTPS only, and
/// redirects followed only to GitHub's own HTTPS hosts.
enum HTTPFetch {
    static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return testHost(url)
        }
        // Release downloads redirect to GitHub's asset hosts; nothing else
        // under githubusercontent.com (raw files, gists) is followed.
        return ["github.com", "api.github.com", "release-assets.githubusercontent.com",
                "objects.githubusercontent.com"].contains(host)
    }

    /// Debug builds only: lets tests point the check at a local server.
    /// Release builds never follow anything but GitHub over HTTPS.
    static func testHost(_ url: URL?) -> Bool {
        #if DEBUG
        guard let url, url.scheme == "http", let host = url.host else { return false }
        return host == "127.0.0.1" || host == "localhost"
        #else
        return false
        #endif
    }

    final class Delegate: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
        let limit: Int
        let lock = NSLock()
        var data = Data()
        var downloaded: URL?
        var tooBig = false
        let done = DispatchSemaphore(value: 0)
        var error: Error?
        var status = 0

        init(limit: Int) { self.limit = limit }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(HTTPFetch.allowed(request.url) ? request : nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            lock.withLock { status = (response as? HTTPURLResponse)?.statusCode ?? 0 }
            if response.expectedContentLength > Int64(limit) {
                lock.withLock { tooBig = true }
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            lock.withLock {
                if data.count + chunk.count > limit {
                    tooBig = true
                    dataTask.cancel()
                } else {
                    data.append(chunk)
                }
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > Int64(limit) || totalBytesExpectedToWrite > Int64(limit) {
                lock.withLock { tooBig = true }
                downloadTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file is deleted when this returns; keep it.
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent("mudroom-download-\(UUID().uuidString)")
            let moved = (try? FileManager.default.moveItem(at: location, to: keep)) != nil
            lock.withLock {
                status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
                downloaded = moved ? keep : nil
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.withLock {
                if status == 0 { status = (task.response as? HTTPURLResponse)?.statusCode ?? 0 }
                self.error = error
            }
            done.signal()
        }
    }

    static func session(_ delegate: Delegate, timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// GETs a small document into memory. Blocks up to `timeout` seconds
    /// (plus a moment); fails rather than read more than `limit` bytes.
    static func data(_ request: URLRequest, timeout: TimeInterval, limit: Int) -> Result<(Int, Data), UpdateCheck.CheckError> {
        guard allowed(request.url) else { return .failure(.network("refusing \(request.url?.absoluteString ?? "?")")) }
        let delegate = Delegate(limit: limit)
        let session = session(delegate, timeout: timeout)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request).resume()
        if delegate.done.wait(timeout: .now() + timeout + 1) == .timedOut { return .failure(.network("timed out")) }
        return delegate.lock.withLock {
            if delegate.tooBig { return .failure(.network("the response was too large")) }
            if let e = delegate.error { return .failure(.network(describe(e))) }
            return .success((delegate.status, delegate.data))
        }
    }

    /// Downloads to a temporary file the caller owns. Fails rather than
    /// write more than `limit` bytes, or on any status but 200.
    static func file(_ url: URL, userAgent: String, timeout: TimeInterval, limit: Int) -> Result<URL, UpdateCheck.CheckError> {
        guard allowed(url) else { return .failure(.network("refusing \(url.absoluteString)")) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        let delegate = Delegate(limit: limit)
        let session = session(delegate, timeout: timeout)
        defer { session.invalidateAndCancel() }
        session.downloadTask(with: request).resume()
        if delegate.done.wait(timeout: .now() + timeout + 1) == .timedOut { return .failure(.network("timed out")) }
        return delegate.lock.withLock {
            let file = delegate.downloaded
            func drop() { if let file { try? FileManager.default.removeItem(at: file) } }
            if delegate.tooBig { drop(); return .failure(.network("the download was too large")) }
            if let e = delegate.error { drop(); return .failure(.network(describe(e))) }
            guard delegate.status == 200 else { drop(); return .failure(.status(delegate.status)) }
            guard let file else { return .failure(.network("the download didn't arrive")) }
            return .success(file)
        }
    }

    static func describe(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == NSURLErrorDomain {
            switch e.code {
            case NSURLErrorTimedOut: return "timed out"
            case NSURLErrorNotConnectedToInternet: return "not connected to the internet"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "couldn't look up the host"
            case NSURLErrorCancelled: return "cancelled (a redirect to a host other than GitHub, or too much data)"
            default: break
            }
        }
        return e.localizedDescription
    }
}
