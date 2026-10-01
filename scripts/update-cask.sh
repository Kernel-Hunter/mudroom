#!/bin/zsh
# Sets the version and sha256 in packaging/homebrew-tap/Casks/mudroom.rb.
#
#   scripts/update-cask.sh 0.4.0            # sha256 of dist/Mudroom-0.4.0.zip
#   scripts/update-cask.sh 0.4.0 --remote   # sha256 of the zip on GitHub Releases
#
# The sha256 in the repo is a placeholder until the first release: run this
# with --remote after the release workflow has uploaded the zip, then copy
# the file to Casks/mudroom.rb in the Kernel-Hunter/homebrew-tap repo.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && "$2" != --remote ) ]]; then
    echo "usage: scripts/update-cask.sh <version> [--remote]" >&2
    exit 1
fi
VERSION=${1#v}
CASK=packaging/homebrew-tap/Casks/mudroom.rb
URL="https://github.com/Kernel-Hunter/mudroom/releases/download/v$VERSION/Mudroom-$VERSION.zip"

if [[ "${2:-}" == --remote ]]; then
    SHA=$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)
else
    ZIP=dist/Mudroom-$VERSION.zip
    [[ -f "$ZIP" ]] || { echo "no $ZIP; run scripts/release.sh $VERSION first, or pass --remote" >&2; exit 1; }
    SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
fi

sed -i '' \
    -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 .*/  sha256 \"$SHA\"/" \
    "$CASK"

grep -E '^  (version|sha256) ' "$CASK"
