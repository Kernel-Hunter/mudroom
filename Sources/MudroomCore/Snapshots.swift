import CryptoKit
import Darwin
import Foundation

/// A point-in-time copy of a session's work/ tree:
/// `<session>/snapshots/<n>-<yyyyMMdd-HHmmss>/`.
public struct Snapshot: Sendable, Equatable, Identifiable {
    public var id: Int { number }
    public let number: Int
    public let date: Date
    public let directory: URL

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    init?(directory: URL) {
        let name = directory.lastPathComponent
        guard let dash = name.firstIndex(of: "-"), let n = Int(name[..<dash]), n > 0,
              let date = Self.formatter.date(from: String(name[name.index(after: dash)...])) else { return nil }
        number = n
        self.date = date
        self.directory = directory
    }

    static func name(_ n: Int, _ date: Date) -> String { "\(n)-\(formatter.string(from: date))" }
}

/// What a diff compares from or to.
public enum TreeRef: Equatable, Sendable, CustomStringConvertible {
    case base
    case snapshot(Int)
    case work

    /// "base", "work", or a snapshot number.
    public init?(_ s: String) {
        switch s.lowercased() {
        case "base", "0": self = .base
        case "work", "now": self = .work
        default:
            guard let n = Int(s), n > 0 else { return nil }
            self = .snapshot(n)
        }
    }

    public var description: String {
        switch self {
        case .base: "base"
        case .work: "work"
        case .snapshot(let n): "snapshot \(n)"
        }
    }
}

public struct SnapshotStore: Sendable {
    public let handle: SessionHandle

    public init(handle: SessionHandle) { self.handle = handle }

    public var directory: URL { handle.snapshotsRoot }

    /// Oldest first.
    public func list() -> [Snapshot] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { Snapshot(directory: directory.appendingPathComponent($0, isDirectory: true)) }
            .sorted { $0.number < $1.number }
    }

    public func url(for ref: TreeRef) throws -> URL {
        switch ref {
        case .base: return handle.base
        case .work: return handle.work
        case .snapshot(let n):
            guard let s = list().first(where: { $0.number == n }) else {
                throw MudroomError.invalid("session \(handle.session.id) has no snapshot \(n)")
            }
            return s.directory
        }
    }

    /// Clones work/ into a new snapshot unless nothing changed since the
    /// last one (or since base, for the first). Then prunes to `limit`,
    /// oldest first. Returns the new snapshot, or nil if skipped.
    @discardableResult
    public func take(limit: Int = 24, now: Date = Date()) throws -> Snapshot? {
        let existing = list()
        let previous = existing.last?.directory ?? handle.base
        if try Self.fingerprint(handle.work) == Self.fingerprint(previous) { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let number = (existing.last?.number ?? 0) + 1
        let dest = directory.appendingPathComponent(Snapshot.name(number, now), isDirectory: true)
        try Cloner.cloneTree(from: handle.work, to: dest)
        try prune(limit: limit)
        return Snapshot(directory: dest)
    }

    /// Deletes the oldest snapshots beyond `limit`. Numbers are never reused.
    public func prune(limit: Int) throws {
        let all = list()
        guard limit >= 0, all.count > limit else { return }
        for s in all.prefix(all.count - limit) {
            try FileManager.default.removeItem(at: s.directory)
        }
    }

    /// A cheap summary of a tree: every path with its type, size, mode, mtime
    /// and symlink target. Clones keep mtimes, so an unchanged work/ matches
    /// its last snapshot. (The review diff itself compares content hashes;
    /// this only decides whether a snapshot is worth taking.)
    static func fingerprint(_ root: URL) throws -> String {
        var hasher = SHA256()
        try walk(root, "", &hasher)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func walk(_ dir: URL, _ rel: String, _ hasher: inout SHA256) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() {
            let path = rel.isEmpty ? name : rel + "/" + name
            let url = dir.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            let type = st.st_mode & S_IFMT
            var line = "\(path)\u{0}\(st.st_mode)\u{0}"
            if type == S_IFREG {
                line += "\(st.st_size)\u{0}\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
            } else if type == S_IFLNK {
                line += (try? FileNode.readLink(url)) ?? ""
            }
            hasher.update(data: Data((line + "\n").utf8))
            if type == S_IFDIR { try walk(url, path, &hasher) }
        }
    }
}

/// Takes a snapshot every `interval` seconds on a background queue while the
/// agent runs.
public final class Snapshotter: @unchecked Sendable {
    let store: SnapshotStore
    let interval: TimeInterval
    let limit: Int
    private let queue = DispatchQueue(label: "mudroom.snapshots", qos: .utility)
    private var timer: DispatchSourceTimer?
    public private(set) var taken: [Snapshot] = []
    public var onError: (@Sendable (Error) -> Void)?

    public init(store: SnapshotStore, interval: TimeInterval, limit: Int) {
        self.store = store
        self.interval = interval
        self.limit = limit
    }

    public func start() {
        guard interval > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.snap() }
        t.resume()
        timer = t
    }

    private func snap() {
        do {
            if let s = try store.take(limit: limit) { taken.append(s) }
        } catch {
            onError?(error)
        }
    }

    /// Stops the timer and takes the final snapshot (if anything changed).
    @discardableResult
    public func finish() -> Snapshot? {
        queue.sync {
            timer?.cancel()
            timer = nil
            let before = taken.count
            snap()
            return taken.count > before ? taken.last : nil
        }
    }
}
