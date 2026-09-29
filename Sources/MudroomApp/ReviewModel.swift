import AppKit
import Foundation
import MudroomCore
import Observation

enum CheckState { case on, off, mixed }

enum ReviewTab: String, CaseIterable, Identifiable {
    case files = "Files"
    case network = "Network"
    var id: String { rawValue }
}

enum DiffLayout: String, CaseIterable, Identifiable {
    case unified = "Unified"
    case split = "Split"
    var id: String { rawValue }
}

/// State of the review screen for one session.
@MainActor
@Observable
final class ReviewModel {
    private(set) var handle: SessionHandle
    /// What the file list shows: base -> work, or a timeline comparison.
    private(set) var snapshot: ReviewSnapshot?
    /// Always base -> work; selections and apply work on this.
    private(set) var baseSnapshot: ReviewSnapshot?
    private(set) var isLoading = false
    var loadError: String?
    var tab: ReviewTab = .files

    // Timeline
    private(set) var timeline: [Snapshot] = []
    /// 0 = compare from the session start (base, the normal review);
    /// n = show only what changed after snapshot n. Read-only.
    var compareFrom: Int = 0 {
        didSet { if oldValue != compareFrom { reload() } }
    }
    var isTimelineView: Bool { compareFrom != 0 }
    var compareSnapshot: Snapshot? { timeline.first { $0.number == compareFrom } }

    // Network
    let configStore: ProjectConfigStore
    private(set) var networkEntries: [NetworkLogEntry] = []
    private(set) var networkRows: [NetworkLog.HostSummary] = []
    private(set) var projectConfig: ProjectConfig?
    var focusedHostRow: String?

    /// Files whose checkbox is on (for non-partial files).
    var selectedFiles: Set<String> = []
    /// Selected hunk ids for files that allow partial apply.
    var selectedHunks: [String: Set<Int>] = [:]
    /// The file shown in the right pane.
    var focusedPath: String?

    /// Result of the last apply/undo, shown as a banner.
    var lastResult: ResultBanner?
    var isWorking = false

    struct ResultBanner: Equatable {
        enum Style { case success, warning, info }
        let style: Style
        let title: String
        let detail: String?
        let offerUndo: Bool
    }

    init(handle: SessionHandle, store: SessionStore) {
        self.handle = handle
        self.configStore = ProjectConfigStore(store: store)
        // For screenshots and demos: -MudroomTab network, -MudroomFocusHost
        // host:port:false, -MudroomCompareFrom <snapshot number>.
        let d = UserDefaults.standard
        if let t = d.string(forKey: "MudroomTab").flatMap({ ReviewTab(rawValue: $0.capitalized) }) { tab = t }
        focusedHostRow = d.string(forKey: "MudroomFocusHost")
        compareFrom = d.integer(forKey: "MudroomCompareFrom")
    }

    var canUndo: Bool { baseSnapshot?.canUndo == true }
    var agentID: String? { AgentPreset.matching(agent: handle.session.agent, command: handle.session.command)?.id }

    var files: [FileEntry] { snapshot?.files ?? [] }
    /// base -> work files, whatever the timeline shows.
    var baseFiles: [FileEntry] { baseSnapshot?.files ?? [] }
    var focused: FileEntry? { files.first { $0.path == focusedPath } }
    var conflicts: [FileEntry] { files.filter { $0.conflict != nil } }
    var isRunning: Bool { handle.isRunnerAlive }

    func updateHandle(_ h: SessionHandle) {
        let statusChanged = h.session.status != handle.session.status
        handle = h
        if statusChanged && h.session.status == .finished { reload() } else if isRunning { loadNetwork() }
    }

    // MARK: Network

    func loadNetwork() {
        let entries = NetworkLog.read(handle.networkLog)
        if entries != networkEntries {
            networkEntries = entries
            networkRows = NetworkLog.summarize(entries)
        }
        projectConfig = try? configStore.load(handle.session.projectPath)
    }

    var blockedHosts: [String] { Array(Set(networkEntries.filter { !$0.allowed }.map(\.host))).sorted() }

    var focusedHost: NetworkLog.HostSummary? { networkRows.first { $0.id == focusedHostRow } }

    /// True if the project's current allowlist lets `host` through (for
    /// blocked rows that were allowed after the run).
    func isAllowedNow(_ host: String) -> Bool {
        projectConfig?.allowlist(agent: agentID).allows(host) ?? false
    }

    func allowForProject(_ host: String) {
        guard let pattern = HostPattern(host) else { return }
        do {
            projectConfig = try configStore.update(handle.session.projectPath) { $0.allow(pattern) }
            lastResult = .init(style: .success, title: "Allowed \(host)",
                               detail: "Sessions for \(handle.session.projectName) can reach it from now on. This session's log doesn't change.",
                               offerUndo: false)
        } catch {
            lastResult = .init(style: .warning, title: "Couldn't update the allowlist", detail: "\(error)", offerUndo: false)
        }
    }

    func removeFromProject(_ host: String) {
        guard let pattern = HostPattern(host) else { return }
        projectConfig = try? configStore.update(handle.session.projectPath) { $0.disallow(pattern) }
    }

    // MARK: Loading

    func reload(keepSelection: Bool = true) {
        loadNetwork()
        guard handle.hasClones else {
            snapshot = ReviewSnapshot(files: [], hiddenDeletedDirectories: [], gitMetadataChanges: 0, canUndo: false)
            baseSnapshot = snapshot
            timeline = []
            return
        }
        timeline = SnapshotStore(handle: handle).list()
        if compareFrom != 0 && compareSnapshot == nil { compareFrom = 0 }
        isLoading = true
        let h = handle
        if let from = compareSnapshot?.directory {
            let n = compareFrom
            Task {
                let needBase = baseSnapshot == nil
                let (result, base) = await Task.detached(priority: .userInitiated) { () -> (Result<ReviewSnapshot, Error>, ReviewSnapshot?) in
                    (Result { try ReviewSnapshot.loadTimeline(h, from: from) }, needBase ? try? ReviewSnapshot.load(h) : nil)
                }.value
                if let base, baseSnapshot == nil {
                    // Selections are set up from the base comparison.
                    let shown = snapshot
                    apply(snapshot: base, keepSelection: false)
                    snapshot = shown
                }
                isLoading = false
                guard n == compareFrom else { return }
                switch result {
                case .success(let snap):
                    snapshot = snap
                    if focusedPath == nil || !snap.files.contains(where: { $0.path == focusedPath }) {
                        focusedPath = snap.files.first?.path
                    }
                    loadError = nil
                case .failure(let error):
                    loadError = "\(error)"
                }
            }
            return
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ReviewSnapshot, Error> in
                Result { try ReviewSnapshot.load(h) }
            }.value
            isLoading = false
            guard compareFrom == 0 else { return }
            switch result {
            case .success(let snap):
                apply(snapshot: snap, keepSelection: keepSelection && baseSnapshot != nil)
                loadError = nil
            case .failure(let error):
                loadError = "\(error)"
            }
        }
    }

    private func apply(snapshot snap: ReviewSnapshot, keepSelection: Bool) {
        let previous = baseSnapshot
        snapshot = snap
        baseSnapshot = snap
        let known = Set(previous?.files.map(\.path) ?? [])
        // New files (and everything on first load) start selected, unless
        // they can't be applied.
        for f in snap.files where !keepSelection || !known.contains(f.path) {
            if f.allowsPartial {
                selectedHunks[f.path] = f.canApply ? Set(f.hunks.map(\.id)).subtracting(f.appliedHunks) : []
            } else if f.canApply {
                selectedFiles.insert(f.path)
            }
        }
        // Drop selections that can no longer be applied.
        for f in snap.files where !f.canApply {
            selectedFiles.remove(f.path)
            if f.allowsPartial { selectedHunks[f.path] = [] }
        }
        for f in snap.files where f.allowsPartial {
            selectedHunks[f.path] = (selectedHunks[f.path] ?? []).subtracting(f.appliedHunks)
        }
        if focusedPath == nil || !snap.files.contains(where: { $0.path == focusedPath }) {
            // `-MudroomFocus <path>` on the command line picks the first file shown
            // (used for screenshots and demos).
            let preferred = UserDefaults.standard.string(forKey: "MudroomFocus")
            focusedPath = snap.files.first { $0.path == preferred }?.path ?? snap.files.first?.path
        }
    }

    // MARK: Selection

    func checkState(_ f: FileEntry) -> CheckState {
        if f.allowsPartial {
            let open = Set(f.hunks.map(\.id)).subtracting(f.appliedHunks)
            let sel = (selectedHunks[f.path] ?? []).intersection(open)
            if sel.isEmpty { return .off }
            return sel == open ? .on : .mixed
        }
        return selectedFiles.contains(f.path) ? .on : .off
    }

    func toggle(_ path: String) {
        guard let f = files.first(where: { $0.path == path }), f.canApply else { return }
        if f.allowsPartial {
            let open = Set(f.hunks.map(\.id)).subtracting(f.appliedHunks)
            selectedHunks[path] = checkState(f) == .on ? [] : open
        } else if selectedFiles.contains(path) {
            selectedFiles.remove(path)
        } else {
            selectedFiles.insert(path)
        }
    }

    func toggleFocused() {
        if let focusedPath { toggle(focusedPath) }
    }

    func isHunkSelected(_ path: String, _ id: Int) -> Bool {
        selectedHunks[path]?.contains(id) ?? false
    }

    func toggleHunk(_ path: String, _ id: Int) {
        guard let f = files.first(where: { $0.path == path }), f.canApply, !f.appliedHunks.contains(id) else { return }
        var s = selectedHunks[path] ?? []
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        selectedHunks[path] = s
    }

    func setAll(_ on: Bool) {
        for f in baseFiles where f.canApply {
            if f.allowsPartial {
                selectedHunks[f.path] = on ? Set(f.hunks.map(\.id)).subtracting(f.appliedHunks) : []
            } else if on {
                selectedFiles.insert(f.path)
            } else {
                selectedFiles.remove(f.path)
            }
        }
    }

    /// Paths and hunk selections the "Apply Selected" button would send.
    var pendingSelection: (paths: [String], hunks: [String: Set<Int>]) {
        var paths: [String] = []
        var hunks: [String: Set<Int>] = [:]
        for f in baseFiles where f.canApply {
            if f.allowsPartial {
                let open = Set(f.hunks.map(\.id)).subtracting(f.appliedHunks)
                let want = (selectedHunks[f.path] ?? []).intersection(open)
                if want.isEmpty { continue }
                if want == open { paths.append(f.path) } else { hunks[f.path] = want }
            } else if selectedFiles.contains(f.path) {
                paths.append(f.path)
            }
        }
        // A deleted folder goes too when everything under it is selected.
        for dir in baseSnapshot?.hiddenDeletedDirectories ?? [] {
            let under = baseFiles.filter { $0.path.hasPrefix(dir + "/") }
            if !under.isEmpty && under.allSatisfy({ paths.contains($0.path) || $0.isApplied }) {
                paths.append(dir)
            }
        }
        return (paths, hunks)
    }

    var selectedCount: Int {
        let s = pendingSelection
        return s.paths.filter { p in baseFiles.contains { $0.path == p } }.count + s.hunks.count
    }

    var applicableCount: Int { baseFiles.filter(\.canApply).count }

    // MARK: Actions

    var canApply: Bool { !isRunning && !isWorking && handle.hasClones && !isTimelineView }

    func applySelected() {
        let s = pendingSelection
        guard !(s.paths.isEmpty && s.hunks.isEmpty) else { return }
        perform(verb: "Applied") { try Applier(handle: $0).apply(paths: s.paths, hunks: s.hunks) }
    }

    func applyAll() {
        perform(verb: "Applied") { try Applier(handle: $0).apply(paths: nil) }
    }

    private func perform(verb: String, _ body: @escaping @Sendable (SessionHandle) throws -> ApplyReport) {
        guard canApply else { return }
        isWorking = true
        let h0 = handle
        Task {
            let result = await Task.detached { () -> Result<ApplyReport, Error> in
                Result {
                    var h = h0
                    let report = try body(h)
                    if report.wroteAnything { try h.setStatus(.applied) }
                    return report
                }
            }.value
            isWorking = false
            var h = h0
            switch result {
            case .success(let report):
                try? h.reload()
                handle = h
                // Count rows the user sees; folders applied along with their
                // contents aren't rows.
                let rows = Set(baseFiles.map(\.path))
                let n = report.applied.filter { rows.contains($0) }.count
                let c = report.conflicts.count
                if n == 0 && c == 0 {
                    lastResult = .init(style: .info, title: "Nothing to apply", detail: nil, offerUndo: false)
                } else {
                    let files = n == 1 ? "1 file" : "\(n) files"
                    let detail = c == 0 ? "Undo puts the previous versions back."
                        : "\(c) \(c == 1 ? "path was" : "paths were") left alone because of conflicts."
                    lastResult = .init(style: c == 0 ? .success : .warning, title: "\(verb) \(files)",
                                       detail: detail, offerUndo: n > 0)
                }
                reload()
            case .failure(let error):
                lastResult = .init(style: .warning, title: "Apply failed", detail: "\(error)", offerUndo: false)
            }
        }
    }

    func undo() {
        guard !isWorking else { return }
        isWorking = true
        let h0 = handle
        Task {
            let result = await Task.detached { () -> Result<UndoReport, Error> in
                Result {
                    var h = h0
                    let applier = Applier(handle: h)
                    let report = try applier.undo()
                    if !applier.canUndo { try h.setStatus(.undone) }
                    return report
                }
            }.value
            isWorking = false
            var h = h0
            switch result {
            case .success(let report):
                try? h.reload()
                handle = h
                let c = report.conflicts.count
                lastResult = .init(style: c == 0 ? .info : .warning,
                                   title: "Undid last apply",
                                   detail: c == 0 ? "Restored \(report.restored.count) \(report.restored.count == 1 ? "path" : "paths") in your project."
                                       : "\(c) \(c == 1 ? "path was" : "paths were") changed after the apply and kept as is.",
                                   offerUndo: false)
                reload()
            case .failure(let error):
                lastResult = .init(style: .warning, title: "Undo failed", detail: "\(error)", offerUndo: false)
            }
        }
    }

    func revealInFinder(_ path: String? = nil) {
        let url = path.map { handle.work.appendingPathComponent($0) } ?? handle.project
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
