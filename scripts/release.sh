#!/bin/zsh
# Builds a release zip: dist/Mudroom-<version>.zip, containing Mudroom.app
# (app + bundled `mudroom` CLI), ad-hoc signed. Prints the SHA-256.
#
#   scripts/release.sh 0.4.0
#
# Not notarized. install.sh and the Homebrew cask remove the quarantine flag
# on install, so Gatekeeper doesn't block the app.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -ne 1 ]]; then
    echo "usage: scripts/release.sh <version>   (e.g. 0.4.0, no leading v)" >&2
    exit 1
fi
VERSION=${1#v}

VERSION=$VERSION CONFIG=release scripts/build-app.sh

APP=build/Mudroom.app
CLI=$APP/Contents/Helpers/mudroom

# Check what we're about to ship.
plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
cli_version=$("$CLI" --version)
if [[ "$plist_version" != "$VERSION" || "$cli_version" != "$VERSION" ]]; then
    echo "release.sh: version mismatch: Info.plist $plist_version, CLI $cli_version, wanted $VERSION" >&2
    exit 1
fi
codesign --verify --deep --strict "$APP"
for bin in "$APP/Contents/MacOS/Mudroom" "$CLI"; do
    if ! lipo -archs "$bin" | grep -qw arm64; then
        echo "release.sh: $bin is not arm64" >&2
        exit 1
    fi
done

mkdir -p dist
ZIP=dist/Mudroom-$VERSION.zip
rm -f "$ZIP"
# ditto keeps the bundle's symlinks, modes and signature intact.
ditto -c -k --keepParent "$APP" "$ZIP"

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "$SHA  Mudroom-$VERSION.zip" > "$ZIP.sha256"

echo
echo "version  $VERSION"
echo "zip      $ZIP"
echo "sha256   $SHA"
