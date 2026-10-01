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
        The agent works on a copy of your project inside a sandbox: a Linux micro-VM \
        with the apple backend, a container with docker or podman. Nothing touches \
        your real folder until you review the diff and apply it.
        """,
        version: mudroomVersion,
        subcommands: [SetupCommand.self, Run.self, New.self, Start.self, Diff.self, Review.self, Hunks.self, Apply.self, Undo.self,
                      Snapshots.self, NetworkCommand.self, Agent.self, Keys.self, List.self, Discard.self, Image.self]
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

    @Flag(help: "Start even if the agent isn't signed in, and sign in inside the session.")
    var signInInSession = false

    func options(tty: Bool) throws -> RunOptions {
        var hosts: [HostPattern] = []
        for raw in allow {
            guard let p = HostPattern(raw) else { throw ValidationError("not a host name or *.suffix pattern: \(raw)") }
            hosts.append(p)
        }
        var o = RunOptions(tty: tty, cpus: cpus, memory: memory, networkMode: network, extraHosts: hosts,
                           snapshotMinutes: snapshotEvery, snapshotLimit: snapshotLimit,
                           tokenStore: AgentToken.defaultStore(store()))
        o.probeNetwork = ProcessInfo.processInfo.environment["MUDROOM_SKIP_NETWORK_PROBE"] != "1"
        return o
    }
}

extension NetworkMode: ExpressibleByArgument {}
extension BackendChoice: ExpressibleByArgument {}

/// `--backend` and `--oci-runtime`, shared by every command that starts a sandbox.
struct BackendOptions: ParsableArguments {
    @Option(help: "Sandbox backend: auto, apple, docker or podman. Default: $MUDROOM_BACKEND, else auto (apple on Apple-silicon macOS 26+ with `container` installed, else docker, else podman).")
    var backend: BackendChoice?

    @Option(help: "OCI runtime for docker or podman, e.g. runsc (gVisor) or kata. Default: $MUDROOM_OCI_RUNTIME.")
    var ociRuntime: String?

    /// `recorded` is the backend a session was created for; an explicit
    /// --backend or $MUDROOM_BACKEND wins over it.
    func make(recorded: String? = nil) throws -> SandboxBackend {
        let env = ProcessInfo.processInfo.environment
        let runtime = ociRuntime ?? env["MUDROOM_OCI_RUNTIME"].flatMap { $0.isEmpty ? nil : $0 }
        let fromEnv = env["MUDROOM_BACKEND"].flatMap { BackendChoice(rawValue: $0.lowercased()) }
        let choice = backend ?? fromEnv ?? recorded.flatMap(BackendChoice.init(backendName:)) ?? .auto
        return try Backends.make(choice, ociRuntime: runtime)
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clone a project into a new session and run an agent on the clone.")

    @Argument(help: "The project directory. It is cloned, never mounted.")
    var project: String

    @Option(help: "Container image to run.")
    var image: String = AgentBaseImage.tag

    @OptionGroup var flags: RunFlags

    @OptionGroup var backendOptions: BackendOptions

    @Flag(help: "Copy instead of a copy-on-write clone (for testing).")
    var noClone = false

    @Argument(parsing: .postTerminator, help: "Command to run inside the VM (after --). Defaults to the image's command.")
    var command: [String] = []

    func run() throws {
        let backend: SandboxBackend
        do {
            backend = try backendOptions.make()
            try backend.checkAvailable()
        } catch { fail(error) }

        if !flags.signInInSession, let why = signInProblem(agent: nil, command: command) { fail(why) }

        let projectURL = URL(fileURLWithPath: project, isDirectory: true)
        var handle: SessionHandle
        do {
            handle = try store().create(project: projectURL, command: command, image: image, allowClonefile: !noClone)
        } catch { fail(error) }

        let s = handle.session
        print("session \(s.id)  (\(s.cloneMethod.label))")
        print("project \(s.projectPath) stays untouched; the agent sees a copy at /workspace")
        print("backend \(backend.name)")

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
    printSignInHint(handle.session, options: options)
    let result: SessionRunner.Result
    do {
        let runner = SessionRunner(backend: backend, store: store()) { line in
            print(line)
            fflush(nil)
        }
        fflush(nil)
        do {
            result = try runner.run(&handle, options: options)
        } catch MudroomError.networkUnreachable(let why) {
            // Offer the fix instead of starting a session that can't reach its API.
            print("\nThe VM network isn't working: \(why).")
            guard backend.name == "apple-container",
                  confirm("Repair it now? This restarts Apple's container system (about 10 seconds).", yes: false) else {
                throw MudroomError.networkUnreachable(why)
            }
            let r = repairAndProbe(backend)
            print(r.isOK ? "repaired: \(r.summary)" : "still failing: \(r.summary)")
            guard r.isOK else { throw MudroomError.networkUnreachable(r.summary) }
            result = try runner.run(&handle, options: options)
        }
    } catch { fail(error) }

    let id = handle.session.id
    print("\nagent exited with status \(result.status). Changes in session \(id):")
    let diff = try Differ.compare(base: handle.base, work: handle.work)
    DiffRenderer(base: handle.base, work: handle.work).writeStat(diff) { print($0) }
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
    var image: String = AgentBaseImage.tag

    @Option(help: "Agent name to record, e.g. \"Claude Code\".")
    var agent: String?

    @Option(help: "Backend to record for `mudroom start`: apple, docker or podman. Default: decided when it starts.")
    var backend: BackendChoice?

    @Argument(parsing: .postTerminator, help: "Command to run inside the VM (after --).")
    var command: [String] = []

    func run() throws {
        do {
            var handle = try store().create(project: URL(fileURLWithPath: project, isDirectory: true),
                                            command: command, image: image, agent: agent)
            if let backend, backend != .auto {
                handle.session.backend = backend.rawValue
                try handle.save()
            }
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

    @OptionGroup var backendOptions: BackendOptions

    func run() throws {
        let backend: SandboxBackend
        var handle: SessionHandle
        do {
            handle = try store().open(session)
            backend = try backendOptions.make(recorded: handle.session.backend)
            try backend.checkAvailable()
        } catch { fail(error) }
        if handle.isRunnerAlive { fail(MudroomError.invalid("session \(handle.session.id) is already running")) }
        if !flags.signInInSession, let why = signInProblem(agent: handle.session.agent, command: handle.session.command) {
            fail(why)
        }
        let s = handle.session
        print("session \(s.id)  \(s.agentLabel) on \(s.projectName)")
        print("project \(s.projectPath) stays untouched; the agent sees a copy at /workspace")
        print("backend \(backend.name)")
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
            let path = Applier.normalizePath(self.path)
            let diff = try Differ.compare(base: handle.base, work: handle.work)
            guard let change = diff.changes.first(where: { $0.path == path }) else {
                throw MudroomError.invalid("no change at \(path)")
            }
            // What you see here is what `apply --hunks` will apply.
            var record = ReviewedChanges.load(handle) ?? ReviewedChanges([])
            record.merge([change])
            try? record.save(handle)
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
            if TreeRef(from) == .base && TreeRef(to) == .work {
                // `apply` later refuses paths that changed after this.
                try? ReviewedChanges(result.changes + result.gitMetadataChanges).save(handle)
            }
            if includeGit {
                result.changes = (result.changes + result.gitMetadataChanges).sorted { $0.path < $1.path }
                result.gitMetadataChanges = []
            }
            let renderer = DiffRenderer(base: a, work: b)
            // Streamed: a big diff isn't held in memory.
            if stat { renderer.writeStat(result) { print($0) } } else { try renderer.writeFull(result) { print($0) } }
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
            try SessionGuard.ensureIdle(handle)
            let applier = Applier(handle: handle)
            // After `mudroom diff` / `hunks` / `review`, only what was shown
            // there is applied.
            let reviewed = ReviewedChanges.load(handle)
            if let ids = hunkIDs {
                report = try applier.applyHunks(path: paths[0], hunks: ids, reviewed: reviewed)
            } else {
                report = try applier.apply(paths: all ? nil : paths, includeGit: includeGit, reviewed: reviewed)
            }
        } catch { fail(error) }

        for p in report.applied { print("applied    \(p)") }
        for w in report.warnings { print("note       \(w.path): check it; it \(w.reason)") }
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
            try SessionGuard.ensureIdle(handle)
            report = try Applier(handle: handle).undo(force: force)
        } catch { fail(error) }
        for p in report.restored { print("restored   \(p)") }
        for i in report.conflicts { print("CONFLICT   \(i)") }
        if report.remaining > 0 {
            print("\n\(report.remaining) path(s) of this apply were not restored. Put them back as they were after the apply and run undo again, or use --force.")
        }
        // Undone only when nothing applied is left in the project.
        if !Applier(handle: handle).canUndo { try handle.setStatus(.undone) }
        if !report.conflicts.isEmpty { throw ExitCode(2) }
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List sessions.")

    func run() throws {
        let sessions: [SessionHandle]
        do { sessions = try store().list() } catch { fail(error) }
        for dir in store().brokenSessions() {
            print("\(dir.lastPathComponent)  CORRUPT (session.json unreadable; remove with `mudroom discard \(dir.lastPathComponent)`)")
        }
        if sessions.isEmpty && store().brokenSessions().isEmpty {
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
            if store().brokenSessions().contains(where: { $0.lastPathComponent == session }) {
                try store().discardBroken(session)
                print("removed \(session) (its session.json was unreadable)")
                return
            }
            let handle = try store().open(session)
            if handle.isRunnerAlive { throw MudroomError.invalid("session \(handle.session.id) is still running") }
            try store().discard(handle, keepRecord: keepRecord)
            print("discarded \(handle.session.id). Its rollback bundles are gone too, so earlier applies can't be undone with mudroom anymore.")
        } catch { fail(error) }
    }
}

struct Image: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the agent image.", subcommands: [Build.self])

    struct Build: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build mudroom/agent-base:latest with the backend's build command (container, docker or podman build).")

        @Option(help: "Use this Containerfile instead of the built-in one.")
        var file: String?

        @Option(help: "Image tag.")
        var tag: String = AgentBaseImage.tag

        @OptionGroup var backendOptions: BackendOptions

        func run() throws {
            do {
                let backend = try backendOptions.make()
                if let file {
                    let url = URL(fileURLWithPath: file)
                    try backend.buildImage(containerfile: url, context: url.deletingLastPathComponent(), tag: tag)
                } else {
                    // Labeled with the Containerfile's hash, so setup can tell when it is outdated.
                    print("building \(tag) from the built-in Containerfile (a few minutes the first time)")
                    try AgentBaseImage.build(backend: backend, tag: tag) { line in
                        print(line)
                        fflush(nil)
                    }
                }
                print("built \(tag) for \(backend.name)")
            } catch { fail(error) }
        }
    }
}
