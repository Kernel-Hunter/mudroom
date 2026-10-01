import Foundation

/// Which sandbox backend to use.
public enum BackendChoice: String, Sendable, CaseIterable {
    /// Apple `container` on Apple-silicon macOS 26+ when it's installed,
    /// otherwise Docker, otherwise Podman.
    case auto
    /// Apple's `container` CLI: one lightweight VM per session.
    case apple
    case docker
    case podman
}

extension BackendChoice {
    /// The choice for a backend's `name` ("apple-container" is apple).
    public init?(backendName: String) {
        self.init(rawValue: backendName == "apple-container" ? "apple" : backendName)
    }
}

public enum Backends {
    /// `$MUDROOM_BACKEND`, or auto.
    public static func defaultChoice(_ env: [String: String] = ProcessInfo.processInfo.environment) -> BackendChoice {
        env["MUDROOM_BACKEND"].flatMap { BackendChoice(rawValue: $0.lowercased()) } ?? .auto
    }

    /// True on Apple silicon running macOS 26 or later.
    public static var appleContainerSupported: Bool {
        #if os(macOS) && arch(arm64)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        #else
        return false
        #endif
    }

    /// Resolves `auto` to a concrete backend. Doesn't check that a daemon
    /// is running unless it has to choose between Docker and Podman.
    public static func resolve(_ choice: BackendChoice, which: (String) -> String? = ProcessRunner.which) -> BackendChoice {
        guard choice == .auto else { return choice }
        if appleContainerSupported && which("container") != nil { return .apple }
        let docker = which("docker")
        let podman = which("podman")
        if let docker, podman != nil {
            // Both installed: prefer the one that answers.
            let ok = (try? ProcessRunner.capture(docker, ["info", "--format", "{{.ID}}"]))?.status == 0
            return ok ? .docker : .podman
        }
        if docker != nil { return .docker }
        if podman != nil { return .podman }
        return appleContainerSupported ? .apple : .docker
    }

    /// Makes the backend. `ociRuntime` (e.g. runsc) only applies to Docker
    /// and Podman.
    public static func make(_ choice: BackendChoice, ociRuntime: String? = nil) throws -> SandboxBackend {
        let resolved = resolve(choice)
        if ociRuntime != nil && resolved == .apple {
            throw MudroomError.invalid("--oci-runtime only applies to the docker and podman backends")
        }
        switch resolved {
        case .apple, .auto:
            if !appleContainerSupported {
                throw MudroomError.backendUnavailable(
                    "the apple backend needs macOS 26 or later on Apple silicon. Use --backend docker or --backend podman.")
            }
            return AppleContainerBackend()
        case .docker:
            return DockerBackend(flavor: .docker, ociRuntime: ociRuntime)
        case .podman:
            return DockerBackend(flavor: .podman, ociRuntime: ociRuntime)
        }
    }
}
