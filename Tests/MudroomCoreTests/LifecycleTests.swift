import Foundation
import Testing
@testable import MudroomCore

/// A backend with a set of local images and running containers, no VMs.
final class LifecycleBackend: SandboxBackend, @unchecked Sendable {
    let name: String
    var images: [String: [String: String]] = [:]
    var running: Set<String> = []
    var stopped: [String] = []

    init(name: String = "apple-container") { self.name = name }

    func checkAvailable() throws {}
    func run(_ spec: SandboxSpec) throws -> Int32 { 0 }
    func capture(_ spec: SandboxSpec) throws -> CapturedOutput { CapturedOutput(status: 0, stdout: "", stderr: "") }
    func buildImage(containerfile: URL, context: URL, tag: String) throws {}
    func hostOnlyNetwork() throws -> SandboxNetwork? { nil }
    func defaultNetwork() throws -> SandboxNetwork? { nil }
    func imageLabels(_ tag: String) -> [String: String]? { images[tag] }
    func isRunning(_ name: String) -> Bool { running.contains(name) }
    func stop(_ name: String) {
        stopped.append(name)
        running.remove(name)
    }
}

@Suite("Session lifecycle")
struct LifecycleTests {
    @Test("a missing image is reported before cloning, with the way to get it")
    func missingImage() throws {
        let b = LifecycleBackend()
        b.images = ["alpine": [:], AgentBaseImage.tag: [AgentBaseImage.hashLabel: "x"]]
        #expect(b.missingImageProblem("alpine") == nil)
        #expect(b.missingImageProblem(AgentBaseImage.tag) == nil)

        let custom = try #require(b.missingImageProblem("nosuchimage"))
        #expect("\(custom)".contains("nosuchimage"))
        #expect("\(custom)".contains("container image pull nosuchimage"))
        #expect(LifecycleBackend(name: "docker").missingImageProblem("nosuchimage")?.description.contains("docker pull nosuchimage") == true)

        let base = try #require(LifecycleBackend().missingImageProblem(AgentBaseImage.tag))
        #expect("\(base)".contains("mudroom setup"))
        #expect("\(base)".contains("Setup in the Mudroom app"))
    }
}
