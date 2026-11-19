#!/usr/bin/env bash
# A local end-to-end test of the updater: no release, no server, no Apple account.
#
#   Scripts/test-update.sh            build both versions and the feed, install the old one, serve the feed
#   Scripts/test-update.sh --no-install   the same, but leave ~/Applications alone (old build stays in build/update-test/old)
#
# What it makes, all under build/update-test/ (gitignored):
#   key            a throwaway EdDSA key pair for this test only (never the release key)
#   old/Meboki.app the current version, with the updater pointed at http://127.0.0.1:8765/appcast.xml
#   feed/          the next version (build number + 1) as a signed zip, and appcast.xml
# Then it serves feed/ on 127.0.0.1:8765 until Ctrl-C. In the installed app: right-click the menu-bar icon ›
# Check for Updates…, or wait for the dot on the icon. Afterwards run Scripts/make-app.sh --install to get
# the plain build (no updater) back.
#
# Both builds are signed with the usual local identity, so the Accessibility grant survives the update.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/update-test"
PORT="${MEBOKI_TEST_PORT:-8765}"
FEED="http://127.0.0.1:$PORT/appcast.xml"
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
INSTALL=1
CONFIG_FLAG=()
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --debug) CONFIG_FLAG=(--debug) ;;
    *) echo "Unknown option $arg"; exit 2 ;;
  esac
done

cd "$ROOT"
swift package resolve >/dev/null
[ -x "$TOOLS/generate_appcast" ] || { echo "Missing $TOOLS/generate_appcast (swift package resolve)."; exit 1; }
mkdir -p "$WORK"

# The test key: a 32-byte Ed25519 seed (base64) in a file, and its public key.
if [ ! -s "$WORK/key" ]; then
  ( umask 077; cat > "$WORK/makekey.swift" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
    swift "$WORK/makekey.swift" > "$WORK/key.out"
    sed -n 1p "$WORK/key.out" > "$WORK/key"
    sed -n 2p "$WORK/key.out" > "$WORK/key.pub"
    rm -f "$WORK/key.out" "$WORK/makekey.swift" )
fi
PUBLIC="$(cat "$WORK/key.pub")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' App/Info.plist)"
NEXT_BUILD=$((BUILD + 1))
NEXT_VERSION="$VERSION-test$NEXT_BUILD"

export MEBOKI_FEED_URL="$FEED" MEBOKI_UPDATE_KEY="$PUBLIC"
rm -rf "$WORK/old" "$WORK/new" "$WORK/feed"
mkdir -p "$WORK/old" "$WORK/new" "$WORK/feed"

echo "== New version $NEXT_VERSION ($NEXT_BUILD)"
MEBOKI_APP_DIR="$WORK/new/Meboki.app" MEBOKI_VERSION="$NEXT_VERSION" MEBOKI_BUILD="$NEXT_BUILD" \
  Scripts/make-app.sh ${CONFIG_FLAG[@]+"${CONFIG_FLAG[@]}"}
ditto -c -k --sequesterRsrc --keepParent "$WORK/new/Meboki.app" "$WORK/feed/Meboki-$NEXT_VERSION.zip"
cat > "$WORK/feed/Meboki-$NEXT_VERSION.html" <<HTML
<h2>Meboki $NEXT_VERSION</h2>
<ul><li>A test update, built on this Mac by Scripts/test-update.sh.</li></ul>
HTML
"$TOOLS/generate_appcast" --ed-key-file "$WORK/key" --download-url-prefix "http://127.0.0.1:$PORT/" \
  --embed-release-notes "$WORK/feed"

echo "== Old version $VERSION ($BUILD)"
MEBOKI_APP_DIR="$WORK/old/Meboki.app" Scripts/make-app.sh ${CONFIG_FLAG[@]+"${CONFIG_FLAG[@]}"}

if [ "$INSTALL" = 1 ]; then
  DEST="$HOME/Applications/Meboki.app"
  mkdir -p "$HOME/Applications"
  pkill -x Meboki 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  cp -R "$WORK/old/Meboki.app" "$DEST"
  echo "Installed $DEST ($VERSION, updater on)"
fi

echo "== Serving $FEED (Ctrl-C to stop)"
[ "$INSTALL" = 0 ] || open "$HOME/Applications/Meboki.app"
exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/feed"
