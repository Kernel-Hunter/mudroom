# Mudroom

A pull-request gate for local coding agents on macOS.

Mudroom runs Claude Code, Codex, Gemini CLI (or any command) inside a Linux
micro-VM, on a copy of your project. Your real folder is never mounted. The
VM can only reach the hosts you allow. When the agent is done you read the
diff, then apply all of it, some files, some hunks, or none. Every apply can
be undone.

> Status: early prototype. Expect rough edges and breaking changes.

![Reviewing a session in Mudroom](docs/screenshots/review-light.png)

## Why

Agents in "skip permissions" mode are fast, and every so often they delete
something they shouldn't, or reach somewhere they shouldn't. There are good
tools for parts of this:

- Apple's `sandboxy` example runs the agent in a VM, but shares your project
  folder into it live (virtio-fs), so every write lands in your real files as
  it happens.
- Docker Sandboxes (`sbx`) mounts the folder read-write by default. Its
  `--clone` mode is closer to Mudroom: the repo is mounted read-only, the
  agent works on a private git clone, and you `git fetch` the result and
  review it with your usual git tools.
- ArcBox mounts nothing: `/workspace` starts empty and you copy files in and
  out yourself.
- vibe-kanban runs agents on git worktrees and gives you a diff review and
  merge step, without a VM.

Mudroom puts these pieces together in one place:

- The agent runs in a VM, in skip-permissions mode.
- It works on an APFS copy-on-write clone of the **whole folder**, including
  untracked, ignored and non-git files. It's not a git clone or worktree, and
  it takes no extra disk until files change.
- The real folder is never mounted.
- The VM sits on a host-only network. Its only way out is a proxy that allows
  the agent's API plus hosts you add, and logs everything it sees.
- When the agent is done you get a native review screen: per-file and
  per-hunk apply, including deletions, permission bits and symlinks.
- Apply refuses any file you changed yourself in the meantime, and every
  apply can be undone.
- Snapshots taken while the agent runs let you see what it did after a given
  point.

## Requirements

- macOS 26 or later on Apple silicon
- Xcode 26+ / Swift 6.2+ to build
- Apple's [`container`](https://github.com/apple/container) CLI, 1.5 or later
  (`brew install container`). Earlier versions may lack host-only networks;
  see [Network](#network).

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
mudroom agent login claude      # optional: sign in once, kept for later sessions
```

## The app

- **Sidebar**: sessions grouped by project, each with its agent, time and
  status (running, ready to review, applied, discarded).
- **New Session** (⌘N): pick a folder, an agent (Claude Code, Codex, Gemini
  CLI or a custom command) and a network mode (Locked, Open, Offline), then
  start. Mudroom clones the folder and opens the agent in a new Terminal
  window.
- **Review, Files**: changed files grouped into Added, Modified, Deleted and
  Mode & Type, each with a checkbox. The right pane shows a unified or
  side-by-side diff with line numbers. Modified text files have a checkbox per
  hunk, so you can take some edits and leave others.
- **Review, Network**: every host the VM tried to reach, blocked ones first,
  with bytes and connection counts. **Allow** adds a blocked host to the
  project's allowlist for the next session.
- **Timeline**: if the session has snapshots, a slider picks a point in time
  and the file list shows only what changed after it (read-only).
- **Conflicts**: files you changed yourself since the session started are
  flagged in the list and above the diff, and are never overwritten.
- **Apply Selected** (⌘↩), **Apply All** (⇧⌘↩), **Undo** (⌥⌘Z) and
  **Discard** (⌘⌫). One click is one rollback bundle, so one Undo reverts it.
  Space toggles the selected file.

| | |
|---|---|
| ![Network tab: two hosts blocked](docs/screenshots/network-light.png) | ![Timeline: changes after snapshot 2](docs/screenshots/timeline-light.png) |
| ![Dark mode, split diff](docs/screenshots/review-split-dark.png) | ![A conflict](docs/screenshots/conflict-light.png) |
| ![After a partial apply](docs/screenshots/applied-light.png) | ![New session](docs/screenshots/new-session-light.png) |

Why Terminal: agents are interactive terminal programs and you often need to
answer them. Terminal.app gives you scrollback, copy/paste and resizing
without Mudroom shipping a terminal emulator. The app writes a small
`run.command` into the session folder that runs `mudroom start <id>` in a
login shell (so `PATH` and API keys match your usual shell), and it follows
progress by polling `session.json`, which `mudroom start` keeps up to date.
An embedded terminal may come later.

## Command line

```sh
# Start a session: clone the project, boot a VM, run the agent on the clone.
export ANTHROPIC_API_KEY=...    # passed through only if set
mudroom run ~/code/myapp -- claude --dangerously-skip-permissions

# Review.
mudroom diff last --stat
mudroom diff last
mudroom network log last        # what the VM connected to, and what was blocked

# Apply everything, only some paths, or only some hunks of one file.
mudroom apply last --all
mudroom apply last src/parser.swift docs/
mudroom hunks last src/parser.swift            # numbered hunks
mudroom apply last src/parser.swift --hunks 1,3

# Changed your mind.
mudroom undo last

# Snapshots taken while the agent ran.
mudroom snapshots last
mudroom diff last --from 2 --to work           # what changed after snapshot 2
mudroom diff last --from 1 --to 3

# Housekeeping.
mudroom list
mudroom discard <session>       # deletes the session's clones, never the project

# Two-step start (what the app does).
mudroom new ~/code/myapp --agent "Claude Code" -- claude --dangerously-skip-permissions
mudroom start <session>
```

Sessions can be named by full id, a unique prefix, or `last`. `run` and
`start` also take `--network locked|open|offline`, `--allow <host>` (this run
only) and `--snapshot-every <minutes>`.

### Network settings

```sh
mudroom network show                          # mode and allowlist for the current directory
mudroom network allow registry.npmjs.org '*.githubusercontent.com'
mudroom network allow pypi.org --session last # the project of a session
mudroom network deny registry.npmjs.org
mudroom network registries on                 # npm, PyPI and GitHub in one go
mudroom network mode offline
mudroom network check                         # boot a VM and try to get out (see below)
```

Settings are per project, in
`~/Library/Application Support/Mudroom/projects/<hash>.json`, outside the
project so the agent can't change them.

### Credentials and logins

`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY` and
`GEMINI_API_KEY` are forwarded into the VM when they are set on the host.
They are passed by name (`container run --env NAME`), so the values don't show
up in the process list.

To use a subscription login instead, sign in once inside a VM:

```sh
mudroom agent login claude      # runs `claude auth login`; paste the code back
mudroom agent login codex       # `codex login --device-auth`
mudroom agent login gemini      # Gemini CLI's sign-in screen, NO_BROWSER mode
mudroom agent status
```

Each agent gets its own config directory,
`~/Library/Application Support/Mudroom/agents/<agent>/home`, mounted at
`/home/node/.claude`, `/home/node/.codex` or `/home/node/.gemini` in every
session for that agent. Your real `~/.claude` (and the others) is never
mounted.

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

Snapshots don't change this: apply always compares the session's base with
the agent's final copy, whatever point the timeline shows.

## Network

Each project has a mode:

- **Locked** (default). The VM is attached to a host-only network
  (`container network create --internal`, named `mudroom-hostonly`). It has
  no route to the internet and no DNS. `mudroom start` runs a small HTTP
  proxy on the Mac for as long as the agent runs, and the VM gets
  `HTTP_PROXY`/`HTTPS_PROXY` pointing at it. The proxy handles `CONNECT`
  (HTTPS) and plain HTTP, lets through only allowlisted hosts, and writes one
  line per connection (host, port, allowed or blocked, bytes, duration) to
  the session's `network.jsonl`.
- **Open**. Normal outbound access. Nothing is filtered or logged.
- **Offline**. The host-only network with no proxy: no internet at all.

The allowlist is the agent's own hosts plus whatever you add:

| Agent | Default hosts |
|---|---|
| Claude Code | api.anthropic.com, console.anthropic.com, platform.claude.com, claude.ai |
| Codex | api.openai.com, chatgpt.com, auth.openai.com |
| Gemini CLI | generativelanguage.googleapis.com, cloudcode-pa.googleapis.com, oauth2.googleapis.com, www.googleapis.com |
| Package registries (off by default) | registry.npmjs.org, pypi.org, files.pythonhosted.org, github.com, codeload.github.com, *.githubusercontent.com |

Telemetry and error-reporting hosts are left out; Claude Code runs with
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` so it doesn't try them. Patterns
are exact hosts or `*.suffix`, which matches subdomains but not the bare
domain. The proxy also refuses an allowed name that resolves to a loopback,
link-local or VM-network address.

### What the isolation actually does

`mudroom network check` boots a VM with a project's settings and tries to
get out. This is its output on macOS 27 with `container` 1.5.0, locked mode:

```
ok        got through  CONNECT api.anthropic.com:443 via proxy: HTTP/1.1 200 Connection Established
ok        got through  HTTPS GET https://api.anthropic.com/ (proxy variables, if set): HTTP 404
ok        stopped      CONNECT example.com:443 via proxy: HTTP/1.1 403 Forbidden
ok        stopped      HTTPS GET https://example.com/ (proxy variables, if set): Request was cancelled.
ok        stopped      resolve example.com in the VM: EAI_AGAIN
ok        stopped      TCP 1.1.1.1:443, ignoring the proxy: timeout
ok        stopped      TCP [2606:4700:4700::1111]:443, ignoring the proxy: ENETUNREACH
ok        stopped      UDP DNS query to 8.8.8.8:53: no reply
note      got through  TCP 192.168.128.1:7000 (a port macOS often listens on): connected
```

A program in the VM that ignores the proxy settings, or opens raw sockets,
gets nowhere: no DNS, no route over IPv4, IPv6 or UDP. Offline mode stops
all of these, including the proxy lines; only the last line (the Mac itself)
still gets through. Run the check on your own machine before relying on it.

If your `container` version can't create host-only networks, locked mode
falls back to the normal NAT network with the proxy variables set. The
session is then marked **proxy-enforced (advisory)** in the CLI and the app:
well-behaved tools go through the allowlist, but nothing stops a direct
connection.

## How it works

```
~/Library/Application Support/Mudroom/
  sessions/<id>/
    session.json   id, project path, command, image, status, network mode and allowlist
    base/          clone of the project when the session started
    work/          clone the agent edits, mounted at /workspace in the VM
    snapshots/     <n>-<time>/ clones of work/ taken while the agent ran
    network.jsonl  one line per proxied or refused connection
    rollback/      one bundle per apply: manifest.json + copies of overwritten files
  projects/<hash>.json   per-project network mode, allowlist, snapshot interval
  agents/<agent>/home/   the agent's persistent config directory
```

`diff` compares `base/` with `work/`. `apply` copies from `work/` to the
project after checking the project against `base/`. Set `MUDROOM_HOME` to keep
all of this somewhere else. If the project is on a different volume or a
non-APFS disk, clones fall back to plain copies.

Snapshots are APFS clones of `work/`, taken every 5 minutes while the agent
runs (configurable per project or with `--snapshot-every`) and once when it
exits. A snapshot is skipped when nothing changed since the last one, and the
oldest are pruned past 24.

The VM layer is a small `SandboxBackend` protocol. The only backend today
shells out to Apple's `container` CLI, which boots each container in its own
lightweight VM. A backend built directly on the `Containerization` Swift
package can replace it later without touching the diff/apply code.

## Limitations

- **The VM can reach services on your Mac.** The host-only network's gateway
  is the Mac itself, so anything listening on all interfaces (AirPlay
  Receiver on port 7000, a dev server bound to `0.0.0.0`, a database) is
  reachable from the VM. `network check` reports this. Bind local services to
  `127.0.0.1`, or turn off the ones you don't need. Apple's `sandboxy`
  documents the same gap. Closing it needs packet filtering that neither
  `container` nor Mudroom offers yet.
- The allowlist works on host names. An allowed host is allowed completely:
  Mudroom doesn't look inside TLS, so it can't tell which API calls the agent
  makes or what it uploads.
- Tools that ignore proxy variables simply fail in locked mode. That is the
  point, but some installers (and anything that opens raw sockets) will need
  the project switched to open for that run.
- The agent's config directory persists and is shared by every session of
  that agent. A session can change it (settings, hooks, MCP servers), and the
  change carries into later sessions for other projects too. It is still
  separate from your real `~/.claude`.
- Snapshots skip unchanged trees by comparing file size, mode and mtime. An
  edit that keeps both size and mtime the same doesn't trigger a snapshot on
  its own. The review diff always compares content.
- The app is ad-hoc signed; no notarized build or Homebrew cask yet.

## Development

```sh
swift build
swift test                 # diff, hunks, apply, undo, allowlist, proxy, snapshot tests; no VM needed
scripts/make-demo.sh       # demo sessions in build/demo (no VM)
scripts/screenshots.sh     # regenerates docs/screenshots from the demo
mudroom network check      # needs `container`: verifies isolation in a real VM
```

The proxy tests run it against a loopback test server. The app target is
`MudroomApp` (SwiftUI, macOS 26+). `MudroomCore` has no UI code; the app and
the CLI both sit on top of it.

## License

MIT. See [LICENSE](LICENSE).
