import ArgumentParser
import Foundation
import MudroomCore

struct Exclude: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exclude",
        abstract: "Per-project list of files kept out of the sandbox (.env, keys).",
        discussion: """
        Patterns use .gitignore syntax, relative to the project root: `.env`, `.env.*`, \
        `*.pem`, `secrets/`, `**/id_rsa`, `!.env.example`. New sessions leave matching \
        files out of both copies, so the agent never sees them and apply never writes \
        them. A project starts with a default list (`mudroom exclude list` shows it). \
        A `.mudroomignore` file at the project root adds more patterns; it can't take \
        any of the project's own patterns back.
        """,
        subcommands: [List.self, Add.self, Remove.self, Reset.self])

    typealias ProjectOption = NetworkCommand.ProjectOption

    static func configStore() -> ProjectConfigStore { ProjectConfigStore(store: store()) }

    /// A note for patterns that probably don't mean what they say.
    static func hint(_ pattern: String) -> String? {
        if pattern.contains("\\") && !pattern.contains("/") {
            return "note: \\ escapes the next character in a pattern; separate folders with /"
        }
        return nil
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a project's exclude patterns and what a new session would leave out.")
        @OptionGroup var where_: ProjectOption

        func run() throws {
            do {
                let path = try where_.path()
                let config = try Exclude.configStore().load(path)
                let ignore = ExcludeList.readIgnoreFile(URL(fileURLWithPath: path, isDirectory: true))
                print("project   \(path)")
                print("config    \(Exclude.configStore().url(for: path).path)")
                if config.excludePatterns.isEmpty {
                    print("\nno project patterns (restore the defaults with `mudroom exclude reset`)")
                } else {
                    print("\npatterns:")
                    for p in config.excludePatterns {
                        let origin = ExcludeList.defaults.contains(p) ? "default" : "added"
                        print("  \(p.padding(toLength: 40, withPad: " ", startingAt: 0)) \(origin)")
                    }
                }
                if !ignore.isEmpty {
                    print("\n\(ExcludeList.ignoreFileName) (adds to the list, can't take patterns back):")
                    for p in ignore { print("  \(p)") }
                }
                let list = ExcludeList(patterns: config.excludePatterns, ignoreFile: ignore)
                let found = ExcludeList.preview(URL(fileURLWithPath: path, isDirectory: true), rules: list.rules)
                if let summary = ExcludedEntry.summary(found, limit: 20) {
                    print("\na new session leaves out: \(summary)")
                } else {
                    print("\na new session leaves nothing out")
                }
            } catch { fail(error) }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add patterns to a project's exclude list.")
        @Argument(help: "Patterns, e.g. .npmrc 'config/*.json' secrets/ '!.env.test'.")
        var patterns: [String]
        @OptionGroup var where_: ProjectOption

        func validate() throws {
            for p in patterns where !ExcludeRules.isPattern(p.trimmingCharacters(in: .whitespacesAndNewlines)) {
                throw ValidationError("not a pattern: \(p.debugDescription)")
            }
        }

        func run() throws {
            do {
                let path = try where_.path()
                try Exclude.configStore().update(path) { c in
                    for p in patterns {
                        print(c.exclude(p) ? "added \(p)" : "already in the list: \(p)")
                        if let hint = Exclude.hint(p) { print(hint) }
                    }
                }
                print("applies to sessions created from now on")
            } catch { fail(error) }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove patterns from a project's exclude list (defaults too).",
            discussion: "To let one file in while keeping its pattern, add a `!` pattern instead: `mudroom exclude add '!.env.test'`.")
        @Argument(help: "Patterns exactly as `mudroom exclude list` shows them.")
        var patterns: [String] = []
        @Flag(help: "Remove every pattern: new sessions copy everything (except what .mudroomignore lists).")
        var all = false
        @OptionGroup var where_: ProjectOption

        func validate() throws {
            if all == !patterns.isEmpty { throw ValidationError("pass patterns to remove, or --all (not both)") }
        }

        func run() throws {
            do {
                let path = try where_.path()
                let ignore = ExcludeList.readIgnoreFile(URL(fileURLWithPath: path, isDirectory: true))
                try Exclude.configStore().update(path) { c in
                    if all {
                        c.excludePatterns = []
                        print("removed every pattern")
                        return
                    }
                    for p in patterns {
                        if c.unexclude(p) {
                            print("removed \(p)")
                        } else if ignore.contains(p) {
                            print("\(p) comes from \(ExcludeList.ignoreFileName); edit that file to remove it")
                        } else {
                            print("not in the project list: \(p)")
                        }
                    }
                }
            } catch { fail(error) }
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Put back Mudroom's default exclude list for a project.")
        @OptionGroup var where_: ProjectOption

        func run() throws {
            do {
                let path = try where_.path()
                try Exclude.configStore().update(path) { $0.excludePatterns = ExcludeList.defaults }
                print("\(path): default exclude list (\(ExcludeList.defaults.joined(separator: " ")))")
            } catch { fail(error) }
        }
    }
}
