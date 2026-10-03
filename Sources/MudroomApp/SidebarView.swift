import MudroomCore
import SwiftUI

struct SidebarView: View {
    @Bindable var app: AppModel
    /// Offscreen snapshots: the sidebar style's glass selection doesn't
    /// render into a bitmap, the inset style does.
    var forSnapshot = false

    var body: some View {
        List(selection: $app.selectedSessionID) {
            ForEach(app.groups) { group in
                Section {
                    ForEach(group.sessions, id: \.session.id) { h in
                        SessionRow(handle: h)
                            .tag(h.session.id)
                            .contextMenu {
                                Button("Show Project in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([h.project])
                                }
                                if SessionPhase(h) == .notStarted {
                                    Button("Start Agent in Terminal") { app.runAgain(h) }
                                }
                                Divider()
                                Button("Remove from List…", role: .destructive) { app.confirmRemove = h }
                                    .disabled(h.isRunnerAlive)
                            }
                    }
                } header: {
                    Label(group.name, systemImage: "folder")
                        .help(group.path)
                }
            }
        }
        .modifier(SidebarListStyle(forSnapshot: forSnapshot))
        .confirmationDialog("Remove this session from the list?",
                            isPresented: .init(get: { app.confirmRemove != nil }, set: { if !$0 { app.confirmRemove = nil } }),
                            presenting: app.confirmRemove) { h in
            Button("Remove Session", role: .destructive) { app.removeFromList(h) }
        } message: { h in
            Text(SessionPhase(h) == .discarded
                 ? "Its record is deleted."
                 : "The agent's copy and its changes are deleted. Anything you already applied stays in your project, but can no longer be undone with Mudroom.")
        }
        .overlay {
            if app.sessions.isEmpty && app.creatingSession == nil {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                    Text("No sessions").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if let name = app.creatingSession {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Copying \(name) for the agent…").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    Divider().padding(.horizontal, 10)
                }
                if let problem = app.setup.problems.first, !forSnapshot {
                    Button { app.openSetup(focus: app.setupFocus) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Setup needs attention").font(.system(size: 11.5, weight: .semibold))
                                Text(problem).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open Setup")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    Divider().padding(.horizontal, 10)
                }
                Button {
                    app.showingNewSession = true
                } label: {
                    Label("New Session", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            // Rows scroll under the footer; keep them from showing through.
            .background(.bar)
        }
    }
}

struct SessionRow: View {
    let handle: SessionHandle

    var body: some View {
        let s = handle.session
        let phase = SessionPhase(handle)
        HStack(spacing: 9) {
            AgentIcon(session: s, size: 24)
                .opacity(phase == .discarded ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.agentLabel)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(phase == .discarded ? .secondary : .primary)
                HStack(spacing: 4) {
                    if phase == .running {
                        PulsingDot(color: phase.color)
                    } else {
                        Image(systemName: phase.symbol).font(.system(size: 8, weight: .bold))
                            .foregroundStyle(phase.color)
                    }
                    Text(phase.title)
                        .foregroundStyle(phase == .discarded || phase == .notStarted ? Color.secondary : phase.color)
                        .fontWeight(.medium)
                    Text("· " + (s.finished ?? s.started ?? s.created).relative)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10.5))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct SidebarListStyle: ViewModifier {
    let forSnapshot: Bool
    func body(content: Content) -> some View {
        if forSnapshot {
            content.listStyle(.inset).scrollContentBackground(.hidden)
        } else {
            content.listStyle(.sidebar)
        }
    }
}
