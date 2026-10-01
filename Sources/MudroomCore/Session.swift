#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

public enum SessionStatus: String, Codable, Sendable {
    /// Clones exist, the agent hasn't started.
    case created
    case running
    /// The agent exited; see `exitCode`.
    case finished
    /// Changes (some or all) were applied to the real project.
    case applied
    /// The last apply was rolled back.
    case undone
    /// Clones deleted; only session.json is kept as a record.
    case discarded
}

public struct Session: Codable, Sendable, Equatable {
    public var id: String
    public var projectPath: String
    public var created: Date
    public var command: [String]
    public var image: String
    public var status: SessionStatus
    public var cloneMethod: CloneMethod
    public var exitCode: Int32?
    /// Display name of the agent preset, e.g. "Claude Code". Optional in the file.
    public var agent: String?
    /// PID of the `mudroom` process running the agent while status is `running`.
    public var runnerPID: Int32?
    public var started: Date?
    public var finished: Date?
    /// How the last run reached the network. Nil for sessions that never ran
    /// (or ran before Mudroom recorded this).
    public var network: SessionNetwork?
    /// Sandbox backend ("apple", "docker" or "podman") the session was
    /// created for or last ran with. `mudroom start` uses it unless told
    /// otherwise. Nil for older sessions.
    public var backend: String?
    /// Entries of the project the clones don't have (sockets, FIFOs,
    /// unreadable files). Nil when nothing was left out.
    public var cloneSkipped: [SkippedEntry]?

    public init(id: String, projectPath: String, created: Date, command: [String], image: String,
                status: SessionStatus, cloneMethod: CloneMethod, exitCode: Int32? = nil, agent: String? = nil) {
        self.id = id
        self.projectPath = projectPath
        self.created = created
        self.command = command
        self.image = image
        self.status = status
        self.cloneMethod = cloneMethod
        self.exitCode = exitCode
        self.agent = agent
    }

    public var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }

    /// The agent label to show: the preset name, else the command's first word.
    public var agentLabel: String {
        if let agent, !agent.isEmpty { return agent }
        return command.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "image default"
    }
}

/// The network setup of a run, as recorded in session.json.
public struct SessionNetwork: Codable, Sendable, Equatable {
    public var mode: NetworkMode
    public var enforcement: NetworkEnforcement
    /// Effective allowlist for the run (locked mode).
    public var allowlist: [String]
    /// Proxy address given to the VM, e.g. "http://192.168.128.1:51234".
    public var proxy: String?
    /// VM network name; nil means the runtime's default (NAT) network.
    public var vmNetwork: String?

    public init(mode: NetworkMode, enforcement: NetworkEnforcement, allowlist: [String] = [],
                proxy: String? = nil, vmNetwork: String? = nil) {
        self.mode = mode
        self.enforcement = enforcement
        self.allowlist = allowlist
        self.proxy = proxy
        self.vmNetwork = vmNetwork
    }
}

/// A session directory on disk:
///
///     <root>/sessions/<id>/
///       session.json
///       base/        clone of the project at session start (never mounted)
///       work/        clone the agent edits (mounted at /workspace)
///       rollback/    one bundle per apply, used by `undo`
///       snapshots/   <n>-<time>/ clones of work/ taken while the agent ran
///       network.jsonl  one line per proxied or refused connection
public struct SessionHandle: Sendable {
    public let directory: URL
    public var session: Session

    public var base: URL { directory.appendingPathComponent("base", isDirectory: true) }
    public var work: URL { directory.appendingPathComponent("work", isDirectory: true) }
    public var rollbackRoot: URL { directory.appendingPathComponent("rollback", isDirectory: true) }
    public var snapshotsRoot: URL { directory.appendingPathComponent("snapshots", isDirectory: true) }
    public var networkLog: URL { directory.appendingPathComponent("network.jsonl") }
    /// This session's copy of the agent's config directory (see AgentHome).
    public var agentHomeCopy: URL { directory.appendingPathComponent("agent-home", isDirectory: true) }
    public var project: URL { URL(fileURLWithPath: session.projectPath, isDirectory: true) }
    var metadataURL: URL { directory.appendingPathComponent("session.json") }
    /// Held (flock) by `mudroom start` and the sandbox process it runs, for
    /// as long as either lives.
    public var runnerLockURL: URL { directory.appendingPathComponent("runner.lock") }
    /// The sandbox's container name.
    public var containerName: String { "mudroom-\(session.id)" }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(session).write(to: metadataURL, options: .atomic)
    }

    public mutating func setStatus(_ status: SessionStatus, exitCode: Int32? = nil) throws {
        session.status = status
        if let exitCode { session.exitCode = exitCode }
        try save()
    }

    /// Re-reads session.json (another process may have updated it).
    public mutating func reload() throws {
        session = try SessionStore.decode(Data(contentsOf: metadataURL))
    }

    /// True while the agent may still be writing work/: some process holds
    /// the runner lock. The lock goes away with the processes, even after a
    /// crash, so a stale `running` status or a reused PID can't keep a
    /// session "running" forever.
    public var isRunnerAlive: Bool {
        if FileLock.isHeld(runnerLockURL) { return true }
        guard session.status == .running, let pid = session.runnerPID, pid > 0,
              !FileManager.default.fileExists(atPath: runnerLockURL.path) else { return false }
        // Started by a Mudroom without the lock: the PID must be one of ours
        // (EPERM means another user's process) and have started before the run.
        guard kill(pid, 0) == 0 else { return false }
        guard let started = session.started, let procStart = ProcessInfo.startTime(of: pid) else { return false }
        return procStart <= started.addingTimeInterval(2)
    }

    /// Whether the clones still exist (false after a discard).
    public var hasClones: Bool {
        FileManager.default.fileExists(atPath: base.path) && FileManager.default.fileExists(atPath: work.path)
    }
}

public struct SessionStore: Sendable {
    public let root: URL

    public var sessionsDirectory: URL { root.appendingPathComponent("sessions", isDirectory: true) }

    public init(root: URL) { self.root = root }

    /// `$MUDROOM_HOME`, or ~/Library/Application Support/Mudroom.
    public static func defaultStore() -> SessionStore {
        if let override = ProcessInfo.processInfo.environment["MUDROOM_HOME"], !override.isEmpty {
            return SessionStore(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        #if os(macOS)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SessionStore(root: support.appendingPathComponent("Mudroom", isDirectory: true))
        #else
        // $XDG_DATA_HOME/mudroom, or ~/.local/share/mudroom.
        let env = ProcessInfo.processInfo.environment
        let data = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
        return SessionStore(root: data.appendingPathComponent("mudroom", isDirectory: true))
        #endif
    }

    static func newID(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(UInt32.random(in: 0...0xffff), radix: 16)
        return f.string(from: now) + "-" + String(repeating: "0", count: 4 - suffix.count) + suffix
    }

    /// Creates the session directory with `base/` and `work/` cloned from the
    /// project. The project itself is only read.
    public func create(project: URL, command: [String], image: String, agent: String? = nil,
                       allowClonefile: Bool = true) throws -> SessionHandle {
        let project = project.resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDir), isDir.boolValue else {
            throw MudroomError.notADirectory(project.path)
        }
        if project.path == root.standardizedFileURL.path || root.standardizedFileURL.path.hasPrefix(project.path + "/") {
            throw MudroomError.invalid("the Mudroom store (\(root.path)) is inside the project; set MUDROOM_HOME elsewhere")
        }
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let id = Self.newID()
        let dir = sessionsDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        var handle = SessionHandle(directory: dir, session: Session(
            id: id, projectPath: project.path, created: Date(), command: command, image: image,
            status: .created, cloneMethod: .clonefile, agent: agent))
        do {
            let r1 = try Cloner.clone(from: project, to: handle.base, allowClonefile: allowClonefile)
            let r2 = try Cloner.clone(from: project, to: handle.work, allowClonefile: allowClonefile)
            handle.session.cloneMethod = r1.method == r2.method ? r1.method : .copy
            var skipped = r1.skipped
            for e in r2.skipped where !skipped.contains(e) { skipped.append(e) }
            if !skipped.isEmpty { handle.session.cloneSkipped = skipped }
            try handle.save()
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return handle
    }

    static func decode(_ data: Data) throws -> Session {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Session.self, from: data)
    }

    /// Session directories whose session.json can't be read. They don't
    /// show up in `list`, but can be removed with `discardBroken`.
    public func brokenSessions() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path)) ?? []
        return names.sorted().compactMap { name in
            let dir = sessionsDirectory.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
                  (try? Self.decode(data)) != nil else { return dir }
            return nil
        }
    }

    /// Deletes a session directory whose session.json is unreadable, by its
    /// directory name. Refuses if it is running.
    public func discardBroken(_ id: String) throws {
        guard let dir = brokenSessions().first(where: { $0.lastPathComponent == id }) else {
            throw MudroomError.sessionNotFound(id)
        }
        if FileLock.isHeld(dir.appendingPathComponent("runner.lock")) {
            throw MudroomError.invalid("session \(id) is still running")
        }
        try FileManager.default.removeItem(at: dir)
    }

    /// All sessions, oldest first. Unreadable session.json files are skipped
    /// (see `brokenSessions`).
    public func list() throws -> [SessionHandle] {
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path).sorted().compactMap { name in
            let dir = sessionsDirectory.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
                  let session = try? Self.decode(data) else { return nil }
            return SessionHandle(directory: dir, session: session)
        }
    }

    /// Finds a session by full id, unique prefix, or "last".
    public func open(_ query: String) throws -> SessionHandle {
        let all = try list()
        if query == "last" {
            guard let last = all.max(by: { $0.session.created < $1.session.created }) else {
                throw MudroomError.sessionNotFound(query)
            }
            return last
        }
        if let exact = all.first(where: { $0.session.id == query }) { return exact }
        let matches = all.filter { $0.session.id.hasPrefix(query) }
        switch matches.count {
        case 1: return matches[0]
        case 0:
            if let broken = brokenSessions().first(where: { $0.lastPathComponent.hasPrefix(query) }) {
                throw MudroomError.invalid("session \(broken.lastPathComponent) has an unreadable session.json; remove it with `mudroom discard \(broken.lastPathComponent)`")
            }
            throw MudroomError.sessionNotFound(query)
        default: throw MudroomError.ambiguousSession(query, matches.map(\.session.id))
        }
    }

    /// Deletes the session directory. Never touches the project.
    ///
    /// With `keepRecord`, only the clones and rollback bundles are deleted and
    /// session.json stays behind with status `discarded`, so the session still
    /// shows up in history.
    public func discard(_ handle: SessionHandle, keepRecord: Bool = false) throws {
        let dir = handle.directory.standardizedFileURL
        guard dir.path.hasPrefix(sessionsDirectory.standardizedFileURL.path + "/") else {
            throw MudroomError.invalid("refusing to delete \(dir.path): not inside \(sessionsDirectory.path)")
        }
        guard keepRecord else {
            try FileManager.default.removeItem(at: dir)
            return
        }
        for sub in [handle.base, handle.work, handle.rollbackRoot, handle.snapshotsRoot, handle.agentHomeCopy] where FileManager.default.fileExists(atPath: sub.path) {
            try FileManager.default.removeItem(at: sub)
        }
        var h = handle
        h.session.runnerPID = nil
        try h.setStatus(.discarded)
    }
}

/// Refuses to touch the project while the agent may still be running.
public enum SessionGuard {
    /// Throws when the runner is alive or the session's container is still
    /// running (e.g. `mudroom start` was killed but the sandbox wasn't).
    /// `backend` defaults to the one the session last ran with.
    public static func ensureIdle(_ handle: SessionHandle, backend: SandboxBackend? = nil) throws {
        if handle.isRunnerAlive {
            throw MudroomError.invalid("session \(handle.session.id) is still running; let the agent finish (or quit it) first")
        }
        guard handle.session.started != nil else { return }
        let b = backend ?? handle.session.backend.flatMap(BackendChoice.init(backendName:)).flatMap { try? Backends.make($0) }
        if let b, b.isRunning(handle.containerName) {
            throw MudroomError.invalid("the sandbox \(handle.containerName) is still running; stop it first (\(b.stopHint(handle.containerName)))")
        }
    }
}

extension ProcessInfo {
    /// When process `pid` started, or nil if unknown.
    static func startTime(of pid: Int32) -> Date? {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
        #else
        // Field 22 of /proc/<pid>/stat: start time in clock ticks after boot.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 19, let ticks = Double(fields[19]),
              let procStat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let line = procStat.split(separator: "\n").first(where: { $0.hasPrefix("btime ") }),
              let boot = Double(line.split(separator: " ")[1]) else { return nil }
        let hz = Double(sysconf(Int32(_SC_CLK_TCK)))
        return Date(timeIntervalSince1970: boot + ticks / max(hz, 1))
        #endif
    }
}
