import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif
import Foundation
import MudroomCore

/// GitHub's latest-release endpoint. Debug builds can be pointed at a local
/// server with MUDROOM_UPDATE_TEST_URL, for tests; release builds can't.
func latestReleaseEndpoint() -> URL {
    #if DEBUG
    if let s = ProcessInfo.processInfo.environment["MUDROOM_UPDATE_TEST_URL"], let url = URL(string: s) { return url }
    #endif
    return UpdateCheck.latestReleaseURL
}

/// The Mac app's "Check for updates automatically" is off. The copy of the
/// CLI inside the app follows it.
func appUpdateChecksOff(_ method: InstallMethod) -> Bool {
    #if os(macOS)
    guard case .appBundle(let app, _) = method, let id = Bundle(url: app)?.bundleIdentifier else { return false }
    return UserDefaults(suiteName: id)?.object(forKey: "SUEnableAutomaticChecks") as? Bool == false
    #else
    return false
    #endif
}

/// The one-line notice after a command, when a release is out.
enum UpdateNoticeHook {
    static func begin(arguments: [String]) -> UpdateNoticeRun? {
        // Only for a person at a terminal, and never in machine output.
        guard UpdateNotice.allowed(arguments: arguments),
              isatty(STDERR_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
              let current = ReleaseVersion(mudroomVersion) else { return nil }
        let sessions = store()
        let method = InstallMethod.current()
        guard UpdateNotice.disabledReason(environment: ProcessInfo.processInfo.environment,
                                          settings: MudroomSettings.load(sessions),
                                          appChecksOff: appUpdateChecksOff(method)) == nil else { return nil }
        let endpoint = latestReleaseEndpoint()
        let run = UpdateNoticeRun(store: sessions, current: current) {
            UpdateCheck.fetchLatest(from: endpoint, currentVersion: mudroomVersion, timeout: 3)
        }
        run.begin()
        return run
    }

    /// Waits at most a second for a check still running (only a command
    /// shorter than that waits at all).
    static func finish(_ run: UpdateNoticeRun?) {
        guard let run, let line = run.finish(wait: 1) else { return }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check for a new release and install it the way Mudroom was installed.",
        discussion: """
        Homebrew: runs `brew upgrade --cask mudroom`. Mudroom.app from install.sh or the \
        zip: opens the app's updater. A Windows release zip: downloads the new zip, checks \
        it against the SHA-256 the release publishes and swaps the files in. Scoop and \
        winget: prints the command to run, since they can't replace mudroom.exe while it \
        runs. Asks before changing anything, unless --yes.

        Mudroom also checks once a day, after a command run in a terminal, and prints one \
        line when a release is out. Turn that off with `mudroom update --auto-check off` \
        or MUDROOM_NO_UPDATE_CHECK=1.
        """)

    @Flag(help: "Only check, and say how this copy would be updated.")
    var check = false

    @Flag(name: .shortAndLong, help: "Update without asking.")
    var yes = false

    @Option(help: "Turn the daily update check on or off.")
    var autoCheck: String?

    func validate() throws {
        if let autoCheck, !["on", "off"].contains(autoCheck) { throw ValidationError("--auto-check takes on or off") }
    }

    func run() throws {
        let sessions = store()
        if let autoCheck {
            var settings = MudroomSettings.load(sessions)
            settings.checkForUpdates = autoCheck == "on"
            do { try settings.save(sessions) } catch { fail(error) }
            print("The daily update check is \(autoCheck).")
            let method = InstallMethod.current()
            if autoCheck == "on", let why = UpdateNotice.disabledReason(environment: ProcessInfo.processInfo.environment,
                                                                        settings: settings, appChecksOff: appUpdateChecksOff(method)) {
                print("It still won't run here: \(why).")
            }
            return
        }

        guard let current = ReleaseVersion(mudroomVersion) else { fail(MudroomError.invalid("this build's version '\(mudroomVersion)' isn't a release version")) }
        let latest: LatestRelease
        switch UpdateCheck.fetchLatest(from: latestReleaseEndpoint(), currentVersion: mudroomVersion, timeout: 15) {
        case .success(let l): latest = l
        case .failure(let e): fail(MudroomError.invalid("couldn't check for updates: \(e)"))
        }
        var state = UpdateNoticeState.load(sessions)
        state.checked = Date()
        state.latest = latest.version.description
        try? state.save(sessions)

        guard latest.version > current else {
            print("Mudroom \(current) is up to date.")
            return
        }
        print("Mudroom \(latest.version) is available (you have \(current)).")
        print("Release notes: \(latest.pageURL)")
        try install(latest.version, method: InstallMethod.current())
    }

    func install(_ version: ReleaseVersion, method: InstallMethod) throws {
        switch method {
        case .appBundle(let app, let brew?):
            print("Homebrew installed Mudroom. Update with: brew upgrade --cask mudroom")
            guard !check else { return }
            guard confirm("Run it now?", yes: yes) else { return notUpdating() }
            fflush(nil)
            let status: Int32
            do { status = try ProcessRunner.runAttached(brew.path, ["upgrade", "--cask", "mudroom"]) } catch { fail(error) }
            if status != 0 { throw ExitCode(status) }
            print("Updated \(app.path).")

        case .appBundle(let app, nil):
            print("Mudroom.app updates itself, and this command with it: Mudroom > Check for Updates.")
            guard !check else { return }
            guard confirm("Open Mudroom and check now?", yes: yes) else { return notUpdating() }
            openAppUpdater(app)
            print("In Mudroom's update window, click Install Update. Mudroom restarts with \(version).")

        case .scoop:
            print("Scoop installed this copy. Update it with:\n  scoop update mudroom")
            print("(Scoop won't replace mudroom.exe while it runs, so mudroom doesn't run it for you.)")

        case .winget:
            print("winget installed this copy. Update it with:\n  winget upgrade --id \(InstallMethod.wingetID) --exact")
            print("(winget can't replace mudroom.exe while it runs, so mudroom doesn't run it for you.)")

        case .releaseZip(let dir):
            let zip = ReleaseZipUpdate.folderName(version: version, arch: ReleaseZipUpdate.currentArch) + ".zip"
            print("This copy came from a release zip. The update downloads \(zip), checks its SHA-256 and replaces the files in \(dir.path).")
            guard !check else { return }
            guard confirm("Update now?", yes: yes) else { return notUpdating() }
            do {
                try ReleaseZipUpdate.install(version, into: dir, currentVersion: mudroomVersion) { say($0) }
            } catch { fail(error) }
            print("Mudroom \(version) is installed. `mudroom --version` shows it from the next command on.")

        case .source:
            print("This copy wasn't installed from a release (a build from source?). Update the checkout and rebuild:")
            print("  git pull && swift build -c release")
        }
    }

    func notUpdating() {
        print(stdinIsTTY ? "Not updated." : "Not updated: pass --yes to update without a terminal to ask in.")
    }

    /// Opens this copy of Mudroom.app with its update check. A running app
    /// gets the request as a notification instead of the argument.
    func openAppUpdater(_ app: URL) {
        #if os(macOS)
        do {
            let r = try ProcessRunner.capture("/usr/bin/open", ["-a", app.path, "--args", "--check-for-updates"], timeout: 30)
            if r.status != 0 { fail(MudroomError.commandFailed("open -a \(app.path)", r.status, r.stderr)) }
        } catch { fail(error) }
        if let id = Bundle(url: app)?.bundleIdentifier {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(id + ".checkForUpdates"), object: nil, userInfo: nil, deliverImmediately: true)
        }
        #endif
    }
}
