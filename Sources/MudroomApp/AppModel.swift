import AppKit
import Foundation
import MudroomCore
import Observation

/// What the sidebar badge says about a session.
enum SessionPhase: Equatable {
    case notStarted, running, readyToReview, applied, discarded

    init(_ h: SessionHandle) {
        switch h.session.status {
        case .created: self = .notStarted
        case .running: self = h.isRunnerAlive ? .running : .readyToReview
        case .finished, .undone: self = .readyToReview
        case .applied: self = .applied
        case .discarded: self = .discarded
        }
    }

    var title: String {
        switch self {
        case .notStarted: "Not started"
        case .running: "Running"
        case .readyToReview: "Ready to review"
        case .applied: "Applied"
        case .discarded: "Discarded"
        }
    }
}

struct ProjectGroup: Identifiable {
    var id: String { path }
    let path: String
    let sessions: [SessionHandle]
    var name: String { (path as NSString).lastPathComponent }
}

@MainActor
@Observable
final class AppModel {
    let store: SessionStore
    private(set) var sessions: [SessionHandle] = []
    var selectedSessionID: String? {
        didSet { if oldValue != selectedSessionID { syncReview(reload: true) } }
    }
    /// Review model for the selected session.
    private(set) var review: ReviewModel?
    var showingNewSession = false
    var confirmDiscard = false
    /// Session to remove from the list, waiting for confirmation.
    var confirmRemove: SessionHandle?
    /// Name of the project being copied for a new session.
    private(set) var creatingSession: String?
    let setup: SetupModel
    /// Bumped to open the Setup window (RootView watches it).
    private(set) var setupRequest = 0
    var errorMessage: String?
    @ObservationIgnored private var listError: String?
    private var reviews: [String: ReviewModel] = [:]
    private var pollTask: Task<Void, Never>?

    init(store: SessionStore = .defaultStore()) {
        self.store = store
        setup = SetupModel(store: store)
        refresh()
        // Newest session waiting for review, else the newest one at all.
        let newest = sessions.sorted { $0.session.created > $1.session.created }
        let preferred = UserDefaults.standard.string(forKey: "MudroomSession")
        selectedSessionID = (newest.first { $0.session.id == preferred }
            ?? newest.first { SessionPhase($0) == .readyToReview }
            ?? newest.first { SessionPhase($0) != .discarded })?.session.id
        syncReview(reload: true)
        startPolling()
    }

    var groups: [ProjectGroup] {
        let byProject = Dictionary(grouping: sessions, by: \.session.projectPath)
        return byProject.map { ProjectGroup(path: $0.key, sessions: $0.value.sorted { $0.session.created > $1.session.created }) }
            .sorted { ($0.sessions.first?.session.created ?? .distantPast) > ($1.sessions.first?.session.created ?? .distantPast) }
    }

    var recentProjects: [String] { groups.map(\.path) }

    var selectedHandle: SessionHandle? { sessions.first { $0.session.id == selectedSessionID } }

    var runningSessions: Int { sessions.filter { SessionPhase($0) == .running }.count }

    /// Opens the Setup window, scrolled to `focus` (a step or agent id).
    func openSetup(focus: String? = nil) {
        setup.focus = focus
        setupRequest += 1
    }

    /// The card for the first step that needs attention.
    var setupFocus: String? {
        if !setup.runtimeReady { return "runtime" }
        if !setup.imageReady { return "image" }
        if !setup.networkReady { return "network" }
        if !setup.anySignedIn { return "claude" }
        return nil
    }

    private func syncReview(reload: Bool) {
        guard let h = selectedHandle else {
            review = nil
            return
        }
        if let r = reviews[h.session.id] {
            if review !== r { review = r }
            if reload { r.reload() }
            return
        }
        let r = ReviewModel(handle: h, store: store)
        reviews[h.session.id] = r
        review = r
        r.reload(keepSelection: false)
    }

    func refresh() {
        do {
            sessions = try store.list()
            listError = nil
        } catch {
            // Polled every 1.5 s: say it once, not again after each OK.
            let message = "Couldn't read the session list: \(MudroomError.message(error))"
            if message != listError { errorMessage = message }
            listError = message
        }
        for h in sessions { reviews[h.session.id]?.updateHandle(h) }
        if review?.handle.session.id != selectedSessionID { syncReview(reload: false) }
    }

    /// session.json is the source of truth; poll it so status set by the
    /// `mudroom start` process in Terminal shows up here.
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                self?.refresh()
            }
        }
    }

    // MARK: Sessions

    func startSession(project: URL, preset: AgentPreset?, customCommand: String, image: String) {
        let command = preset?.command ?? AgentPreset.parseCommand(customCommand)
        let agent = preset?.name ?? command.first.map { "Custom: \($0)" }
        let store = self.store
        let choice = setup.choice
        // The sheet is gone by now and a big project takes a while to copy;
        // the sidebar shows this until the session appears.
        creatingSession = project.lastPathComponent
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<SessionHandle, Error> in
                Result {
                    // Before the copy: a missing image would otherwise only
                    // fail in Terminal (a registry error), after the session exists.
                    let backend = try Backends.make(choice)
                    try backend.checkAvailable()
                    if let why = backend.missingImageProblem(image) { throw why }
                    return try store.create(project: project, command: command, image: image, agent: agent)
                }
            }.value
            creatingSession = nil
            switch result {
            case .success(let handle):
                refresh()
                selectedSessionID = handle.session.id
                do { try TerminalLauncher.launch(handle) } catch { errorMessage = "Couldn't open Terminal: \(MudroomError.message(error))" }
            case .failure(let error):
                errorMessage = "Couldn't create the session: \(MudroomError.message(error))"
            }
        }
    }

    func runAgain(_ handle: SessionHandle) {
        do { try TerminalLauncher.launch(handle) } catch { errorMessage = "Couldn't open Terminal: \(MudroomError.message(error))" }
    }

    func discardSelected() {
        guard let h = selectedHandle, !h.isRunnerAlive else { return }
        do {
            try store.discard(h, keepRecord: true)
            reviews[h.session.id] = nil
            review = nil
            refresh()
        } catch {
            errorMessage = "Couldn't discard: \(MudroomError.message(error))"
        }
    }

    func removeFromList(_ h: SessionHandle) {
        guard !h.isRunnerAlive else { return }
        do {
            try store.discard(h, keepRecord: false)
            reviews[h.session.id] = nil
            if selectedSessionID == h.session.id { selectedSessionID = nil }
            refresh()
        } catch {
            errorMessage = "Couldn't remove: \(MudroomError.message(error))"
        }
    }
}

/// Runs `mudroom start <id>` in a new Terminal window.
///
/// Agents are interactive TUIs, so they need a real terminal. Terminal.app
/// gives the user one they already know (copy/paste, scrollback, resizing)
/// without Mudroom embedding a terminal emulator. The app follows progress by
/// polling session.json, which `mudroom start` keeps up to date.
enum TerminalLauncher {
    static func cliURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        // Mudroom.app/Contents/Helpers/mudroom (not MacOS/: the names differ only by case).
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mudroom"))
        // `swift run MudroomApp`: the CLI sits next to the app binary.
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("mudroom"))
        }
        candidates += ["/opt/homebrew/bin/mudroom", "/usr/local/bin/mudroom"].map { URL(fileURLWithPath: $0) }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    static func launch(_ handle: SessionHandle) throws {
        guard let cli = cliURL() else {
            throw MudroomError.invalid("the mudroom command-line tool was not found inside the app or on PATH")
        }
        let script = handle.directory.appendingPathComponent("run.command")
        // The settings this app runs with, so the session uses the same
        // store, token store and backend.
        let text = RunScript.text(cli: cli.path, sessionID: handle.session.id,
                                  environment: ProcessInfo.processInfo.environment,
                                  appBundleID: Bundle.main.bundleIdentifier ?? "io.github.kernel-hunter.mudroom")
        try text.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o700)
        // `open -F` starts Terminal fresh: if it wasn't running, it doesn't
        // also bring back the windows of its last run.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-F", "-b", "com.apple.Terminal", script.path]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw MudroomError.commandFailed("open -F -b com.apple.Terminal", open.terminationStatus, "")
        }
    }
}
