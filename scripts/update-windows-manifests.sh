#!/bin/zsh
# Sets the version, URLs and SHA-256s of the Windows zips in the Scoop
# manifest (packaging/scoop/mudroom.json) and the winget manifests
# (packaging/winget/manifests/k/KernelHunter/Mudroom/<version>/).
#
#   scripts/update-windows-manifests.sh 0.2.0
#
# The hashes come from dist/mudroom-<version>-windows-<arch>.zip.sha256 when
# those files are there, otherwise from the .sha256 files the release
# workflow attached to the GitHub release. The hashes in the repo are
# placeholders (all zeros) until the release exists: run this after the
# release workflow has finished, then copy mudroom.json to the
# Kernel-Hunter/scoop-bucket repo and the winget folder to a fork of
# microsoft/winget-pkgs.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -ne 1 ]]; then
    echo "usage: scripts/update-windows-manifests.sh <version>   (e.g. 0.2.0, no leading v)" >&2
    exit 1
fi
VERSION=${1#v}
BASE="https://github.com/Kernel-Hunter/mudroom/releases/download/v$VERSION"

sha() {
    local file="mudroom-$VERSION-windows-$1.zip.sha256" hash
    if [[ -f "dist/$file" ]]; then
        hash=$(cut -d' ' -f1 "dist/$file")
    else
        hash=$(curl -fsSL "$BASE/$file" | cut -d' ' -f1)
    fi
    [[ "$hash" =~ '^[0-9a-f]{64}$' ]] || { echo "no SHA-256 for $file" >&2; exit 1; }
    echo "$hash"
}
X64=$(sha x86_64)
ARM64=$(sha arm64)

# Scoop: the version, then each architecture's url, hash and extract_dir.
SCOOP=packaging/scoop/mudroom.json
sed -i '' -E \
    -e "s|^    \"version\": \".*\"|    \"version\": \"$VERSION\"|" \
    -e "s|/v[^/\$]*/mudroom-[^/\$]*-windows-|/v$VERSION/mudroom-$VERSION-windows-|" \
    -e "s|\"extract_dir\": \"mudroom-[^\$]*-windows-|\"extract_dir\": \"mudroom-$VERSION-windows-|" \
    "$SCOOP"
# The hash line follows its url line.
sed -i '' -E \
    -e "/windows-x86_64\\.zip\"/{n;s|\"hash\": \"[0-9a-f]*\"|\"hash\": \"$X64\"|;}" \
    -e "/windows-arm64\\.zip\"/{n;s|\"hash\": \"[0-9a-f]*\"|\"hash\": \"$ARM64\"|;}" \
    "$SCOOP"

# winget: move the newest manifest folder to the new version and edit it.
WINGET=packaging/winget/manifests/k/KernelHunter/Mudroom
OLD=$(ls "$WINGET" | sort -V | tail -1)
if [[ "$OLD" != "$VERSION" ]]; then
    mv "$WINGET/$OLD" "$WINGET/$VERSION"
fi
for f in "$WINGET/$VERSION"/*.yaml; do
    sed -i '' -E \
        -e "s|^PackageVersion: .*|PackageVersion: $VERSION|" \
        -e "s|/v[^/]*/mudroom-[^/]*-windows-|/v$VERSION/mudroom-$VERSION-windows-|" \
        -e "s|RelativeFilePath: mudroom-[^/]*-windows-|RelativeFilePath: mudroom-$VERSION-windows-|" \
        -e "s|/releases/tag/v.*|/releases/tag/v$VERSION|" \
        "$f"
done
INSTALLER="$WINGET/$VERSION/KernelHunter.Mudroom.installer.yaml"
sed -i '' -E \
    -e "/windows-x86_64\\.zip$/{n;s|InstallerSha256: .*|InstallerSha256: ${X64:u}|;}" \
    -e "/windows-arm64\\.zip$/{n;s|InstallerSha256: .*|InstallerSha256: ${ARM64:u}|;}" \
    "$INSTALLER"

grep -nE '"(version|url|hash|extract_dir)"' "$SCOOP" | grep -v '\$'
grep -nE 'PackageVersion|InstallerUrl|InstallerSha256|RelativeFilePath' "$INSTALLER"
