import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import MudroomCore

func projectPath(_ arg: String?) -> String {
    URL(fileURLWithPath: arg ?? FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().standardizedFileURL.path
}

func bytes(_ n: Int64) -> String { NetworkLog.byteString(n) }

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

struct Snapshots: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the snapshots taken while a session's agent ran.",
        discussion: "Compare any two with `mudroom diff <session> --from <n> --to <m|work>`.")

    @Argument(help: "Session id, unique prefix, or 'last'.")
    var session: String

    func run() throws {
        do {
            let handle = try store().open(session)
            let snaps = SnapshotStore(handle: handle).list()
            if snaps.isEmpty {
                print("no snapshots for \(handle.session.id)")
                return
            }
            var previous = handle.base
            print("  #  taken                changes since previous")
            for s in snaps {
                let d = try Differ.compare(base: previous, work: s.directory)
                print(String(format: "%3d  %@  %d", s.number, timeFormatter.string(from: s.date), d.changes.count))
                previous = s.directory
            }
            let tail = try Differ.compare(base: previous, work: handle.work).changes.count
            print("     work                 \(tail)")
        } catch { fail(error) }
    }
}

struct NetworkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Per-project network settings and what sessions connected to.",
        discussion: """
        Locked (the default) puts the VM on a host-only network; the only way out is \
        Mudroom's proxy, which allows the agent's API hosts plus anything you add. \
        Open gives normal access, offline none.
        """,
        subcommands: [Show.self, Log.self, Allow.self, Deny.self, Mode.self, Registries.self, LocalModels.self, Check.self, Probe.self])

    struct ProjectOption: ParsableArguments {
        @Option(name: .customLong("project"), help: "Project directory (default: the current directory).")
        var project: String?

        @Option(name: .customLong("session"), help: "Use this session's project instead.")
        var session: String?

        func path() throws -> String {
            if let session { return try store().open(session).session.projectPath }
            return projectPath(project)
        }
    }

    static func configStore() -> ProjectConfigStore { ProjectConfigStore(store: store()) }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a project's network mode and allowlist.")
        @OptionGroup var where_: ProjectOption
        @Option(help: "Show the effective allowlist for this agent (claude, codex, gemini).")
        var agent: String = "claude"

        func run() throws {
            do {
                let path = try where_.path()
                let config = try NetworkCommand.configStore().load(path)
                print("project   \(path)")
                print("config    \(NetworkCommand.configStore().url(for: path).path)")
                print("mode      \(config.networkMode.rawValue)")
                print("agent hosts \(config.includeAgentHosts ? "on" : "off"), package registries \(config.includePackageRegistries ? "on" : "off"), local models \(config.localModels ? "on" : "off")")
                print("snapshots every \(config.snapshotMinutes) min, keep \(config.snapshotLimit)")
                print("\nallowed for \(agent):")
                let tokens = AgentToken.defaultStore(store())
                let keys = APIKeys.storedNames(tokens) + AgentEnvironment.present(names: APIKeys.providers.map(\.variable))
                for p in config.allowlist(agent: AgentPreset.find(agent)?.id ?? agent, keys: keys).patterns {
                    let origin = config.allowedHosts.contains(p) ? "project" : "default"
                    print("  \(p.value.padding(toLength: 40, withPad: " ", startingAt: 0)) \(origin)")
                }
            } catch { fail(error) }
        }
    }

    struct Log: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "What a session's VM connected to, and what was blocked.")
        @Argument(help: "Session id, unique prefix, or 'last'.")
        var session: String
        @Flag(help: "One line per connection instead of per host.")
        var all = false

        func run() throws {
            do {
                let handle = try store().open(session)
                let entries = NetworkLog.read(handle.networkLog)
                if let n = handle.session.network {
                    print("mode \(n.mode.rawValue) (\(n.enforcement.title))\(n.proxy.map { ", proxy \($0)" } ?? "")")
                }
                if entries.isEmpty {
                    print("no connections logged")
                    return
                }
                if all {
                    for e in entries {
                        let verdict = e.allowed ? (e.reason == nil ? "allowed" : "failed ") : "BLOCKED"
                        print("\(timeFormatter.string(from: e.time))  \(verdict)  \(e.method.padding(toLength: 7, withPad: " ", startingAt: 0)) \(e.host):\(e.port)  out \(bytes(e.bytesOut)) in \(bytes(e.bytesIn))  \(e.durationMs) ms\(e.reason.map { "  (\($0))" } ?? "")")
                    }
                    return
                }
                for r in NetworkLog.summarize(entries) {
                    let verdict = r.allowed ? "allowed" : "BLOCKED"
                    print("\(verdict)  \(("\(r.host):\(r.port)").padding(toLength: 44, withPad: " ", startingAt: 0)) \(r.count)x  out \(bytes(r.bytesOut)) in \(bytes(r.bytesIn))")
                }
                let blocked = Set(entries.filter { !$0.allowed }.map(\.host))
                if !blocked.isEmpty {
                    print("\nallow one for this project: mudroom network allow <host> --session \(handle.session.id)")
                }
            } catch { fail(error) }
        }
    }

    struct Allow: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add hosts to a project's allowlist (exact, or *.suffix).")
        @Argument(help: "Hosts, e.g. registry.npmjs.org '*.githubusercontent.com'.")
        var hosts: [String]
        @OptionGroup var where_: ProjectOption

        func run() throws {
            do {
                let patterns = try hosts.map { raw -> HostPattern in
                    guard let p = HostPattern(raw) else { throw MudroomError.invalid("not a host name or *.suffix pattern: \(raw)") }
                    return p
                }
                let path = try where_.path()
                try NetworkCommand.configStore().update(path) { c in
                    for p in patterns { print(c.allow(p) ? "allowed \(p)" : "already allowed \(p)") }
                }
            } catch { fail(error) }
        }
    }

    struct Deny: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove hosts you added to a project's allowlist.")
        @Argument var hosts: [String]
        @OptionGroup var where_: ProjectOption

        func run() throws {
            do {
                let path = try where_.path()
                try NetworkCommand.configStore().update(path) { c in
                    for raw in hosts {
                        guard let p = HostPattern(raw), c.disallow(p) else {
                            print("not in the project list: \(raw) (agent defaults are switched off with `network show`/config)")
                            continue
                        }
                        print("removed \(p)")
                    }
                }
            } catch { fail(error) }
        }
    }

    struct Mode: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set a project's network mode: locked, open or offline.")
        @Argument var mode: NetworkMode
        @OptionGroup var where_: ProjectOption

        func run() throws {
            do {
                let path = try where_.path()
                try NetworkCommand.configStore().update(path) { $0.networkMode = mode }
                print("\(path): network \(mode.rawValue)")
                if mode == .open { print("warning: open sessions can reach anything and nothing is logged") }
            } catch { fail(error) }
        }
    }

    struct Registries: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Allow npm, PyPI and GitHub for a project (on/off).",
            discussion: NetworkDefaults.packageRegistries.joined(separator: ", "))
        @Argument var state: String
        @OptionGroup var where_: ProjectOption

        func validate() throws {
            guard ["on", "off"].contains(state) else { throw ValidationError("use on or off") }
        }

        func run() throws {
            do {
                let path = try where_.path()
                try NetworkCommand.configStore().update(path) { $0.includePackageRegistries = state == "on" }
                print("\(path): package registries \(state)")
            } catch { fail(error) }
        }
    }

    struct LocalModels: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "local-models",
            abstract: "Let a project's VM use Ollama and LM Studio on this machine (on/off).",
            discussion: """
            Locked mode only. The VM reaches them as http://\(NetworkDefaults.hostServiceName):11434 (Ollama) and \
            :1234 (LM Studio) through Mudroom's proxy, which connects to 127.0.0.1 on those two ports and no \
            others. Sessions get OLLAMA_HOST, OLLAMA_API_BASE and LM_STUDIO_API_BASE pointing there.
            """)
        @Argument var state: String
        @OptionGroup var where_: ProjectOption

        func validate() throws {
            guard ["on", "off"].contains(state) else { throw ValidationError("use on or off") }
        }

        func run() throws {
            do {
                let path = try where_.path()
                let c = try NetworkCommand.configStore().update(path) { $0.localModels = state == "on" }
                print("\(path): local models \(state)")
                if c.localModels && c.networkMode != .locked { print("note: this project's network is \(c.networkMode.rawValue); local models only work in locked mode") }
            } catch { fail(error) }
        }
    }

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start a sandbox with a project's network settings and try to get out.",
            discussion: """
            Tries an allowed and a blocked host through the proxy, then DNS, direct \
            TCP (IPv4 and IPv6) and UDP around it, and reports what connected.
            """)
        @OptionGroup var where_: ProjectOption
        @Option(help: "Agent whose default hosts to include.")
        var agent: String = "claude"
        @Option(help: "Override the mode for this check.")
        var mode: NetworkMode?
        @Option(help: "A host that should be blocked.")
        var blocked: String = "example.com"
        @OptionGroup var backendOptions: BackendOptions

        func run() throws {
            do {
                let path = try where_.path()
                let config = try NetworkCommand.configStore().load(path)
                let m = mode ?? config.networkMode
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mudroom-check-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: scratch) }
                let backend = try backendOptions.make()
                print("checking \(m.rawValue) network with \(backend.name)...")
                fflush(nil)
                let report = try NetworkCheck.run(mode: m, allowlist: config.allowlist(agent: AgentPreset.find(agent)?.id),
                                                  backend: backend, blocked: blocked, scratch: scratch)
                print("mode \(report.network.mode.rawValue) (\(report.network.enforcement.title))\(report.network.proxy.map { ", proxy \($0)" } ?? "")\n")
                for o in report.outcomes {
                    let got = o.connected ? "got through" : "stopped    "
                    let verdict: String
                    switch o.expected {
                    case .some(let e): verdict = e == o.connected ? "ok      " : "UNEXPECTED"
                    case .none: verdict = "note    "
                    }
                    print("\(verdict)  \(got)  \(o.detail): \(o.result)")
                }
                if report.outcomes.contains(where: { $0.name == "mac-services" && $0.connected }) {
                    if backend.name == "apple-container" {
                    print("\nnote: the VM can reach services on this Mac that listen on all interfaces (the host-only network's gateway is the Mac).")
                } else {
                    print("\nnote: the sandbox can reach the internal network's gateway. On Linux that is the host itself, so services listening on all interfaces are reachable; with Docker Desktop or a Podman VM it is the runtime's VM.")
                }
                }
                if !report.matchesExpectation { throw ExitCode(3) }
            } catch let e as ExitCode { throw e } catch { fail(error) }
        }
    }
}

struct Agent: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Persistent agent logins, kept in Mudroom's own directory (never your real ~/.claude).",
        subcommands: [Login.self, Import.self, Token.self, Status.self])

    struct Login: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Sign an agent in, inside a VM; the login is kept for later sessions.",
            discussion: "claude runs `claude auth login`, codex `codex login --device-auth`, gemini its first-run sign-in.")
        @Argument(help: "claude, codex or gemini.")
        var agent: String
        @Option(help: "Container image to run.")
        var image: String = AgentBaseImage.tag
        @Flag(help: "Always sign in inside the sandbox, even when claude is installed on this machine.")
        var inVM = false
        @OptionGroup var backendOptions: BackendOptions

        func run() throws {
            guard let preset = AgentPreset.find(agent), AgentHome(store: store(), agent: preset.id) != nil else {
                fail(MudroomError.invalid("unknown agent \(agent); use claude, codex or gemini"))
            }
            if preset.id == "gemini" { print("Pick \"Login with Google\", finish in your browser, then type /quit.") }
            let tty = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
            // Most robust for Claude: a long-lived token made by the claude CLI
            // on this machine, which opens the browser itself.
            if preset.id == "claude", !inVM, tty, let claude = HostCLI.findClaude() {
                // The token is read from claude's output; nothing to copy or paste.
                if confirm("The claude CLI is installed here (\(claude)). Sign in with it?", yes: false) {
                    if signInClaudeWithHostCLI(claude) { return }
                    print("Signing in inside the sandbox instead.")
                }
            }
            print(AuthLinkHandoff.pasteNote)
            if tty { print("The sign-in page opens in your browser by itself; the link is also copied to the clipboard.") }
            fflush(nil)
            let status: Int32
            do {
                status = try AgentLogin.run(preset, store: store(), backend: try backendOptions.make(), image: image, tty: tty) {
                    print($0)
                    fflush(nil)
                }
            } catch { fail(error) }
            if status != 0 { throw ExitCode(status) }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether each agent is signed in, and its config directory.")
        func run() throws {
            for p in AgentPreset.all {
                guard let h = AgentHome(store: store(), agent: p.id) else { continue }
                // Names only: no stored value is read.
                let st = SignInStatus.check(p, store: store(), tokens: AgentToken.defaultStore(store()))
                let state = st.method.map { "signed in (\($0))" } ?? SetupCommand().hint(p)
                print("\(p.id.padding(toLength: 7, withPad: " ", startingAt: 0)) \(state)  \(h.hostDirectory.path) -> \(h.guestPath)")
            }
        }
    }
}

extension Agent {
    struct Token: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Store a long-lived token for an agent (e.g. the output of `claude setup-token`).",
            discussion: """
            Reads the token from standard input without showing it, and keeps it in the macOS \
            Keychain (service io.github.kernel-hunter.mudroom), or on Linux in a 0600 file in \
            Mudroom's data directory. Sessions get it as CLAUDE_CODE_OAUTH_TOKEN (codex: \
            OPENAI_API_KEY, gemini: GEMINI_API_KEY), passed by name: the value is never on a \
            command line. Example: claude setup-token, then mudroom agent token claude.
            """)
        @Argument(help: "claude, codex or gemini.")
        var agent: String = "claude"
        @Flag(help: "Delete the stored token instead.")
        var clear = false

        func run() throws {
            guard let preset = AgentPreset.find(agent) else { fail(MudroomError.invalid("unknown agent \(agent); use claude, codex or gemini")) }
            do {
                if clear {
                    let had = try AgentToken.defaultStore(store()).delete(preset.id)
                    print(had ? "deleted the stored \(preset.id) token" : "no \(preset.id) token was stored")
                    return
                }
                try storeToken(for: preset.id)
            } catch { fail(error) }
        }
    }
}

/// Asks for a token without echo and stores it.
func storeToken(for agent: String) throws {
    let tty = isatty(STDIN_FILENO) == 1
    if tty {
        FileHandle.standardError.write(Data("Paste the token, then press Enter (it shows as dots).\n> ".utf8))
    }
    let raw = tty ? readSecretFromTerminal() : String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    if tty { FileHandle.standardError.write(Data("\n".utf8)) }
    let token = AgentToken.clean(raw)
    if let problem = AgentToken.problem(token, agent: agent) { throw MudroomError.invalid("not stored: \(problem)") }
    let tokens = AgentToken.defaultStore(store())
    try tokens.write(agent, token)
    if agent == "claude" { try? AgentHome(store: store(), agent: "claude")?.seedClaudeOnboarding() }
    let name = AgentToken.variable(for: agent) ?? "the agent's variable"
    print("stored the \(agent) token (\(token.count) characters) in \(tokens.location). Sessions get it as \(name).")
}

/// Reads a pasted secret with echo off. A paste arrives as one burst, so
/// line breaks inside it (a token the terminal wrapped) don't end the
/// input; Enter after a pause does.
func readSecretFromTerminal() -> String {
    var saved = termios()
    guard tcgetattr(STDIN_FILENO, &saved) == 0 else { return readLine() ?? "" }
    var raw = saved
    raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    defer { tcsetattr(STDIN_FILENO, TCSANOW, &saved) }
    var bytes: [UInt8] = []
    while true {
        var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, -1) > 0 else { break }
        var b: UInt8 = 0
        guard read(STDIN_FILENO, &b, 1) == 1 else { break }
        if b == 3 { return "" } // Ctrl-C
        if b == 0x7f || b == 8 {
            if !bytes.isEmpty {
                bytes.removeLast()
                FileHandle.standardError.write(Data("\u{8} \u{8}".utf8))
            }
            continue
        }
        if b == 0x0d || b == 0x0a {
            // More input within a moment means it was part of the paste.
            var q = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            if poll(&q, 1, 300) > 0 { bytes.append(0x0a); continue }
            break
        }
        bytes.append(b)
        // A dot per character, so a paste visibly arrived (the value isn't shown).
        if b >= 0x20 { FileHandle.standardError.write(Data("•".utf8)) }
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Before a session: if the agent isn't signed in yet, say how the code
/// paste works (and that a token avoids it).
/// Claude Code, Codex and Gemini CLI start signed in or not at all:
/// sessions don't stop to ask. Nil when the agent can start (or isn't one
/// of these three).
func signInProblem(agent: String?, command: [String]) -> MudroomError? {
    guard let preset = AgentPreset.matching(agent: agent, command: command), !preset.isMultiProvider else { return nil }
    let status = SignInStatus.check(preset, store: store(), tokens: AgentToken.defaultStore(store()))
    if status.isSignedIn { return nil }
    let how = switch preset.id {
    case "claude": "mudroom agent login claude   (or set CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY)"
    case "codex": HostLogin.forAgent("codex")?.isAvailable == true ? "mudroom agent import codex" : "mudroom agent login codex"
    case "gemini": HostLogin.forAgent("gemini")?.isAvailable == true ? "mudroom agent import gemini" : "mudroom agent login gemini   (or mudroom keys set GEMINI_API_KEY)"
    default: "mudroom setup"
    }
    return .invalid("""
        \(preset.name) isn't signed in yet. Sign in once, then run this again:
          \(how)
        Or add --sign-in-in-session to sign in inside this session.
        """)
}

func printSignInHint(_ session: Session, options: RunOptions) {
    guard let preset = AgentPreset.matching(agent: session.agent, command: session.command),
          let home = AgentHome(store: store(), agent: preset.id), !home.hasCredentials else { return }
    if let name = AgentToken.variable(for: preset.id), options.environmentNames.contains(name) { return }
    if options.tokenStore?.contains(preset.id) == true { return }
    if preset.credential.map(options.environmentNames.contains) == true { return }
    print("\(preset.name) isn't signed in yet. When it asks for a code: \(AuthLinkHandoff.pasteNote)")
    print("The sign-in page opens in your browser on its own. To skip this next time: mudroom agent login \(preset.id)")
}
