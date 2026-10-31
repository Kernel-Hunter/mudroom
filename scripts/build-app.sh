#!/bin/zsh
# Builds build/Mudroom.app: the SwiftUI app plus the `mudroom` CLI it runs in
# Terminal, with Info.plist, icon and Sparkle.framework (the updater),
# ad-hoc signed.
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
    # The backup goes in build/, not next to the source, where SwiftPM
    # would warn about an unhandled file.
    mkdir -p build
    cp "$VERSION_FILE" build/Version.swift.orig
    trap 'mv -f build/Version.swift.orig "$VERSION_FILE"' EXIT
    sed -i '' "s/^let mudroomVersion = .*/let mudroomVersion = \"$VERSION\"/" "$VERSION_FILE"
fi

swift build -c "$CONFIG" --product MudroomApp
swift build -c "$CONFIG" --product mudroom
BIN=$(swift build -c "$CONFIG" --show-bin-path)

[[ -f App/AppIcon.icns ]] || swift scripts/make-icon.swift App/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/MudroomApp" "$APP/Contents/MacOS/Mudroom"
# SwiftPM also leaves an rpath to its own build folder; the app loads
# Sparkle from Contents/Frameworks only.
otool -l "$APP/Contents/MacOS/Mudroom" |
    awk '/cmd LC_RPATH/ { getline; getline; sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print }' |
    while IFS= read -r rpath; do
    [[ "$rpath" == @* ]] || install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/Mudroom"
done
# ditto keeps the framework's symlinks. The XPC services are only for
# sandboxed apps, which Mudroom isn't.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
# Not in MacOS/: "mudroom" and "Mudroom" are the same name on a
# case-insensitive volume.
cp "$BIN/mudroom" "$APP/Contents/Helpers/mudroom"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" App/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature, inside out: Sparkle's helpers, then the framework, the
# CLI, and the bundle last. No hardened runtime and no entitlements: the app
# and CLI only shell out to `container`, which has its own virtualization
# entitlement.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --timestamp=none "$SPARKLE/Versions/B/Autoupdate"
codesign --force --sign - --timestamp=none "$SPARKLE/Versions/B/Updater.app"
codesign --force --sign - --timestamp=none "$SPARKLE"
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/mudroom"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

# Keep dev builds out of Spotlight and the app launcher, so they don't show up
# next to an installed copy.
touch "$(dirname "$APP")/.metadata_never_index"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true

echo "built $APP ($VERSION, build $BUILD, $CONFIG)"
