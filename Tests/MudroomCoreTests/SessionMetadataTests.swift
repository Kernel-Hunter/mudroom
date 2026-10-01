import Foundation
import Testing
@testable import MudroomCore

@Suite("Session metadata, presets and soft discard")
struct SessionMetadataTests {
    @Test("session.json from phase 1 (no agent/pid fields) still decodes")
    func oldFormat() throws {
        let json = """
        {"cloneMethod":"clonefile","command":["claude"],"created":"2026-09-29T10:00:00Z",
         "id":"20260929-100000-abcd","image":"mudroom/agent-base:latest",
         "projectPath":"/tmp/p","status":"finished","exitCode":0}
        """
        let s = try SessionStore.decode(Data(json.utf8))
        #expect(s.agent == nil && s.runnerPID == nil)
        #expect(s.agentLabel == "claude")
        #expect(s.projectName == "p")
    }

    @Test("discard with keepRecord deletes clones but keeps the record")
    func softDiscard() throws {
        let f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        try f.store.discard(f.handle, keepRecord: true)
        let listed = try #require(try f.store.list().first)
        #expect(listed.session.status == .discarded)
        #expect(!listed.hasClones)
        #expect(exists(f.project.appendingPathComponent("a.txt")))
        try f.store.discard(listed)
        #expect(try f.store.list().isEmpty)
    }

    @Test("a session is running while its runner lock is held, not because of a pid")
    func staleRunner() throws {
        var f = try Fixture { try write("a\n", to: $0.appendingPathComponent("a.txt")) }
        f.handle.session.runnerPID = getpid()
        try f.handle.setStatus(.running)
        let lock = try #require(FileLock.tryAcquire(f.handle.runnerLockURL))
        #expect(f.handle.isRunnerAlive)
        lock.release()
        // Lock released: a live pid alone doesn't make it running.
        #expect(!f.handle.isRunnerAlive)
        f.handle.session.runnerPID = 999_999
        try f.handle.setStatus(.running)
        #expect(!f.handle.isRunnerAlive)
        var reloaded = try f.store.open(f.handle.session.id)
        try reloaded.reload()
        #expect(reloaded.session.runnerPID == 999_999)
    }

    @Test("custom command parsing")
    func parse() {
        #expect(AgentPreset.parseCommand("aider --yes  --model 'gpt 5'") == ["aider", "--yes", "--model", "gpt 5"])
        #expect(AgentPreset.parseCommand("  ") == [])
        #expect(AgentPreset.parseCommand("sh -c \"echo hi\" ''") == ["sh", "-c", "echo hi", ""])
    }
}
