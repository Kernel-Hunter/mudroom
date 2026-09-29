#!/bin/zsh
# Builds build/Mudroom.app: the SwiftUI app plus the `mudroom` CLI it runs in
# Terminal, with Info.plist and icon, ad-hoc signed.
#
#   scripts/build-app.sh            # release build
#   CONFIG=debug scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
VERSION=${VERSION:-0.3.0}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
APP=build/Mudroom.app

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

# Ad-hoc signature: enough to run locally. Release builds need a Developer ID
# and notarization.
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/mudroom"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "built $APP ($VERSION, build $BUILD, $CONFIG)"
