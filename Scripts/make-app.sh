#!/usr/bin/env bash
# Builds Meboki.app, bundles llama-server, and signs both with the local certificate.
# Usage: Scripts/make-app.sh [--debug] [--install]
#   --install  copies the app to ~/Applications and opens it
#   --debug    DEBUG configuration: debug menus, demo flags, and licence keys from test payments are accepted
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${SIGN_IDENTITY:-Local Code Signing}"
APP="$ROOT/build/Meboki.app"
LLAMA="$ROOT/Vendor/bin/llama-server"

[ -x "$LLAMA" ] || { echo "Missing $LLAMA. Run Scripts/build-llama-server.sh first."; exit 1; }

CONFIG=release
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option $arg"; exit 2 ;;
  esac
done

cd "$ROOT"
swift build -c "$CONFIG" --product Meboki
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Meboki"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Meboki"
cp "$LLAMA" "$APP/Contents/MacOS/llama-server"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"

# Sign the nested binary first, then the app. Same identity every build keeps the Accessibility grant.
codesign --force --sign "$IDENTITY" --identifier dev.local.meboki.llama-server "$APP/Contents/MacOS/llama-server"
codesign --force --sign "$IDENTITY" --identifier dev.local.meboki "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "Built $APP ($CONFIG)"

if [ "$INSTALL" = 1 ]; then
  DEST="$HOME/Applications/Meboki.app"
  mkdir -p "$HOME/Applications"
  pkill -x Meboki 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed $DEST"
  open "$DEST"
fi
