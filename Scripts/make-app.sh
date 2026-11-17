#!/usr/bin/env bash
# Builds Meboki.app, bundles llama-server, and signs both with the local certificate.
# Usage: Scripts/make-app.sh [--install]     (--install copies the app to ~/Applications and opens it)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${SIGN_IDENTITY:-Local Code Signing}"
APP="$ROOT/build/Meboki.app"
LLAMA="$ROOT/Vendor/bin/llama-server"

[ -x "$LLAMA" ] || { echo "Missing $LLAMA. Run Scripts/build-llama-server.sh first."; exit 1; }

cd "$ROOT"
swift build -c release --product Meboki
BIN="$(swift build -c release --show-bin-path)/Meboki"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Meboki"
cp "$LLAMA" "$APP/Contents/MacOS/llama-server"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"

# Sign the nested binary first, then the app. Same identity every build keeps the Accessibility grant.
codesign --force --sign "$IDENTITY" --identifier dev.local.meboki.llama-server "$APP/Contents/MacOS/llama-server"
codesign --force --sign "$IDENTITY" --identifier dev.local.meboki "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="$HOME/Applications/Meboki.app"
  mkdir -p "$HOME/Applications"
  pkill -x Meboki 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed $DEST"
  open "$DEST"
fi
