import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle, set up from Info.plist: the feed (SUFeedURL), the key that
/// signs every update and the feed itself (SUPublicEDKey), no system
/// profile, and installs only when the user clicks Install. Sparkle asks
/// on the second launch whether to check automatically.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController
    /// False for builds without a feed (`swift run`) and for screenshots.
    let isAvailable: Bool
    @Published private(set) var canCheck = false
    private var lastRequest = Date.distantPast

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        isAvailable = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil && !AppDelegate.isSnapshot
        guard isAvailable else { return }
        controller.startUpdater()
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    var automaticallyChecks: Bool {
        get { isAvailable && controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        guard isAvailable else { return }
        controller.checkForUpdates(nil)
    }

    /// `mudroom update` opens the app with --check-for-updates, and posts
    /// this notification for a copy that is already running. Either way the
    /// user still sees the update and clicks Install. Any local program can
    /// post it, so it only opens the check, at most every 30 seconds, and
    /// doesn't pull the app in front of what the user is typing into.
    func listenForCLI() {
        guard isAvailable else { return }
        if CommandLine.arguments.contains("--check-for-updates") {
            lastRequest = Date()
            checkForUpdates()
        }
        let name = Notification.Name((Bundle.main.bundleIdentifier ?? "io.github.kernel-hunter.mudroom") + ".checkForUpdates")
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let updater = AppUpdater.shared
                guard Date().timeIntervalSince(updater.lastRequest) > 30 else { return }
                updater.lastRequest = Date()
                updater.checkForUpdates()
            }
        }
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecks },
                    set: { updater.automaticallyChecks = $0 }))
                    .disabled(!updater.isAvailable)
                Text("Once a day Mudroom reads its update feed from kernel-hunter.github.io. Nothing about your Mac or your projects is sent. An update is installed only when you click Install, and only if it is signed with Mudroom's key. The mudroom command in Terminal follows this setting.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                HStack {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    Spacer()
                    CheckForUpdatesButton(updater: updater)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}
