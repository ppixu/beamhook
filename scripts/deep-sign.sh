#!/usr/bin/env bash
#
# Deep-sign Beamhook.app for notarization.
#
#   ./scripts/deep-sign.sh path/to/Beamhook.app
#
# Why this exists: Sparkle ships prebuilt helpers nested *inside*
# Sparkle.framework (Autoupdate, Updater.app, and the Downloader/Installer XPC
# services). Xcode does not re-sign content nested in an SPM framework, so those
# keep Sparkle's own signature — and notarization then fails with "not signed
# with a valid Developer ID certificate" plus "does not include a secure
# timestamp" for each one. Code signing seals inside-out, so every nested item
# must be signed before its container, finishing with the app itself.
#
# BEAMHOOK_SIGN_ID overrides the identity (defaults to the Developer ID cert).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: deep-sign.sh path/to/Beamhook.app}"
ENTITLEMENTS="Sources/Beamhook/Beamhook-Release.entitlements"

ID="${BEAMHOOK_SIGN_ID:-$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 \
  | sed -n 's/^[[:space:]]*[0-9][0-9]*)[[:space:]]*\([0-9A-Fa-f]\{40\}\).*/\1/p')}"
[ -n "$ID" ] || { echo "error: no Developer ID Application identity found" >&2; exit 1; }

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"

# Inside-out: nested helpers, then frameworks, then the app.
TARGETS=(
  "$SPARKLE/XPCServices/Downloader.xpc"
  "$SPARKLE/XPCServices/Installer.xpc"
  "$SPARKLE/Updater.app"
  "$SPARKLE/Autoupdate"
  "$APP/Contents/Frameworks/Sparkle.framework"
  "$APP/Contents/Frameworks/BeamhookKit.framework"
)

for t in "${TARGETS[@]}"; do
  [ -e "$t" ] || { echo "  skip (absent): ${t#$APP/}"; continue; }
  # Preserve any entitlements the component already declares, so re-signing
  # Sparkle's helpers cannot silently strip a capability they rely on.
  ents=$(mktemp -t deepsign).plist
  if codesign -d --entitlements - --xml "$t" 2>/dev/null | grep -q "<plist"; then
    codesign -d --entitlements - --xml "$t" 2>/dev/null > "$ents"
    codesign --force --timestamp --options runtime \
      --entitlements "$ents" --sign "$ID" "$t"
  else
    codesign --force --timestamp --options runtime --sign "$ID" "$t"
  fi
  rm -f "$ents"
  echo "  signed: ${t#$APP/}"
done

# The app last, with its release entitlements (apple-events, no get-task-allow).
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" --sign "$ID" "$APP"
echo "  signed: $(basename "$APP")"

echo
echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3
