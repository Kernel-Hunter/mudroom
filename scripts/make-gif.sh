#!/bin/zsh
# Builds docs/demo.gif and docs/demo.mp4 from the screenshots
# (scripts/screenshots.sh), one captioned frame per step.
set -euo pipefail
cd "$(dirname "$0")/.."
S=docs/screenshots
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

frames=(
  "new-session-light|Pick a folder and an agent"
  "review-light|The agent worked on a clone in a Linux VM"
  "conflict-light|Your own edits are never overwritten"
  "network-light|Only allowed hosts get out"
  "applied-light|Apply only what you picked, undo anytime"
)
i=0
for f in $frames; do
  name=${f%%|*} caption=${f#*|}
  swift scripts/caption.swift "$S/$name.png" "$TMP/$(printf %02d $i).png" "$caption"
  i=$((i + 1))
done

# 3.5 s per frame.
ffmpeg -loglevel error -y -framerate 1/3.5 -i "$TMP/%02d.png" \
  -vf "fps=10,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
  docs/demo.gif
ffmpeg -loglevel error -y -framerate 1/3.5 -i "$TMP/%02d.png" \
  -vf "fps=30,format=yuv420p" -c:v libx264 -crf 20 -movflags +faststart docs/demo.mp4
ls -lh docs/demo.gif docs/demo.mp4
