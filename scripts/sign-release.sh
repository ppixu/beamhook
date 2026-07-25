#!/usr/bin/env bash
#
# Package a notarized Beamhook.app for Sparkle distribution. Verifies the app,
# creates the zip, and regenerates docs/appcast.xml with archive and feed
# signatures using Sparkle's tools from this project's pinned DerivedData.
#
#   ./scripts/sign-release.sh path/to/Beamhook.app
#
# UPDATE_BASE_URL sets where the zip will be hosted (no trailing slash).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_INPUT="${1:?usage: sign-release.sh path/to/Beamhook.app}"
BASE_URL="${UPDATE_BASE_URL:-https://updates.beamhook.app}"
DERIVED_DATA="${BEAMHOOK_DERIVED_DATA:-build}"
SPARKLE_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-ed25519}"
SPARKLE_BIN="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"

case "$BASE_URL" in
  https://*) ;;
  *) echo "error: UPDATE_BASE_URL must use HTTPS" >&2; exit 1 ;;
esac

[ -d "$APP_INPUT/Contents" ] || { echo "error: not an app bundle: $APP_INPUT" >&2; exit 1; }
APP="$(cd "$(dirname "$APP_INPUT")" && pwd)/$(basename "$APP_INPUT")"
[ -x "$SIGN_UPDATE" ] || {
  echo "error: $SIGN_UPDATE not found — build the Official configuration first" >&2
  exit 1
}
[ -x "$GENERATE_APPCAST" ] || {
  echo "error: $GENERATE_APPCAST not found — build the Official configuration first" >&2
  exit 1
}

INFO="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")
case "$VERSION" in
  ""|*[!0-9A-Za-z._-]*) echo "error: unsafe app version: $VERSION" >&2; exit 1 ;;
esac
case "$BUILD" in
  ""|*[!0-9]*) echo "error: build number must be numeric: $BUILD" >&2; exit 1 ;;
esac
for required_key in SUFeedURL SUPublicEDKey; do
  /usr/libexec/PlistBuddy -c "Print :$required_key" "$INFO" >/dev/null || {
    echo "error: $required_key is missing; this is not an update-capable build" >&2
    exit 1
  }
done
for required_key in SUVerifyUpdateBeforeExtraction SURequireSignedFeed; do
  [ "$(/usr/libexec/PlistBuddy -c "Print :$required_key" "$INFO")" = "true" ] || {
    echo "error: $required_key must be enabled in an Official build" >&2
    exit 1
  }
done
nm "$APP/Contents/MacOS/Beamhook" 2>/dev/null | grep SPUStandardUpdaterController >/dev/null || {
  echo "error: Sparkle updater code is missing; build the Official configuration" >&2
  exit 1
}

echo "==> Verifying Developer ID signature and notarization ticket"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
xcrun stapler validate "$APP"

ZIP="Beamhook-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/beamhook-appcast.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp docs/appcast.xml "$STAGE/appcast.xml"
cp "$ZIP" "$STAGE/$ZIP"

echo "==> Signing update archive and feed"
"$GENERATE_APPCAST" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "${BASE_URL%/}/" \
  --link "https://github.com/ppixu/beamhook/releases/tag/v$VERSION" \
  --versions "$BUILD" \
  --maximum-versions 0 \
  --maximum-deltas 0 \
  "$STAGE"
"$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$STAGE/appcast.xml"

cp "$STAGE/appcast.xml" docs/appcast.xml

echo
echo "Created $ZIP — upload it to: ${BASE_URL%/}/$ZIP"
echo "Updated and verified signed feed: docs/appcast.xml"
echo "Do not edit the appcast after signing; commit it exactly as generated."
