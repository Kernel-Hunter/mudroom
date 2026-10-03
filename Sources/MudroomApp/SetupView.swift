import AppKit
import MudroomCore
import SwiftUI

/// First-run setup: one card per step, each with its status and one button.
struct SetupView: View {
    @Bindable var model: SetupModel
    let runningSessions: Int
    var onDone: () -> Void
    @State private var confirmRepair = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        runtimeCard.id("runtime")
                        imageCard.id("image")
                        networkCard.id("network")
                        signInSection
                    }
                    .padding(24)
                }
                .onChange(of: model.focus) { _, f in
                    guard let f else { return }
                    withAnimation { proxy.scrollTo(f, anchor: .top) }
                }
                .onAppear {
                    if let f = model.focus {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo(f, anchor: .top) }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 600, idealHeight: 860)
        .confirmationDialog("Restart the container system?", isPresented: $confirmRepair) {
            Button("Restart and Repair", role: .destructive) { Task { await model.repairNetwork(force: true) } }
        } message: {
            Text(runningSessions > 0
                 ? "\(runningSessions) session\(runningSessions == 1 ? " is" : "s are") running. Restarting stops \(runningSessions == 1 ? "its VM" : "their VMs"); the agent's work so far stays in the session."
                 : "This stops every container on this Mac for a few seconds.")
        }
    }

    var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "door.left.hand.open")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Set up Mudroom").font(.title2.weight(.semibold))
                Text("Agents run in a small Linux VM on this Mac. These steps get the VM ready and sign your agents in once, so sessions start without questions.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.checking { ProgressView().controlSize(.small) }
        }
    }

    var footer: some View {
        HStack {
            if let first = model.problems.first {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(first + (model.problems.count > 1 ? " (+\(model.problems.count - 1) more)" : ""))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if model.hasChecked {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Everything is ready.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Check Again") { Task { await model.refresh() } }
                .disabled(model.checking)
            // No Return shortcut: Return in the sign-in code or a key field
            // would close the window, cancelling the sign-in or losing the key.
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // MARK: Steps

    var runtimeCard: some View {
        let state = model.runtime
        let status: StepStatus = model.runtimeBusy ? .working : state == nil ? .checking : state!.isReady ? .done : .todo
        return StepCard(number: 1, title: "VM runtime", status: status, detail: runtimeDetail) {
            switch state {
            case .notInstalled(let brew?) where model.resolvedBackend == .apple:
                Button("Install") { Task { await model.installRuntime() } }
                    .buttonStyle(.borderedProminent).disabled(model.runtimeBusy)
                let _ = brew
            case .notInstalled:
                CommandHint(command: model.resolvedBackend == .apple ? RuntimeSetup.installCommand : "",
                            link: model.resolvedBackend == .apple ? RuntimeSetup.projectURL : RuntimeSetup.dockerURL)
            case .stopped:
                Button("Start") { Task { await model.startRuntime() } }
                    .buttonStyle(.borderedProminent).disabled(model.runtimeBusy)
            default:
                EmptyView()
            }
        } extra: {
            if model.runtimeBusy || model.runtimeError != nil, !model.runtimeLog.isEmpty {
                LogBox(lines: Array(model.runtimeLog.suffix(6)))
            }
            if let e = model.runtimeError { ErrorText(e) }
        }
    }

    var runtimeDetail: String {
        switch model.runtime {
        case nil: return "Checking…"
        case .notInstalled(let brew):
            if model.resolvedBackend != .apple { return "\(model.resolvedBackend.rawValue) isn't installed." }
            return brew == nil
                ? "Apple's container runtime isn't installed, and Homebrew wasn't found. Install it with Homebrew or the package from GitHub."
                : "Apple's container runtime isn't installed. Install runs `\(RuntimeSetup.installCommand)`."
        case .unsupported(let why): return why
        case .stopped: return model.runtimeBusy ? "Starting… The first start downloads Apple's recommended Linux kernel." : "Installed, not running. Start also installs Apple's recommended Linux kernel the first time."
        case .running(_, let version): return "Running (\(version.replacingOccurrences(of: "container CLI version ", with: "container ").components(separatedBy: " (").first ?? version))."
        }
    }

    var imageCard: some View {
        // nil and not checking: the check couldn't run (no spinner forever).
        let status: StepStatus = model.imageBusy ? .working : !model.runtimeReady ? .waiting
            : model.image == nil ? (model.checking ? .checking : .todo) : model.image == .current ? .done : .todo
        let detail: String = switch (model.imageBusy, model.image) {
        case (true, _): model.imageStep
        case (_, .current?): "\(AgentBaseImage.tag) is built and up to date."
        case (_, .outdated?): "This image was built by an older Mudroom. Rebuild it to get the current agents."
        case (_, .missing?): "Node and the agent CLIs (Claude Code, Codex, Gemini CLI, opencode, Aider). A few minutes, about 2 GB."
        default: !model.runtimeReady ? "Needs the VM runtime first." : model.checking ? "Checking…" : "Not checked yet. Press Check Again."
        }
        return StepCard(number: 2, title: "Agent image", status: status, detail: detail) {
            if model.runtimeReady, !model.imageBusy, let image = model.image, image != .current {
                Button(image == .missing ? "Build" : "Rebuild") { Task { await model.buildImage() } }
                    .buttonStyle(.borderedProminent)
            }
        } extra: {
            if model.imageBusy { ProgressView(value: model.imageProgress).progressViewStyle(.linear) }
            if let e = model.imageError { ErrorText(e) }
        }
    }

    var networkCard: some View {
        let r = model.network
        let status: StepStatus = model.networkBusy ? .working : !(model.runtimeReady && model.image != nil && model.image != .missing) ? .waiting
            : r == nil ? (model.checking ? .checking : .todo) : r!.isOK ? .done : .todo
        let detail: String = if model.networkBusy { model.networkStep ?? "Checking…" }
            else if let r { r.isOK ? "A VM reaches Mudroom's network proxy on this Mac." : r.summary.prefix(1).uppercased() + r.summary.dropFirst() + "." }
            else if status == .waiting { "Needs the runtime and image first." }
            else if model.checking { "Checking…" }
            else { "Not checked yet." }
        return StepCard(number: 3, title: "VM network", status: status, detail: detail) {
            if status != .waiting && !model.networkBusy {
                if let r, !r.isOK, model.resolvedBackend == .apple {
                    Button("Repair Network") { confirmRepair = true }
                        .buttonStyle(.borderedProminent)
                }
                Button(r == nil ? "Check" : "Check Again") { Task { await model.checkNetwork() } }
            }
        } extra: {
            if let e = model.networkError { ErrorText(e) }
        }
    }

    // MARK: Sign in

    var signInSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StepBadge(number: 4, status: model.anySignedIn ? .done : .todo)
                Text("Sign in").font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            Text("Sign in each agent you want to use. Logins and keys are kept by Mudroom (keys in the Keychain), never in your project.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(SetupModel.signInAgents) { p in
                    AgentSignInCard(model: model, preset: p).id(p.id)
                }
                OtherAgentsCard(model: model)
            }
            APIKeysCard(model: model).id("keys")
            if let e = model.keyError { ErrorText(e) }
        }
        .padding(.top, 6)
    }
}

enum StepStatus { case done, todo, working, checking, waiting }

struct StepBadge: View {
    let number: Int
    let status: StepStatus

    var body: some View {
        ZStack {
            Circle().fill(fill).frame(width: 24, height: 24)
            switch status {
            case .done: Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            case .working, .checking: ProgressView().controlSize(.mini)
            default: Text("\(number)").font(.system(size: 12, weight: .semibold)).foregroundStyle(status == .waiting ? Color.secondary : Color.white)
            }
        }
    }

    var fill: Color {
        switch status {
        case .done: .green
        case .todo: .orange
        case .working, .checking: Color.secondary.opacity(0.15)
        case .waiting: Color.secondary.opacity(0.15)
        }
    }
}

struct StepCard<Actions: View, Extra: View>: View {
    let number: Int
    let title: String
    let status: StepStatus
    let detail: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                StepBadge(number: number, status: status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) { actions }
            }
            extra
        }
        .padding(14)
        .background(CardBackground(highlight: status == .todo))
    }
}

struct CardBackground: View {
    var highlight = false
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.secondary.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(highlight ? Color.orange.opacity(0.45) : Color.secondary.opacity(0.15)))
    }
}

struct LogBox: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
        .textSelection(.enabled)
    }
}

struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11.5)).foregroundStyle(.red)
            .lineLimit(6)
            .textSelection(.enabled)
    }
}

struct CommandHint: View {
    let command: String
    let link: String
    var body: some View {
        HStack(spacing: 6) {
            if !command.isEmpty {
                Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Button { copy(command) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
            }
            if let url = URL(string: link) { Link("Download", destination: url).font(.system(size: 12)) }
        }
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// Name, symbol and color for each agent, shared by the cards and icons.
enum AgentStyle {
    static func symbol(_ id: String) -> String {
        switch id {
        case "claude": "sparkle"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "gemini": "diamond"
        case "opencode": "curlybraces"
        case "aider": "wand.and.stars"
        default: "terminal"
        }
    }

    static func tint(_ id: String) -> Color {
        switch id {
        case "claude": .orange
        case "codex": .teal
        case "gemini": .indigo
        case "opencode": .mint
        case "aider": .green
        default: .gray
        }
    }
}

struct AgentTile: View {
    let id: String
    var size: CGFloat = 28
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(AgentStyle.tint(id).gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: AgentStyle.symbol(id)).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white))
    }
}

struct SignedInBadge: View {
    let method: String
    var body: some View {
        Label("Signed in · \(method)", systemImage: "checkmark.seal.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.green)
            .lineLimit(1)
    }
}

struct AgentSignInCard: View {
    @Bindable var model: SetupModel
    let preset: AgentPreset

    var status: SignInStatus? { model.status(preset.id) }
    var hostLogin: HostLogin? { HostLogin.forAgent(preset.id).flatMap { $0.isAvailable ? $0 : nil } }
    var active: LoginConsole? { model.login?.agent == preset.id && model.login?.finished == false ? model.login : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentTile(id: preset.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.system(size: 13, weight: .semibold))
                    if let m = status?.method { SignedInBadge(method: m) }
                    else { Text("Not signed in").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer()
                if status?.isSignedIn == true, active == nil {
                    Button("Sign Out") { model.signOut(preset.id) }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            if let console = active {
                LoginConsoleView(console: console)
            } else if status?.isSignedIn != true {
                options
                if let last = model.login, last.agent == preset.id, last.finished, let e = last.error { ErrorText(e) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(CardBackground())
    }

    @ViewBuilder var options: some View {
        switch preset.id {
        case "claude":
            if model.hostClaude != nil {
                Button("Use my Claude account") { model.signInClaudeWithAccount() }
                    .buttonStyle(.borderedProminent)
                Caption("Runs `claude setup-token` on this Mac. Your browser opens; approve it there and you're done.")
                Button("Sign in inside the VM instead") { model.signInInVM("claude") }
                    .buttonStyle(.link).font(.system(size: 11))
            } else {
                Button("Sign In") { model.signInInVM("claude") }.buttonStyle(.borderedProminent)
                Caption("The sign-in page opens in your browser. Paste the code it shows into the field that appears here.")
            }
        case "codex", "gemini":
            if let login = hostLogin {
                Button(preset.id == "codex" ? "Use my ChatGPT login" : "Use my Google login") { model.importLogin(preset.id) }
                    .buttonStyle(.borderedProminent)
                Caption("Copies \(login.displayPath) into Mudroom's own folder. The original stays as it is.")
                Button(preset.id == "codex" ? "Sign in with a device code instead" : "Sign in inside the VM instead") { model.signInInVM(preset.id) }
                    .buttonStyle(.link).font(.system(size: 11))
            } else {
                Button(preset.id == "codex" ? "Sign in with a device code" : "Sign In") { model.signInInVM(preset.id) }
                    .buttonStyle(.borderedProminent)
                Caption(preset.id == "codex"
                        ? "Shows a code here and opens the ChatGPT page in your browser. Or add an OPENAI_API_KEY below."
                        : "Choose \"Login with Google\" (press Send), finish in your browser. Or add a GEMINI_API_KEY below.")
            }
        default:
            EmptyView()
        }
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(.init(text)).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct OtherAgentsCard: View {
    let model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                AgentTile(id: "opencode")
                AgentTile(id: "aider")
                VStack(alignment: .leading, spacing: 2) {
                    Text("opencode and Aider").font(.system(size: 13, weight: .semibold))
                    if let m = model.status("aider")?.method { SignedInBadge(method: m) }
                    else { Text("Need an API key").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
            Caption("They use any provider key you add below (OpenRouter covers most models), or local models from Ollama or LM Studio, which you turn on per project in New Session.")
            Button("Add a Key") { model.focus = nil; DispatchQueue.main.async { model.focus = "keys" } }
                .buttonStyle(.link).font(.system(size: 11))
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(CardBackground())
    }
}

struct LoginConsoleView: View {
    @Bindable var console: LoginConsole

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let code = console.deviceCode {
                HStack(spacing: 8) {
                    Text(code).font(.system(size: 20, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Button { copy(code) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy the code")
                }
                Caption("Enter this code on the page that opened in your browser.")
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(console.kind == .claudeHost ? "Waiting for you to approve in the browser…" : "Starting the sign-in in a VM…")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            if !console.lines.isEmpty {
                LogBox(lines: console.lines.filter { !$0.contains("won't appear when you paste") })
            }
            if console.deviceCode == nil {
                HStack(spacing: 6) {
                    TextField("Paste the code from the browser", text: $console.code)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { console.sendCode() }
                    Button("Send") { console.sendCode() }
                }
            }
            HStack {
                if !console.links.isEmpty {
                    Button("Open Sign-in Page Again") { console.openLink() }.buttonStyle(.link).font(.system(size: 11))
                }
                Spacer()
                Button("Cancel") { console.cancel() }.font(.system(size: 11))
            }
        }
    }
}

struct APIKeysCard: View {
    @Bindable var model: SetupModel
    @State private var values: [String: String] = [:]
    @State private var customName = ""
    @State private var customValue = ""

    var custom: [String] { model.keys.filter { APIKeys.provider($0) == nil }.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").font(.system(size: 14)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.gray.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text("API keys").font(.system(size: 13, weight: .semibold))
                    Text("Saved in the Keychain and passed to sessions by name. A provider's API host is allowed once its key is set.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(APIKeys.providers) { p in
                    keyRow(p.variable, title: p.name)
                }
                ForEach(custom, id: \.self) { n in keyRow(n, title: "Custom") }
                GridRow {
                    TextField("CUSTOM_NAME", text: $customName)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                        .frame(width: 150)
                    SecureField("Value", text: $customValue).textFieldStyle(.roundedBorder)
                        .onSubmit(saveCustom)
                    Button("Save", action: saveCustom)
                        .disabled(customName.isEmpty || customValue.isEmpty)
                }
            }
        }
        .padding(14)
        .background(CardBackground())
    }

    @ViewBuilder func keyRow(_ name: String, title: String) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(name).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
            if model.keys.contains(name) {
                Label("Saved", systemImage: "checkmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(.green)
                Button("Remove") { model.removeKey(name) }
            } else {
                SecureField("Paste key", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save(name) }
                Button("Save") { save(name) }
                    .disabled((values[name] ?? "").isEmpty)
            }
        }
    }

    func save(_ name: String) {
        guard let value = values[name], !value.isEmpty else { return }
        if model.saveKey(name, value) { values[name] = nil }
    }

    func saveCustom() {
        guard !customName.isEmpty, !customValue.isEmpty else { return }
        if model.saveKey(customName, customValue) { customName = ""; customValue = "" }
    }
}
