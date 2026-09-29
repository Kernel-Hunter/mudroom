import AppKit
import MudroomCore
import SwiftUI

struct NewSessionSheet: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var project: URL?
    @State private var presetID = AgentPreset.claude.id
    @State private var customCommand = ""
    @State private var image = AppleContainerBackend.defaultImage
    @State private var showAdvanced = false

    private let customID = "custom"

    var preset: AgentPreset? { AgentPreset.all.first { $0.id == presetID } }

    var command: [String] {
        preset?.command ?? AgentPreset.parseCommand(customCommand)
    }

    var canStart: Bool { project != nil && !command.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.and.arrow.backward")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Session").font(.title3.weight(.semibold))
                    Text("The agent works on a copy of the folder inside a Linux VM. Nothing reaches your files until you apply it.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section("Project") {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    Text(project?.path ?? "No folder chosen")
                        .font(.system(size: 12, design: project == nil ? .default : .monospaced))
                        .foregroundStyle(project == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if !app.recentProjects.isEmpty {
                        Menu {
                            ForEach(app.recentProjects, id: \.self) { p in
                                Button((p as NSString).abbreviatingWithTildeInPath) { project = URL(fileURLWithPath: p) }
                            }
                        } label: { Image(systemName: "clock") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Recent projects")
                    }
                    Button("Choose…", action: choose)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
            }

            section("Agent") {
                HStack(spacing: 8) {
                    ForEach(AgentPreset.all) { p in
                        AgentCard(title: p.name, symbol: symbol(p.id), tint: tint(p.id), selected: presetID == p.id) {
                            presetID = p.id
                        }
                    }
                    AgentCard(title: "Custom", symbol: "terminal", tint: .gray, selected: presetID == customID) {
                        presetID = customID
                    }
                }
                if presetID == customID {
                    TextField("Command, e.g. aider --yes", text: $customCommand)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right.2").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(command.isEmpty ? "—" : command.joined(separator: " "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let key = preset?.credential {
                    Text("\(key) is passed into the VM if it is set in your shell.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                LabeledContent("Image") {
                    TextField("Image", text: $image).textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                .padding(.top, 6)
            }
            .font(.system(size: 12))

            HStack {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text("Opens in Terminal so you can talk to the agent.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Session") {
                    guard let project else { return }
                    app.startSession(project: project, preset: preset, customCommand: customCommand, image: image)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
        }
        .padding(22)
        .frame(width: 540)
        .onAppear {
            if project == nil, let recent = app.recentProjects.first { project = URL(fileURLWithPath: recent) }
        }
    }

    func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    func symbol(_ id: String) -> String {
        switch id {
        case "claude": "sparkle"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "gemini": "diamond"
        default: "terminal"
        }
    }

    func tint(_ id: String) -> Color {
        switch id {
        case "claude": .orange
        case "codex": .teal
        case "gemini": .indigo
        default: .gray
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder the agent should work on. Mudroom works on a copy."
        if let project { panel.directoryURL = project }
        if panel.runModal() == .OK, let url = panel.url { project = url }
    }
}

private struct AgentCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 32, height: 32)
                    .overlay(Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
