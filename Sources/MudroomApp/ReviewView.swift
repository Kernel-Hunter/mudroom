import MudroomCore
import SwiftUI

/// Middle column: session summary, conflict warning and the changed files.
struct FileListColumn: View {
    @Bindable var review: ReviewModel
    let app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(review: review)
            Divider()
            if review.isRunning {
                Banner(style: .running, title: "\(review.handle.session.agentLabel) is still working",
                       detail: "Follow it in Terminal. The list refreshes when it finishes; applying is disabled until then.")
                    .padding(10)
            }
            if !review.conflicts.isEmpty {
                Banner(style: .warning,
                       title: review.conflicts.count == 1 ? "1 conflict" : "\(review.conflicts.count) conflicts",
                       detail: conflictSummary)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, review.lastResult == nil ? 4 : 0)
            }
            if let result = review.lastResult {
                Banner(style: result.style == .success ? .success : result.style == .warning ? .warning : .info,
                       title: result.title, detail: result.detail,
                       actions: AnyView(HStack(spacing: 6) {
                           if result.offerUndo && review.snapshot?.canUndo == true {
                               Button("Undo") { review.undo() }.controlSize(.small)
                           }
                           Button { review.lastResult = nil } label: { Image(systemName: "xmark") }
                               .buttonStyle(.borderless).controlSize(.small)
                       }))
                    .padding(10)
            }
            fileList
        }
    }

    var conflictSummary: String {
        let names = review.conflicts.prefix(2).map(\.name).joined(separator: ", ")
        let more = review.conflicts.count > 2 ? " and \(review.conflicts.count - 2) more" : ""
        return "\(names)\(more) changed in your project since the session started. Mudroom won't overwrite them."
    }

    @ViewBuilder var fileList: some View {
        if !review.handle.hasClones {
            ContentUnavailableView("Session discarded", systemImage: "trash",
                                   description: Text("The agent's copy was deleted. Your project was not touched."))
        } else if review.snapshot == nil {
            ProgressView("Comparing files…").controlSize(.small).frame(maxHeight: .infinity)
        } else if review.files.isEmpty {
            ContentUnavailableView {
                Label(review.isRunning ? "No changes yet" : "No changes", systemImage: "checkmark.seal")
            } description: {
                Text(review.isRunning ? "Files the agent edits will show up here."
                     : "The agent didn't change any files.")
            }
        } else {
            List(selection: $review.focusedPath) {
                ForEach(ChangeGroup.allCases, id: \.self) { group in
                    let items = review.files.filter { $0.group == group }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { f in
                                FileRow(review: review, entry: f).tag(f.path)
                                    .contextMenu {
                                        Button("Show Agent's Copy in Finder") { review.revealInFinder(f.path) }
                                        Button(review.checkState(f) == .on ? "Deselect" : "Select") { review.toggle(f.path) }
                                            .disabled(!f.canApply)
                                    }
                            }
                        } header: {
                            HStack {
                                Text(group.title)
                                Text("\(items.count)").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if let git = review.snapshot?.gitMetadataChanges, git > 0 {
                    Section {
                        Label("\(git) entries under .git/ changed. They are not applied.", systemImage: "info.circle")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                }
            }
            .listStyle(.inset)
            .onKeyPress(.space) {
                review.toggleFocused()
                return .handled
            }
            .safeAreaInset(edge: .bottom) { selectionBar }
        }
    }

    var selectionBar: some View {
        HStack(spacing: 8) {
            Button("Select All") { review.setAll(true) }
            Button("None") { review.setAll(false) }
            Spacer()
            Text("\(review.selectedCount) of \(review.applicableCount) selected")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct SessionHeader: View {
    let review: ReviewModel

    var body: some View {
        let s = review.handle.session
        let phase = SessionPhase(review.handle)
        let files = review.files
        HStack(alignment: .center, spacing: 10) {
            AgentIcon(session: s, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.projectName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    StatusBadge(phase: phase)
                }
                HStack(spacing: 4) {
                    Text(s.agentLabel)
                    Text("·")
                    Text(s.created.relative)
                    if !files.isEmpty {
                        Text("·")
                        DiffStat(added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed })
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if review.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct FileRow: View {
    let review: ReviewModel
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 8) {
            CheckBox(state: entry.isApplied ? .on : review.checkState(entry), disabled: !entry.canApply) {
                review.toggle(entry.path)
            }
            KindTag(entry: entry)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .strikethrough(entry.group == .deleted, color: .secondary)
                    .lineLimit(1)
                if !entry.directory.isEmpty {
                    Text(entry.directory)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if entry.conflict != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(entry.conflict ?? "")
            } else if entry.isApplied {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Applied")
            } else if !entry.appliedHunks.isEmpty {
                Text("\(entry.appliedHunks.count)/\(entry.hunks.count)")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                    .help("Hunks already applied")
            }
            detail
        }
        .padding(.vertical, 2)
        .opacity(entry.conflict != nil ? 0.8 : 1)
    }

    @ViewBuilder var detail: some View {
        switch entry.content {
        case .text:
            DiffStat(added: entry.added, removed: entry.removed)
        case .binary:
            Text("binary").font(.system(size: 10)).foregroundStyle(.secondary)
        case .tooLarge:
            Text("large").font(.system(size: 10)).foregroundStyle(.secondary)
        case .meta:
            if entry.change.kind == .modeChanged, let m1 = entry.change.before.mode, let m2 = entry.change.after.mode {
                Text("\(String(m1, radix: 8))→\(String(m2, radix: 8))")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.purple)
            }
        }
    }
}
