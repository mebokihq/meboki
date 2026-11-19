#!/usr/bin/env bash
# Builds Meboki.app, bundles llama-server, and signs both with the local certificate.
# Usage: Scripts/make-app.sh [--debug] [--install]
#   --install  copies the app to ~/Applications and opens it
#   --debug    DEBUG configuration: debug menus, demo flags, and licence keys from test payments are accepted
#
# Updates: a build has an updater only when both are set (a release, or Scripts/test-update.sh):
#   MEBOKI_FEED_URL     the appcast address (https; http only on 127.0.0.1 / localhost, for a local test)
#   MEBOKI_UPDATE_KEY   the public EdDSA key the updates are signed with (base64)
# Without them the app has no update check and no update rows. Optional, for a release or a test:
#   MEBOKI_VERSION, MEBOKI_BUILD   CFBundleShortVersionString and CFBundleVersion (default: App/Info.plist)
#   MEBOKI_APP_DIR      where the bundle is built (default: build/Meboki.app)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${SIGN_IDENTITY:-Local Code Signing}"
APP="${MEBOKI_APP_DIR:-$ROOT/build/Meboki.app}"
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
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/Meboki"
SPARKLE="$BIN_DIR/Sparkle.framework"
[ -d "$SPARKLE" ] || { echo "Missing $SPARKLE (the Sparkle package didn't build)."; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Meboki"
cp "$LLAMA" "$APP/Contents/MacOS/llama-server"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
# The updater framework (symlinks kept). The binary looks for it next to itself in .build; in the bundle
# it is in Contents/Frameworks.
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Meboki"

PLIST="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
[ -z "${MEBOKI_VERSION:-}" ] || plist "Set :CFBundleShortVersionString $MEBOKI_VERSION"
[ -z "${MEBOKI_BUILD:-}" ] || plist "Set :CFBundleVersion $MEBOKI_BUILD"
if [ -n "${MEBOKI_FEED_URL:-}" ] || [ -n "${MEBOKI_UPDATE_KEY:-}" ]; then
  [ -n "${MEBOKI_FEED_URL:-}" ] && [ -n "${MEBOKI_UPDATE_KEY:-}" ] || { echo "Set both MEBOKI_FEED_URL and MEBOKI_UPDATE_KEY."; exit 2; }
  case "$MEBOKI_FEED_URL" in
    https://*) ;;
    http://127.0.0.1[:/]*|http://localhost[:/]*)
      # A local test feed: plain HTTP to this Mac only.
      plist "Add :NSAppTransportSecurity dict"
      plist "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" ;;
    *) echo "MEBOKI_FEED_URL must be https (or http on 127.0.0.1 / localhost)."; exit 2 ;;
  esac
  plist "Add :SUFeedURL string $MEBOKI_FEED_URL"
  plist "Add :SUPublicEDKey string $MEBOKI_UPDATE_KEY"
  plist "Add :SUEnableAutomaticChecks bool true"      # on from the first launch; the app says so (onboarding, Settings)
  plist "Add :SUScheduledCheckInterval integer 86400" # once a day
  plist "Add :SUEnableSystemProfiling bool false"     # nothing about the Mac is sent
  echo "Updater on: $MEBOKI_FEED_URL"
fi

# Sign from the inside out: the updater's helpers, the framework, llama-server, then the app. Same identity
# every build keeps the Accessibility grant.
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$IDENTITY" "$FW/XPCServices/Installer.xpc"
codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
codesign --force --sign "$IDENTITY" "$FW/Autoupdate"
codesign --force --sign "$IDENTITY" "$FW/Updater.app"
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" --identifier dev.local.meboki.llama-server "$APP/Contents/MacOS/llama-server"
codesign --force --sign "$IDENTITY" --identifier dev.local.meboki "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
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
