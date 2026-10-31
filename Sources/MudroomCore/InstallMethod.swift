import Foundation

/// How this copy of the `mudroom` CLI was installed, which decides what
/// `mudroom update` does.
public enum InstallMethod: Equatable, Sendable {
    /// Inside Mudroom.app (Homebrew cask, install.sh or the zip). The app
    /// updates itself, CLI included; `homebrew` is the cask's `brew`.
    case appBundle(app: URL, homebrew: URL?)
    /// `scoop install mudroom`.
    case scoop
    /// `winget install KernelHunter.Mudroom`.
    case winget
    /// A Windows release zip unpacked by hand: mudroom.exe with its DLLs.
    case releaseZip(directory: URL)
    /// Built from source, or something this doesn't recognize.
    case source

    public static let wingetID = "KernelHunter.Mudroom"

    /// `executable` is this program's path with symlinks resolved.
    /// `exists` is asked about paths only, so tests can use fake trees.
    public static func detect(executable: URL, windows: Bool, exists: (URL) -> Bool,
                              contents: (URL) -> [String] = { _ in [] }) -> InstallMethod {
        let parts = executable.pathComponents
        let lower = parts.map { $0.lowercased() }
        let dir = executable.deletingLastPathComponent()

        if !windows, parts.count >= 4,
           Array(lower.suffix(3)) == ["contents", "helpers", "mudroom"], parts[parts.count - 4].hasSuffix(".app") {
            let app = URL(fileURLWithPath: dir.deletingLastPathComponent().deletingLastPathComponent().path, isDirectory: true)
            return .appBundle(app: app, homebrew: homebrew(exists: exists))
        }
        guard windows else { return .source }

        // <root>\apps\mudroom\<version or current>\mudroom.exe, with <root>\shims.
        if lower.count >= 4, lower[lower.count - 4] == "apps", lower[lower.count - 3] == "mudroom" {
            let root = dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if exists(root.appendingPathComponent("shims")) { return .scoop }
        }
        // ...\WinGet\Packages\KernelHunter.Mudroom_<source>\<folder>\mudroom.exe
        if let i = lower.firstIndex(of: "packages"), i > 0, lower[i - 1] == "winget", i + 1 < lower.count,
           lower[i + 1].hasPrefix(wingetID.lowercased() + "_") {
            return .winget
        }
        if isReleaseZipFolder(contents(dir)) { return .releaseZip(directory: URL(fileURLWithPath: dir.path, isDirectory: true)) }
        return .source
    }

    /// A folder unpacked from a release zip: mudroom.exe, its license and
    /// the Swift runtime, and no other program. `mudroom update` replaces
    /// files there, so a shared tools folder (other .exe files, or
    /// another Swift program's DLLs without our LICENSE.txt) doesn't count.
    static func isReleaseZipFolder(_ names: [String]) -> Bool {
        let lower = Set(names.map { $0.lowercased() })
        guard lower.isSuperset(of: ["mudroom.exe", "license.txt", "swiftcore.dll", "foundation.dll"]) else { return false }
        return !lower.contains { $0.hasSuffix(".exe") && $0 != "mudroom.exe" }
    }

    /// The `brew` that installed the mudroom cask, if one did.
    static func homebrew(exists: (URL) -> Bool) -> URL? {
        // The two standard prefixes only: `mudroom update --yes` runs this
        // brew, so it isn't taken from the environment.
        for p in ["/opt/homebrew", "/usr/local"] {
            let prefix = URL(fileURLWithPath: p, isDirectory: true)
            let brew = prefix.appendingPathComponent("bin/brew")
            if exists(prefix.appendingPathComponent("Caskroom/mudroom")) && exists(brew) { return brew }
        }
        return nil
    }

    /// This program's path, symlinks resolved.
    public static func currentExecutable() -> URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath()
    }

    public static func current() -> InstallMethod {
        guard let exe = currentExecutable() else { return .source }
        #if os(Windows)
        let windows = true
        #else
        let windows = false
        #endif
        return detect(executable: exe, windows: windows, exists: { FileManager.default.fileExists(atPath: $0.path) },
                      contents: { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] })
    }
}
