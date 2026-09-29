# Mudroom

A pull-request gate for local coding agents on macOS.

Mudroom runs Claude Code, Codex, Gemini CLI (or any command) inside a Linux
micro-VM, on a copy of your project. Your real folder is never mounted. When
the agent is done you read the diff, then apply all of it, some files, or
none. Every apply can be undone.

> Status: early prototype. Command-line only. Expect rough edges and breaking
> changes.

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
swift build -c release
cp .build/release/mudroom /usr/local/bin/   # or anywhere on your PATH
```

Set up the VM runtime and the agent image once:

```sh
brew install container
container system start          # first run offers to download Apple's default kernel
mudroom image build             # builds mudroom/agent-base:latest (Node LTS, git, ripgrep, claude, codex, gemini)
```

## Usage

```sh
# Start a session: clone the project, boot a VM, run the agent on the clone.
export ANTHROPIC_API_KEY=...    # passed through only if set
mudroom run ~/code/myapp -- claude --dangerously-skip-permissions

# Review.
mudroom diff last --stat
mudroom diff last

# Apply everything, or only some paths.
mudroom apply last --all
mudroom apply last src/parser.swift docs/

# Changed your mind.
mudroom undo last

# Housekeeping.
mudroom list
mudroom discard <session>       # deletes the session's clones, never the project
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
- No per-hunk apply; selection is per path.
- No GUI yet.
- Agent config inside the VM (`~/.claude`, etc.) is thrown away with the VM.

## Development

```sh
swift build
swift test     # clone, diff, apply, conflict and undo tests; no VM needed
```

## License

MIT. See [LICENSE](LICENSE).
