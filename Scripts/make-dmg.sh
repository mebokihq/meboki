#!/usr/bin/env bash
# Packs an app bundle into a styled DMG: background (App/Art/dmg-background.tiff), the app on the left,
# an Applications link on the right, no toolbar. The layout is written straight into the image's .DS_Store
# by dmgbuild, so no Finder scripting runs on this Mac.
# Usage: Scripts/make-dmg.sh <Meboki.app> <out.dmg>
# dmgbuild is installed once into build/.dmg-venv (needs the network the first time).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-}"; DMG="${2:-}"
[ -d "$APP" ] && [ -n "$DMG" ] || { echo "usage: $0 <Meboki.app> <out.dmg>"; exit 2; }

VENV="$ROOT/build/.dmg-venv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  /usr/bin/python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "dmgbuild==1.6.5"
fi

SETTINGS="$(mktemp -t meboki-dmg).py"
trap 'rm -f "$SETTINGS"' EXIT
cat > "$SETTINGS" <<'EOF'
import os
app = defines["app"]
name = os.path.basename(app)
format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]
window_rect = ((200, 120), (660, int(defines.get("height", 428))))  # 400 of content + the title bar
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
show_icon_preview = False
arrange_by = None
icon_size = 128
text_size = 13
# Centres match App/Art/dmg-background.svg.
icon_locations = {name: (170, 220), "Applications": (490, 220)}
EOF

rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$SETTINGS" \
  -D app="$APP" -D height="${MEBOKI_DMG_HEIGHT:-428}" -D icon="$ROOT/App/Art/AppIcon.icns" -D background="$ROOT/App/Art/dmg-background.tiff" \
  "Meboki" "$DMG"
echo "Built $DMG"
