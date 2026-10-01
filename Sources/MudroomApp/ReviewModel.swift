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

    /// Ticked files and hunks. Every change goes through `selectionDidChange`.
    var selection = ReviewSelection() {
        didSet { selectionCache = nil }
    }
    @ObservationIgnored private var selectionCache: ReviewSelection.Pending?
    /// The file (or "folder:<path>" summary row) shown in the right pane.
    var focusedPath: String?
    /// Collapsed folders the user opened.
    var expandedFolders: Set<String> = [] {
        didSet { rebuildRows() }
    }
    /// What the file list shows, by group; folders first.
    private(set) var visibleFolders: [FolderSummary] = []
    private(set) var visibleGroups: [(ChangeGroup, [FileEntry])] = []
    /// Lines of added/deleted files, loaded when one is focused.
    private(set) var detailHunks: [String: [Hunk]] = [:]
    @ObservationIgnored private var detailLoading: Set<String> = []

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
    var focused: FileEntry? { snapshot?.entry(focusedPath) }
    var focusedFolder: FolderSummary? {
        guard let p = focusedPath, p.hasPrefix("folder:") else { return nil }
        return snapshot?.folders.first { "folder:" + $0.path == p }
    }
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
            snapshot = .empty
            baseSnapshot = snapshot
            timeline = []
            rebuildRows()
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
                    detailHunks = [:]
                    if snap.entry(focusedPath) == nil { focusedPath = snap.files.first?.path }
                    rebuildRows()
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
        detailHunks = [:]
        var sel = selection
        // New files (and everything on first load) start selected, unless
        // they can't be applied or are flagged (host-run files, setuid).
        // So do files an undo just took back out of the project.
        for f in snap.files where !keepSelection || previous?.entry(f.path) == nil
            || (previous?.entry(f.path)?.isApplied == true && !f.isApplied) {
            sel.setDefault(f)
        }
        // Drop selections that can no longer be applied.
        for f in snap.files {
            if !f.canApply { sel.set(f, false) }
            if f.allowsPartial { sel.hunks[f.path] = (sel.hunks[f.path] ?? []).subtracting(f.appliedHunks) }
        }
        selection = sel
        if snap.entry(focusedPath) == nil && focusedFolder == nil {
            // `-MudroomFocus <path>` on the command line picks the first file shown
            // (used for screenshots and demos).
            let preferred = UserDefaults.standard.string(forKey: "MudroomFocus")
            focusedPath = snap.entry(preferred)?.path ?? snap.files.first?.path
        }
        rebuildRows()
    }

    /// Recomputes the list's sections (after a load or folder toggle).
    private func rebuildRows() {
        guard let snap = snapshot else {
            visibleFolders = []
            visibleGroups = []
            return
        }
        let collapsed = snap.folders.filter { !expandedFolders.contains($0.path) }
        var hidden = Set<Int>()
        for f in collapsed { hidden.formUnion(f.rows) }
        var groups: [ChangeGroup: [FileEntry]] = [:]
        for (i, f) in snap.files.enumerated() where !hidden.contains(i) { groups[f.group, default: []].append(f) }
        visibleFolders = collapsed
        visibleGroups = ChangeGroup.allCases.compactMap { g in groups[g].map { (g, $0) } }
    }

    func toggleFolder(_ path: String) {
        if expandedFolders.contains(path) { expandedFolders.remove(path) } else { expandedFolders.insert(path) }
    }

    /// Loads the lines of an added or deleted file for the detail pane.
    func loadDetail(_ entry: FileEntry) {
        guard case .lines = entry.content, detailHunks[entry.path] == nil, !detailLoading.contains(entry.path) else { return }
        detailLoading.insert(entry.path)
        let h = handle
        let from = compareSnapshot?.directory ?? h.base
        Task {
            let hunks = await Task.detached(priority: .userInitiated) {
                (try? ReviewSnapshot.detail(entry, before: from, after: h.work)) ?? []
            }.value
            detailLoading.remove(entry.path)
            if detailHunks.count > 200 { detailHunks = [:] }
            detailHunks[entry.path] = hunks
        }
    }

    // MARK: Selection

    func checkState(_ f: FileEntry) -> CheckState {
        if f.allowsPartial {
            let open = f.openHunks
            let sel = (selection.hunks[f.path] ?? []).intersection(open)
            if sel.isEmpty { return .off }
            return sel == open ? .on : .mixed
        }
        return selection.files.contains(f.path) ? .on : .off
    }

    func folderState(_ folder: FolderSummary) -> CheckState {
        guard let snap = baseSnapshot else { return .off }
        var on = 0, total = 0
        for i in folder.rows where i < snap.files.count && snap.files[i].canApply {
            total += 1
            if selection.isSelected(snap.files[i]) { on += 1 }
        }
        return on == 0 ? .off : on == total ? .on : .mixed
    }

    func toggleFolderSelection(_ folder: FolderSummary) {
        guard let snap = baseSnapshot else { return }
        let on = folderState(folder) != .on
        var sel = selection
        for i in folder.rows where i < snap.files.count { sel.set(snap.files[i], on) }
        selection = sel
    }

    func toggle(_ path: String) {
        guard let f = snapshot?.entry(path), f.canApply else { return }
        selection.set(f, checkState(f) != .on)
    }

    func toggleFocused() {
        if let folder = focusedFolder { toggleFolderSelection(folder) } else if let focusedPath { toggle(focusedPath) }
    }

    func isHunkSelected(_ path: String, _ id: Int) -> Bool {
        selection.hunks[path]?.contains(id) ?? false
    }

    func toggleHunk(_ path: String, _ id: Int) {
        guard let f = snapshot?.entry(path), f.canApply, !f.appliedHunks.contains(id) else { return }
        var s = selection.hunks[path] ?? []
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        selection.hunks[path] = s
    }

    func setAll(_ on: Bool) {
        var sel = selection
        for f in baseFiles where f.canApply { sel.set(f, on) }
        selection = sel
    }

    /// Paths and hunk selections the "Apply Selected" button would send.
    /// Computed once per selection change, not per redraw.
    var pendingSelection: ReviewSelection.Pending {
        _ = selection // observed
        if let c = selectionCache { return c }
        let p = selection.pending(baseSnapshot ?? .empty)
        selectionCache = p
        return p
    }

    var selectedCount: Int { pendingSelection.rowCount }

    var applicableCount: Int { baseFiles.reduce(0) { $0 + ($1.canApply ? 1 : 0) } }

    // MARK: Actions

    var canApply: Bool { !isRunning && !isWorking && handle.hasClones && !isTimelineView }

    func applySelected() {
        let s = pendingSelection
        guard !s.isEmpty, let reviewed = baseSnapshot?.reviewed else { return }
        perform(verb: "Applied") { try Applier(handle: $0).apply(paths: s.paths, hunks: s.hunks, reviewed: reviewed) }
    }

    func applyAll() {
        guard let reviewed = baseSnapshot?.reviewed else { return }
        perform(verb: "Applied") { try Applier(handle: $0).apply(paths: nil, reviewed: reviewed) }
    }

    private func perform(verb: String, _ body: @escaping @Sendable (SessionHandle) throws -> ApplyReport) {
        guard canApply else { return }
        isWorking = true
        let h0 = handle
        Task {
            let result = await Task.detached { () -> Result<ApplyReport, Error> in
                Result {
                    var h = h0
                    try SessionGuard.ensureIdle(h)
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
                    try SessionGuard.ensureIdle(h)
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
                                   // Conflicted paths stay in the bundle: undo again once they're back.
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
