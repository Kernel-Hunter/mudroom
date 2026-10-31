#!/bin/zsh
# Adds a release to the Mac app's update feed, docs/appcast.xml, which GitHub
# Pages serves at https://kernel-hunter.github.io/mudroom/appcast.xml.
#
#   scripts/appcast.sh 0.6.0 [<sha256>]
#
# Pass the zip's SHA-256 from the release workflow's log (the "Upload to the
# release" step prints it) to make sure the zip signed here is the one CI
# built; without it the script trusts the .sha256 on the release.
#
# Run it after the release workflow has uploaded Mudroom-<version>.zip. It
# downloads the zip and its .sha256 and checks one against the other, reads
# the version, build number and minimum macOS from the app inside, signs the
# zip with Sparkle's sign_update (the EdDSA key in the login Keychain), puts
# the item first in the feed (the last ten releases are kept) and signs the
# feed. Then commit docs/appcast.xml and push it to main; installed copies
# of Mudroom see the update on their next daily check.
#
# Environment:
#   SPARKLE_BIN   folder with sign_update
#                 (default ~/Library/Application Support/KernelHunter/sparkle-2.10.0/bin)
#   SPARKLE_KEY_FILE  sign with the private key in this file instead of the
#                 Keychain (sign_update --ed-key-file)
#   For testing only:
#   APPCAST_PUBLIC_KEY  the public key the app must carry, instead of Mudroom's
#   APPCAST_ZIP   use this zip (with <zip>.sha256 next to it) instead of downloading
#   APPCAST_URL   put this download URL in the feed instead of the GitHub one
#   APPCAST_FILE  write this feed instead of docs/appcast.xml
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: scripts/appcast.sh <version> [<sha256>]   (e.g. 0.6.0, no leading v)" >&2
    exit 1
fi
VERSION=${1#v}
PINNED=${2:-}
if [[ -n "$PINNED" && ! "$PINNED" =~ '^[0-9a-f]{64}$' ]]; then
    echo "appcast.sh: '$PINNED' isn't a SHA-256" >&2
    exit 1
fi
# The test settings must never reach the real feed.
if [[ -z "${APPCAST_FILE:-}" && -n "${APPCAST_ZIP:-}${APPCAST_URL:-}${APPCAST_PUBLIC_KEY:-}" ]]; then
    echo "appcast.sh: APPCAST_ZIP, APPCAST_URL and APPCAST_PUBLIC_KEY are for tests; set APPCAST_FILE too" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "appcast.sh: '$VERSION' isn't a release version" >&2
    exit 1
fi
REPO=Kernel-Hunter/mudroom
PUBLIC_KEY=${APPCAST_PUBLIC_KEY:-QKKfpvfADDZDhLbEDTOZ4QKgc5EgHgxP3hGulato8T8=}
SPARKLE_BIN=${SPARKLE_BIN:-"$HOME/Library/Application Support/KernelHunter/sparkle-2.10.0/bin"}
SIGN="$SPARKLE_BIN/sign_update"
KEY_ARGS=()
[[ -z "${SPARKLE_KEY_FILE:-}" ]] || KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
FEED=${APPCAST_FILE:-docs/appcast.xml}
NAME="Mudroom-$VERSION.zip"
URL=${APPCAST_URL:-"https://github.com/$REPO/releases/download/v$VERSION/$NAME"}
NOTES_URL="https://github.com/$REPO/releases/tag/v$VERSION"

[[ -x "$SIGN" ]] || { echo "appcast.sh: no sign_update at $SIGN (set SPARKLE_BIN)" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/mudroom-appcast.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

if [[ -n "${APPCAST_ZIP:-}" ]]; then
    cp "$APPCAST_ZIP" "$tmp/$NAME"
    cp "$APPCAST_ZIP.sha256" "$tmp/$NAME.sha256"
else
    echo "==> Downloading $URL"
    curl -fL --proto '=https' --proto-redir '=https' --max-filesize 300000000 --progress-bar -o "$tmp/$NAME" "$URL"
    curl -fsSL --proto '=https' --proto-redir '=https' --max-filesize 1000 -o "$tmp/$NAME.sha256" "$URL.sha256"
fi
expected=$(cut -d' ' -f1 "$tmp/$NAME.sha256")
actual=$(shasum -a 256 "$tmp/$NAME" | cut -d' ' -f1)
if [[ ! "$expected" =~ '^[0-9a-f]{64}$' || "$expected" != "$actual" ]]; then
    echo "appcast.sh: checksum mismatch (the .sha256 says '$expected', the zip is $actual)" >&2
    exit 1
fi
if [[ -n "$PINNED" && "$PINNED" != "$actual" ]]; then
    echo "appcast.sh: the zip on the release is $actual, not the $PINNED you passed. Not signing it." >&2
    exit 1
fi
echo "    sha256 ok ($actual)${PINNED:+, matches the one you passed}"
[[ -n "$PINNED" ]] || echo "    Compare it with the release workflow's log before you push the feed."

# What's inside has to be what the feed will say it is.
ditto -x -k "$tmp/$NAME" "$tmp/unpacked"
APP="$tmp/unpacked/Mudroom.app"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
short=$(plist CFBundleShortVersionString)
build=$(plist CFBundleVersion)
min_os=$(plist LSMinimumSystemVersion)
key=$(plist SUPublicEDKey)
if [[ "$short" != "$VERSION" ]]; then
    echo "appcast.sh: the zip holds Mudroom $short, not $VERSION" >&2
    exit 1
fi
if [[ "$key" != "$PUBLIC_KEY" ]]; then
    echo "appcast.sh: the app's SUPublicEDKey is '$key', not Mudroom's key" >&2
    exit 1
fi
[[ "$build" =~ '^[0-9]+$' ]] || { echo "appcast.sh: odd build number '$build'" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
# Sparkle wants major.minor.patch.
parts=(${(s:.:)min_os})
while (( ${#parts} < 3 )); do parts+=(0); done
min_os=${(j:.:)parts}

# sparkle:edSignature="..." length="..."
signed=$("$SIGN" "${KEY_ARGS[@]}" "$tmp/$NAME")
if [[ ! "$signed" =~ '^sparkle:edSignature="[A-Za-z0-9+/=]+" length="[0-9]+"$' ]]; then
    echo "appcast.sh: unexpected sign_update output: $signed" >&2
    exit 1
fi
signature=${${signed#*edSignature=\"}%%\"*}
"$SIGN" "${KEY_ARGS[@]}" --verify "$tmp/$NAME" "$signature"

# The release notes go in the feed itself, so they are covered by its
# signature. GitHub writes them when the release is created.
notes=""
if [[ -z "${APPCAST_ZIP:-}" ]] && command -v gh >/dev/null 2>&1; then
    notes=$(gh release view "v$VERSION" --repo "$REPO" --json body --jq .body 2>/dev/null || true)
fi
[[ -n "$notes" ]] || notes="See the [release notes]($NOTES_URL)."
printf '%s' "$notes" > "$tmp/notes.md"

mkdir -p "$(dirname "$FEED")"
[[ -f "$FEED" ]] || : > "$FEED"
python3 -I - "$FEED" "$tmp/notes.md" "$VERSION" "$build" "$min_os" "$URL" "$NOTES_URL" "$signed" <<'PY'
import re, sys
from email.utils import formatdate
from xml.sax.saxutils import escape, quoteattr

feed, notes_file, version, build, min_os, url, notes_url, signed = sys.argv[1:]
notes = open(notes_file, encoding="utf-8").read().replace("]]>", "]] >")
length = re.search(r'length="(\d+)"', signed).group(1)
signature = re.search(r'edSignature="([^"]+)"', signed).group(1)

item = f"""    <item>
      <title>Mudroom {escape(version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(min_os)}</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <sparkle:fullReleaseNotesLink>{escape(notes_url)}</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[{notes}]]></description>
      <enclosure url={quoteattr(url)} length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>"""

old = open(feed, encoding="utf-8").read()
items = re.findall(r"    <item>.*?</item>", old, flags=re.S)
items = [i for i in items if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" not in i]
# Sparkle orders updates by build number; a smaller one would never be offered.
older = [int(b) for i in items for b in re.findall(r"<sparkle:version>(\d+)</sparkle:version>", i)]
if older and int(build) <= max(older):
    sys.exit(f"appcast.sh: build {build} isn't newer than build {max(older)} already in the feed")
items = [item] + items[:9]

# Everything else, the old feed signature included, is written fresh.
out = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Mudroom</title>
    <link>https://github.com/Kernel-Hunter/mudroom</link>
    <description>Updates for Mudroom.app. Made by scripts/appcast.sh; edit nothing by hand, the signature covers the whole file.</description>
    <language>en</language>
""" + "\n".join(items) + """
  </channel>
</rss>
"""
open(feed, "w", encoding="utf-8").write(out)
PY

# Signs the feed in place (the signature goes in the file), then checks it.
"$SIGN" "${KEY_ARGS[@]}" --disable-signing-warning "$FEED"
"$SIGN" "${KEY_ARGS[@]}" --verify "$FEED"
xmllint --noout "$FEED"

echo
echo "version  $VERSION (build $build, macOS $min_os or later)"
echo "feed     $FEED"
echo "next     commit $FEED and push it to main"
