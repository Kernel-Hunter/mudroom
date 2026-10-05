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

    @Test("discard is refused while the session's container still runs, and says to use mudroom stop")
    func guardWhileContainerRuns() throws {
        var f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        f.handle.session.started = Date()
        try f.handle.setStatus(.running)
        let b = LifecycleBackend()
        b.running = [f.handle.containerName]
        // No runner lock: mudroom itself was killed, the sandbox wasn't.
        #expect(!f.handle.isRunnerAlive)
        do {
            try SessionGuard.ensureIdle(f.handle, backend: b)
            Issue.record("expected a refusal")
        } catch {
            #expect("\(error)".contains("mudroom stop \(f.handle.session.id)"))
        }
        #expect(f.handle.hasClones)

        #expect(try SessionGuard.stop(&f.handle, backend: b, wait: 0))
        #expect(b.stopped == [f.handle.containerName])
        #expect(f.handle.session.status == .interrupted)
        #expect(f.handle.session.finished != nil)
        try f.handle.reload()
        #expect(f.handle.session.status == .interrupted)
        try SessionGuard.ensureIdle(f.handle, backend: b)
        try f.store.discard(f.handle, keepRecord: true)
    }

    @Test("stop leaves a finished session's record alone and stops nothing that isn't running")
    func stopIdle() throws {
        var f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        f.handle.session.started = Date()
        try f.handle.setStatus(.finished, exitCode: 0)
        let b = LifecycleBackend()
        #expect(try !SessionGuard.stop(&f.handle, backend: b, wait: 0))
        #expect(b.stopped.isEmpty)
        #expect(f.handle.session.status == .finished)
    }
}
