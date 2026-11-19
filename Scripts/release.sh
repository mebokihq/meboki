#!/usr/bin/env bash
# Builds an official, notarized release: Meboki-<version>.dmg plus the Sparkle appcast.xml that announces it.
# Usage: Scripts/release.sh <version> <build> [--notes notes.html] [--publish]
#   <version>    CFBundleShortVersionString, for example 1.0.0
#   <build>      CFBundleVersion, a whole number that grows with every release (Sparkle compares it)
#   --notes      an HTML fragment shown in the update window (default: one line with the version)
#   --publish    tag v<version>, push the tag and create the GitHub release with the DMG and appcast.xml
#
# Needs, on this Mac:
#   - a "Developer ID Application" identity in the login keychain (make-app.sh picks it up)
#   - a notarytool keychain profile (NOTARY_PROFILE, default meboki-notary):
#       xcrun notarytool store-credentials meboki-notary --apple-id <id> --team-id <team>
#   - the update signing key in the login keychain (SPARKLE_ACCOUNT, default meboki), made once with
#       .build/artifacts/sparkle/Sparkle/bin/generate_keys --account meboki
#   - gh, signed in, for --publish
# Output in build/release/<version>/. The app checks FEED_URL, which serves the newest release's appcast.xml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${MEBOKI_REPO:-mebokihq/meboki}"
FEED_URL="${MEBOKI_FEED_URL:-https://meboki.com/api/appcast.xml}"
NOTARY_PROFILE="${NOTARY_PROFILE:-meboki-notary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-meboki}"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

VERSION="${1:-}"; BUILD="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <version x.y.z> <build> [--notes file] [--publish]"; exit 2; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "<build> must be a whole number"; exit 2; }
shift 2
NOTES=""; PUBLISH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    *) echo "Unknown option $1"; exit 2 ;;
  esac
done

cd "$ROOT"
step() { printf '\n== %s\n' "$*"; }

step "Checks"
[ -z "$(git status --porcelain)" ] || { echo "The working tree has changes; commit them first."; exit 1; }
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity in the keychain."; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null || { echo "notarytool profile '$NOTARY_PROFILE' doesn't work."; exit 1; }
[ -x "$SPARKLE_BIN/sign_update" ] || swift package resolve
PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p)"
[ -n "$PUBLIC_KEY" ] || { echo "No update signing key for account '$SPARKLE_ACCOUNT'."; exit 1; }
if [ "$PUBLISH" = 1 ]; then
  gh auth status >/dev/null 2>&1 || { echo "gh isn't signed in."; exit 1; }
  ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "Tag v$VERSION exists."; exit 1; }
fi
echo "Signing as $IDENTITY; update key $PUBLIC_KEY"

OUT="$ROOT/build/release/$VERSION"
APP="$OUT/Meboki.app"
DMG="$OUT/Meboki-$VERSION.dmg"
rm -rf "$OUT"; mkdir -p "$OUT"

step "Build $VERSION ($BUILD)"
SIGN_IDENTITY="$IDENTITY" MEBOKI_FEED_URL="$FEED_URL" MEBOKI_UPDATE_KEY="$PUBLIC_KEY" \
  MEBOKI_VERSION="$VERSION" MEBOKI_BUILD="$BUILD" MEBOKI_APP_DIR="$APP" "$ROOT/Scripts/make-app.sh"

notarize() {  # <file>: submit, wait, fail with Apple's log unless accepted
  local result id status
  result="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
  id="$(printf '%s' "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  status="$(printf '%s' "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
  echo "notarization $id: $status"
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
    exit 1
  fi
}

step "Notarize the app"
ditto -c -k --keepParent "$APP" "$OUT/Meboki-app.zip"
notarize "$OUT/Meboki-app.zip"
rm -f "$OUT/Meboki-app.zip"
xcrun stapler staple "$APP"

step "DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Meboki.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Meboki" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
spctl -a -t exec -v "$APP"

step "Appcast"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")"   # sparkle:edSignature="…" length="…"
URL="https://github.com/$REPO/releases/download/v$VERSION/Meboki-$VERSION.dmg"
if [ -n "$NOTES" ]; then DESCRIPTION="$(cat "$NOTES")"; else DESCRIPTION="<p>Meboki $VERSION</p>"; fi
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Meboki</title>
    <item>
      <title>Meboki $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[$DESCRIPTION]]></description>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF
/usr/bin/python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])' "$OUT/appcast.xml"
shasum -a 256 "$DMG" | tee "$OUT/SHA256.txt"

if [ "$PUBLISH" = 1 ]; then
  step "Publish v$VERSION to $REPO"
  git tag -a "v$VERSION" -m "Meboki $VERSION"
  git push origin "v$VERSION"
  gh release create "v$VERSION" "$DMG" "$OUT/appcast.xml" --repo "$REPO" --title "Meboki $VERSION" \
    --notes "Meboki $VERSION for macOS 14 or later on Apple Silicon. SHA-256: $(cut -d' ' -f1 "$OUT/SHA256.txt")"
fi

step "Done"
ls -l "$OUT"
