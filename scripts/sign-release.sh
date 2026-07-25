#!/usr/bin/env bash
#
# Package a notarized Beamhook.app for Sparkle distribution:
# zips it, signs the zip with the Sparkle EdDSA key from the login keychain,
# and prints the appcast <item> to paste into docs/appcast.xml.
#
#   ./scripts/sign-release.sh path/to/Beamhook.app
#
# UPDATE_BASE_URL sets where the zip will be hosted (no trailing slash).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: sign-release.sh path/to/Beamhook.app}"
BASE_URL="${UPDATE_BASE_URL:-https://updates.beamhook.app}"

SIGN_UPDATE=$(ls ~/Library/Developer/Xcode/DerivedData/Beamhook-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update 2>/dev/null | head -1)
[ -n "$SIGN_UPDATE" ] || { echo "error: Sparkle's sign_update not found — build the app once so SPM fetches Sparkle" >&2; exit 1; }

VERSION=$(defaults read "$(cd "$APP" && pwd)/Contents/Info" CFBundleShortVersionString)
BUILD=$(defaults read "$(cd "$APP" && pwd)/Contents/Info" CFBundleVersion)
MINOS=$(defaults read "$(cd "$APP" && pwd)/Contents/Info" LSMinimumSystemVersion)
ZIP="Beamhook-$VERSION.zip"

ditto -c -k --keepParent "$APP" "$ZIP"
SIG_AND_LEN=$("$SIGN_UPDATE" "$ZIP" | tr -d '\n')   # sparkle:edSignature="…" length="…"

echo
echo "Created $ZIP — upload it to: $BASE_URL/$ZIP"
echo
echo "Paste into docs/appcast.xml (inside <channel>, newest first):"
echo
cat <<ITEM
    <item>
      <title>Beamhook $VERSION</title>
      <pubDate>$(date -R)</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <link>https://github.com/ppixu/beamhook/releases/tag/v$VERSION</link>
      <enclosure url="$BASE_URL/$ZIP" $SIG_AND_LEN type="application/octet-stream"/>
    </item>
ITEM
