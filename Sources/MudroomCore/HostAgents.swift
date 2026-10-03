#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Turns raw terminal output into text a person (or a parser) can read:
/// escape sequences removed, tokens hidden, links and device codes found.
public enum ConsoleText {
    /// Removes ANSI/VT escape sequences (CSI, OSC, single-character ones)
    /// and carriage returns; other control characters but tab and newline
    /// are dropped too.
    public static func strip(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        var it = raw.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return it.next()
        }
        while let c = next() {
            if c == "\u{1B}" {
                guard let k = next() else { break }
                switch k {
                case "[":
                    // Parameters and intermediates, then one final byte.
                    while let d = next() {
                        if (0x40...0x7E).contains(d.value) { break }
                    }
                case "]", "P", "_", "^":
                    // String sequences end with BEL or ESC \.
                    while let d = next() {
                        if d == "\u{07}" { break }
                        if d == "\u{1B}" {
                            if let e = next(), e != "\\" { pending = e }
                            break
                        }
                    }
                case "(", ")", "*", "+", "#":
                    _ = next()
                default:
                    break
                }
                continue
            }
            if c == "\r" {
                // CR LF is a line break; a lone CR starts the line over
                // (a redraw), which reads best as a new line.
                if let n = next() {
                    pending = n
                    if n != "\n" { out.append("\n") }
                }
                continue
            }
            if c.value < 0x20 && c != "\n" && c != "\t" { continue }
            if c.value == 0x7F || (0x80...0x9F).contains(c.value) { continue }
            out.append(c)
        }
        return String(out)
    }

    /// Hides anything that looks like a Claude or OpenAI-style secret.
    public static func redact(_ text: String) -> String {
        var s = text
        for pattern in [#"sk-ant-[A-Za-z0-9_\-]{6,}"#, #"sk-(proj-)?[A-Za-z0-9_\-]{20,}"#] {
            s = s.replacingOccurrences(of: pattern, with: "[token hidden]", options: .regularExpression)
        }
        return s
    }

    /// Readable lines for a log view: stripped, redacted, blank and
    /// repeated lines (from redraws) dropped, last `limit` kept.
    public static func lines(_ raw: Data, limit: Int = 12) -> [String] {
        let text = redact(strip(String(decoding: raw, as: UTF8.self)))
        var seen = Set<String>()
        var out: [String] = []
        for line in text.split(separator: "\n").reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.contains(where: { $0.isLetter || $0.isNumber }), seen.insert(t).inserted else { continue }
            out.append(t)
            if out.count >= limit { break }
        }
        return out.reversed()
    }

    /// https links in the output, in order, without duplicates.
    public static func links(_ text: String) -> [String] {
        let clean = strip(text)
        var out: [String] = []
        var scanner = clean[...]
        while let r = scanner.range(of: "https://") {
            let rest = scanner[r.lowerBound...]
            let end = rest.firstIndex { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "<" || $0 == ">" } ?? rest.endIndex
            var link = String(rest[..<end])
            while let last = link.last, ".,;:)]".contains(last) { link.removeLast() }
            if !out.contains(link) { out.append(link) }
            scanner = rest[end...]
        }
        return out
    }

    /// A device sign-in code such as "ABCD-EFGH1" (Codex, GitHub style).
    public static func deviceCode(_ text: String) -> String? {
        let clean = strip(text)
        guard let r = clean.range(of: #"(?<![A-Z0-9-])[A-Z0-9]{4,5}-[A-Z0-9]{4,5}(?![A-Z0-9-])"#, options: [.regularExpression, .backwards]) else {
            return nil
        }
        let code = String(clean[r])
        // Needs letters and digits mixed or all letters; skips dates like 2026-1001.
        return code.contains(where: \.isLetter) ? code : nil
    }
}

/// Picks the token out of `claude setup-token` output.
public enum SetupTokenCapture {
    static let tokenChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    /// Real tokens are about 108 characters; shorter ones were cut by a
    /// line wrap.
    static let expectedLength = 100

    /// The longest `sk-ant-oat...` token in the output, put back together
    /// if the terminal wrapped it.
    public static func extract(_ raw: String) -> String? {
        let text = ConsoleText.strip(raw)
        var best: String?
        var search = text.startIndex
        while let r = text.range(of: "sk-ant-oat", range: search..<text.endIndex) {
            var token = ""
            var i = r.lowerBound
            while i < text.endIndex, tokenChars.contains(text[i]) {
                // Two copies back to back (a redraw): stop at the second.
                if !token.isEmpty, text[i...].hasPrefix("sk-ant-") { break }
                token.append(text[i])
                i = text.index(after: i)
            }
            // A wrapped token goes on at the start of the next line, after
            // any indent or box border, with nothing else on that line.
            let border = CharacterSet(charactersIn: " \t│|")
            while token.count < expectedLength, i < text.endIndex {
                var j = i
                while j < text.endIndex, text[j] != "\n", text[j].unicodeScalars.allSatisfy(border.contains) { j = text.index(after: j) }
                guard j < text.endIndex, text[j] == "\n" else { break }
                let lineStart = text.index(after: j)
                let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
                let piece = text[lineStart..<lineEnd].trimmingCharacters(in: border)
                guard !piece.isEmpty, !piece.hasPrefix("sk-ant-"), piece.allSatisfy({ tokenChars.contains($0) }) else { break }
                token += piece
                i = lineEnd
            }
            if token.count >= 40, token.count > (best?.count ?? 0) { best = token }
            search = r.upperBound
        }
        return best
    }
}

/// Coding-agent CLIs installed on this machine (not in the VM).
public enum HostCLI {
    /// Where `claude` is usually installed: the native installer, npm's
    /// old local install, Homebrew.
    public static func claudeCandidates(home: String) -> [String] {
        [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    /// The host `claude` binary: this process's PATH, then the usual places,
    /// then PATH as a login shell sees it (an app started from Finder has a
    /// bare PATH).
    public static func findClaude(home: String = NSHomeDirectory(),
                                  isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                                  loginShellPath: () -> String? = HostCLI.loginShellPath,
                                  path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        find("claude", candidates: claudeCandidates(home: home), isExecutable: isExecutable,
             loginShellPath: loginShellPath, path: path)
    }

    public static func find(_ name: String, candidates: [String], isExecutable: (String) -> Bool,
                            loginShellPath: () -> String?, path: String?) -> String? {
        func onPath(_ p: String?) -> String? {
            for dir in (p ?? "").split(separator: ":") where dir.hasPrefix("/") {
                let c = dir + "/" + name
                if isExecutable(c) { return c }
            }
            return nil
        }
        // PATH first, as `which` does, so a stale copy in one of the usual
        // places (an old ~/.claude/local install) doesn't win over the one
        // the person runs.
        return onPath(path) ?? candidates.first(where: isExecutable) ?? onPath(loginShellPath())
    }

    /// PATH from the user's login shell, or nil if it can't be read quickly.
    public static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell),
              let out = try? ProcessRunner.capture(shell, ["-l", "-c", "printf %s \"$PATH\""]), out.status == 0 else { return nil }
        let p = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? nil : p
    }
}

/// Existing sign-ins on this machine that can be copied into Mudroom's
/// agent directory, so sessions start signed in. Always a copy, only after
/// the person asks for it; the originals are never mounted or changed.
public struct HostLogin: Sendable, Equatable {
    public var agent: String
    /// Files to copy, relative to `sourceDirectory`, and whether each is needed.
    public var files: [(name: String, required: Bool)]
    public var sourceDirectory: URL

    public static func == (a: HostLogin, b: HostLogin) -> Bool {
        a.agent == b.agent && a.sourceDirectory == b.sourceDirectory && a.files.map(\.name) == b.files.map(\.name)
    }

    public static func forAgent(_ agent: String, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> HostLogin? {
        switch agent {
        case "codex":
            HostLogin(agent: agent, files: [("auth.json", true)], sourceDirectory: home.appendingPathComponent(".codex"))
        case "gemini":
            HostLogin(agent: agent, files: [("oauth_creds.json", true), ("google_accounts.json", false)],
                      sourceDirectory: home.appendingPathComponent(".gemini"))
        default:
            nil
        }
    }

    public var displayPath: String {
        let path = sourceDirectory.appendingPathComponent(files[0].name).path
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// True if the main credential file exists (it is not read).
    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: sourceDirectory.appendingPathComponent(files[0].name).path)
    }

    /// Copies the files into `home`. Each must be a regular file holding a
    /// JSON object; written 0600. Returns the names copied.
    @discardableResult
    public func importInto(_ home: AgentHome) throws -> [String] {
        try home.create()
        var copied: [String] = []
        for f in files {
            let data: Data
            do {
                data = try SafeFS.readBeneath(sourceDirectory, f.name, limit: 1 << 20)
            } catch {
                if f.required { throw MudroomError.invalid("couldn't read \(sourceDirectory.appendingPathComponent(f.name).path): \(error)") }
                continue
            }
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                if f.required { throw MudroomError.invalid("\(f.name) is not a JSON sign-in file") }
                continue
            }
            try AgentHome.writePrivate(data, to: home.hostDirectory.appendingPathComponent(f.name))
            copied.append(f.name)
        }
        if agent == "gemini" { try home.setGeminiAuthType("oauth-personal") }
        return copied
    }
}

extension AgentHome {
    /// Reads a JSON object (or starts an empty one), lets `body` change it
    /// and writes it back 0600. Best effort.
    static func updateJSON(_ url: URL, _ body: (inout [String: Any]) -> Void) {
        var obj = ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let before = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        body(&obj)
        guard let after = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) != before else { return }
        try? writePrivate(after, to: url)
    }

    /// Tells Gemini CLI which sign-in to use, so its first run doesn't ask.
    /// Written in both the current (security.auth.selectedType) and the
    /// older (selectedAuthType) settings layout.
    public func setGeminiAuthType(_ type: String) throws {
        try create()
        let url = hostDirectory.appendingPathComponent("settings.json")
        var settings = ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        var security = settings["security"] as? [String: Any] ?? [:]
        var auth = security["auth"] as? [String: Any] ?? [:]
        auth["selectedType"] = type
        security["auth"] = auth
        settings["security"] = security
        settings["selectedAuthType"] = type
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try Self.writePrivate(data, to: url)
    }

    /// Marks Claude Code's first-run screens (theme, the bypass-permissions
    /// warning, folder trust for /workspace) as done, so a session signed
    /// in with a token starts straight in the prompt. Existing values win.
    public func seedClaudeOnboarding() throws {
        guard agent == "claude" else { return }
        try create()
        let url = hostDirectory.appendingPathComponent(".claude.json")
        var config = ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let defaults: [String: Any] = ["hasCompletedOnboarding": true, "theme": "dark", "bypassPermissionsModeAccepted": true]
        for (k, v) in defaults where config[k] == nil { config[k] = v }
        var projects = config["projects"] as? [String: Any] ?? [:]
        var ws = projects["/workspace"] as? [String: Any] ?? [:]
        if ws["hasTrustDialogAccepted"] == nil { ws["hasTrustDialogAccepted"] = true }
        projects["/workspace"] = ws
        config["projects"] = projects
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try Self.writePrivate(data, to: url)
        // Newer Claude Code reads the bypass-permissions consent from
        // settings.json; without it every session opens on that warning.
        let settingsURL = hostDirectory.appendingPathComponent("settings.json")
        var settings = ((try? Data(contentsOf: settingsURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        if settings["skipDangerousModePermissionPrompt"] == nil {
            settings["skipDangerousModePermissionPrompt"] = true
            try Self.writePrivate(try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]), to: settingsURL)
        }
    }
}

/// Runs `claude setup-token` on the host in a terminal of its own. Claude
/// opens the browser itself; when the person has approved, it prints a
/// long-lived token, which is picked out of the output and handed over.
/// The token is never shown: the readable output has it hidden.
public final class ClaudeTokenSignIn: @unchecked Sendable {
    public let pty: PtyProcess
    private let found = LockedBox<String?>(nil)
    private let done = DispatchSemaphore(value: 0)

    public init(claude: String) throws {
        // BROWSER is left as it is: claude opens the default browser. PATH
        // as a login shell has it, for an npm install that needs `node`.
        var env: [String: String] = [:]
        if let path = HostCLI.loginShellPath() { env["PATH"] = path }
        pty = try PtyProcess(claude, ["setup-token"], environment: env)
        let found = self.found
        let done = self.done
        let p = pty
        pty.onOutput = { _ in
            guard found.value == nil, let t = SetupTokenCapture.extract(String(decoding: p.allOutput, as: UTF8.self)),
                  t.count >= SetupTokenCapture.expectedLength || !p.isRunning else { return }
            found.value = t
            done.signal()
        }
        Thread.detachNewThread { [weak self] in
            _ = p.wait()
            guard let self else { return }
            if self.found.value == nil, let t = SetupTokenCapture.extract(String(decoding: p.allOutput, as: UTF8.self)) {
                self.found.value = t
            }
            done.signal()
        }
    }

    /// Readable output so far, token hidden.
    public func lines(limit: Int = 12) -> [String] { ConsoleText.lines(pty.allOutput, limit: limit) }

    /// Sign-in links printed so far (to open again if the browser didn't).
    public var links: [String] { ConsoleText.links(String(decoding: pty.allOutput, as: UTF8.self)) }

    /// Types a code the page showed back into claude.
    public func sendCode(_ code: String) { pty.sendLine(code.trimmingCharacters(in: .whitespacesAndNewlines)) }

    /// Waits until a token was printed or claude exited. Returns the token.
    public func waitForToken(timeout: TimeInterval = 900) -> String? {
        _ = done.wait(timeout: .now() + timeout)
        let t = found.value
        // Give it a moment to finish on its own, then stop it.
        if t != nil {
            let deadline = Date().addingTimeInterval(3)
            while pty.isRunning && Date() < deadline { usleep(100_000) }
        }
        pty.terminate()
        return t
    }

    public func cancel() { pty.terminate() }
}
