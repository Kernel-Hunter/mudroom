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

    public init(id: String, projectPath: String, created: Date, command: [String], image: String,
                status: SessionStatus, cloneMethod: CloneMethod, exitCode: Int32? = nil) {
        self.id = id
        self.projectPath = projectPath
        self.created = created
        self.command = command
        self.image = image
        self.status = status
        self.cloneMethod = cloneMethod
        self.exitCode = exitCode
    }
}

/// A session directory on disk:
///
///     <root>/sessions/<id>/
///       session.json
///       base/        clone of the project at session start (never mounted)
///       work/        clone the agent edits (mounted at /workspace)
///       rollback/    one bundle per apply, used by `undo`
public struct SessionHandle: Sendable {
    public let directory: URL
    public var session: Session

    public var base: URL { directory.appendingPathComponent("base", isDirectory: true) }
    public var work: URL { directory.appendingPathComponent("work", isDirectory: true) }
    public var rollbackRoot: URL { directory.appendingPathComponent("rollback", isDirectory: true) }
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
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SessionStore(root: support.appendingPathComponent("Mudroom", isDirectory: true))
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
    public func create(project: URL, command: [String], image: String, allowClonefile: Bool = true) throws -> SessionHandle {
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
            status: .created, cloneMethod: .clonefile))
        do {
            let m1 = try Cloner.cloneTree(from: project, to: handle.base, allowClonefile: allowClonefile)
            let m2 = try Cloner.cloneTree(from: project, to: handle.work, allowClonefile: allowClonefile)
            handle.session.cloneMethod = (m1 == .clonefile && m2 == .clonefile) ? .clonefile : .copy
            try handle.save()
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return handle
    }

    public func list() throws -> [SessionHandle] {
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path).sorted().compactMap { name in
            let dir = sessionsDirectory.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")) else { return nil }
            return SessionHandle(directory: dir, session: try decoder.decode(Session.self, from: data))
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
    public func discard(_ handle: SessionHandle) throws {
        let dir = handle.directory.standardizedFileURL
        guard dir.path.hasPrefix(sessionsDirectory.standardizedFileURL.path + "/") else {
            throw MudroomError.invalid("refusing to delete \(dir.path): not inside \(sessionsDirectory.path)")
        }
        try FileManager.default.removeItem(at: dir)
    }
}
