import ArgumentParser
import Darwin
import Foundation
import MudroomCore

func projectPath(_ arg: String?) -> String {
    URL(fileURLWithPath: arg ?? FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().standardizedFileURL.path
}

func bytes(_ n: Int64) -> String { NetworkLog.byteString(n) }

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

struct Snapshots: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the snapshots taken while a session's agent ran.",
        discussion: "Compare any two with `mudroom diff <session> --from <n> --to <m|work>`.")

    @Argument(help: "Session id, unique prefix, or 'last'.")
    var session: String

    func run() throws {
        do {
            let handle = try store().open(session)
            let snaps = SnapshotStore(handle: handle).list()
            if snaps.isEmpty {
                print("no snapshots for \(handle.session.id)")
                return
            }
            var previous = handle.base
            print("  #  taken                changes since previous")
            for s in snaps {
                let d = try Differ.compare(base: previous, work: s.directory)
                print(String(format: "%3d  %@  %d", s.number, timeFormatter.string(from: s.date), d.changes.count))
                previous = s.directory
            }
            let tail = try Differ.compare(base: previous, work: handle.work).changes.count
            print("     work                 \(tail)")
        } catch { fail(error) }
    }
}

struct NetworkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Per-project network settings and what sessions connected to.",
        discussion: """
        Locked (the default) puts the VM on a host-only network; the only way out is \
        Mudroom's proxy, which allows the agent's API hosts plus anything you add. \
        Open gives normal access, offline none.
        """,
        subcommands: [Show.self, Log.self, Allow.self, Deny.self, Mode.self, Registries.self, Check.self])

    struct ProjectOption: ParsableArguments {
        @Option(name: .customLong("project"), help: "Project directory (default: the current directory).")
        var project: String?

        @Option(name: .customLong("session"), help: "Use this session's project instead.")
        var session: String?

        func path() throws -> String {
            if let session { return try store().open(session).session.projectPath }
            return projectPath(project)
        }
    }

    static func configStore() -> ProjectConfigStore { ProjectConfigStore(store: store()) }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a project's network mode and allowlist.")
        @OptionGroup var where_: ProjectOption
        @Option(help: "Show the effective allowlist for this agent (claude, codex, gemini).")
        var agent: String = "claude"

        func run() throws {
            do {
                let path = try where_.path()
                let config = try NetworkCommand.configStore().load(path)
                print("project   \(path)")
                print("config    \(NetworkCommand.configStore().url(for: path).path)")
                print("mode      \(config.networkMode.rawValue)")
                print("agent hosts \(config.includeAgentHosts ? "on" : "off"), package registries \(config.includePackageRegistries ? "on" : "off")")
                print("snapshots every \(config.snapshotMinutes) min, keep \(config.snapshotLimit)")
                print("\nallowed for \(agent):")
                for p in config.allowlist(agent: AgentPreset.find(agent)?.id ?? agent).patterns {
                    let origin = config.allowedHosts.contains(p) ? "project" : "default"
                    print("  \(p.value.padding(toLength: 40, withPad: " ", startingAt: 0)) \(origin)")
                }
            } catch { fail(error) }
        }
    }

    struct Log: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "What a session's VM connected to, and what was blocked.")
        @Argument(help: "Session id, unique prefix, or 'last'.")
        var session: String
        @Flag(help: "One line per connection instead of per host.")
        var all = false

        func run() throws {
            do {
                let handle = try store().open(session)
                let entries = NetworkLog.read(handle.networkLog)
                if let n = handle.session.network {
                    print("mode \(n.mode.rawValue) (\(n.enforcement.title))\(n.proxy.map { ", proxy \($0)" } ?? "")")
                }
                if entries.isEmpty {
                    print("no connections logged")
                    return
                }
                if all {
                    for e in entries {
                        let verdict = e.allowed ? (e.reason == nil ? "allowed" : "failed ") : "BLOCKED"
                        print("\(timeFormatter.string(from: e.time))  \(verdict)  \(e.method.padding(toLength: 7, withPad: " ", startingAt: 0)) \(e.host):\(e.port)  out \(bytes(e.bytesOut)) in \(bytes(e.bytesIn))  \(e.durationMs) ms\(e.reason.map { "  (\($0))" } ?? "")")
                    }
                    return
                }
                for r in NetworkLog.summarize(entries) {
                    let verdict = r.allowed ? "allowed" : "BLOCKED"
                    print("\(verdict)  \(("\(r.host):\(r.port)").padding(toLength: 44, withPad: " ", startingAt: 0)) \(r.count)x  out \(bytes(r.bytesOut)) in \(bytes(r.bytesIn))")
                }
                let blocked = Set(entries.filter { !$0.allowed }.map(\.host))
                if !blocked.isEmpty {
                    print("\nallow one for this project: mudroom network allow <host> --session \(handle.session.id)")
                }
            } catch { fail(error) }
        }
    }

    struct Allow: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add hosts to a project's allowlist (exact, or *.suffix).")
        @Argument(help: "Hosts, e.g. registry.npmjs.org '*.githubusercontent.com'.")
        var hosts: [String]
        @OptionGroup var where_: ProjectOption

        func run() throws {
            do {
                let patterns = try hosts.map { raw -> HostPattern in
                    guard let p = HostPattern(raw) else { throw MudroomError.invalid("not a host name or *.suffix pattern: \(raw)") }
                    return p
                }
                let path = try where_.path()
                try NetworkCommand.configStore().update(path) { c in
                    for p in patterns { print(c.allow(p) ? "allowed \(p)" : "already allowed \(p)") }
                }
            } catch { fail(error) }
        }
    }

    struct Deny: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove hosts you added to a project's allowlist.")
        @Argument var hosts: [String]
        @OptionGroup var where_: ProjectOption

        func run() throws {
            do {
                let path = try where_.path()
                try NetworkCommand.configStore().update(path) { c in
                    for raw in hosts {
                        guard let p = HostPattern(raw), c.disallow(p) else {
                            print("not in the project list: \(raw) (agent defaults are switched off with `network show`/config)")
                            continue
                        }
                        print("removed \(p)")
                    }
                }
            } catch { fail(error) }
        }
    }

    struct Mode: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set a project's network mode: locked, open or offline.")
        @Argument var mode: NetworkMode
        @OptionGroup var where_: ProjectOption

        func run() throws {
            do {
                let path = try where_.path()
                try NetworkCommand.configStore().update(path) { $0.networkMode = mode }
                print("\(path): network \(mode.rawValue)")
                if mode == .open { print("warning: open sessions can reach anything and nothing is logged") }
            } catch { fail(error) }
        }
    }

    struct Registries: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Allow npm, PyPI and GitHub for a project (on/off).",
            discussion: NetworkDefaults.packageRegistries.joined(separator: ", "))
        @Argument var state: String
        @OptionGroup var where_: ProjectOption

        func validate() throws {
            guard ["on", "off"].contains(state) else { throw ValidationError("use on or off") }
        }

        func run() throws {
            do {
                let path = try where_.path()
                try NetworkCommand.configStore().update(path) { $0.includePackageRegistries = state == "on" }
                print("\(path): package registries \(state)")
            } catch { fail(error) }
        }
    }

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Boot a VM with a project's network settings and try to get out.",
            discussion: """
            Tries an allowed and a blocked host through the proxy, then DNS, direct \
            TCP (IPv4 and IPv6) and UDP around it, and reports what connected.
            """)
        @OptionGroup var where_: ProjectOption
        @Option(help: "Agent whose default hosts to include.")
        var agent: String = "claude"
        @Option(help: "Override the mode for this check.")
        var mode: NetworkMode?
        @Option(help: "A host that should be blocked.")
        var blocked: String = "example.com"

        func run() throws {
            do {
                let path = try where_.path()
                let config = try NetworkCommand.configStore().load(path)
                let m = mode ?? config.networkMode
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mudroom-check-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: scratch) }
                print("checking \(m.rawValue) network in a VM...")
                fflush(stdout)
                let report = try NetworkCheck.run(mode: m, allowlist: config.allowlist(agent: AgentPreset.find(agent)?.id),
                                                  backend: AppleContainerBackend(), blocked: blocked, scratch: scratch)
                print("mode \(report.network.mode.rawValue) (\(report.network.enforcement.title))\(report.network.proxy.map { ", proxy \($0)" } ?? "")\n")
                for o in report.outcomes {
                    let got = o.connected ? "got through" : "stopped    "
                    let verdict: String
                    switch o.expected {
                    case .some(let e): verdict = e == o.connected ? "ok      " : "UNEXPECTED"
                    case .none: verdict = "note    "
                    }
                    print("\(verdict)  \(got)  \(o.detail): \(o.result)")
                }
                if report.outcomes.contains(where: { $0.name == "mac-services" && $0.connected }) {
                    print("\nnote: the VM can reach services on this Mac that listen on all interfaces (the host-only network's gateway is the Mac).")
                }
                if !report.matchesExpectation { throw ExitCode(3) }
            } catch let e as ExitCode { throw e } catch { fail(error) }
        }
    }
}

struct Agent: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Persistent agent logins, kept in Mudroom's own directory (never your real ~/.claude).",
        subcommands: [Login.self, Status.self])

    struct Login: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Sign an agent in, inside a VM; the login is kept for later sessions.",
            discussion: "claude runs `claude auth login`, codex `codex login --device-auth`, gemini its first-run sign-in.")
        @Argument(help: "claude, codex or gemini.")
        var agent: String
        @Option(help: "Container image to run.")
        var image: String = AppleContainerBackend.defaultImage

        func run() throws {
            guard let preset = AgentPreset.find(agent), AgentHome(store: store(), agent: preset.id) != nil else {
                fail(MudroomError.invalid("unknown agent \(agent); use claude, codex or gemini"))
            }
            if preset.id == "gemini" { print("Pick \"Login with Google\", finish in your browser, then type /quit.") }
            let tty = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
            let status: Int32
            do {
                status = try AgentLogin.run(preset, store: store(), backend: AppleContainerBackend(), image: image, tty: tty) {
                    print($0)
                    fflush(stdout)
                }
            } catch { fail(error) }
            if status != 0 { throw ExitCode(status) }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show each agent's config directory.")
        func run() throws {
            for p in AgentPreset.all {
                guard let h = AgentHome(store: store(), agent: p.id) else { continue }
                let state = h.isPopulated ? "has config" : "empty (run `mudroom agent login \(p.id)`)"
                print("\(p.id.padding(toLength: 7, withPad: " ", startingAt: 0)) \(h.hostDirectory.path) -> \(h.guestPath)  \(state)")
            }
        }
    }
}
