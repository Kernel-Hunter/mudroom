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
    @State private var networkMode: NetworkMode = .locked
    @State private var registries = false
    @State private var localModels = false
    @State private var projectHosts: [String] = []
    @State private var checkingNetwork = false
    @State private var networkProblem: NetworkProbe.Result?
    /// Set on the first click, so a double-click starts one session.
    @State private var starting = false

    private let customID = "custom"

    var preset: AgentPreset? { AgentPreset.all.first { $0.id == presetID } }

    var command: [String] {
        preset?.command ?? AgentPreset.parseCommand(customCommand)
    }

    /// nil for custom commands (we can't tell what they need).
    var signIn: SignInStatus? {
        guard let preset else { return nil }
        return app.setup.status(preset.id)
            ?? SignInStatus.check(preset, store: app.store, tokens: app.setup.tokens, environment: app.setup.sessionEnvironment)
    }

    /// Signed in, or an agent that can run on local models with them on.
    var isReady: Bool {
        guard let preset, let signIn else { return true }
        if signIn.isSignedIn { return true }
        return preset.isMultiProvider && localModels && networkMode == .locked && !aiderNeedsModel
    }

    /// Aider on local models only: it has to be told the model (Custom).
    var aiderNeedsModel: Bool {
        guard let project else { return false }
        return AgentPreset.aiderModelProblem(command: command, keys: [], workspace: project) != nil
    }

    /// Why the chosen folder can't be used (/, the home folder, Mudroom's store...).
    var projectProblem: String? {
        guard let project, let problem = app.store.projectProblem(project) else { return nil }
        let text = problem.description
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    var canStart: Bool { project != nil && projectProblem == nil && !command.isEmpty && isReady && !checkingNetwork && !starting }

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
                if let problem = projectProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section("Agent") {
                HStack(spacing: 8) {
                    ForEach(AgentPreset.all) { p in
                        AgentCard(title: p.name, symbol: AgentStyle.symbol(p.id), tint: AgentStyle.tint(p.id), selected: presetID == p.id) {
                            presetID = p.id
                        }
                    }
                    AgentCard(title: "Custom", symbol: "terminal", tint: .gray, selected: presetID == customID) {
                        presetID = customID
                    }
                }
                if presetID == customID {
                    TextField("Command, e.g. aider --model ollama_chat/qwen3", text: $customCommand)
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
                if let p = preset {
                    if let m = signIn?.method {
                        SignedInBadge(method: m)
                    } else if isReady {
                        Label("Uses local models from this Mac", systemImage: "desktopcomputer")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                            Text(localModels && aiderNeedsModel
                                 ? "Aider needs a model name to use local models. Pick Custom and run: aider --yes-always --no-auto-commits --model ollama_chat/<model>"
                                 : p.isMultiProvider ? "\(p.name) needs an API key (or local models, below)." : "\(p.name) isn't signed in yet.")
                                .font(.system(size: 11.5))
                            Spacer()
                            Button(p.isMultiProvider ? "Add a Key" : "Sign In First") {
                                app.openSetup(focus: p.isMultiProvider ? "keys" : p.id)
                                dismiss()
                            }
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.10)))
                    }
                }
            }

            section("Network") {
                Picker("Network", selection: $networkMode) {
                    Label("Locked", systemImage: "lock.shield").tag(NetworkMode.locked)
                    Label("Open", systemImage: "globe").tag(NetworkMode.open)
                    Label("Offline", systemImage: "wifi.slash").tag(NetworkMode.offline)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(networkHint)
                    .font(.system(size: 11)).foregroundStyle(networkMode == .open ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if networkMode == .locked {
                    Toggle("Also allow package registries (npm, PyPI, GitHub)", isOn: $registries)
                        .font(.system(size: 12))
                    Toggle("Local models (Ollama, LM Studio on this Mac)", isOn: $localModels)
                        .font(.system(size: 12))
                        .help("The VM reaches them at http://\(NetworkDefaults.hostServiceName):11434 and :1234 through Mudroom's proxy. No other port on this Mac is reachable.")
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

            if let problem = networkProblem {
                Banner(style: .warning, title: "The VM network isn't working",
                       detail: problem.summary.prefix(1).uppercased() + problem.summary.dropFirst() + ". Restarting the VM runtime usually fixes it.",
                       actions: AnyView(
                        Button(app.setup.networkBusy ? "Repairing…" : "Repair Network") {
                            Task {
                                await app.setup.repairNetwork(force: false)
                                if app.setup.networkReady { networkProblem = nil }
                            }
                        }
                        .disabled(app.setup.networkBusy)))
                if let e = app.setup.networkError {
                    Text(e).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if checkingNetwork {
                    ProgressView().controlSize(.small)
                    Text("Checking the VM network…").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                    Text("Opens in Terminal so you can talk to the agent.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Session") {
                    guard !starting else { return }
                    starting = true
                    Task { await start() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
        }
        .padding(22)
        .frame(width: 600)
        .onAppear {
            if project == nil, let recent = app.recentProjects.first { project = URL(fileURLWithPath: recent) }
            loadNetwork()
            app.setup.refreshSignIn()
        }
        .onChange(of: project) { loadNetwork() }
    }

    var configStore: ProjectConfigStore { ProjectConfigStore(store: app.store) }

    var networkHint: String {
        switch networkMode {
        case .locked:
            let agentHosts = NetworkDefaults.hosts(forAgent: preset?.id)
            var parts: [String] = []
            if preset?.isMultiProvider ?? true { parts.append("the API hosts of the provider keys you set") }
            else if !agentHosts.isEmpty { parts.append("\(preset?.name ?? "the agent")'s API") }
            if !projectHosts.isEmpty { parts.append("\(projectHosts.count) host\(projectHosts.count == 1 ? "" : "s") you allowed") }
            let what = parts.isEmpty ? "nothing (add hosts from the Network tab)" : parts.joined(separator: " and ")
            return "The VM can only reach \(what). Blocked attempts show up in the review."
        case .open:
            return "The VM gets normal internet access. Nothing is filtered or logged."
        case .offline:
            return "No internet at all. The agent can't reach its own API, so this suits local commands."
        }
    }

    /// Checks the VM network first (locked mode), so a broken one is
    /// repaired here instead of in a session that can't reach its API.
    func start() async {
        guard let project else { starting = false; return }
        saveNetwork(project)
        if networkMode == .locked {
            checkingNetwork = true
            let r = await app.setup.probeBeforeSession()
            checkingNetwork = false
            if r.needsRepair {
                networkProblem = r
                starting = false
                return
            }
        }
        app.startSession(project: project, preset: preset, customCommand: customCommand, image: image)
        dismiss()
    }

    func loadNetwork() {
        guard let project, let c = try? configStore.load(project.path) else { return }
        networkMode = c.networkMode
        registries = c.includePackageRegistries
        localModels = c.localModels
        projectHosts = c.allowedHosts.map(\.value)
    }

    func saveNetwork(_ project: URL) {
        do {
            try configStore.update(project.path) {
                $0.networkMode = networkMode
                $0.includePackageRegistries = registries
                $0.localModels = localModels
            }
        } catch {
            app.errorMessage = "Couldn't save the network setting: \(MudroomError.message(error))"
        }
    }

    func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
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
