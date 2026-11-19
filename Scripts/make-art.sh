#!/usr/bin/env bash
# Renders the app icon and the DMG window background from their SVG sources in App/Art/.
# Usage: Scripts/make-art.sh
# Needs rsvg-convert (brew install librsvg). Outputs are committed, so a build doesn't need it:
#   App/Art/AppIcon.icns            the app icon (all sizes 16–1024)
#   App/Art/dmg-background.tiff     660 × 400 window background, 1x + 2x in one file
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ART="$ROOT/App/Art"
command -v rsvg-convert >/dev/null || { echo "rsvg-convert is missing: brew install librsvg"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" "$ART/AppIcon.svg" -o "$ICONSET/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) "$ART/AppIcon.svg" -o "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$ART/AppIcon.icns"

rsvg-convert -w 660 -h 400 "$ART/dmg-background.svg" -o "$TMP/bg.png"
rsvg-convert -w 1320 -h 800 "$ART/dmg-background.svg" -o "$TMP/bg@2x.png"
tiffutil -cathidpicheck "$TMP/bg.png" "$TMP/bg@2x.png" -out "$ART/dmg-background.tiff" 2>/dev/null

ls -l "$ART/AppIcon.icns" "$ART/dmg-background.tiff"
