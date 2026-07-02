#!/usr/bin/env bash
#
# release.sh — build a signed, notarized, distributable Beamhook.dmg
#
# This produces the artifact you upload to Gumroad (or GitHub Releases). Unlike
# run.sh (which signs with a free "Apple Development" cert for local use), a
# *distributable* build must be signed with a "Developer ID Application" cert and
# notarized by Apple, or users get Gatekeeper "unidentified developer" blocks.
#
# ── One-time setup (requires the paid Apple Developer Program, $99/yr) ─────────
#   1. Enroll: https://developer.apple.com/programs/
#   2. In Xcode > Settings > Accounts > Manage Certificates, create a
#      "Developer ID Application" certificate.
#   3. Create an app-specific password at https://account.apple.com (Sign-In &
#      Security > App-Specific Passwords), then store notary credentials once:
#        xcrun notarytool store-credentials "Beamhook-Notary" \
#          --apple-id "you@example.com" --team-id "XXXXXXXXXX" --password "abcd-efgh-ijkl-mnop"
#   4. (Recommended) set a real bundle id before shipping: change
#      PRODUCT_BUNDLE_IDENTIFIER in project.yml from dev.local.Beamhook to e.g.
#      co.yourdomain.beamhook. (Changing it means re-granting Accessibility once.)
#
# Then just:  ./release.sh
#
set -euo pipefail
cd "$(dirname "$0")"

NOTARY_PROFILE="${BEAMHOOK_NOTARY_PROFILE:-Beamhook-Notary}"

command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }

# Find a Developer ID Application identity (paid program only).
DEVID_LINE=$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 || true)
if [ -z "$DEVID_LINE" ]; then
  echo "error: no 'Developer ID Application' certificate found in your keychain." >&2
  echo "       This build is for distribution and needs the paid Apple Developer" >&2
  echo "       Program. See the one-time setup at the top of this script." >&2
  echo "       (For local use on your own Mac, use ./run.sh instead.)" >&2
  exit 1
fi
DEVID=$(echo "$DEVID_LINE" | sed -n 's/^[[:space:]]*[0-9][0-9]*)[[:space:]]*\([0-9A-Fa-f]\{40\}\).*/\1/p')

echo "==> Regenerating project"
xcodegen generate

echo "==> Building Release, signed with Developer ID ($DEVID)"
xcodebuild -project Beamhook.xcodeproj -scheme Beamhook -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVID" PROVISIONING_PROFILE_SPECIFIER="" \
  CODE_SIGN_ENTITLEMENTS=Sources/Beamhook/Beamhook-Release.entitlements \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  clean build

APP="build/Build/Products/Release/Beamhook.app"
DMG="build/Beamhook.dmg"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Authority=Developer ID|TeamIdentifier=' | sed 's/^/    /'

echo "==> Packaging DMG"
rm -f "$DMG"
hdiutil create -volname "Beamhook" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling the notarization ticket"
xcrun stapler staple "$APP"
# Re-pack so the DMG contains the stapled app, then staple the DMG too.
rm -f "$DMG"
hdiutil create -volname "Beamhook" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
xcrun stapler staple "$DMG" || true

echo "==> Gatekeeper assessment (expect: accepted)"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | head -3 || true

echo ""
echo "Done. Upload this file to Gumroad / GitHub Releases:"
echo "    $DMG"
