# Mudroom

A pull-request gate for local coding agents on macOS.

Mudroom runs Claude Code, Codex, Gemini CLI (or any command) inside a Linux
micro-VM, on a copy of your project. Your real folder is never mounted. When
the agent is done you read the diff, then apply all of it, some files, or
none. Every apply can be undone.

> Status: early prototype. Expect rough edges and breaking changes.

![Reviewing a session in Mudroom](docs/screenshots/review-light.png)

## Why

Agents in "skip permissions" mode are fast, and every so often they delete
something they shouldn't. Sandboxes fix half of that: Docker Sandboxes, Apple's
`sandboxy` example and ArcBox all put the agent in a VM, but they mount your
project folder straight in. Whatever the agent writes lands in your real files
as it happens. If it rewrites twenty files, deletes a directory and chmods a
script, you find out afterwards with `git status`, and only for files git
tracks.

Mudroom puts a review step in between:

- The agent edits a copy-on-write clone (APFS `clonefile`, instant, no extra
  disk until files change).
- `mudroom diff` shows every change, including untracked files, deletions,
  permission bits and symlinks, not just what git sees.
- `mudroom apply` copies the changes you picked into the real folder, and
  refuses any file you edited yourself in the meantime.
- `mudroom undo` puts back what the last apply overwrote.

## Requirements

- macOS 26 or later on Apple silicon
- Xcode 26+ / Swift 6.2+ to build
- Apple's [`container`](https://github.com/apple/container) CLI for running
  agents (`brew install container`)

## Build

```sh
git clone https://github.com/Kernel-Hunter/mudroom
cd mudroom
scripts/build-app.sh            # build/Mudroom.app (app + bundled CLI), ad-hoc signed
open build/Mudroom.app
```

For the command line only:

```sh
swift build -c release
cp .build/release/mudroom /usr/local/bin/   # or anywhere on your PATH
```

Set up the VM runtime and the agent image once:

```sh
brew install container
container system start          # first run offers to download Apple's default kernel
mudroom image build             # builds mudroom/agent-base:latest (Node LTS, git, ripgrep, claude, codex, gemini)
```

## The app

- **Sidebar**: sessions grouped by project, each with its agent, time and
  status (running, ready to review, applied, discarded).
- **New Session** (⌘N): pick a folder, pick Claude Code, Codex, Gemini CLI or
  a custom command, start. Mudroom clones the folder and opens the agent in a
  new Terminal window.
- **Review**: changed files grouped into Added, Modified, Deleted and
  Mode & Type, each with a checkbox. The right pane shows a unified or
  side-by-side diff with line numbers. Modified text files have a checkbox per
  hunk, so you can take some edits and leave others.
- **Conflicts**: files you changed yourself since the session started are
  flagged in the list and above the diff, and are never overwritten.
- **Apply Selected** (⌘↩), **Apply All** (⇧⌘↩), **Undo** (⌥⌘Z) and
  **Discard** (⌘⌫). One click is one rollback bundle, so one Undo reverts it.
  Space toggles the selected file.

Why Terminal: agents are interactive terminal programs and you often need to
answer them. Terminal.app gives you scrollback, copy/paste and resizing
without Mudroom shipping a terminal emulator. The app writes a small
`run.command` into the session folder that runs `mudroom start <id>` in a
login shell (so `PATH` and API keys match your usual shell), and it follows
progress by polling `session.json`, which `mudroom start` keeps up to date
(status, runner pid, start and end time). An embedded terminal may come later.

| | |
|---|---|
| ![Dark mode, split diff](docs/screenshots/review-split-dark.png) | ![A conflict](docs/screenshots/conflict-light.png) |
| ![After a partial apply](docs/screenshots/applied-light.png) | ![New session](docs/screenshots/new-session-light.png) |

## Command line

```sh
# Start a session: clone the project, boot a VM, run the agent on the clone.
export ANTHROPIC_API_KEY=...    # passed through only if set
mudroom run ~/code/myapp -- claude --dangerously-skip-permissions

# Review.
mudroom diff last --stat
mudroom diff last

# Apply everything, only some paths, or only some hunks of one file.
mudroom apply last --all
mudroom apply last src/parser.swift docs/
mudroom hunks last src/parser.swift            # numbered hunks
mudroom apply last src/parser.swift --hunks 1,3

# Changed your mind.
mudroom undo last

# Housekeeping.
mudroom list
mudroom discard <session>       # deletes the session's clones, never the project

# Two-step start (what the app does).
mudroom new ~/code/myapp --agent "Claude Code" -- claude --dangerously-skip-permissions
mudroom start <session>
```

Sessions can be named by full id, a unique prefix, or `last`.

Credentials: `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`
and `GEMINI_API_KEY` are forwarded into the VM when they are set on the host.
They are passed by name (`container run --env NAME`), so the values don't show
up in the process list.

### What `diff` shows

```
M  src/app.swift
A  src/new.swift
D  old/
D  old/notes.txt
P  scripts/build.sh  (mode 644 -> 755)
L  current  (v1 -> v2)
T  config  (file -> symlink)
git metadata changed (12 entries under .git/)
```

Text files get a unified diff (via `git diff --no-index`). Binary files show
`binary changed (size a -> b)`. Changes inside `.git/` are collapsed into one
line unless you pass `--include-git`; `apply` skips them by default for the
same reason.

Files are compared by content hash, never by timestamp, so an agent can't hide
an edit by resetting mtime.

### How apply stays safe

For each path, Mudroom checks that the real project still has exactly what the
session started from. If you edited `README.md` while the agent was working,
`apply` reports a conflict for that file and leaves it alone; the rest still
applies. Other rules:

- Files are written to a temp name and renamed into place.
- Directories are removed with `rmdir`, so a directory that gained a file on
  your side is not deleted.
- Mudroom won't write through a symlinked directory in your project.
- Before touching a file, Mudroom copies it into a rollback bundle in the
  session directory. `undo` restores from there, and skips any path you changed
  again after the apply (`--force` overrides).
- Per-hunk apply uses Mudroom's own line diff (Myers), not `patch`. It
  rebuilds the file from the base version plus the chosen hunks, keeps CRLF
  line endings and a missing final newline as they were, and writes through
  the same checks. A file that already has some hunks from an earlier apply is
  not a conflict; the new hunks are added to it.

## How it works

```
~/Library/Application Support/Mudroom/sessions/<id>/
  session.json   id, project path, created, command, image, status
  base/          clone of the project when the session started
  work/          clone the agent edits, mounted at /workspace in the VM
  rollback/      one bundle per apply: manifest.json + copies of overwritten files
```

`diff` compares `base/` with `work/`. `apply` copies from `work/` to the
project after checking the project against `base/`. Set `MUDROOM_HOME` to keep
sessions somewhere else. If the project is on a different volume or a
non-APFS disk, the clone falls back to a plain copy.

The VM layer is a small `SandboxBackend` protocol. The only backend today
shells out to Apple's `container` CLI, which boots each container in its own
lightweight VM. A backend built directly on the `Containerization` Swift
package can replace it later without touching the diff/apply code.

## Not done yet

- Network is not restricted. The VM has normal outbound access.
- Agent config inside the VM (`~/.claude`, etc.) is thrown away with the VM,
  so interactive logins have to be repeated each session.
- No snapshot timeline yet: one base per session, undo per apply.
- The app is ad-hoc signed; no notarized build or Homebrew cask yet.

## Development

```sh
swift build
swift test                 # diff, hunks, apply, conflict and undo tests; no VM needed
scripts/make-demo.sh       # demo sessions in build/demo (no VM)
scripts/screenshots.sh     # regenerates docs/screenshots from the demo
```

The app target is `MudroomApp` (SwiftUI, macOS 26+). `MudroomCore` has no UI
code; the app and the CLI both sit on top of it.

## License

MIT. See [LICENSE](LICENSE).
