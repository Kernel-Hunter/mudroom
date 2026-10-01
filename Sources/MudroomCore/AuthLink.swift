#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Gets sign-in links out of the sandbox and into the browser on the host.
///
/// Agents print their OAuth URL in the terminal, where it wraps over
/// several lines and copying it tends to lose the end (Claude Code then
/// fails with "Invalid code_challenge_method"). Instead, each run sets
/// BROWSER to a tiny script on a mounted folder; Claude Code (like most
/// tools) calls it with the URL. Mudroom picks the URL up on the host,
/// checks it is a known sign-in page, copies it to the clipboard, prints
/// it on one line and opens it in the default browser.
public final class AuthLinkHandoff: @unchecked Sendable {
    public static let guestDirectory = "/opt/mudroom"
    public let directory: URL
    private let urlsFile: URL
    private let stopped = LockedBox(false)
    private let done = DispatchSemaphore(value: 0)
    private var thread: Thread?
    /// Links already handled, and how many (at most `maxLinks` a run).
    private var seen = Set<String>()
    static let maxLinks = 5

    /// Sign-in hosts whose pages may be opened. Anything else the sandbox
    /// hands over is ignored.
    public static let hosts: Set<String> = [
        "claude.ai", "claude.com", "platform.claude.com", "console.anthropic.com",
        "auth.openai.com", "chatgpt.com", "accounts.google.com",
    ]
    /// Claude Code's page that shows the code to paste back.
    public static let claudeManualRedirect = "https://platform.claude.com/oauth/code/callback"

    public init(directory: URL) throws {
        self.directory = directory
        urlsFile = directory.appendingPathComponent("urls")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o700)
        let script = directory.appendingPathComponent("open-url")
        try """
        #!/bin/sh
        # Set as BROWSER by Mudroom: hands sign-in links to the host, which
        # opens them in your browser there.
        for u in "$@"; do printf '%s\\n' "$u" >> \(Self.guestDirectory)/urls; done
        exit 0

        """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        _ = FileManager.default.createFile(atPath: urlsFile.path, contents: nil)
    }

    public var mount: SandboxMount { SandboxMount(source: directory, target: Self.guestDirectory) }
    public var environment: [String: String] { ["BROWSER": Self.guestDirectory + "/open-url"] }

    /// Watches for links until `stop`. `deliver` gets each usable one.
    public func start(_ deliver: @escaping @Sendable (URL) -> Void) {
        let t = Thread { [self] in
            defer { done.signal() }
            var offset: UInt64 = 0
            var partial = Data()
            while !stopped.value {
                usleep(250_000)
                guard let h = try? FileHandle(forReadingFrom: urlsFile) else { continue }
                try? h.seek(toOffset: offset)
                let data = (try? h.read(upToCount: 64 << 10)) ?? Data()
                try? h.close()
                if data.isEmpty { continue }
                offset += UInt64(data.count)
                partial.append(data)
                while let nl = partial.firstIndex(of: 0x0A) {
                    let line = String(decoding: partial[partial.startIndex..<nl], as: UTF8.self)
                    partial = Data(partial[partial.index(after: nl)...])
                    guard seen.count < Self.maxLinks, !seen.contains(line) else { continue }
                    seen.insert(line)
                    if let url = Self.prepare(line) { deliver(url) }
                }
                if partial.count > 16 << 10 { partial = Data() }
            }
        }
        t.name = "mudroom.auth-links"
        thread = t
        t.start()
    }

    public func stop() {
        guard thread != nil, !stopped.value else { return }
        stopped.value = true
        done.wait()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The link to open, or nil if it isn't a sign-in page we know, or
    /// can't work from the host. A Claude link whose callback is a port
    /// inside the sandbox gets Claude's manual-code page as redirect
    /// instead; it is the same request Claude prints for copying.
    public static func prepare(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count < 8192, s.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }),
              var c = URLComponents(string: s), c.scheme == "https", let host = c.host?.lowercased(),
              hosts.contains(host), c.user == nil, c.password == nil, c.port == nil else { return nil }
        if let i = c.queryItems?.firstIndex(where: { $0.name == "redirect_uri" }),
           let redirect = c.queryItems?[i].value.flatMap(URLComponents.init(string:)),
           ["localhost", "127.0.0.1", "::1", "[::1]"].contains(redirect.host ?? "") {
            guard ["claude.ai", "claude.com"].contains(host), c.path.hasSuffix("/oauth/authorize") else { return nil }
            var items = c.queryItems ?? []
            items[i].value = claudeManualRedirect
            if !items.contains(where: { $0.name == "code" }) { items.insert(URLQueryItem(name: "code", value: "true"), at: 0) }
            c.queryItems = items
            // URLComponents leaves ":" and "/" in values; encode like Claude does.
            c.percentEncodedQuery = c.percentEncodedQuery?
                .replacingOccurrences(of: claudeManualRedirect, with: claudeManualRedirect
                    .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!)
        }
        return c.url
    }

    /// Copies the link to the clipboard, opens it in the browser and
    /// prints it on one line.
    public static func deliver(_ url: URL, log: (String) -> Void) {
        let s = url.absoluteString
        var copied = false
        #if os(macOS)
        copied = pipe(s, to: "/usr/bin/pbcopy", [])
        _ = try? ProcessRunner.capture("/usr/bin/open", [s])
        #else
        if let wl = ProcessRunner.which("wl-copy") { copied = pipe(s, to: wl, []) }
        else if let xc = ProcessRunner.which("xclip") { copied = pipe(s, to: xc, ["-selection", "clipboard"]) }
        let env = ProcessInfo.processInfo.environment
        if env["DISPLAY"] != nil || env["WAYLAND_DISPLAY"] != nil, let xo = ProcessRunner.which("xdg-open") {
            _ = try? ProcessRunner.capture(xo, [s])
        }
        #endif
        log("\r\nmudroom: opened the sign-in page in your browser\(copied ? " (the link is on your clipboard too)" : ""):\r\n\(s)\r\n"
            + "After signing in, paste the code back here. \(pasteNote)\r\n")
    }

    /// Shown wherever a login asks for a pasted code.
    public static let pasteNote = "The code won't appear when you paste it. Paste with ⌘V (Ctrl+Shift+V on Linux), then press Enter."

    static func pipe(_ text: String, to exe: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        input.fileHandleForWriting.write(Data(text.utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
