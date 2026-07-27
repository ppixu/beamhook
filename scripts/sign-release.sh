#!/usr/bin/env bash
#
# Package a notarized Beamhook.app for Sparkle distribution. Verifies the app,
# creates the zip, and regenerates docs/appcast.xml with archive and feed
# signatures using Sparkle's tools from this project's pinned DerivedData.
#
#   ./scripts/sign-release.sh path/to/Beamhook.app
#
# UPDATE_BASE_URL sets where the zip will be hosted (no trailing slash).
# The archive is uploaded to Cloudflare R2 with wrangler (bucket
# BEAMHOOK_R2_BUCKET, default "beamhook-updates" — the bucket behind
# updates.beamhook.app). Without wrangler the script still produces everything
# and just tells you to upload by hand.
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

# Sparkle offers an update by comparing CFBundleVersion. Re-publishing a build
# number that is already in the feed therefore produces a perfectly valid,
# correctly signed release that reaches nobody — the one failure mode this
# pipeline cannot detect after the fact. release.sh checks this too; repeated
# here because this script is the one that actually writes the feed.
if grep -q "<sparkle:version>$BUILD</sparkle:version>" docs/appcast.xml; then
  echo "error: build $BUILD is already published in docs/appcast.xml." >&2
  echo "       No existing user would be offered this update." >&2
  echo "       Bump the version and rebuild:  ./release.sh <next-version>" >&2
  exit 1
fi

echo "==> Verifying Developer ID signature and notarization ticket"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
xcrun stapler validate "$APP"

ZIP_NAME="Beamhook-$VERSION.zip"
ZIP="build/$ZIP_NAME"          # build/ is gitignored: the paid binary stays out of the repo
mkdir -p build
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/beamhook-appcast.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp docs/appcast.xml "$STAGE/appcast.xml"
cp "$ZIP" "$STAGE/$ZIP_NAME"

# generate_appcast embeds <archive-basename>.html from the staging directory as
# the item's release notes. Without it Sparkle's "What's New" panel is blank, so
# render this version's CHANGELOG section into it.
render_release_notes() {
  awk -v ver="$VERSION" '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
    function flush_item() { if (item != "") { print "<li>" esc(item) "</li>"; item = "" } }
    function close_list() { flush_item(); if (in_list) { print "</ul>"; in_list = 0 } }
    $0 ~ "^## \\[" ver "\\]" { in_section = 1; next }
    in_section && /^## / { exit }
    !in_section { next }
    /^### / { close_list(); print "<h3>" esc(substr($0, 5)) "</h3>"; next }
    /^- / { flush_item(); if (!in_list) { print "<ul>"; in_list = 1 } item = substr($0, 3); next }
    /^[[:space:]]+[^[:space:]]/ { if (item != "") { line = $0; sub(/^[[:space:]]+/, "", line); item = item " " line } next }
    /^[[:space:]]*$/ { close_list(); next }
    END { close_list() }
  ' CHANGELOG.md
}
render_release_notes >"$STAGE/Beamhook-$VERSION.html"
[ -s "$STAGE/Beamhook-$VERSION.html" ] || {
  echo "error: CHANGELOG.md has no '## [$VERSION]' section to use as release notes" >&2
  exit 1
}

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

# ── Publish the archive ───────────────────────────────────────────────────────
# The zip has to be reachable BEFORE the feed announcing it is pushed, or every
# client that checks in between is offered an update it cannot download.
UPLOAD_URL="${BASE_URL%/}/$ZIP_NAME"
R2_BUCKET="${BEAMHOOK_R2_BUCKET:-beamhook-updates}"
uploaded=""
if [ -n "$R2_BUCKET" ] && command -v wrangler >/dev/null 2>&1; then
  echo "==> Uploading $ZIP_NAME to R2 bucket '$R2_BUCKET'"
  wrangler r2 object put "$R2_BUCKET/$ZIP_NAME" \
    --file "$ZIP" --content-type application/zip --remote
  uploaded=1
fi

if [ -n "$uploaded" ]; then
  echo "==> Verifying the published archive"
  local_length=$(wc -c <"$ZIP" | tr -d ' ')
  remote_length=$(curl -fsSI "$UPLOAD_URL" \
    | awk 'tolower($1) == "content-length:" { gsub(/\r/, "", $2); print $2 }')
  feed_length=$(grep -o "$ZIP_NAME[^>]*" docs/appcast.xml \
    | grep -oE 'length="[0-9]+"' | grep -oE '[0-9]+' | head -1)
  if [ "$remote_length" != "$local_length" ] || [ "$feed_length" != "$local_length" ]; then
    echo "error: size mismatch — local $local_length, host ${remote_length:-none}, feed ${feed_length:-none}." >&2
    echo "       Sparkle refuses an enclosure whose length disagrees with the download." >&2
    exit 1
  fi
  echo "   $UPLOAD_URL matches the feed ($local_length bytes)"
fi

echo
echo "Created $ZIP"
if [ -n "$uploaded" ]; then
  echo "Published: $UPLOAD_URL"
else
  echo "NOT uploaded — set BEAMHOOK_R2_BUCKET (and install wrangler), or upload by hand to:"
  echo "    $UPLOAD_URL"
fi
echo "Signed feed: docs/appcast.xml — commit exactly as generated; any edit breaks it."
echo
echo "Customers get the update when docs/appcast.xml is pushed. Upload first, push second."
