#!/bin/zsh
# Regenerates docs/screenshots from the demo sessions (scripts/make-demo.sh).
# The app draws its own window (-MudroomSnapshot), so no Screen Recording
# permission is needed.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$PWD/docs/screenshots
mkdir -p "$OUT"
[[ -d build/Mudroom.app ]] || scripts/build-app.sh
scripts/make-demo.sh >/dev/null
APP=build/Mudroom.app/Contents/MacOS/Mudroom
export MUDROOM_HOME=$PWD/build/demo/store
shot() {  # shot <name> <appearance> [extra defaults...]
  local name=$1 look=$2; shift 2
  rm -f "$OUT/$name.png"
  "$APP" -MudroomAppearance "$look" -MudroomSnapshot "$OUT/$name.png" "$@" 2>/dev/null
  echo "$OUT/$name.png"
}
shot review-light light -MudroomFocus src/api.ts -diffLayout Unified
shot review-dark dark -MudroomFocus src/api.ts -diffLayout Unified
shot review-split-dark dark -MudroomFocus src/api.ts -diffLayout Split
shot conflict-light light -MudroomFocus package.json -diffLayout Unified
shot network-light light -MudroomTab network -MudroomFocusHost registry.npmjs.org:443:false
shot network-dark dark -MudroomTab network
shot timeline-light light -MudroomCompareFrom 2 -MudroomFocus src/cache.ts -diffLayout Unified
shot new-session-light light -MudroomSnapshotAction newSession
MUDROOM_HOME=$PWD/build/demo/empty-store shot welcome-dark dark
# Setup with nothing signed in: a fresh store and file tokens, so your own
# Keychain items don't show. Runtime, image and network are this Mac's.
mkdir -p build/demo/setup-store
MUDROOM_HOME=$PWD/build/demo/setup-store MUDROOM_TOKEN_STORE=file shot setup-light light -MudroomSnapshotAction setup -MudroomSnapshotDelay 9
# Last, since it writes to the demo project: api.ts hunk 1 left out, rest applied.
shot applied-light light -MudroomFocus src/api.ts -diffLayout Unified -MudroomSnapshotDelay 5 \
  -MudroomSnapshotDeselectHunk src/api.ts:1 -MudroomSnapshotAction applySelected
