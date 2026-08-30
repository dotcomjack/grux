#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="Resources/AppIcon.icns"
MASTER="/tmp/grux-icon-master.png"
ISET="/tmp/grux-icon.iconset"

echo "[1/3] Rendering 1024x1024 master…"
swift tools/MakeIcon.swift "$MASTER"

echo "[2/3] Generating iconset sizes with sips…"
rm -rf "$ISET"
mkdir -p "$ISET"
# macOS .iconset standard sizes + @2x retina variants.
for spec in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    set -- $spec
    sips -z $1 $1 "$MASTER" --out "$ISET/$2" > /dev/null
done

echo "[3/3] iconutil → $OUT"
mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ISET" -o "$OUT"

echo "✅ Built $OUT"
