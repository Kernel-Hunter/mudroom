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
                                Button("Remove from List…", role: .destructive) { app.removeFromList(h) }
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
        .overlay {
            if app.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                    Text("No sessions").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
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
