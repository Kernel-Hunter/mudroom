import Foundation

/// Mudroom-wide CLI settings: `<store>/settings.json`.
public struct MudroomSettings: Codable, Sendable, Equatable {
    /// The daily check for a new release. Nil means on.
    public var checkForUpdates: Bool?

    public init(checkForUpdates: Bool? = nil) { self.checkForUpdates = checkForUpdates }

    public static func url(_ store: SessionStore) -> URL { store.root.appendingPathComponent("settings.json") }

    /// The saved settings; defaults when there is no file. A file that
    /// can't be read turns the update check off rather than on.
    public static func load(_ store: SessionStore) -> MudroomSettings {
        guard FileManager.default.fileExists(atPath: url(store).path) else { return MudroomSettings() }
        guard let data = try? Data(contentsOf: url(store)),
              let s = try? JSONDecoder().decode(MudroomSettings.self, from: data) else { return MudroomSettings(checkForUpdates: false) }
        return s
    }

    public func save(_ store: SessionStore) throws {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).writeAtomically(to: Self.url(store))
    }
}

/// When to check for a new release and when to say so. The check runs at
/// most once a day; after a failed one it waits an hour before trying
/// again; the notice for a version shows at most once a day.
public struct UpdateNoticeState: Codable, Sendable, Equatable {
    /// Last check that got an answer.
    public var checked: Date?
    /// Last check started, answered or not.
    public var attempted: Date?
    /// The latest release that answer named.
    public var latest: String?
    /// When the notice was last printed, and for which version.
    public var shown: Date?
    public var shownVersion: String?

    public init(checked: Date? = nil, attempted: Date? = nil, latest: String? = nil,
                shown: Date? = nil, shownVersion: String? = nil) {
        self.checked = checked
        self.attempted = attempted
        self.latest = latest
        self.shown = shown
        self.shownVersion = shownVersion
    }

    public static let checkInterval: TimeInterval = 24 * 3600
    public static let retryInterval: TimeInterval = 3600
    /// A check the command finished before: try again this much later.
    public static let cutOffRetry: TimeInterval = 300
    public static let noticeInterval: TimeInterval = 24 * 3600

    public static func url(_ store: SessionStore) -> URL { store.root.appendingPathComponent("update-check.json") }

    public static func load(_ store: SessionStore) -> UpdateNoticeState {
        guard let data = try? Data(contentsOf: url(store)),
              let s = try? JSONDecoder().decode(UpdateNoticeState.self, from: data) else { return UpdateNoticeState() }
        return s
    }

    public func save(_ store: SessionStore) throws {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).writeAtomically(to: Self.url(store))
    }

    /// Whether `t` is less than `interval` ago. A time in the future (a
    /// clock that was wrong) counts as long ago.
    static func recent(_ t: Date?, _ interval: TimeInterval, now: Date) -> Bool {
        guard let t else { return false }
        let age = now.timeIntervalSince(t)
        return age >= -300 && age < interval
    }

    public func needsCheck(now: Date) -> Bool {
        !Self.recent(checked, Self.checkInterval, now: now) && !Self.recent(attempted, Self.retryInterval, now: now)
    }

    /// The version to tell the user about, if one is newer than `current`
    /// and wasn't already shown in the last day.
    public func versionToAnnounce(current: ReleaseVersion, now: Date) -> ReleaseVersion? {
        guard let latest = latest.flatMap(ReleaseVersion.init), !latest.isPrerelease, latest > current else { return nil }
        if shownVersion == latest.description, Self.recent(shown, Self.noticeInterval, now: now) { return nil }
        return latest
    }
}

public enum UpdateNotice {
    public static let environmentVariable = "MUDROOM_NO_UPDATE_CHECK"

    /// Why the automatic check is off, or nil when it's on. `appChecksOff`
    /// is the Mac app's own "Check for updates automatically" setting, for
    /// the copy of the CLI inside the app.
    public static func disabledReason(environment: [String: String], settings: MudroomSettings,
                                      appChecksOff: Bool = false) -> String? {
        if let v = environment[environmentVariable], !v.isEmpty, v != "0" { return "\(environmentVariable) is set" }
        if settings.checkForUpdates == false { return "turned off with `mudroom update --auto-check off`" }
        if appChecksOff { return "turned off in Mudroom's settings" }
        // CI logs aren't read by anyone who can act on it.
        if let ci = environment["CI"], !ci.isEmpty, ci.lowercased() != "false", ci != "0" { return "running under CI" }
        return nil
    }

    /// Commands that never print the notice: sessions own the terminal
    /// (`run`, `start`, `agent login`), and `update` speaks for itself.
    static let quietCommands: Set<String> = ["run", "start", "agent", "update", "help"]

    /// Whether a command line may end with the notice. Help, version and
    /// JSON output never do.
    public static func allowed(arguments: [String]) -> Bool {
        guard let first = arguments.first(where: { !$0.hasPrefix("-") }) else { return false }
        if quietCommands.contains(first) { return false }
        let quietFlags: Set<String> = ["--json", "--help", "-h", "--version", "--experimental-dump-help"]
        return !arguments.contains { quietFlags.contains($0) || $0.hasPrefix("--generate-completion") }
    }

    public static func message(_ v: ReleaseVersion, current: ReleaseVersion) -> String {
        "Mudroom \(v) is available (you have \(current)). Run `mudroom update` to get it."
    }
}

/// The once-a-day check run alongside a command: `begin` starts it in the
/// background when it's due, `finish` (after the command's own output)
/// waits a moment for it and returns the line to print, if any.
public final class UpdateNoticeRun: @unchecked Sendable {
    let store: SessionStore
    let current: ReleaseVersion
    let fetch: @Sendable () -> Result<LatestRelease, UpdateCheck.CheckError>
    let now: @Sendable () -> Date
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var started = false
    private var result: Result<LatestRelease, UpdateCheck.CheckError>?

    public init(store: SessionStore, current: ReleaseVersion,
                now: @escaping @Sendable () -> Date = { Date() },
                fetch: @escaping @Sendable () -> Result<LatestRelease, UpdateCheck.CheckError>) {
        self.store = store
        self.current = current
        self.now = now
        self.fetch = fetch
    }

    public func begin() {
        var state = UpdateNoticeState.load(store)
        guard state.needsCheck(now: now()) else { return }
        state.attempted = now()
        // Can't record the attempt (read-only store): don't check, or
        // every command would.
        guard (try? state.save(store)) != nil else { return }
        started = true
        Thread.detachNewThread { [self] in
            let r = fetch()
            lock.withLock { result = r }
            done.signal()
        }
    }

    /// Waits at most `wait` seconds for a check still running, saves what
    /// it found, and returns the notice line, or nil.
    public func finish(wait: TimeInterval) -> String? {
        if started { _ = done.wait(timeout: .now() + wait) }
        var state = UpdateNoticeState.load(store)
        switch lock.withLock({ result }) {
        case .success(let latest)?:
            state.checked = now()
            state.latest = latest.version.description
        case .failure?:
            break
        case nil where started:
            // Cut off by the command ending, not refused: try again soon.
            state.attempted = now().addingTimeInterval(UpdateNoticeState.cutOffRetry - UpdateNoticeState.retryInterval)
        case nil:
            break
        }
        guard let v = state.versionToAnnounce(current: current, now: now()) else {
            if started { try? state.save(store) }
            return nil
        }
        state.shown = now()
        state.shownVersion = v.description
        try? state.save(store)
        return UpdateNotice.message(v, current: current)
    }
}
