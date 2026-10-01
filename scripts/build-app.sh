#!/bin/zsh
# Builds build/Mudroom.app: the SwiftUI app plus the `mudroom` CLI it runs in
# Terminal, with Info.plist and icon, ad-hoc signed.
#
#   scripts/build-app.sh            # release build
#   CONFIG=debug scripts/build-app.sh
#   VERSION=1.2.3 scripts/build-app.sh   # stamp a version into the app and CLI
#
# The default version comes from Sources/mudroom/Version.swift.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
VERSION_FILE=Sources/mudroom/Version.swift
SOURCE_VERSION=$(sed -n 's/^let mudroomVersion = "\(.*\)"$/\1/p' "$VERSION_FILE")
VERSION=${VERSION:-$SOURCE_VERSION}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
APP=build/Mudroom.app

if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$' ]]; then
    echo "build-app.sh: bad version '$VERSION'" >&2
    exit 1
fi

# Stamp the CLI's version for this build only, and put the file back after.
if [[ "$VERSION" != "$SOURCE_VERSION" ]]; then
    cp "$VERSION_FILE" "$VERSION_FILE.orig"
    trap 'mv -f "$VERSION_FILE.orig" "$VERSION_FILE"' EXIT
    sed -i '' "s/^let mudroomVersion = .*/let mudroomVersion = \"$VERSION\"/" "$VERSION_FILE"
fi

swift build -c "$CONFIG" --product MudroomApp
swift build -c "$CONFIG" --product mudroom
BIN=$(swift build -c "$CONFIG" --show-bin-path)

[[ -f App/AppIcon.icns ]] || swift scripts/make-icon.swift App/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/MudroomApp" "$APP/Contents/MacOS/Mudroom"
# Not in MacOS/: "mudroom" and "Mudroom" are the same name on a
# case-insensitive volume.
cp "$BIN/mudroom" "$APP/Contents/Helpers/mudroom"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" App/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature, inside out (helper first, then the bundle). No hardened
# runtime and no entitlements: the app and CLI only shell out to `container`,
# which has its own virtualization entitlement.
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/mudroom"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "built $APP ($VERSION, build $BUILD, $CONFIG)"
