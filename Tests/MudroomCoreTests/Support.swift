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
@testable import MudroomCore

/// A throwaway directory under the system temp dir, deleted on deinit.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mudroom-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ rel: String) -> URL { url.appendingPathComponent(rel) }
}

func write(_ text: String, to url: URL, mode: UInt16? = nil) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    if let mode { chmod(url.path, mode_t(mode)) }
}

func read(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

func exists(_ url: URL) -> Bool {
    #if os(Windows)
    if case .success = WinFS.lstat(url.path) { return true }
    return false
    #else
    var st = stat()
    return lstat(url.path, &st) == 0
    #endif
}

#if os(Windows)
/// Windows has no Unix permission bits, FIFOs or /bin/sh: tests of those
/// are skipped there, and Windows' own behaviour is tested instead.
let isWindows = true
/// Running as root, which reads files whatever their mode.
let isRoot = false
#else
let isWindows = false
let isRoot = getuid() == 0
#endif

/// The mode FileNode reports for a file written with `mode`: Windows has no
/// permission bits, so every file reads as 0644 there.
func expectedMode(_ mode: UInt16) -> UInt16 { isWindows ? 0o644 : mode }

/// A program that waits `seconds` and exits: /bin/sleep, or ping on Windows,
/// which has no sleep command.
func sleepCommand(_ seconds: Int) -> (String, [String]) {
    #if os(Windows)
    return (ProcessRunner.which("ping") ?? "C:\\Windows\\System32\\PING.EXE", ["-n", "\(seconds + 1)", "127.0.0.1"])
    #else
    return ("/bin/sleep", ["\(seconds)"])
    #endif
}

/// A program that prints `text` and exits 0.
func echoCommand(_ text: String) -> (String, [String]) {
    #if os(Windows)
    return (ProcessRunner.which("cmd") ?? "C:\\Windows\\System32\\cmd.exe", ["/c", "echo", text])
    #else
    return ("/bin/echo", [text])
    #endif
}

func modeOf(_ url: URL) throws -> UInt16? {
    try FileNode.read(at: url).mode
}

/// A project plus a session store, with the session already created.
struct Fixture {
    let tmp: TempDir
    let project: URL
    let store: SessionStore
    var handle: SessionHandle

    /// `populate` fills the project before the session is cloned.
    init(clone: Bool = true, populate: (URL) throws -> Void) throws {
        tmp = try TempDir()
        project = tmp.path("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try populate(project)
        store = SessionStore(root: tmp.path("store"))
        handle = try store.create(project: project, command: ["true"], image: "test", allowClonefile: clone)
    }

    var work: URL { handle.work }

    func diff() throws -> DiffResult { try Differ.compare(base: handle.base, work: handle.work) }
}
