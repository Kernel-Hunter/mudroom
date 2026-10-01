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
    public var project: URL { URL(fileURLWithPath: session.projectPath, isDirectory: true) }
    var metadataURL: URL { directory.appendingPathComponent("session.json") }

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

    /// True while status is `running` and the recorded runner process exists.
    /// A `running` session whose runner is gone (terminal closed, crash) is stale.
    public var isRunnerAlive: Bool {
        guard session.status == .running, let pid = session.runnerPID else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
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
            let m1 = try Cloner.cloneTree(from: project, to: handle.base, allowClonefile: allowClonefile)
            let m2 = try Cloner.cloneTree(from: project, to: handle.work, allowClonefile: allowClonefile)
            handle.session.cloneMethod = m1 == m2 ? m1 : .copy
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

    /// All sessions, oldest first. Unreadable session.json files are skipped.
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
        case 0: throw MudroomError.sessionNotFound(query)
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
        for sub in [handle.base, handle.work, handle.rollbackRoot, handle.snapshotsRoot] where FileManager.default.fileExists(atPath: sub.path) {
            try FileManager.default.removeItem(at: sub)
        }
        var h = handle
        h.session.runnerPID = nil
        try h.setStatus(.discarded)
    }
}
