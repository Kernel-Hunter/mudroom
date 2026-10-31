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
import Testing
@testable import MudroomCore

@Suite("Release versions")
struct ReleaseVersionTests {
    func v(_ s: String) -> ReleaseVersion { ReleaseVersion(s)! }

    @Test("semver order, pre-releases before their release")
    func order() {
        let sorted = ["0.5.0", "0.5.1", "0.6.0-alpha", "0.6.0-alpha.1", "0.6.0-alpha.beta", "0.6.0-beta",
                      "0.6.0-beta.2", "0.6.0-beta.11", "0.6.0-rc.1", "0.6.0", "0.10.0", "1.0.0"].map(v)
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            #expect(a < b, "\(a) < \(b)")
            #expect(!(b < a))
        }
        #expect(v("v1.2.3") == v("1.2.3"))
        #expect(v("1.2.3+build.5") == v("1.2.3"))
        #expect(v("0.9.9") < v("0.10.0"))
        #expect(v("1.2.3-rc.1").description == "1.2.3-rc.1")
    }

    @Test("anything that isn't a plain version is rejected, so it is safe to print")
    func rejects() {
        for bad in ["", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.3-", "1.2.3-01", "1.2.3-a..b", "1.2.3+",
                    "v", "1.2.3 ", " 1.2.3", "1.2.3\u{1b}[31m", "1.2.3-é", "1.2.x", "-1.2.3",
                    "1.2.3-" + String(repeating: "a", count: 80), "9999999999.0.0"] {
            #expect(ReleaseVersion(bad) == nil, "\(bad.debugDescription)")
        }
    }
}

@Suite("Update check")
struct UpdateCheckTests {
    @Test("reads GitHub's latest release; drafts, pre-releases and odd tags are ignored")
    func parse() {
        let ok = Data(#"{"tag_name":"v0.6.0","draft":false,"prerelease":false,"html_url":"https://evil.example"}"#.utf8)
        #expect(UpdateCheck.parseLatest(ok)?.version == ReleaseVersion("0.6.0"))
        #expect(UpdateCheck.parseLatest(ok)?.pageURL == "https://github.com/Kernel-Hunter/mudroom/releases/tag/v0.6.0")
        #expect(UpdateCheck.parseLatest(Data(#"{"tag_name":"v0.6.0","prerelease":true}"#.utf8)) == nil)
        #expect(UpdateCheck.parseLatest(Data(#"{"tag_name":"v0.6.0","draft":true}"#.utf8)) == nil)
        #expect(UpdateCheck.parseLatest(Data(#"{"tag_name":"v0.6.0-rc.1"}"#.utf8)) == nil)
        #expect(UpdateCheck.parseLatest(Data(#"{"tag_name":"latest\u001b]0;pwned\u0007"}"#.utf8)) == nil)
        #expect(UpdateCheck.parseLatest(Data(#"{"message":"API rate limit exceeded"}"#.utf8)) == nil)
        #expect(UpdateCheck.parseLatest(Data("not json".utf8)) == nil)
    }

    @Test("only GitHub over HTTPS (and loopback in debug test builds) is fetched or followed")
    func hosts() {
        #expect(HTTPFetch.allowed(URL(string: "https://api.github.com/repos/x/y/releases/latest")))
        #expect(HTTPFetch.allowed(URL(string: "https://github.com/x/y/releases/download/v1/a.zip")))
        #expect(HTTPFetch.allowed(URL(string: "https://release-assets.githubusercontent.com/a")))
        #expect(!HTTPFetch.allowed(URL(string: "http://api.github.com/repos")))
        #expect(!HTTPFetch.allowed(URL(string: "https://github.com.evil.example/a")))
        #expect(!HTTPFetch.allowed(URL(string: "https://evilgithubusercontent.com/a")))
        #expect(!HTTPFetch.allowed(URL(string: "https://raw.githubusercontent.com/someone/else/main/x.zip")))
        #expect(!HTTPFetch.allowed(URL(string: "https://gist.githubusercontent.com/a")))
        #expect(!HTTPFetch.allowed(URL(string: "file:///etc/passwd")))
        #expect(!HTTPFetch.allowed(URL(string: "http://10.0.0.1/a")))
    }

    @Test("a check against a local server: answer, redirect elsewhere, too big, error status")
    func fetch() throws {
        let release = #"{"tag_name":"v9.8.7","draft":false,"prerelease":false}"#
        let server = try CannedHTTPServer { path in
            switch path {
            case "/latest": return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(release.utf8.count)\r\nConnection: close\r\n\r\n\(release)"
            case "/moved": return "HTTP/1.1 302 Found\r\nLocation: https://example.com/latest\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            case "/huge": return "HTTP/1.1 200 OK\r\nContent-Length: 5000000\r\nConnection: close\r\n\r\n" + String(repeating: "x", count: 1000)
            default: return "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
        }
        defer { server.cancel() }
        func get(_ path: String) -> Result<LatestRelease, UpdateCheck.CheckError> {
            UpdateCheck.fetchLatest(from: URL(string: "http://127.0.0.1:\(server.port)\(path)")!, currentVersion: "0.5.0", timeout: 5)
        }
        #expect(try get("/latest").get().version == ReleaseVersion("9.8.7"))
        #expect(server.requests.first?.contains("User-Agent: mudroom/0.5.0") == true)
        #expect(server.requests.first?.lowercased().contains("cookie") == false)
        guard case .failure = get("/moved") else { Issue.record("followed a redirect off GitHub"); return }
        guard case .failure = get("/huge") else { Issue.record("read an oversized answer"); return }
        #expect(get("/limited") == .failure(.status(403)))
        // Nothing listening: fails, quickly, without throwing.
        let closed = UpdateCheck.fetchLatest(from: URL(string: "http://127.0.0.1:1/latest")!, currentVersion: "0.5.0", timeout: 2)
        guard case .failure = closed else { Issue.record("a closed port answered"); return }
    }
}

@Suite("Update notice")
struct UpdateNoticeTests {
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    let current = ReleaseVersion("0.5.0")!

    @Test("checks once a day, retries an hour after a failure, distrusts future dates")
    func schedule() {
        #expect(UpdateNoticeState().needsCheck(now: t0))
        let checked = UpdateNoticeState(checked: t0, attempted: t0)
        #expect(!checked.needsCheck(now: t0.addingTimeInterval(23 * 3600)))
        #expect(checked.needsCheck(now: t0.addingTimeInterval(24 * 3600)))
        let failed = UpdateNoticeState(checked: t0.addingTimeInterval(-3 * 86400), attempted: t0)
        #expect(!failed.needsCheck(now: t0.addingTimeInterval(59 * 60)))
        #expect(failed.needsCheck(now: t0.addingTimeInterval(61 * 60)))
        // A clock that ran ahead and came back doesn't stop checks forever.
        #expect(UpdateNoticeState(checked: t0.addingTimeInterval(86400 * 30)).needsCheck(now: t0))
    }

    @Test("announces a newer release, once a day per version")
    func announce() {
        var s = UpdateNoticeState(latest: "0.6.0")
        #expect(s.versionToAnnounce(current: current, now: t0) == ReleaseVersion("0.6.0"))
        s.shown = t0
        s.shownVersion = "0.6.0"
        #expect(s.versionToAnnounce(current: current, now: t0.addingTimeInterval(3600)) == nil)
        #expect(s.versionToAnnounce(current: current, now: t0.addingTimeInterval(86400)) != nil)
        s.latest = "0.6.1"
        #expect(s.versionToAnnounce(current: current, now: t0.addingTimeInterval(3600)) == ReleaseVersion("0.6.1"))
        for same in ["0.5.0", "0.4.9", "0.6.0-rc.1", "garbage", "v0.6.0\u{1b}[2J"] {
            #expect(UpdateNoticeState(latest: same).versionToAnnounce(current: current, now: t0) == nil, "\(same)")
        }
        #expect(UpdateNotice.message(ReleaseVersion("0.6.0")!, current: current)
            == "Mudroom 0.6.0 is available (you have 0.5.0). Run `mudroom update` to get it.")
    }

    @Test("opt-outs: environment, settings, the app's setting, CI")
    func optOut() {
        let on = MudroomSettings()
        #expect(UpdateNotice.disabledReason(environment: [:], settings: on) == nil)
        #expect(UpdateNotice.disabledReason(environment: ["MUDROOM_NO_UPDATE_CHECK": "1"], settings: on) != nil)
        #expect(UpdateNotice.disabledReason(environment: ["MUDROOM_NO_UPDATE_CHECK": "true"], settings: on) != nil)
        #expect(UpdateNotice.disabledReason(environment: ["MUDROOM_NO_UPDATE_CHECK": "0"], settings: on) == nil)
        #expect(UpdateNotice.disabledReason(environment: ["MUDROOM_NO_UPDATE_CHECK": ""], settings: on) == nil)
        #expect(UpdateNotice.disabledReason(environment: [:], settings: MudroomSettings(checkForUpdates: false)) != nil)
        #expect(UpdateNotice.disabledReason(environment: [:], settings: MudroomSettings(checkForUpdates: true)) == nil)
        #expect(UpdateNotice.disabledReason(environment: [:], settings: on, appChecksOff: true) != nil)
        #expect(UpdateNotice.disabledReason(environment: ["CI": "true"], settings: on) != nil)
        #expect(UpdateNotice.disabledReason(environment: ["CI": "false"], settings: on) == nil)
    }

    @Test("never during sessions, update itself, help, version or JSON output")
    func quietCommands() {
        #expect(UpdateNotice.allowed(arguments: ["list"]))
        #expect(UpdateNotice.allowed(arguments: ["diff", "last"]))
        #expect(UpdateNotice.allowed(arguments: ["network", "log", "last"]))
        for args in [[], ["run", "."], ["start", "last"], ["agent", "login", "claude"], ["update"], ["help"],
                     ["network", "log", "last", "--json"], ["--version"], ["list", "--help"], ["-h"],
                     ["--generate-completion-script", "zsh"]] {
            #expect(!UpdateNotice.allowed(arguments: args), "\(args)")
        }
    }

    @Test("settings and the check cache live in the store and survive a bad file")
    func persistence() throws {
        let tmp = try TempDir()
        let store = SessionStore(root: tmp.path("home"))
        #expect(MudroomSettings.load(store) == MudroomSettings())
        try MudroomSettings(checkForUpdates: false).save(store)
        #expect(MudroomSettings.load(store).checkForUpdates == false)
        // A damaged settings file leaves the check off.
        try write(#"{"checkForUpdates":"no"}"#, to: MudroomSettings.url(store))
        #expect(MudroomSettings.load(store).checkForUpdates == false)
        try write("{not json", to: UpdateNoticeState.url(store))
        #expect(UpdateNoticeState.load(store) == UpdateNoticeState())
        try UpdateNoticeState(checked: t0, latest: "0.6.0").save(store)
        #expect(UpdateNoticeState.load(store).latest == "0.6.0")
    }

    @Test("a run: checks when due, prints once, then stays quiet; a failed check is quiet and backs off")
    func run() throws {
        let tmp = try TempDir()
        let store = SessionStore(root: tmp.path("home"))
        let calls = LockedBox(0)
        let now = t0
        func notice(_ answer: Result<LatestRelease, UpdateCheck.CheckError>, at time: Date) -> String? {
            let r = UpdateNoticeRun(store: store, current: current, now: { time }) {
                calls.value += 1
                return answer
            }
            r.begin()
            return r.finish(wait: 5)
        }
        let newer = Result<LatestRelease, UpdateCheck.CheckError>.success(LatestRelease(version: ReleaseVersion("0.6.0")!))
        #expect(notice(newer, at: now)?.contains("0.6.0 is available") == true)
        #expect(calls.value == 1)
        // Same day: no second request and no second notice.
        #expect(notice(newer, at: now.addingTimeInterval(600)) == nil)
        #expect(calls.value == 1)
        // A day later: one more check, and the notice again.
        #expect(notice(newer, at: now.addingTimeInterval(86400 + 60)) != nil)
        #expect(calls.value == 2)

        let other = SessionStore(root: tmp.path("other"))
        let failing = UpdateNoticeRun(store: other, current: current, now: { now }) {
            calls.value += 1
            return .failure(.network("offline"))
        }
        failing.begin()
        #expect(failing.finish(wait: 5) == nil)
        #expect(calls.value == 3)
        let again = UpdateNoticeRun(store: other, current: current, now: { now.addingTimeInterval(600) }) {
            calls.value += 1
            return .failure(.network("offline"))
        }
        again.begin()
        #expect(again.finish(wait: 5) == nil)
        #expect(calls.value == 3)
    }

    @Test("a slow check doesn't hold the command up")
    func slow() throws {
        let tmp = try TempDir()
        let store = SessionStore(root: tmp.path("home"))
        let r = UpdateNoticeRun(store: store, current: current) {
            Thread.sleep(forTimeInterval: 3)
            return .success(LatestRelease(version: ReleaseVersion("0.6.0")!))
        }
        let start = Date()
        r.begin()
        #expect(r.finish(wait: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 1.5)
        // Cut off rather than refused: tried again in minutes, not an hour.
        let state = UpdateNoticeState.load(store)
        #expect(!state.needsCheck(now: Date().addingTimeInterval(60)))
        #expect(state.needsCheck(now: Date().addingTimeInterval(UpdateNoticeState.cutOffRetry + 5)))
    }
}

@Suite("Install method")
struct InstallMethodTests {
    func detect(_ path: String, windows: Bool = false, existing: Set<String> = [], files: [String] = []) -> InstallMethod {
        let paths = Set(existing.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        return InstallMethod.detect(executable: URL(fileURLWithPath: path), windows: windows,
                                    exists: { paths.contains($0.standardizedFileURL.path) }, contents: { _ in files })
    }

    @Test("the CLI inside Mudroom.app, with and without the Homebrew cask")
    func mac() {
        let app = URL(fileURLWithPath: "/Applications/Mudroom.app", isDirectory: true)
        #expect(detect("/Applications/Mudroom.app/Contents/Helpers/mudroom") == .appBundle(app: app, homebrew: nil))
        #expect(detect("/Applications/Mudroom.app/Contents/Helpers/mudroom",
                       existing: ["/opt/homebrew/Caskroom/mudroom", "/opt/homebrew/bin/brew"])
            == .appBundle(app: app, homebrew: URL(fileURLWithPath: "/opt/homebrew/bin/brew")))
        // A Caskroom entry without brew next to it isn't Homebrew's.
        #expect(detect("/Applications/Mudroom.app/Contents/Helpers/mudroom", existing: ["/opt/homebrew/Caskroom/mudroom"])
            == .appBundle(app: app, homebrew: nil))
        #expect(detect("/Users/me/Applications/Mudroom.app/Contents/Helpers/mudroom")
            == .appBundle(app: URL(fileURLWithPath: "/Users/me/Applications/Mudroom.app", isDirectory: true), homebrew: nil))
        #expect(detect("/Users/me/src/mudroom/.build/release/mudroom") == .source)
        #expect(detect("/usr/local/bin/mudroom") == .source)
        #expect(detect("/tmp/Contents/Helpers/mudroom") == .source)
    }

    @Test("Scoop, winget, a release zip, or a build on Windows")
    func windows() {
        #expect(detect("/C:/Users/me/scoop/apps/mudroom/current/mudroom.exe", windows: true,
                       existing: ["/C:/Users/me/scoop/shims"]) == .scoop)
        #expect(detect("/C:/ProgramData/scoop/apps/mudroom/0.5.0/mudroom.exe", windows: true,
                       existing: ["/C:/ProgramData/scoop/shims"]) == .scoop)
        #expect(detect("/C:/Users/me/AppData/Local/Microsoft/WinGet/Packages/KernelHunter.Mudroom_Microsoft.Winget.Source_8wekyb3d8bbwe/mudroom-0.5.0-windows-x86_64/mudroom.exe",
                       windows: true) == .winget)
        let zipDir = "/C:/Users/me/AppData/Local/Programs/Mudroom"
        let zip = ["mudroom.exe", "LICENSE.txt", "swiftCore.dll", "Foundation.dll", "vcruntime140.dll"]
        #expect(detect(zipDir + "/mudroom.exe", windows: true, files: zip)
            == .releaseZip(directory: URL(fileURLWithPath: zipDir, isDirectory: true)))
        // A shared tools folder, or another Swift program's runtime: not ours to replace.
        #expect(detect("/C:/tools/mudroom.exe", windows: true, files: zip + ["other.exe"]) == .source)
        #expect(detect("/C:/tools/mudroom.exe", windows: true, files: ["mudroom.exe", "swiftCore.dll", "Foundation.dll"]) == .source)
        #expect(detect("/C:/src/mudroom/.build/debug/mudroom.exe", windows: true) == .source)
        // Someone else's apps/mudroom folder without Scoop's shims.
        #expect(detect("/C:/x/apps/mudroom/current/mudroom.exe", windows: true) == .source)
    }
}

@Suite("Release zip update")
struct ReleaseZipUpdateTests {
    let hash = String(repeating: "ab", count: 32)

    @Test("checksum files and GitHub's asset digests")
    func checksums() {
        #expect(ReleaseZipUpdate.parseChecksum("\(hash)  mudroom-0.6.0-windows-x86_64.zip\n", file: "mudroom-0.6.0-windows-x86_64.zip") == hash)
        #expect(ReleaseZipUpdate.parseChecksum("\(hash.uppercased()) *a.zip", file: "a.zip") == hash)
        #expect(ReleaseZipUpdate.parseChecksum(hash, file: "a.zip") == hash)
        #expect(ReleaseZipUpdate.parseChecksum("\(hash)  b.zip", file: "a.zip") == nil)
        #expect(ReleaseZipUpdate.parseChecksum("<html>Not Found</html>", file: "a.zip") == nil)
        #expect(ReleaseZipUpdate.parseChecksum(String(hash.dropLast()), file: "a.zip") == nil)

        let api = Data(#"{"assets":[{"name":"a.zip","digest":"sha256:\#(hash)"},{"name":"b.zip","digest":null}]}"#.utf8)
        #expect(ReleaseZipUpdate.parseAssetDigest(api, file: "a.zip") == hash)
        #expect(ReleaseZipUpdate.parseAssetDigest(api, file: "b.zip") == nil)
        #expect(ReleaseZipUpdate.parseAssetDigest(api, file: "c.zip") == nil)

        #expect(ReleaseZipUpdate.checksumProblem(actual: hash, published: []) != nil)
        #expect(ReleaseZipUpdate.checksumProblem(actual: hash, published: [hash]) == nil)
        #expect(ReleaseZipUpdate.checksumProblem(actual: hash, published: [hash, hash]) == nil)
        #expect(ReleaseZipUpdate.checksumProblem(actual: hash, published: [hash, String(repeating: "cd", count: 32)]) != nil)
    }

    @Test("SHA-256 of a file")
    func sha() throws {
        let tmp = try TempDir()
        try write("abc", to: tmp.path("f"))
        #expect(try ReleaseZipUpdate.sha256(of: tmp.path("f")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("swaps new files in, sets old ones aside, and removes them later")
    func swap() throws {
        let tmp = try TempDir()
        let dir = tmp.path("Mudroom")
        let staged = tmp.path("Mudroom/.stage/mudroom-0.6.0-windows-x86_64")
        try write("old exe", to: dir.appendingPathComponent("mudroom.exe"))
        try write("old dll", to: dir.appendingPathComponent("swiftCore.dll"))
        try write("mine", to: dir.appendingPathComponent("notes.txt"))
        try write("new exe", to: staged.appendingPathComponent("mudroom.exe"))
        try write("new dll", to: staged.appendingPathComponent("swiftCore.dll"))
        try write("added", to: staged.appendingPathComponent("Foundation.dll"))
        // Held open while it is replaced, like the running mudroom.exe.
        let held = try FileHandle(forReadingFrom: dir.appendingPathComponent("mudroom.exe"))
        defer { try? held.close() }

        let names = try ReleaseZipUpdate.swapIn(staged, to: dir)
        #expect(names == ["Foundation.dll", "mudroom.exe", "swiftCore.dll"])
        #expect(try read(dir.appendingPathComponent("mudroom.exe")) == "new exe")
        #expect(try read(dir.appendingPathComponent("swiftCore.dll")) == "new dll")
        #expect(try read(dir.appendingPathComponent("Foundation.dll")) == "added")
        #expect(try read(dir.appendingPathComponent("notes.txt")) == "mine")
        #expect(try read(dir.appendingPathComponent("mudroom.exe.mudroom-old")) == "old exe")
        try held.close()
        ReleaseZipUpdate.removeLeftovers(in: dir)
        #expect(!exists(dir.appendingPathComponent("mudroom.exe.mudroom-old")))
        #expect(!exists(dir.appendingPathComponent("swiftCore.dll.mudroom-old")))
    }

    @Test("a folder in the zip is refused before anything moves")
    func refusesFolders() throws {
        let tmp = try TempDir()
        let dir = tmp.path("Mudroom")
        let staged = tmp.path("stage")
        try write("old", to: dir.appendingPathComponent("mudroom.exe"))
        try write("new", to: staged.appendingPathComponent("mudroom.exe"))
        try write("x", to: staged.appendingPathComponent("sub/evil.dll"))
        #expect(throws: MudroomError.self) { try ReleaseZipUpdate.swapIn(staged, to: dir) }
        #expect(try read(dir.appendingPathComponent("mudroom.exe")) == "old")
    }

    @Test("a failure halfway puts every file back")
    func rollsBack() throws {
        guard !isWindows, !isRoot else { return }
        let tmp = try TempDir()
        let dir = tmp.path("Mudroom")
        let staged = tmp.path("stage")
        try write("old a", to: dir.appendingPathComponent("a.dll"))
        try write("old b", to: dir.appendingPathComponent("b.dll"))
        try write("new a", to: staged.appendingPathComponent("a.dll"))
        try write("new b", to: staged.appendingPathComponent("b.dll"))
        // A leftover for b that can't be deleted stops the swap at b.
        let stuck = dir.appendingPathComponent("b.dll.mudroom-old/locked")
        try write("x", to: stuck.appendingPathComponent("file"))
        chmod(stuck.path, 0o555)
        defer { chmod(stuck.path, 0o755) }

        #expect(throws: MudroomError.self) { try ReleaseZipUpdate.swapIn(staged, to: dir) }
        #expect(try read(dir.appendingPathComponent("a.dll")) == "old a")
        #expect(try read(dir.appendingPathComponent("b.dll")) == "old b")
        #expect(try read(staged.appendingPathComponent("a.dll")) == "new a")
        #expect(!exists(dir.appendingPathComponent("a.dll.mudroom-old")))
    }
}

/// A loopback HTTP server that answers each request with whatever `reply`
/// returns for its path, and keeps the request heads.
final class CannedHTTPServer: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let reply: @Sendable (String) -> String
    private let received = LockedBox<[String]>([])
    private let stopped = LockedBox(false)
    var requests: [String] { received.value }

    init(_ reply: @escaping @Sendable (String) -> String) throws {
        self.reply = reply
        (fd, port) = try Sock.listen(host: "127.0.0.1", port: 0)
        Thread { [self] in serve() }.start()
    }

    private func serve() {
        while !stopped.value {
            guard Sock.waitReadable(fd, timeout: 0.1) else { continue }
            if stopped.value { return }
            guard let (conn, _, _) = Sock.accept(fd) else { continue }
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while buf.range(of: Data("\r\n\r\n".utf8)) == nil {
                guard let n = Sock.receive(conn, &chunk) else { continue }
                if n <= 0 { break }
                buf.append(contentsOf: chunk[0..<n])
            }
            let head = String(decoding: buf, as: UTF8.self)
            received.value = received.value + [head]
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            _ = Sock.sendAll(conn, Data(reply(path).utf8))
            Sock.close(conn)
        }
    }

    func cancel() {
        guard !stopped.value else { return }
        stopped.value = true
        usleep(150_000)
        Sock.close(fd)
    }

    deinit { cancel() }
}
