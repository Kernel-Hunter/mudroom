import AppKit
import MudroomCore
import SwiftUI

@main
struct MudroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    init() {
        // Snapshots start from a clean window layout, whatever was open
        // (or minimized) last time.
        if AppDelegate.isSnapshot { UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true]) }
    }

    var body: some Scene {
        Window("Mudroom", id: "main") {
            RootView(app: app)
                .frame(minWidth: 980, minHeight: 560)
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Mudroom") { AppDelegate.showAbout() }
                Button("Setup…") { app.openSetup() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { app.showingNewSession = true }
                    .keyboardShortcut("n")
            }
            CommandMenu("Session") {
                let review = app.review
                let canApply = review?.canApply == true && (review?.applicableCount ?? 0) > 0
                Button("Apply Selected") { review?.applySelected() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canApply || review?.selectedCount == 0)
                Button("Apply All") { review?.applyAll() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!canApply)
                Button("Undo Last Apply") { review?.undo() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                    .disabled(review?.canUndo != true)
                Divider()
                Button("Toggle File") { review?.toggleFocused() }
                    .disabled(review?.focused?.canApply != true)
                Button("Select All Files") { review?.setAll(true) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                Button("Refresh") {
                    app.refresh()
                    review?.reload()
                }
                .keyboardShortcut("r")
                Button("Show Project in Finder") { review?.revealInFinder() }
                    .disabled(review == nil)
                Divider()
                Button("Discard Session…") { app.confirmDiscard = true }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(app.selectedHandle?.hasClones != true || review?.isRunning == true)
            }
        }

        Window("Mudroom Setup", id: "setup") {
            SetupWindowRoot(app: app)
        }
        .defaultSize(width: 720, height: 860)
        .windowResizability(.contentMinSize)
    }
}

/// The Setup window's content; Done closes it and brings up the main window.
struct SetupWindowRoot: View {
    let app: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SetupView(model: app.setup, runningSessions: app.runningSessions) {
            app.setup.login?.cancel()
            dismissWindow(id: "setup")
            openWindow(id: "main")
        }
        .task { if !app.setup.hasChecked && !app.setup.checking { await app.setup.refresh() } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "MudroomAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        // Screenshot hooks (scripts/screenshots.sh). They can apply changes,
        // so they only work when passed on the command line with a separate
        // MUDROOM_HOME, never from saved preferences.
        let args = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let demoStore = ProcessInfo.processInfo.environment["MUDROOM_HOME"].map { !$0.isEmpty } ?? false
        if demoStore, let path = args["MudroomSnapshot"] as? String {
            let delay = defaults.object(forKey: "MudroomSnapshotDelay") as? Double ?? 3
            // Optional scripted steps before the capture, for docs:
            // -MudroomSnapshotDeselectHunk path:id
            // -MudroomSnapshotAction applySelected|applyAll|undo|newSession|setup
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 2.5) {
                if args["MudroomSnapshotAction"] as? String == "newSession" {
                    Self.model?.showingNewSession = true
                    return
                }
                if args["MudroomSnapshotAction"] as? String == "setup" {
                    Self.model?.openSetup(focus: args["MudroomSnapshotFocus"] as? String)
                    return
                }
                guard let review = Self.model?.review else { return }
                if let spec = args["MudroomSnapshotDeselectHunk"] as? String,
                   let colon = spec.lastIndex(of: ":"), let id = Int(spec[spec.index(after: colon)...]) {
                    review.toggleHunk(String(spec[..<colon]), id)
                }
                switch args["MudroomSnapshotAction"] as? String {
                case "applySelected": review.applySelected()
                case "applyAll": review.applyAll()
                case "undo": review.undo()
                case "newSession": Self.model?.showingNewSession = true
                default: break
                }
            }
            let setupShot = args["MudroomSnapshotAction"] as? String == "setup"
            if !setupShot {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay - 1.5) { Self.prepareSidebarSnapshot() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.snapshot(to: URL(fileURLWithPath: path), title: setupShot ? "Mudroom Setup" : nil)
                // Not terminate(): an open sheet can hold it up.
                exit(0)
            }
        }
    }

    /// Set by RootView; used only for snapshots.
    @MainActor static var model: AppModel?
    @MainActor private static var sidebarWindow: NSWindow?
    static let sidebarWidth: CGFloat = 250

    /// The macOS 26 sidebar is a floating glass panel that a bitmap cache
    /// can't capture, so snapshots render the same SidebarView in a plain
    /// offscreen window and paste it in.
    @MainActor static func prepareSidebarSnapshot() {
        guard let model, let main = NSApp.windows.first(where: { $0.isVisible }) else { return }
        let height = main.contentLayoutRect.height
        let host = NSHostingView(rootView: SidebarView(app: model, forSnapshot: true)
            .frame(width: sidebarWidth, height: height)
            .background(Color(nsColor: .windowBackgroundColor)))
        let w = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: sidebarWidth, height: height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSApp.appearance
        w.contentView = host
        w.orderFrontRegardless()
        sidebarWindow = w
    }

    /// `-MudroomSnapshot out.png`: renders the main window (title bar and
    /// toolbar included) to a PNG and quits. Works without Screen Recording
    /// permission because the app only draws its own views. For docs/demos.
    /// True when started with -MudroomSnapshot (no first-run Setup then).
    static var isSnapshot: Bool {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["MudroomSnapshot"] != nil
    }

    @MainActor static func snapshot(to url: URL, title: String? = nil) {
        guard let window = NSApp.windows.first(where: {
                  $0.isVisible && $0.contentView != nil && $0 !== sidebarWindow && (title == nil || $0.title == title)
              }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            let titles = NSApp.windows.map { "\($0.title.isEmpty ? "untitled" : $0.title)\($0.isVisible ? "" : " (hidden)")\($0.isMiniaturized ? " (minimized)" : "")" }
                + ["app hidden: \(NSApp.isHidden)"]
            FileHandle.standardError.write(Data("snapshot: no window to capture; windows: \(titles.joined(separator: ", "))\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let side = sidebarWindow?.contentView,
           let sideRep = side.bitmapImageRepForCachingDisplay(in: side.bounds),
           let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            side.cacheDisplay(in: side.bounds, to: sideRep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            // Below the toolbar, left edge; bitmap coordinates are bottom-up.
            sideRep.draw(in: NSRect(x: 0, y: 0, width: side.bounds.width, height: side.bounds.height))
            NSColor.separatorColor.setFill()
            NSRect(x: side.bounds.width - 0.5, y: 0, width: 0.5, height: side.bounds.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if let sheet = window.attachedSheet, let sv = sheet.contentView?.superview ?? sheet.contentView,
           let sheetRep = sv.bitmapImageRepForCachingDisplay(in: sv.bounds),
           let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            sv.cacheDisplay(in: sv.bounds, to: sheetRep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            // Dim the window like the sheet backdrop, then place the sheet
            // centered under the toolbar.
            NSColor.black.withAlphaComponent(0.18).setFill()
            view.bounds.fill(using: .sourceAtop)
            let top = view.bounds.height - (view.bounds.height - window.contentLayoutRect.height)
            let r = NSRect(x: (view.bounds.width - sv.bounds.width) / 2, y: top - sv.bounds.height - 8,
                           width: sv.bounds.width, height: sv.bounds.height)
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 24
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.set()
            NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16).addClip()
            sheetRep.draw(in: r)
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor static func showAbout() {
        let credits = NSMutableAttributedString(
            string: "A pull-request gate for local coding agents.\nAgents work on a copy of your project in a Linux VM; you review and apply the diff.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(
            string: "github.com/Kernel-Hunter/mudroom",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .link: URL(string: "https://github.com/Kernel-Hunter/mudroom")!]))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        credits.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .init(rawValue: "Copyright"): "MIT License",
        ])
    }
}

struct RootView: View {
    @Bindable var app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(app: app)
                .navigationSplitViewColumnWidth(min: 220, ideal: AppDelegate.sidebarWidth, max: 320)
        } content: {
            Group {
                if let review = app.review {
                    FileListColumn(review: review, app: app)
                } else if app.sessions.isEmpty {
                    Color.clear
                } else {
                    ContentUnavailableView("No Session Selected", systemImage: "sidebar.left",
                                           description: Text("Pick a session in the sidebar."))
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 480)
        } detail: {
            Group {
                if let review = app.review, review.tab == .network {
                    NetworkDetailView(review: review)
                } else if let review = app.review, let entry = review.focused {
                    FileDetailView(review: review, entry: entry)
                } else if let review = app.review, let folder = review.focusedFolder {
                    FolderDetailView(review: review, folder: folder)
                } else if let review = app.review, !review.files.isEmpty {
                    ContentUnavailableView("No File Selected", systemImage: "doc.text",
                                           description: Text("Pick a file to see its changes."))
                } else if app.sessions.isEmpty {
                    WelcomeView(app: app)
                } else {
                    Color.clear
                }
            }
        }
        .navigationTitle(app.review.map { $0.handle.session.projectName } ?? "Mudroom")
        .navigationSubtitle(app.review.map { $0.handle.session.agentLabel } ?? "")
        .toolbar { toolbar }
        .onAppear { AppDelegate.model = app }
        .onChange(of: app.setupRequest) { openWindow(id: "setup") }
        .task {
            // First run, or something broke since: open Setup at that step.
            guard !AppDelegate.isSnapshot else { return }
            await app.setup.refresh()
            if !app.setup.allGreen { app.openSetup(focus: app.setupFocus) }
        }
        .sheet(isPresented: $app.showingNewSession) { NewSessionSheet(app: app) }
        .confirmationDialog("Discard this session?", isPresented: $app.confirmDiscard) {
            Button("Discard Session", role: .destructive) { app.discardSelected() }
        } message: {
            Text("The agent's copy is deleted and its changes are gone. Anything you already applied stays in your project, but can no longer be undone with Mudroom.")
        }
        .alert("Something went wrong", isPresented: .init(get: { app.errorMessage != nil },
                                                           set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK") { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { app.showingNewSession = true } label: { Label("New Session", systemImage: "plus") }
                .help("New Session (⌘N)")
        }
        if let review = app.review, review.handle.hasClones {
            ToolbarItemGroup(placement: .primaryAction) {
                if review.canUndo {
                    Button { review.undo() } label: { Label("Undo Apply", systemImage: "arrow.uturn.backward") }
                        .help("Undo the last apply (⌥⌘Z)")
                        .disabled(review.isWorking)
                }
                Button(role: .destructive) { app.confirmDiscard = true } label: {
                    Label("Discard", systemImage: "trash")
                }
                .help("Discard session (⌘⌫)")
                .disabled(review.isRunning)

                Button { review.applyAll() } label: { Text("Apply All") }
                    .help("Apply every change without conflicts (⇧⌘↩)")
                    .disabled(!review.canApply || review.applicableCount == 0)

                Button { review.applySelected() } label: {
                    Label(review.selectedCount > 0 ? "Apply \(review.selectedCount) Selected" : "Apply Selected",
                          systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .help("Apply the selected files and hunks (⌘↩)")
                .disabled(!review.canApply || review.selectedCount == 0)
            }
        }
    }
}

struct WelcomeView: View {
    let app: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Review before it lands", systemImage: "door.left.hand.open")
        } description: {
            Text("Start a session and an agent works on a copy of your project inside a Linux VM.\nWhen it's done, you pick which changes reach your real folder.")
        } actions: {
            Button("New Session…") { app.showingNewSession = true }
                .buttonStyle(.borderedProminent)
        }
    }
}
