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

var stdinIsTTY: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }

/// Asks a yes/no question; Enter means yes. Without a terminal, `yes`
/// decides (and nothing is asked).
func confirm(_ question: String, yes: Bool) -> Bool {
    if yes { return true }
    guard stdinIsTTY else { return false }
    print("\(question) [Y/n] ", terminator: "")
    fflush(nil)
    let a = (readLine() ?? "n").trimmingCharacters(in: .whitespaces).lowercased()
    return a.isEmpty || a == "y" || a == "yes"
}

func say(_ s: String) {
    print(s)
    fflush(nil)
}

struct SetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Get everything ready: VM runtime, agent image, VM network, sign-in.",
        discussion: """
        Checks each step and fixes what it can: installs Apple's `container` with Homebrew \
        and starts it (with its recommended kernel), builds the agent image, checks that a VM \
        reaches Mudroom's proxy (and restarts the container system if not), then signs agents in. \
        Run it again any time; steps that are done are skipped.
        """)

    @Flag(name: .shortAndLong, help: "Do every fix without asking (install, start, build, repair).")
    var yes = false

    @Flag(help: "Stop before signing agents in.")
    var noSignIn = false

    @Flag(help: "Only report what is missing; change nothing.")
    var check = false

    @Flag(help: "Restart the container system even if the network check passes.")
    var repairNetwork = false

    @OptionGroup var backendOptions: BackendOptions

    func run() throws {
        var problems = 0
        let choice = backendOptions.backend ?? Backends.defaultChoice()

        // 1. Runtime
        say("1. VM runtime")
        var (resolved, state) = RuntimeSetup.detect(choice)
        switch state {
        case .unsupported(let why):
            say("   \(why)")
            throw ExitCode(1)
        case .notInstalled(let brew):
            if resolved == .apple, let brew, !check,
               confirm("   Apple's container runtime isn't installed. Install it with Homebrew now?", yes: yes) {
                say("   running \(RuntimeSetup.installCommand)")
                do {
                    try RuntimeSetup.install(brew: brew) { say("   | \($0)") }
                } catch { fail(error) }
                (resolved, state) = RuntimeSetup.detect(choice)
            } else {
                if resolved == .apple {
                    say("   not installed. Install it with `\(RuntimeSetup.installCommand)`, or get the installer from \(RuntimeSetup.projectURL)")
                } else {
                    say("   \(resolved.rawValue) is not installed. See \(RuntimeSetup.dockerURL)")
                }
                throw ExitCode(1)
            }
        default:
            break
        }
        if case .stopped(let exe) = state {
            if !check, confirm("   \(resolved == .apple ? "container services are" : "\(resolved.rawValue) is") not running. Start now?", yes: yes) {
                do {
                    try RuntimeSetup.start(resolved, executable: exe) { say("   | \($0)") }
                } catch { fail(error) }
                (resolved, state) = RuntimeSetup.detect(choice)
            }
        }
        guard case .running(_, let version) = state else {
            switch resolved {
            case .docker: say("   not running. Start Docker Desktop (or the Docker daemon), or run `mudroom setup --yes`.")
            case .podman: say("   not running. Start it with `podman machine start`, or run `mudroom setup --yes`.")
            case .apple, .auto: say("   not running. Start it with `container system start --enable-kernel-install`, or run `mudroom setup --yes`.")
            }
            throw ExitCode(1)
        }
        say("   ok: \(version), running")

        let backend: SandboxBackend
        do { backend = try backendOptions.make() } catch { fail(error) }

        // 2. Image
        say("2. Agent image")
        let status = AgentBaseImage.status(labels: backend.imageLabels(AgentBaseImage.tag))
        switch status {
        case .current:
            say("   ok: \(AgentBaseImage.tag) is up to date")
        case .missing, .outdated:
            let what = status == .missing ? "isn't built yet" : "was built by an older Mudroom"
            if !check, confirm("   \(AgentBaseImage.tag) \(what). Build it now? (a few minutes, about 1.5 GB)", yes: yes) {
                do {
                    try buildImageWithProgress(backend)
                    say("   ok: built \(AgentBaseImage.tag)")
                } catch { fail(error) }
            } else {
                say("   \(what). Build it with `mudroom image build`.")
                problems += 1
            }
        }

        // 3. Network
        say("3. VM network")
        if AgentBaseImage.status(labels: backend.imageLabels(AgentBaseImage.tag)) == .missing {
            say("   skipped: needs the agent image")
            problems += 1
        } else {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mudroom-probe-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            say("   checking that a VM reaches Mudroom's proxy (a few seconds)")
            var result = NetworkProbe.run(backend: backend, scratch: scratch)
            NetworkProbe.remember(result, store: store())
            say("   \(result.isOK ? "ok: " : "")\(result.summary)")
            var offered = false
            if (result.needsRepair || repairNetwork) && !check {
                if backend.name == "apple-container",
                   confirm("   Repair it? This restarts Apple's container system.", yes: yes || repairNetwork) {
                    result = repairAndProbe(backend)
                    say("   \(result.isOK ? "ok: " : "still failing: ")\(result.summary)")
                    offered = true
                } else if backend.name != "apple-container" {
                    say("   restart \(backend.name) (Docker Desktop: Troubleshoot > Restart) and run setup again")
                    offered = true
                }
            }
            // --check, no terminal to ask in, or the repair was declined.
            if result.needsRepair && !offered {
                say(backend.name == "apple-container"
                    ? "   fix: mudroom setup --repair-network   (restarts Apple's container system, about 10 seconds)"
                    : "   fix: restart \(backend.name) (Docker Desktop: Troubleshoot > Restart) and run setup again")
            }
            if !result.isOK { problems += 1 }
        }

        // 4. Sign in
        say("4. Sign in")
        let tokens = AgentToken.defaultStore(store())
        let agents = AgentPreset.all
        var anySignedIn = false
        for p in agents {
            var st = SignInStatus.check(p, store: store(), tokens: tokens)
            if !st.isSignedIn, !noSignIn, !check, stdinIsTTY, p.id == "claude" || p.id == "codex" || p.id == "gemini" {
                if confirm("   \(p.name) isn't signed in. Sign in now?", yes: false) {
                    signIn(p)
                    st = SignInStatus.check(p, store: store(), tokens: tokens)
                }
            }
            anySignedIn = anySignedIn || st.isSignedIn
            say("   \(p.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(st.method.map { "signed in (\($0))" } ?? hint(p))")
        }
        let keys = APIKeys.storedNames(tokens)
        say("   API keys     \(keys.isEmpty ? "none stored. Add one with `mudroom keys set OPENROUTER_API_KEY` (or any provider)" : keys.joined(separator: ", "))")
        let signInMissing = !anySignedIn
        if signInMissing && !noSignIn { problems += 1 }

        if problems == 0 && signInMissing {
            say("\nThe runtime, image and network are ready. Sign an agent in when you want to: mudroom setup, or Setup in the app.")
        } else {
            say(problems == 0 ? "\nAll set. Start a session in the app, or: mudroom run <project> -- claude --dangerously-skip-permissions"
                              : "\n\(problems) \(problems == 1 ? "step still needs" : "steps still need") attention.")
        }
        if problems > 0 { throw ExitCode(2) }
    }

    func hint(_ p: AgentPreset) -> String {
        switch p.id {
        case "claude": "not signed in: mudroom agent login claude"
        case "codex": HostLogin.forAgent("codex")?.isAvailable == true ? "not signed in: mudroom agent import codex" : "not signed in: mudroom agent login codex"
        case "gemini": HostLogin.forAgent("gemini")?.isAvailable == true ? "not signed in: mudroom agent import gemini" : "not signed in: mudroom agent login gemini, or mudroom keys set GEMINI_API_KEY"
        case "aider": "needs an API key (mudroom keys set OPENROUTER_API_KEY, or another provider) or a local model (mudroom network local-models on, then aider --model ollama_chat/<model>)"
        default: "needs an API key (mudroom keys set OPENROUTER_API_KEY, or another provider) or local models (mudroom network local-models on)"
        }
    }

    func signIn(_ p: AgentPreset) {
        switch p.id {
        case "claude":
            if let claude = HostCLI.findClaude(), signInClaudeWithHostCLI(claude) { return }
            _ = try? runVMLogin(p)
        case "codex", "gemini":
            if let login = HostLogin.forAgent(p.id), login.isAvailable,
               confirm("   Copy your existing sign-in from \(login.displayPath) into Mudroom? (a copy; the original isn't changed)", yes: false) {
                do {
                    try importLogin(p.id)
                    return
                } catch { say("   couldn't copy it: \(error)") }
            }
            _ = try? runVMLogin(p)
        default:
            break
        }
    }
}

/// Builds the agent image, printing one line per build step.
func buildImageWithProgress(_ backend: SandboxBackend) throws {
    let last = LockedCounter()
    try AgentBaseImage.build(backend: backend) { line in
        if let (step, total) = AgentBaseImage.progress(line), last.advance(to: step) {
            let what = line.replacingOccurrences(of: #"^#\d+\s+\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
            say("   step \(step)/\(total): \(what.prefix(90))")
        } else if line.lowercased().contains("error") {
            say("   | \(line)")
        }
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    /// True when `n` is a new, higher step.
    func advance(to n: Int) -> Bool {
        lock.withLock {
            guard n > value else { return false }
            value = n
            return true
        }
    }
}

/// Restarts the container system and probes again.
func repairAndProbe(_ backend: SandboxBackend) -> NetworkProbe.Result {
    guard let exe = ProcessRunner.which("container") else { return .failed("container CLI not found") }
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mudroom-probe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    do {
        let r = try NetworkRepair.repair(run: NetworkRepair.containerRunner(exe), progress: { step in
            switch step {
            case .stopping: say("   stopping the container system")
            case .starting: say("   starting it again")
            case .recreatingNetwork: say("   recreating Mudroom's VM network")
            case .checking: say("   checking again")
            }
        }, probe: { NetworkProbe.run(backend: AppleContainerBackend(), scratch: scratch) })
        NetworkProbe.remember(r, store: store())
        return r
    } catch {
        return .failed("\(error)")
    }
}

/// `claude setup-token` on this machine: the browser opens, the token is
/// picked out of claude's output and stored. Returns true on success.
func signInClaudeWithHostCLI(_ claude: String) -> Bool {
    say("Signing in with the claude CLI on this machine. Your browser opens; approve the request there.")
    say("If the page shows a code instead, paste it here and press Enter.")
    let signIn: ClaudeTokenSignIn
    do { signIn = try ClaudeTokenSignIn(claude: claude) } catch {
        say("couldn't run claude setup-token: \(error)")
        return false
    }
    let finished = LockedFlag()
    // claude's own output, readable and with the token hidden.
    let printer = Thread {
        var shown = Set<String>()
        while !finished.value {
            for l in signIn.lines(limit: 40) where shown.insert(l).inserted { say("  claude: \(l)") }
            usleep(300_000)
        }
    }
    printer.start()
    // A code typed or pasted here goes to claude.
    let reader = Thread {
        while !finished.value {
            var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 200) > 0 else { continue }
            guard let line = readLine() else { return }
            let code = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty { signIn.sendCode(code) }
        }
    }
    if stdinIsTTY { reader.start() }
    let token = signIn.waitForToken()
    finished.value = true
    usleep(350_000)
    guard let token else {
        say("claude setup-token finished without a token.")
        return false
    }
    do {
        try saveClaudeToken(token)
        return true
    } catch {
        say("couldn't store the token: \(error)")
        return false
    }
}

func saveClaudeToken(_ raw: String) throws {
    let token = AgentToken.clean(raw)
    if let problem = AgentToken.problem(token, agent: "claude") { throw MudroomError.invalid(problem) }
    let tokens = AgentToken.defaultStore(store())
    try tokens.write("claude", token)
    try AgentHome(store: store(), agent: "claude")?.seedClaudeOnboarding()
    say("signed in: stored a Claude token (\(token.count) characters) in \(tokens.location). Sessions get it as CLAUDE_CODE_OAUTH_TOKEN.")
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

func importLogin(_ agent: String) throws {
    guard let login = HostLogin.forAgent(agent), let home = AgentHome(store: store(), agent: agent) else {
        throw MudroomError.invalid("there is nothing to import for \(agent); use codex or gemini")
    }
    guard login.isAvailable else { throw MudroomError.invalid("no sign-in found at \(login.displayPath)") }
    let copied = try login.importInto(home)
    say("copied \(copied.joined(separator: ", ")) from \(login.sourceDirectory.path) to \(home.hostDirectory.path)")
    if agent == "codex" {
        say("If you sign out or in again on this Mac later, run `mudroom agent import codex` again.")
    }
}

func runVMLogin(_ preset: AgentPreset) throws -> Int32 {
    let tty = stdinIsTTY
    if preset.id == "gemini" { say("Pick \"Login with Google\", finish in your browser, then type /quit.") }
    if tty { say("The sign-in page opens in your browser by itself; the link is also copied to the clipboard.") }
    return try AgentLogin.run(preset, store: store(), backend: try Backends.make(Backends.defaultChoice()), tty: tty) { say($0) }
}

struct Keys: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "API keys for model providers (OpenRouter, OpenAI, DeepSeek, Groq...).",
        discussion: """
        Kept in the macOS Keychain (Linux: 0600 files in Mudroom's data directory) and passed \
        to sessions by variable name, never on a command line. Setting a provider's key also \
        allows its API host in locked mode for agents that use many providers (aider, opencode). \
        Known: \(APIKeys.providers.map(\.variable).joined(separator: ", ")); any other NAME works too.
        """,
        subcommands: [ListKeys.self, SetKey.self, RemoveKey.self],
        defaultSubcommand: ListKeys.self)

    struct ListKeys: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List stored keys (names only).")
        func run() throws {
            let names = APIKeys.storedNames(AgentToken.defaultStore(store()))
            if names.isEmpty { print("no API keys stored. Add one: mudroom keys set OPENROUTER_API_KEY") }
            for n in names {
                let p = APIKeys.provider(n)
                print("\(n.padding(toLength: 22, withPad: " ", startingAt: 0)) \(p?.name ?? "custom")\(p.map { "  allows \($0.hosts.joined(separator: ", "))" } ?? "")")
            }
        }
    }

    struct SetKey: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set", abstract: "Store a key. Reads it from the terminal (shown as dots) or standard input.")
        @Argument(help: "Variable name, e.g. OPENROUTER_API_KEY.")
        var name: String

        func run() throws {
            let n = name.uppercased()
            guard APIKeys.isValidName(n) else { fail(MudroomError.invalid("\(name) is not a usable variable name (A-Z, 0-9 and _)")) }
            let tty = isatty(STDIN_FILENO) == 1
            if tty { FileHandle.standardError.write(Data("Paste the \(n) value and press Enter: ".utf8)) }
            let raw = tty ? readSecretFromTerminal() : String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            if tty { FileHandle.standardError.write(Data("\n".utf8)) }
            let tokens = AgentToken.defaultStore(store())
            do {
                try APIKeys.write(n, raw, to: tokens)
            } catch { fail(error) }
            let hosts = APIKeys.provider(n)?.hosts ?? []
            print("stored \(n) in \(tokens.location)\(hosts.isEmpty ? "" : "; allows \(hosts.joined(separator: ", ")) for aider, opencode and custom commands")")
        }
    }

    struct RemoveKey: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Delete a stored key.")
        @Argument var name: String
        func run() throws {
            do {
                let had = try APIKeys.delete(name.uppercased(), from: AgentToken.defaultStore(store()))
                print(had ? "removed \(name.uppercased())" : "\(name.uppercased()) was not stored")
            } catch { fail(error) }
        }
    }
}

extension Agent {
    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy your existing Codex or Gemini CLI sign-in on this machine into Mudroom.",
            discussion: "codex: ~/.codex/auth.json. gemini: ~/.gemini/oauth_creds.json. A copy, kept in Mudroom's agent directory; the original is not changed or mounted.")
        @Argument(help: "codex or gemini.")
        var agent: String

        func run() throws {
            do { try importLogin(agent.lowercased()) } catch { fail(error) }
        }
    }
}

extension NetworkCommand {
    struct Probe: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check that a VM can reach Mudroom's proxy on this machine (a few seconds).")
        @Flag(help: "If it fails, restart the container system and check again.")
        var repair = false
        @OptionGroup var backendOptions: BackendOptions

        func run() throws {
            do {
                let backend = try backendOptions.make()
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mudroom-probe-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: scratch) }
                say("checking that a VM reaches Mudroom's proxy (a few seconds)")
                var r = NetworkProbe.run(backend: backend, scratch: scratch)
                NetworkProbe.remember(r, store: store())
                print(r.isOK ? "ok: \(r.summary)" : "FAILED: \(r.summary)")
                if !r.isOK, repair, backend.name == "apple-container" {
                    r = repairAndProbe(backend)
                    print(r.isOK ? "repaired: \(r.summary)" : "still failing: \(r.summary)")
                }
                if !r.isOK { throw ExitCode(3) }
            } catch let e as ExitCode { throw e } catch { fail(error) }
        }
    }
}
