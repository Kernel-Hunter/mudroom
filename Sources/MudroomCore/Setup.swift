#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// First-run checks shared by `mudroom setup` and the app's Setup window:
/// the VM runtime, the agent image, the VM network and agent sign-in.
public enum RuntimeSetup {
    public enum State: Sendable, Equatable {
        /// Not installed. `brew` is set when Homebrew can install it.
        case notInstalled(brew: String?)
        /// This machine can't run it (Intel Mac, older macOS).
        case unsupported(String)
        case stopped(executable: String)
        case running(executable: String, version: String)

        public var isReady: Bool { if case .running = self { true } else { false } }
    }

    public static let installCommand = "brew install container"
    public static let projectURL = "https://github.com/apple/container/releases"
    public static let dockerURL = "https://docs.docker.com/get-started/get-docker/"

    public static func brew(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/home/linuxbrew/.linuxbrew/bin/brew"].first(where: isExecutable)
    }

    /// What's there for this backend choice (auto resolves like sessions do).
    public static func detect(_ choice: BackendChoice = Backends.defaultChoice()) -> (BackendChoice, State) {
        let resolved = Backends.resolve(choice)
        switch resolved {
        case .apple, .auto:
            guard Backends.appleContainerSupported else {
                return (.apple, .unsupported("Apple's container runtime needs an Apple-silicon Mac with macOS 26 or later. Install Docker or Podman instead."))
            }
            guard let exe = ProcessRunner.which("container") else { return (.apple, .notInstalled(brew: brew())) }
            let status = try? ProcessRunner.capture(exe, ["system", "status"])
            guard status?.status == 0 else { return (.apple, .stopped(executable: exe)) }
            let out = (try? ProcessRunner.capture(exe, ["--version"]))?.stdout ?? ""
            return (.apple, .running(executable: exe, version: containerVersionLabel(out)))
        case .docker, .podman:
            let name = resolved.rawValue
            guard let exe = ProcessRunner.which(name) else { return (resolved, .notInstalled(brew: nil)) }
            let info = try? ProcessRunner.capture(exe, ["info", "--format", "{{.ServerVersion}}"])
            guard info?.status == 0 else { return (resolved, .stopped(executable: exe)) }
            return (resolved, .running(executable: exe, version: "\(name) \(info!.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
    }

    /// "container CLI version 1.5.0 (build: release, commit: unspeci)" ->
    /// "container 1.5.0".
    public static func containerVersionLabel(_ output: String) -> String {
        if let r = output.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) {
            return "container \(output[r])"
        }
        return "container"
    }

    /// `brew install container`, output streamed line by line.
    public static func install(brew: String, onLine: @escaping @Sendable (String) -> Void) throws {
        let r = try ProcessRunner.stream(brew, ["install", "container"], environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"], onLine: onLine)
        if r.status != 0 { throw MudroomError.commandFailed(installCommand, r.status, r.tail.suffix(8).joined(separator: "\n")) }
    }

    /// Starts the runtime. For Apple's, `container system start` with the
    /// recommended kernel installed without a prompt.
    public static func start(_ choice: BackendChoice, executable: String, onLine: @escaping @Sendable (String) -> Void) throws {
        switch choice {
        case .apple, .auto:
            let help = (try? ProcessRunner.capture(executable, ["system", "start", "--help"]))?.stdout ?? ""
            let args = NetworkRepair.startArguments(help: help)
            let r = try ProcessRunner.stream(executable, args, onLine: onLine)
            if r.status != 0 { throw MudroomError.commandFailed("container " + args.joined(separator: " "), r.status, r.tail.suffix(8).joined(separator: "\n")) }
        case .docker:
            #if os(macOS)
            _ = try? ProcessRunner.capture("/usr/bin/open", ["-a", "Docker"])
            onLine("opened Docker Desktop; waiting for it to start")
            for _ in 0..<60 {
                if (try? ProcessRunner.capture(executable, ["info"]))?.status == 0 { return }
                Thread.sleep(forTimeInterval: 2)
            }
            throw MudroomError.backendUnavailable("Docker didn't start within two minutes")
            #else
            throw MudroomError.backendUnavailable("start the Docker daemon, e.g. `sudo systemctl start docker`")
            #endif
        case .podman:
            let r = try ProcessRunner.stream(executable, ["machine", "start"], onLine: onLine)
            if r.status != 0 { throw MudroomError.commandFailed("podman machine start", r.status, r.tail.joined(separator: "\n")) }
        }
    }
}

extension AgentBaseImage {
    /// Label on images built by Mudroom: a hash of the Containerfile they
    /// were built from, so an image from an older version can be spotted.
    public static let hashLabel = "io.github.kernel-hunter.mudroom.containerfile"

    public static var containerfileHash: String {
        SHA256.hash(data: Data(containerfile.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public enum Status: Sendable, Equatable {
        case missing
        /// Built from a different Containerfile (an older Mudroom).
        case outdated
        case current
    }

    public static func status(labels: [String: String]?) -> Status {
        guard let labels else { return .missing }
        return labels[hashLabel] == containerfileHash ? .current : .outdated
    }

    /// Build progress from BuildKit's plain output ("#7 [3/5] RUN ...",
    /// "#8 [linux/arm64 stage-0 2/6] RUN ..."): (step, total), or nil.
    public static func progress(_ line: String) -> (Int, Int)? {
        guard let r = line.range(of: #"\[(?:[^\]]*\s)?\d+/\d+\]"#, options: .regularExpression) else { return nil }
        let inner = line[r].dropFirst().dropLast()
        let last = inner.split(separator: " ").last ?? inner[...]
        let nums = last.split(separator: "/").compactMap { Int($0) }
        guard nums.count == 2, nums[1] > 0, nums[0] <= nums[1] else { return nil }
        return (nums[0], nums[1])
    }

    /// Writes the built-in Containerfile to a temporary directory and
    /// builds it with the hash label. `onLine` gets the build output.
    public static func build(backend: SandboxBackend, tag: String = tag, onLine: @escaping @Sendable (String) -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mudroom-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Containerfile")
        try containerfile.write(to: file, atomically: true, encoding: .utf8)
        try backend.buildImage(containerfile: file, context: dir, tag: tag, labels: [hashLabel: containerfileHash], onLine: onLine)
    }

    /// Finds `Labels` objects anywhere in `image inspect` JSON.
    public static func parseLabels(_ data: Data) -> [String: String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = json as? [Any], arr.isEmpty { return nil }
        var found: [String: String] = [:]
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                for (k, x) in d {
                    if k == "Labels" || k == "labels", let l = x as? [String: Any] {
                        for (lk, lv) in l { if let s = lv as? String { found[lk] = s } }
                    } else {
                        walk(x)
                    }
                }
            } else if let a = v as? [Any] {
                a.forEach(walk)
            }
        }
        walk(json)
        return found
    }
}

/// Whether each agent can start without asking anyone to sign in.
public struct SignInStatus: Sendable, Equatable, Identifiable {
    public var id: String { agent }
    public var agent: String
    /// How it is signed in, or nil if it isn't.
    public var method: String?
    public var isSignedIn: Bool { method != nil }

    /// Works out the status from Mudroom's own files and stores. Reads no
    /// secret values.
    public static func check(_ preset: AgentPreset, store: SessionStore, tokens: AgentTokenStore,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> SignInStatus {
        let stored = Set(APIKeys.storedNames(tokens))
        func have(_ name: String) -> Bool { stored.contains(name) || !(environment[name] ?? "").isEmpty }
        let home = AgentHome(store: store, agent: preset.id)
        var method: String?
        switch preset.id {
        case "claude":
            if tokens.contains("claude") { method = "Claude account" }
            else if !(environment["CLAUDE_CODE_OAUTH_TOKEN"] ?? "").isEmpty { method = "token from your shell" }
            else if home?.hasCredentials == true { method = "signed in inside the VM" }
            else if have("ANTHROPIC_API_KEY") { method = "API key" }
        case "codex":
            if home?.hasCredentials == true { method = "ChatGPT login" }
            else if tokens.contains("codex") || have("OPENAI_API_KEY") { method = "API key" }
        case "gemini":
            if home?.hasCredentials == true { method = "Google login" }
            else if tokens.contains("gemini") || have("GEMINI_API_KEY") { method = "API key" }
        default:
            let names = APIKeys.providers.map(\.variable).filter(have)
            if let first = names.first {
                method = names.count == 1 ? "\(APIKeys.provider(first)?.name ?? first) key" : "\(names.count) API keys"
            }
        }
        return SignInStatus(agent: preset.id, method: method)
    }
}
