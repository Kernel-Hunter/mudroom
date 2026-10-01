import AppKit
import Foundation
import MudroomCore
import Observation

/// State behind the Setup window: VM runtime, agent image, VM network and
/// sign-in. Slow checks run off the main actor; results land here.
@MainActor
@Observable
final class SetupModel {
    let store: SessionStore
    let tokens: AgentTokenStore
    let choice: BackendChoice

    // 1. Runtime
    private(set) var resolvedBackend: BackendChoice = .apple
    private(set) var runtime: RuntimeSetup.State?
    private(set) var runtimeBusy = false
    private(set) var runtimeLog: [String] = []
    private(set) var runtimeError: String?

    // 2. Image
    private(set) var image: AgentBaseImage.Status?
    private(set) var imageBusy = false
    private(set) var imageProgress: Double = 0
    private(set) var imageStep = ""
    private(set) var imageError: String?

    // 3. Network
    private(set) var network: NetworkProbe.Result?
    private(set) var networkBusy = false
    private(set) var networkStep: String?
    private(set) var networkError: String?

    // 4. Sign in
    private(set) var signIn: [String: SignInStatus] = [:]
    private(set) var keys: Set<String> = []
    private(set) var hostClaude: String?
    private(set) var keyError: String?
    var login: LoginConsole?

    /// The card to scroll to when the window opens.
    var focus: String?
    private(set) var checking = false
    private(set) var hasChecked = false

    init(store: SessionStore) {
        self.store = store
        tokens = AgentToken.defaultStore(store)
        choice = Backends.defaultChoice()
    }

    static let signInAgents: [AgentPreset] = [.claude, .codex, .gemini]

    var runtimeReady: Bool { runtime?.isReady == true }
    var imageReady: Bool { image == .current }
    var networkReady: Bool { network?.isOK == true }
    var anySignedIn: Bool { signIn.values.contains { $0.isSignedIn } }

    /// One line per step that isn't done, in order.
    var problems: [String] {
        guard hasChecked else { return [] }
        var p: [String] = []
        if !runtimeReady { p.append("The VM runtime isn't running") }
        else if !imageReady { p.append(image == .outdated ? "The agent image is out of date" : "The agent image isn't built") }
        else if !networkReady { p.append("The VM can't reach the network proxy") }
        if !anySignedIn { p.append("No agent is signed in") }
        return p
    }

    var allGreen: Bool { hasChecked && problems.isEmpty }

    func status(_ agent: String) -> SignInStatus? { signIn[agent] }

    // MARK: Checks

    /// Checks everything. `probe` also starts a small VM to test the network.
    func refresh(probe: Bool = true) async {
        guard !checking else { return }
        checking = true
        defer {
            checking = false
            hasChecked = true
        }
        let choice = self.choice
        let (resolved, state) = await Task.detached { RuntimeSetup.detect(choice) }.value
        resolvedBackend = resolved
        runtime = state
        refreshSignIn()
        guard state.isReady, let backend = try? Backends.make(choice) else {
            image = nil
            network = nil
            return
        }
        image = await Task.detached { AgentBaseImage.status(labels: backend.imageLabels(AgentBaseImage.tag)) }.value
        if probe, image != .missing { await runProbe(backend) }
    }

    func refreshSignIn() {
        hostClaude = HostCLI.findClaude(loginShellPath: { nil })
        var s: [String: SignInStatus] = [:]
        for p in AgentPreset.all { s[p.id] = SignInStatus.check(p, store: store, tokens: tokens) }
        signIn = s
        keys = Set(APIKeys.storedNames(tokens))
    }

    private func runProbe(_ backend: SandboxBackend) async {
        networkBusy = true
        networkStep = "Checking that a VM reaches the proxy…"
        let store = self.store
        let r = await Task.detached { () -> NetworkProbe.Result in
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mudroom-probe-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let r = NetworkProbe.run(backend: backend, scratch: scratch)
            NetworkProbe.remember(r, store: store)
            return r
        }.value
        network = r
        networkBusy = false
        networkStep = nil
    }

    func checkNetwork() async {
        guard let backend = try? Backends.make(choice) else { return }
        networkError = nil
        await runProbe(backend)
    }

    // MARK: Runtime

    func installRuntime() async {
        guard case .notInstalled(let brew?) = runtime else { return }
        runtimeBusy = true
        runtimeError = nil
        runtimeLog = ["$ \(RuntimeSetup.installCommand)"]
        let result = await Task.detached { [weak self] () -> String? in
            do {
                try RuntimeSetup.install(brew: brew) { line in Task { @MainActor in self?.appendRuntime(line) } }
                return nil
            } catch { return "\(error)" }
        }.value
        runtimeBusy = false
        runtimeError = result
        await refresh(probe: false)
        if runtimeError == nil, case .stopped = runtime { await startRuntime() }
    }

    func startRuntime() async {
        guard case .stopped(let exe) = runtime else { return }
        runtimeBusy = true
        runtimeError = nil
        runtimeLog = []
        let resolved = resolvedBackend
        let result = await Task.detached { [weak self] () -> String? in
            do {
                try RuntimeSetup.start(resolved, executable: exe) { line in Task { @MainActor in self?.appendRuntime(line) } }
                return nil
            } catch { return "\(error)" }
        }.value
        runtimeBusy = false
        runtimeError = result
        await refresh()
    }

    private func appendRuntime(_ line: String) {
        runtimeLog.append(line)
        if runtimeLog.count > 200 { runtimeLog.removeFirst(runtimeLog.count - 200) }
    }

    // MARK: Image

    func buildImage() async {
        guard let backend = try? Backends.make(choice) else { return }
        imageBusy = true
        imageError = nil
        imageProgress = 0.02
        imageStep = "Starting the build…"
        let result = await Task.detached { [weak self] () -> String? in
            do {
                try AgentBaseImage.build(backend: backend) { line in
                    Task { @MainActor in self?.buildLine(line) }
                }
                return nil
            } catch { return "\(error)" }
        }.value
        imageBusy = false
        imageError = result
        if result == nil { imageProgress = 1 }
        await refresh()
    }

    private func buildLine(_ line: String) {
        if let (step, total) = AgentBaseImage.progress(line) {
            let p = (Double(step) - 0.5) / Double(total)
            if p > imageProgress {
                imageProgress = p
                let what = line.replacingOccurrences(of: #"^#\d+\s+\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
                imageStep = "Step \(step) of \(total): \(what.prefix(80))"
            }
        } else if line.contains("exporting") || line.contains("sending tarball") || line.contains("unpacking") {
            imageStep = "Saving the image…"
            imageProgress = max(imageProgress, 0.95)
        }
    }

    // MARK: Network repair

    func repairNetwork(force: Bool) async {
        guard let exe = ProcessRunner.which("container") else {
            networkError = "The container CLI wasn't found."
            return
        }
        networkBusy = true
        networkError = nil
        let store = self.store
        let result = await Task.detached { [weak self] () -> Result<NetworkProbe.Result, Error> in
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mudroom-probe-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            return Result {
                let r = try NetworkRepair.repair(run: NetworkRepair.containerRunner(exe), force: force, progress: { step in
                    let text: String = switch step {
                    case .stopping: "Stopping the container system…"
                    case .starting: "Starting it again…"
                    case .recreatingNetwork: "Recreating Mudroom's VM network…"
                    case .checking: "Checking again…"
                    }
                    Task { @MainActor in self?.networkStep = text }
                }, probe: { NetworkProbe.run(backend: AppleContainerBackend(), scratch: scratch) })
                NetworkProbe.remember(r, store: store)
                return r
            }
        }.value
        networkBusy = false
        networkStep = nil
        switch result {
        case .success(let r): network = r
        case .failure(let e): networkError = "\(e)"
        }
    }

    /// The probe a new session runs first. Repairable failures come back
    /// as such; anything else lets the session start (and report).
    func probeBeforeSession() async -> NetworkProbe.Result {
        guard let backend = try? Backends.make(choice) else { return .ok(proxy: "none") }
        let store = self.store
        let r = await Task.detached { NetworkProbe.check(backend: backend, store: store) }.value
        network = r
        return r
    }

    // MARK: Sign in

    func signInClaudeWithAccount() {
        guard let claude = HostCLI.findClaude() else { return }
        login?.cancel()
        login = LoginConsole.claudeHost(claude: claude, model: self)
    }

    func signInInVM(_ agent: String) {
        login?.cancel()
        login = LoginConsole.vm(agent: agent, model: self)
    }

    func importLogin(_ agent: String) {
        guard let source = HostLogin.forAgent(agent), let home = AgentHome(store: store, agent: agent) else { return }
        do {
            try source.importInto(home)
            keyError = nil
        } catch {
            keyError = "Couldn't copy the \(agent) sign-in: \(error)"
        }
        refreshSignIn()
    }

    func signOut(_ agent: String) {
        if agent == "claude", tokens.contains("claude") {
            _ = HelperCLI.run(["agent", "token", "claude", "--clear"])
        }
        if let home = AgentHome(store: store, agent: agent) {
            for f in home.credentialFiles { try? FileManager.default.removeItem(at: home.hostDirectory.appendingPathComponent(f)) }
        }
        refreshSignIn()
    }

    /// Stores the token via the bundled CLI, so the Keychain item belongs
    /// to the program that reads it when a session starts.
    func storeClaudeToken(_ token: String) -> String? {
        let r = HelperCLI.run(["agent", "token", "claude"], input: token)
        if r.status != 0 { return r.output.isEmpty ? "the mudroom tool couldn't store the token" : r.output }
        try? AgentHome(store: store, agent: "claude")?.seedClaudeOnboarding()
        refreshSignIn()
        return nil
    }

    func saveKey(_ name: String, _ value: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).uppercased()
        guard APIKeys.isValidName(n) else {
            keyError = "\(name) isn't a usable variable name (A-Z, 0-9 and _)."
            return false
        }
        let r = HelperCLI.run(["keys", "set", n], input: value)
        keyError = r.status == 0 ? nil : (r.output.isEmpty ? "Couldn't store \(n)." : r.output)
        refreshSignIn()
        return r.status == 0
    }

    func removeKey(_ name: String) {
        let r = HelperCLI.run(["keys", "remove", name])
        keyError = r.status == 0 ? nil : r.output
        refreshSignIn()
    }
}

/// Runs the `mudroom` tool bundled with the app.
enum HelperCLI {
    struct Output {
        var status: Int32
        var output: String
    }

    static func run(_ args: [String], input: String? = nil) -> Output {
        guard let cli = TerminalLauncher.cliURL() else { return Output(status: 127, output: "the mudroom tool wasn't found inside the app") }
        let p = Process()
        p.executableURL = cli
        p.arguments = args
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe
        do { try p.run() } catch { return Output(status: 127, output: "\(error)") }
        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = ConsoleText.redact(String(decoding: data, as: UTF8.self))
            .replacingOccurrences(of: "mudroom: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Output(status: p.terminationStatus, output: text)
    }

    /// Path of the bundled tool, for the in-VM login.
    static var path: String? { TerminalLauncher.cliURL()?.path }
}

/// A sign-in in progress: claude setup-token on the Mac, or an agent's own
/// login inside a VM (through `mudroom agent login`). Shows readable output
/// (tokens hidden), any device code and link, and takes a pasted code.
@MainActor
@Observable
final class LoginConsole {
    enum Kind { case claudeHost, vm }

    let agent: String
    let kind: Kind
    private(set) var lines: [String] = []
    private(set) var links: [String] = []
    private(set) var deviceCode: String?
    private(set) var finished = false
    private(set) var succeeded = false
    private(set) var error: String?
    var code = ""

    private var pty: PtyProcess?
    private var claude: ClaudeTokenSignIn?
    private var timer: Timer?
    private var openedLink = false
    private weak var model: SetupModel?

    private init(agent: String, kind: Kind, model: SetupModel) {
        self.agent = agent
        self.kind = kind
        self.model = model
    }

    static func claudeHost(claude path: String, model: SetupModel) -> LoginConsole {
        let c = LoginConsole(agent: "claude", kind: .claudeHost, model: model)
        do {
            let s = try ClaudeTokenSignIn(claude: path)
            c.claude = s
            c.pty = s.pty
            c.startPolling()
            Task.detached {
                let token = s.waitForToken()
                await MainActor.run { c.claudeFinished(token) }
            }
        } catch {
            c.fail("Couldn't run claude setup-token: \(error)")
        }
        return c
    }

    static func vm(agent: String, model: SetupModel) -> LoginConsole {
        let c = LoginConsole(agent: agent, kind: .vm, model: model)
        guard let cli = HelperCLI.path else {
            c.fail("The mudroom tool wasn't found inside the app.")
            return c
        }
        do {
            let p = try PtyProcess(cli, ["agent", "login", agent, "--in-vm"])
            c.pty = p
            c.startPolling()
            Task.detached {
                let status = p.wait()
                await MainActor.run { c.vmFinished(status) }
            }
        } catch {
            c.fail("Couldn't start the sign-in: \(error)")
        }
        return c
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard let pty else { return }
        let raw = pty.allOutput
        lines = ConsoleText.lines(raw, limit: 8)
        let text = String(decoding: raw, as: UTF8.self)
        links = ConsoleText.links(text).filter { AuthLinkHandoff.prepare($0) != nil }
        deviceCode = agent == "codex" ? ConsoleText.deviceCode(text) : nil
        // Device-code pages aren't handed over through BROWSER; open them here.
        if kind == .vm, agent == "codex", !openedLink, let link = links.first, let url = AuthLinkHandoff.prepare(link) {
            openedLink = true
            NSWorkspace.shared.open(url)
        }
    }

    func openLink() {
        guard let l = links.last, let url = AuthLinkHandoff.prepare(l) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Sends the typed code (or just Enter when empty).
    func sendCode() {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        code = ""
        if let claude { claude.sendCode(c) } else { pty?.sendLine(c) }
    }

    func cancel() {
        timer?.invalidate()
        claude?.cancel()
        pty?.terminate()
        finished = true
    }

    private func claudeFinished(_ token: String?) {
        poll()
        timer?.invalidate()
        finished = true
        guard let token else {
            if error == nil { error = "claude setup-token ended without a token. Try again, or sign in inside the VM." }
            return
        }
        if let problem = model?.storeClaudeToken(token) {
            error = "Couldn't store the token: \(problem)"
        } else {
            succeeded = true
        }
    }

    private func vmFinished(_ status: Int32) {
        poll()
        timer?.invalidate()
        finished = true
        model?.refreshSignIn()
        succeeded = model?.status(agent)?.isSignedIn == true
        if !succeeded && error == nil {
            error = status == 0 ? "The sign-in finished, but no login was saved." : "The sign-in stopped (status \(status))."
        }
    }

    private func fail(_ message: String) {
        error = message
        finished = true
    }
}
