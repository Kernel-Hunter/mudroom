#!/bin/sh
# Installs Mudroom.app and the `mudroom` command from GitHub Releases.
#
#   curl -fsSL https://raw.githubusercontent.com/Kernel-Hunter/mudroom/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --uninstall
#
# Environment:
#   MUDROOM_VERSION   install this version (e.g. 0.4.0) instead of the latest
#   MUDROOM_ZIP       install from this local zip instead of downloading
#   MUDROOM_APP_DIR   install the app here instead of /Applications or ~/Applications
#   MUDROOM_BIN_DIR   put the `mudroom` link here instead of the first usable bin dir
#
# Never uses sudo. If /Applications isn't writable the app goes to
# ~/Applications, and the command goes to ~/.local/bin if no Homebrew bin
# directory is writable.
#
# The whole script is inside main(), so a partial download runs nothing.

set -eu

REPO="Kernel-Hunter/mudroom"
APP_NAME="Mudroom.app"
BUNDLE_ID="io.github.kernel-hunter.mudroom"
CLI_IN_APP="Contents/Helpers/mudroom"

say() { printf '%s\n' "$*"; }
step() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Install Mudroom from GitHub Releases.

usage: install.sh [--uninstall] [--help]

  --uninstall   remove every Mudroom.app and mudroom link this script would
                install (sessions and settings in
                ~/Library/Application Support/Mudroom are kept)

Environment: MUDROOM_VERSION, MUDROOM_ZIP, MUDROOM_APP_DIR, MUDROOM_BIN_DIR
EOF
}

check_platform() {
    [ "$(uname -s)" = "Darwin" ] || die "Mudroom only runs on macOS."

    # uname -m says x86_64 in a shell running under Rosetta, so ask the
    # hardware instead.
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]; then
        die "Mudroom needs a Mac with Apple silicon (Apple's container runtime does not support Intel Macs)."
    fi

    os_version=$(sw_vers -productVersion)
    os_major=${os_version%%.*}
    case "$os_major" in
        '' | *[!0-9]*) die "couldn't read the macOS version ('$os_version')." ;;
    esac
    if [ "$os_major" -lt 26 ]; then
        die "Mudroom needs macOS 26 or later; this Mac has macOS $os_version."
    fi
}

# Is this path a Mudroom app bundle (and not something else with the name)?
is_mudroom_app() {
    [ -d "$1" ] || return 1
    found_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true)
    [ "$found_id" = "$BUNDLE_ID" ]
}

# Is this path a symlink pointing at the CLI inside a Mudroom.app?
is_our_link() {
    [ -L "$1" ] || return 1
    case "$(readlink "$1")" in
        */"$APP_NAME"/"$CLI_IN_APP") return 0 ;;
    esac
    return 1
}

pick_app_dir() {
    if [ -n "${MUDROOM_APP_DIR:-}" ]; then
        mkdir -p "$MUDROOM_APP_DIR" || die "can't create $MUDROOM_APP_DIR"
        app_dir=$MUDROOM_APP_DIR
    elif [ -w /Applications ]; then
        app_dir=/Applications
    else
        app_dir="$HOME/Applications"
        mkdir -p "$app_dir"
        say "    /Applications isn't writable for $(id -un), so installing to ~/Applications instead (no sudo needed)."
    fi
}

pick_bin_dir() {
    if [ -n "${MUDROOM_BIN_DIR:-}" ]; then
        mkdir -p "$MUDROOM_BIN_DIR" || die "can't create $MUDROOM_BIN_DIR"
        bin_dir=$MUDROOM_BIN_DIR
        return
    fi
    for candidate in /opt/homebrew/bin /usr/local/bin; do
        if [ -d "$candidate" ] && [ -w "$candidate" ]; then
            bin_dir=$candidate
            return
        fi
    done
    bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"
}

on_path() {
    case ":$PATH:" in
        *":$1:"*) return 0 ;;
    esac
    return 1
}

# Sets release_tag and zip_url for MUDROOM_VERSION or the latest release.
resolve_release() {
    if [ -n "${MUDROOM_VERSION:-}" ]; then
        version=${MUDROOM_VERSION#v}
        release_tag="v$version"
        zip_url="https://github.com/$REPO/releases/download/$release_tag/Mudroom-$version.zip"
        return
    fi

    api="https://api.github.com/repos/$REPO/releases/latest"
    if json=$(curl -fsSL -H 'Accept: application/vnd.github+json' "$api" 2>/dev/null); then
        release_tag=$(printf '%s\n' "$json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
        zip_url=$(printf '%s\n' "$json" |
            sed -n 's/.*"browser_download_url": *"\([^"]*\/Mudroom-[^"]*\.zip\)".*/\1/p' | head -n 1)
    fi

    # The API allows 60 unauthenticated requests an hour. If it refused, the
    # /releases/latest page redirects to the latest tag, which is enough.
    if [ -z "${zip_url:-}" ]; then
        latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null || true)
        case "$latest" in
            */releases/tag/v*)
                release_tag=${latest##*/}
                zip_url="https://github.com/$REPO/releases/download/$release_tag/Mudroom-${release_tag#v}.zip"
                ;;
            *) die "couldn't find a Mudroom release on github.com/$REPO. Set MUDROOM_VERSION to pick one." ;;
        esac
    fi
}

download() {
    tmp=$1
    if [ -n "${MUDROOM_ZIP:-}" ]; then
        [ -f "$MUDROOM_ZIP" ] || die "MUDROOM_ZIP: no such file: $MUDROOM_ZIP"
        step "Using local zip $MUDROOM_ZIP"
        cp "$MUDROOM_ZIP" "$tmp/Mudroom.zip"
        return
    fi

    resolve_release
    step "Downloading Mudroom $release_tag"
    say "    $zip_url"
    curl -fL --progress-bar -o "$tmp/Mudroom.zip" "$zip_url" ||
        die "download failed. Check the version, or try again later."

    # release.sh publishes a .sha256 next to each zip. Check it when it's there.
    if curl -fsSL -o "$tmp/Mudroom.zip.sha256" "$zip_url.sha256" 2>/dev/null; then
        expected=$(cut -d' ' -f1 <"$tmp/Mudroom.zip.sha256")
        actual=$(shasum -a 256 "$tmp/Mudroom.zip" | cut -d' ' -f1)
        [ "$expected" = "$actual" ] || die "checksum mismatch (expected $expected, got $actual). Not installing."
        say "    sha256 ok ($actual)"
    else
        warn "no checksum file published for this release; skipping the checksum check."
    fi
}

install_app() {
    tmp=$1
    ditto -x -k "$tmp/Mudroom.zip" "$tmp/unpacked" || die "couldn't unpack the zip."
    new_app="$tmp/unpacked/$APP_NAME"
    is_mudroom_app "$new_app" || die "the zip doesn't contain $APP_NAME."
    codesign --verify --deep --strict "$new_app" 2>/dev/null ||
        die "the app's signature doesn't verify; the download may be damaged."

    pick_app_dir
    target="$app_dir/$APP_NAME"
    if [ -e "$target" ] && ! is_mudroom_app "$target"; then
        die "$target exists and isn't Mudroom. Move it away and run this again."
    fi

    if pgrep -f "$target/Contents/MacOS/Mudroom" >/dev/null 2>&1; then
        say "    Mudroom is running; quitting it so it can be replaced."
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        sleep 1
    fi

    step "Installing $target"
    if [ -e "$target" ]; then
        mv "$target" "$tmp/old.app"
    fi
    if ! ditto "$new_app" "$target"; then
        [ -e "$tmp/old.app" ] && mv "$tmp/old.app" "$target"
        die "couldn't copy the app to $app_dir."
    fi

    # curl doesn't set the quarantine flag, but a zip fetched some other way
    # (or MUDROOM_ZIP) may carry it. Mudroom isn't notarized, so with the flag
    # set Gatekeeper would refuse to open it.
    xattr -dr com.apple.quarantine "$target" 2>/dev/null || true

    version_installed=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")
    say "    Mudroom $version_installed"
}

link_cli() {
    pick_bin_dir
    link="$bin_dir/mudroom"
    if [ -e "$link" ] || [ -L "$link" ]; then
        if ! is_our_link "$link"; then
            warn "$link already exists and isn't a link to Mudroom.app; leaving it alone."
            warn "The CLI is at $target/$CLI_IN_APP"
            return
        fi
        rm -f "$link"
    fi
    step "Linking $link -> $target/$CLI_IN_APP"
    ln -s "$target/$CLI_IN_APP" "$link"
    if ! on_path "$bin_dir"; then
        warn "$bin_dir is not on your PATH. Add this to ~/.zshrc:"
        warn "  export PATH=\"$bin_dir:\$PATH\""
    fi
}

next_steps() {
    say ""
    if command -v container >/dev/null 2>&1; then
        container_version=$(container --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -n 1)
        major=${container_version%%.*}
        minor=${container_version#*.}
        minor=${minor%%.*}
        case "$major$minor" in
            '' | *[!0-9]*) say "Found Apple's container CLI. Mudroom needs 1.5 or later." ;;
            *)
                if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 5 ]; }; then
                    warn "Apple's container CLI $container_version is too old; Mudroom needs 1.5 or later."
                    if command -v brew >/dev/null 2>&1; then
                        warn "Update it with: brew upgrade container"
                    else
                        warn "Get the latest installer from https://github.com/apple/container/releases"
                    fi
                else
                    say "Found Apple's container CLI $container_version."
                fi
                ;;
        esac
    elif command -v brew >/dev/null 2>&1; then
        say "Mudroom runs agents with Apple's container CLI, which isn't installed yet."
        say "Setup installs it for you (brew install container)."
    else
        say "Mudroom runs agents with Apple's container CLI, which isn't installed yet."
        say "Install it from https://github.com/apple/container/releases (the signed .pkg), then run Setup."
    fi
    # Before the shell picks up a new PATH entry, the full path works.
    cli=mudroom
    on_path "$bin_dir" || cli="\"$link\""
    say ""
    say "Next: open Mudroom and follow the Setup window, or run Setup in a terminal:"
    say "  open \"$target\""
    say "  $cli setup               # runtime, agent image (a few minutes, once), network, sign-in"
    say ""
    say "Uninstall: curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- --uninstall"
}

uninstall() {
    removed=0
    # With MUDROOM_APP_DIR or MUDROOM_BIN_DIR set, only look there, so
    # removing a test install doesn't also remove the real one.
    app_dirs='/Applications|'"$HOME/Applications"
    [ -z "${MUDROOM_APP_DIR:-}" ] || app_dirs=$MUDROOM_APP_DIR
    bin_dirs='/opt/homebrew/bin|/usr/local/bin|'"$HOME/.local/bin"
    [ -z "${MUDROOM_BIN_DIR:-}" ] || bin_dirs=$MUDROOM_BIN_DIR
    old_ifs=$IFS
    IFS='|'
    for dir in $app_dirs; do
        IFS=$old_ifs
        app="$dir/$APP_NAME"
        if is_mudroom_app "$app"; then
            if [ -w "$dir" ]; then
                step "Removing $app"
                rm -rf "$app"
                removed=1
            else
                warn "$app is in a folder you can't write to. Remove it in Finder, or with: sudo rm -rf '$app'"
            fi
        fi
    done
    IFS='|'
    for dir in $bin_dirs; do
        IFS=$old_ifs
        link="$dir/mudroom"
        if is_our_link "$link"; then
            step "Removing $link"
            rm -f "$link"
            removed=1
        fi
    done
    IFS=$old_ifs
    if [ "$removed" = 0 ]; then
        say "Nothing to remove: no Mudroom.app or mudroom link found."
    fi
    if [ -d "$HOME/Library/Application Support/Mudroom" ]; then
        say ""
        say "Kept your sessions and settings in ~/Library/Application Support/Mudroom."
        say "Delete that folder yourself if you don't need them."
    fi
    uninstall_leftovers
}

# What neither this script nor 'brew uninstall' removes: sign-in tokens and
# API keys in the Keychain, and the agent image in the VM runtime.
uninstall_leftovers() {
    if security find-generic-password -s "$BUNDLE_ID" >/dev/null 2>&1; then
        say ""
        say "Mudroom's tokens and API keys are still in your login Keychain (service $BUNDLE_ID)."
        say "Remove them with (repeat until it says the item could not be found):"
        say "  security delete-generic-password -s $BUNDLE_ID"
    fi
    if command -v container >/dev/null 2>&1 && container image inspect mudroom/agent-base:latest >/dev/null 2>&1; then
        say ""
        say "The agent image (mudroom/agent-base, about 1.5 GB) is still in Apple's container runtime."
        say "Remove it with: container image delete mudroom/agent-base:latest"
    fi
}

main() {
    mode=install
    for arg in "$@"; do
        case "$arg" in
            --uninstall) mode=uninstall ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; die "unknown option: $arg" ;;
        esac
    done

    brew_cask=0
    if command -v brew >/dev/null 2>&1 && brew list --cask mudroom >/dev/null 2>&1; then
        brew_cask=1
    fi

    if [ "$mode" = uninstall ]; then
        [ "$brew_cask" = 0 ] || die "Mudroom is installed with Homebrew. Use 'brew uninstall --cask mudroom' instead."
        uninstall
        return
    fi

    check_platform
    [ "$brew_cask" = 0 ] || die "Mudroom is installed with Homebrew. Use 'brew upgrade --cask mudroom' instead."

    tmp=$(mktemp -d "${TMPDIR:-/tmp}/mudroom-install.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT
    trap 'exit 130' INT TERM

    download "$tmp"
    install_app "$tmp"
    link_cli
    next_steps
}

main "$@"
