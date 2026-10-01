#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
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
    var st = stat()
    return lstat(url.path, &st) == 0
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
