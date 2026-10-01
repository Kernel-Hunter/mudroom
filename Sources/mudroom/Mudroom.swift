import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import MudroomCore

@main
struct Mudroom: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mudroom",
        abstract: "A pull-request gate for local coding agents.",
        discussion: """
        The agent works on a copy of your project inside a Linux micro-VM. Nothing \
        touches your real folder until you review the diff and apply it.
        """,
        version: mudroomVersion,
        subcommands: [Run.self, New.self, Start.self, Diff.self, Hunks.self, Apply.self, Undo.self, Snapshots.self,
                      NetworkCommand.self, Agent.self, List.self, Discard.self, Image.self]
    )
}

func store() -> SessionStore { SessionStore.defaultStore() }

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("mudroom: \(error)\n".utf8))
    exit(1)
}

/// Options shared by `run` and `start`.
struct RunFlags: ParsableArguments {
    @Option(help: "CPUs for the VM.")
    var cpus: Int?

    @Option(help: "Memory for the VM, e.g. 4G.")
    var memory: String?

    @Option(help: "Network for this run: locked (allowlist), open or offline. Default: the project's setting.")
    var network: NetworkMode?

    @Option(name: .customLong("allow"), help: "Also allow this host for this run (repeatable, e.g. --allow '*.example.com').")
    var allow: [String] = []

    @Option(help: "Minutes between snapshots of the agent's copy (0 = only when it exits). Default: the project's setting.")
    var snapshotEvery: Int?

    @Option(help: "Keep at most this many snapshots.")
    var snapshotLimit: Int?

    func options(tty: Bool) throws -> RunOptions {
        var hosts: [HostPattern] = []
        for raw in allow {
            guard let p = HostPattern(raw) else { throw ValidationError("not a host name or *.suffix pattern: \(raw)") }
            hosts.append(p)
        }
        return RunOptions(tty: tty, cpus: cpus, memory: memory, networkMode: network, extraHosts: hosts,
                          snapshotMinutes: snapshotEvery, snapshotLimit: snapshotLimit)
    }
}

extension NetworkMode: ExpressibleByArgument {}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clone a project into a new session and run an agent on the clone.")

    @Argument(help: "The project directory. It is cloned, never mounted.")
    var project: String

    @Option(help: "Container image to run.")
    var image: String = AppleContainerBackend.defaultImage

    @OptionGroup var flags: RunFlags

    @Flag(help: "Copy instead of a copy-on-write clone (for testing).")
    var noClone = false

    @Argument(parsing: .postTerminator, help: "Command to run inside the VM (after --). Defaults to the image's command.")
    var command: [String] = []

    func run() throws {
        let backend = AppleContainerBackend()
        do { try backend.checkAvailable() } catch { fail(error) }

        let projectURL = URL(fileURLWithPath: project, isDirectory: true)
        var handle: SessionHandle
        do {
            handle = try store().create(project: projectURL, command: command, image: image, allowClonefile: !noClone)
        } catch { fail(error) }

        let s = handle.session
        print("session \(s.id)  (\(s.cloneMethod.label))")
        print("project \(s.projectPath) stays untouched; the agent sees a copy at /workspace")

        try runAgent(&handle, backend: backend, flags: flags)
    }
}

/// Shared by `run` and `start`: runs the agent attached to this terminal and
/// prints a summary of what changed.
func runAgent(_ handle: inout SessionHandle, backend: SandboxBackend, flags: RunFlags) throws {
    let tty = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    var options: RunOptions
    do { options = try flags.options(tty: tty) } catch { fail(error) }
    if !options.environmentNames.isEmpty { print("passing through: \(options.environmentNames.joined(separator: ", "))") }
    let result: SessionRunner.Result
    do {
        let runner = SessionRunner(backend: backend, store: store()) { line in
            print(line)
            fflush(nil)
        }
        fflush(nil)
        result = try runner.run(&handle, options: options)
    } catch { fail(error) }

    let id = handle.session.id
    print("\nagent exited with status \(result.status). Changes in session \(id):")
    let diff = try Differ.compare(base: handle.base, work: handle.work)
    print(DiffRenderer(base: handle.base, work: handle.work).stat(diff))
    if result.network.mode == .locked {
        let blocked = result.blocked.isEmpty ? "" : "; blocked: \(result.blocked.joined(separator: ", "))"
        print("network: \(result.connections) connections\(blocked). Details: mudroom network log \(id)")
    }
    if result.snapshotCount > 0 {
        print("snapshots: \(result.snapshotCount). List: mudroom snapshots \(id)")
    }
    print("\nreview: mudroom diff \(id)    apply: mudroom apply \(id) --all    drop: mudroom discard \(id)")
    if result.status != 0 { throw ExitCode(result.status) }
}

struct New: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a session (clone the project) without starting the agent.",
        discussion: "Prints the session id. Start it later with `mudroom start <id>`.")

    @Argument(help: "The project directory.")
    var project: String

    @Option(help: "Container image to run.")
    var image: String = AppleContainerBackend.defaultImage

    @Option(help: "Agent name to record, e.g. \"Claude Code\".")
    var agent: String?

    @Argument(parsing: .postTerminator, help: "Command to run inside the VM (after --).")
    var command: [String] = []

    func run() throws {
        do {
            let handle = try store().create(project: URL(fileURLWithPath: project, isDirectory: true),
                                            command: command, image: image, agent: agent)
            print(handle.session.id)
        } catch { fail(error) }
    }
}

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the agent for a session created with `mudroom new` (or by the app).")

    @Argument(help: "Session id, unique prefix, or 'last'.")
    var session: String

    @OptionGroup var flags: RunFlags

    func run() throws {
        let backend = AppleContainerBackend()
        var handle: SessionHandle
        do {
            try backend.checkAvailable()
            handle = try store().open(session)
        } catch { fail(error) }
        if handle.isRunnerAlive { fail(MudroomError.invalid("session \(handle.session.id) is already running")) }
        let s = handle.session
        print("session \(s.id)  \(s.agentLabel) on \(s.projectName)")
        print("project \(s.projectPath) stays untouched; the agent sees a copy at /workspace")
        try runAgent(&handle, backend: backend, flags: flags)
    }
}

struct Hunks: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show one file's changes as numbered hunks, for `apply --hunks`.")

    @Argument(help: "Session id, unique prefix, or 'last'.")
    var session: String

    @Argument(help: "A modified text file in the session.")
    var path: String

    func run() throws {
        do {
            let handle = try store().open(session)
            let applier = Applier(handle: handle)
            let diff = try Differ.compare(base: handle.base, work: handle.work)
            guard let change = diff.changes.first(where: { $0.path == path }) else {
                throw MudroomError.invalid("no change at \(path)")
            }
            guard let hunks = try applier.hunks(for: change) else {
                throw MudroomError.invalid("\(path) is not a modified text file; it can only be applied as a whole")
            }
            let applied = try applier.appliedHunks(for: change)
            print("--- a/\(path)\n+++ b/\(path)")
            print(LineDiff.numberedText(hunks))
            if !applied.isEmpty {
                print("\nalready applied: \(applied.sorted().map(String.init).joined(separator: ", "))")
            }
        } catch { fail(error) }
    }
}

struct Diff: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what the agent changed (base vs work).")

    @Argument(help: "Session id, unique prefix, or 'last'.")
    var session: String

    @Flag(help: "Only list changed paths.")
    var stat = false

    @Flag(help: "Show changes inside .git/ instead of a one-line summary.")
    var includeGit = false

    @Option(help: "Compare from: base (default) or a snapshot number. See `mudroom snapshots`.")
    var from: String = "base"

    @Option(help: "Compare to: work (default, the agent's final copy) or a snapshot number.")
    var to: String = "work"

    func validate() throws {
        guard TreeRef(from) != nil else { throw ValidationError("--from takes base, work or a snapshot number") }
        guard TreeRef(to) != nil else { throw ValidationError("--to takes base, work or a snapshot number") }
    }

    func run() throws {
        do {
            let handle = try store().open(session)
            let snaps = SnapshotStore(handle: handle)
            let a = try snaps.url(for: TreeRef(from)!)
            let b = try snaps.url(for: TreeRef(to)!)
            var result = try Differ.compare(base: a, work: b)
            if includeGit {
                result.changes = (result.changes + result.gitMetadataChanges).sorted { $0.path < $1.path }
                result.gitMetadataChanges = []
            }
            let renderer = DiffRenderer(base: a, work: b)
            print(stat ? renderer.stat(result) : try renderer.full(result))
        } catch { fail(error) }
    }
}

struct Apply: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy approved changes into the real project.",
        discussion: """
        A path is written only if the real project still matches the state the \
        agent started from; otherwise it is reported as a conflict and left alone. \
        Overwritten files are saved in a rollback bundle for `mudroom undo`.
        """)

    @Argument(help: "Session id, unique prefix, or 'last'.")
    var session: String

    @Argument(help: "Paths (files or directories) to apply.")
    var paths: [String] = []

    @Flag(help: "Apply every change.")
    var all = false

    @Flag(help: "Also apply changes inside .git/.")
    var includeGit = false

    @Option(help: "Apply only these hunks (e.g. 1,3) of a single text file. See `mudroom hunks`.")
    var hunks: String?

    func validate() throws {
        if all == !paths.isEmpty {
            throw ValidationError("pass paths to apply, or --all (not both)")
        }
        if hunks != nil {
            guard paths.count == 1 else { throw ValidationError("--hunks needs exactly one file path") }
            guard hunkIDs != nil else { throw ValidationError("--hunks takes numbers like 1,3") }
        }
    }

    var hunkIDs: Set<Int>? {
        guard let hunks else { return nil }
        let parts = hunks.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let ids = parts.compactMap(Int.init)
        return ids.count == parts.count && !ids.isEmpty ? Set(ids) : nil
    }

    func run() throws {
        var handle: SessionHandle
        let report: ApplyReport
        do {
            handle = try store().open(session)
            let applier = Applier(handle: handle)
            if let ids = hunkIDs {
                report = try applier.applyHunks(path: paths[0], hunks: ids)
            } else {
                report = try applier.apply(paths: all ? nil : paths, includeGit: includeGit)
            }
        } catch { fail(error) }

        for p in report.applied { print("applied    \(p)") }
        for p in report.alreadyApplied { print("unchanged  \(p) (project already matches)") }
        for i in report.skipped { print("skipped    \(i)") }
        for i in report.conflicts { print("CONFLICT   \(i)") }
        if !report.applied.isEmpty {
            try handle.setStatus(.applied)
            print("\n\(report.applied.count) applied. Undo with: mudroom undo \(handle.session.id)")
        } else if report.conflicts.isEmpty {
            print("nothing to apply")
        }
        if !report.conflicts.isEmpty { throw ExitCode(2) }
    }
}

struct Undo: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Roll back the last apply of a session.")

    @Argument(help: "Session id, unique prefix, or 'last'.")
    var session: String

    @Flag(help: "Restore even paths that changed again after the apply.")
    var force = false

    func run() throws {
        var handle: SessionHandle
        let report: UndoReport
        do {
            handle = try store().open(session)
            report = try Applier(handle: handle).undo(force: force)
        } catch { fail(error) }
        for p in report.restored { print("restored   \(p)") }
        for i in report.conflicts { print("CONFLICT   \(i)") }
        try handle.setStatus(.undone)
        if !report.conflicts.isEmpty { throw ExitCode(2) }
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List sessions.")

    func run() throws {
        let sessions: [SessionHandle]
        do { sessions = try store().list() } catch { fail(error) }
        if sessions.isEmpty {
            print("no sessions")
            return
        }
        let f = ISO8601DateFormatter()
        for h in sessions {
            let s = h.session
            let exit = s.exitCode.map { " exit=\($0)" } ?? ""
            print("\(s.id)  \(s.status.rawValue)\(exit)  \(f.string(from: s.created))  \(s.projectPath)  \(s.command.joined(separator: " "))")
        }
    }
}

struct Discard: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete a session (its clones and rollback bundles). The project is not touched.")

    @Argument(help: "Session id, unique prefix, or 'last'.")
    var session: String

    @Flag(help: "Keep session.json as a record (status: discarded); delete only the clones.")
    var keepRecord = false

    func run() throws {
        do {
            let handle = try store().open(session)
            if handle.isRunnerAlive { throw MudroomError.invalid("session \(handle.session.id) is still running") }
            try store().discard(handle, keepRecord: keepRecord)
            print("discarded \(handle.session.id)")
        } catch { fail(error) }
    }
}

struct Image: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the agent image.", subcommands: [Build.self])

    struct Build: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build mudroom/agent-base:latest with `container build`.")

        @Option(help: "Use this Containerfile instead of the built-in one.")
        var file: String?

        @Option(help: "Image tag.")
        var tag: String = AgentBaseImage.tag

        func run() throws {
            do {
                let backend = AppleContainerBackend()
                if let file {
                    let url = URL(fileURLWithPath: file)
                    try backend.buildImage(containerfile: url, context: url.deletingLastPathComponent(), tag: tag)
                } else {
                    let dir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("mudroom-image-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: dir) }
                    let containerfile = dir.appendingPathComponent("Containerfile")
                    try AgentBaseImage.containerfile.write(to: containerfile, atomically: true, encoding: .utf8)
                    try backend.buildImage(containerfile: containerfile, context: dir, tag: tag)
                }
                print("built \(tag)")
            } catch { fail(error) }
        }
    }
}
