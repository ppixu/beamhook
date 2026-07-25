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

# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO is essential: without it Xcode merges a
# debug-only `com.apple.security.get-task-allow` entitlement into the signature,
# which the Apple notary service rejects ("Archive contains critical validation
# errors"). We only want the entitlements in Beamhook-Release.entitlements.
echo "==> Building Official, signed with Developer ID ($DEVID)"
xcodebuild -project Beamhook.xcodeproj -scheme Beamhook -configuration Official \
  -derivedDataPath build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVID" PROVISIONING_PROFILE_SPECIFIER="" \
  CODE_SIGN_ENTITLEMENTS=Sources/Beamhook/Beamhook-Release.entitlements \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  clean build

APP="build/Build/Products/Official/Beamhook.app"
DMG="build/Beamhook.dmg"

# A normal Xcode Archive + Export re-signs Sparkle's nested helpers for
# distribution. A direct `xcodebuild build` only re-signs Sparkle.framework
# itself, leaving Updater, Autoupdate, and the XPC services ad-hoc signed. The
# notary service rejects those helpers for having neither a Developer ID
# signature nor a secure timestamp, so sign Sparkle explicitly from the inside
# out and then refresh the enclosing app signature.
sign_sparkle_for_distribution() {
  local sparkle="$APP/Contents/Frameworks/Sparkle.framework"
  local current="$sparkle/Versions/Current"
  [ -d "$sparkle" ] || return 0

  echo "==> Signing Sparkle's embedded helpers with Developer ID"
  codesign --force --sign "$DEVID" --timestamp --options runtime \
    "$current/XPCServices/Installer.xpc"
  codesign --force --sign "$DEVID" --timestamp --options runtime \
    --preserve-metadata=entitlements \
    "$current/XPCServices/Downloader.xpc"
  codesign --force --sign "$DEVID" --timestamp --options runtime \
    "$current/Autoupdate"
  codesign --force --sign "$DEVID" --timestamp --options runtime \
    "$current/Updater.app"
  codesign --force --sign "$DEVID" --timestamp --options runtime \
    "$sparkle"

  codesign --force --sign "$DEVID" --timestamp --options runtime \
    --entitlements Sources/Beamhook/Beamhook-Release.entitlements \
    "$APP"
}

# `codesign --verify --deep` checks that nested signatures are structurally
# valid, but accepts ad-hoc signatures and therefore did not catch the Sparkle
# failure locally. Check the properties the notary service actually requires on
# every executable Mach-O before spending time uploading it.
verify_notarization_signatures() {
  local file metadata problems failed=""

  while IFS= read -r -d '' file; do
    file -b "$file" | grep -q 'Mach-O' || continue
    if ! metadata=$(codesign -dv --verbose=4 "$file" 2>&1); then
      echo "error: unsigned or invalid executable: $file" >&2
      failed=1
      continue
    fi

    problems=""
    grep -q '^Authority=Developer ID Application:' <<<"$metadata" ||
      problems="${problems} Developer-ID"
    grep -q '^Timestamp=' <<<"$metadata" ||
      problems="${problems} secure-timestamp"
    grep -q '^Runtime Version=' <<<"$metadata" ||
      problems="${problems} hardened-runtime"

    if [ -n "$problems" ]; then
      echo "error: $file is missing:$problems" >&2
      failed=1
    fi
  done < <(find "$APP" -type f -perm -111 -print0)

  [ -z "$failed" ]
}

sign_sparkle_for_distribution

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Authority=Developer ID|TeamIdentifier=' | sed 's/^/    /'
verify_notarization_signatures

# `notarytool submit --wait` exits successfully even when Apple's final status
# is "Invalid". Submit separately so the job ID is machine-readable, wait with
# visible progress, and explicitly gate the release on the final status. On
# rejection, print Apple's detailed log at the point of failure.
notarize() {
  local artifact="$1" submit_result info_result job_id status
  submit_result=$(mktemp build/notary-submit.XXXXXX)
  info_result=$(mktemp build/notary-info.XXXXXX)

  if ! xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARY_PROFILE" --output-format plist \
      >"$submit_result"; then
    unlink "$submit_result"
    unlink "$info_result"
    return 1
  fi

  job_id=$(plutil -extract id raw -o - "$submit_result")
  unlink "$submit_result"
  echo "   submission id: $job_id"
  xcrun notarytool wait "$job_id" --keychain-profile "$NOTARY_PROFILE"
  xcrun notarytool info "$job_id" --keychain-profile "$NOTARY_PROFILE" \
    --output-format plist >"$info_result"
  status=$(plutil -extract status raw -o - "$info_result")
  unlink "$info_result"

  if [ "$status" != "Accepted" ]; then
    echo "error: notarization finished with status '$status'." >&2
    xcrun notarytool log "$job_id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    return 1
  fi
  echo "   notarization accepted ($job_id)"
}

# ── Styled DMG helpers ────────────────────────────────────────────────────────
# Build a compressed DMG whose Finder window shows an "Install Beamhook" title,
# a "Drag Beamhook to Applications" subtitle, Beamhook.app on the left inside a
# rounded gray well, an /Applications shortcut on the right, and a thin arrow
# between them (ChatGPT-installer style). The layout is stored in the image's
# .DS_Store by driving Finder over Apple events, so the FIRST run prompts once
# for Automation permission (this terminal → Finder) — grant it and re-run.
# All scratch files land under build/ (gitignored).
DMG_BG="build/dmg-background.png"

make_dmg_background() {
  cat > build/dmg-background.swift <<'SWIFT'
import AppKit
// Render at 2x so the background is crisp on Retina (1200x852 px shown in a
// 600x426 pt window). rep.size in points + 2x pixels = 144 dpi in the PNG,
// which is what makes Finder display it at the right scale.
let W: CGFloat = 600, H: CGFloat = 426
let scale: CGFloat = 2
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.current = gctx

// AppKit coordinates are bottom-up; the layout below is specified from the TOP
// (matching the Finder icon positions), so flip through this helper.
func fromTop(_ y: CGFloat) -> CGFloat { H - y }

// Soft off-white background, slightly darker toward the top (like the reference).
let bottomColor = NSColor(calibratedRed: 0.965, green: 0.965, blue: 0.973, alpha: 1)
let topColor    = NSColor(calibratedRed: 0.925, green: 0.925, blue: 0.937, alpha: 1)
NSGradient(starting: bottomColor, ending: topColor)?
  .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

// Title + subtitle, centered.
func drawCentered(_ text: String, centerFromTop: CGFloat, font: NSFont, color: NSColor) {
  let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
  let size = s.size()
  s.draw(at: NSPoint(x: (W - size.width) / 2, y: fromTop(centerFromTop) - size.height / 2))
}
drawCentered("Install Beamhook", centerFromTop: 58,
             font: .systemFont(ofSize: 33, weight: .bold),
             color: NSColor(calibratedWhite: 0.11, alpha: 1))
drawCentered("Drag Beamhook to Applications", centerFromTop: 94,
             font: .systemFont(ofSize: 19),
             color: NSColor(calibratedWhite: 0.52, alpha: 1))

// Icon centers sit 215 pt from the top (must match the osascript positions).
let iconY = fromTop(215)

// Rounded gray well behind the app icon (icon center x = 170).
NSColor(calibratedRed: 0.886, green: 0.886, blue: 0.894, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 170 - 70, y: iconY - 70, width: 140, height: 140),
             xRadius: 28, yRadius: 28).fill()

// Thin arrow with an open head, centered between the icons (x 170 → 430).
NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 262, y: iconY))
arrow.line(to: NSPoint(x: 338, y: iconY))
arrow.move(to: NSPoint(x: 322, y: iconY + 14))
arrow.line(to: NSPoint(x: 338, y: iconY))
arrow.line(to: NSPoint(x: 322, y: iconY - 14))
arrow.stroke()

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) } catch { exit(1) }
SWIFT
  swift build/dmg-background.swift "$DMG_BG"
}

make_dmg() {  # $1 = app bundle, $2 = output .dmg
  local app="$1" out="$2" vol="Beamhook"
  local stage="build/dmg-stage" rw="build/Beamhook-rw.dmg" name
  name="$(basename "$app")"

  rm -rf "$stage"; mkdir -p "$stage/.background"
  ditto "$app" "$stage/$name"                 # ditto preserves the signature + stapled ticket
  ln -s /Applications "$stage/Applications"
  cp "$DMG_BG" "$stage/.background/background.png"

  local size_mb=$(( $(du -sm "$stage" | awk '{print $1}') + 50 ))
  rm -f "$rw"
  hdiutil create -volname "$vol" -srcfolder "$stage" -fs HFS+ \
    -format UDRW -size "${size_mb}m" -ov "$rw" >/dev/null

  # A stale mount with the same volume name (e.g. the previous Beamhook.dmg
  # still open in Finder) would make `tell disk "$vol"` target the WRONG disk.
  while [ -d "/Volumes/$vol" ]; do
    echo "   detaching stale '$vol' volume first…" >&2
    hdiutil detach "/Volumes/$vol" -force >/dev/null 2>&1 || break
    sleep 1
  done

  local dev
  dev=$(hdiutil attach -readwrite -noverify -noautoopen "$rw" | grep -E '^/dev/' | head -1 | awk '{print $1}')

  # Drive Finder to lay out the window. Setting the background picture can
  # transiently fail with error -10006 if the disk isn't fully settled, so retry.
  local laid_out=""
  for attempt in 1 2 3; do
    if osascript <<OSA
tell application "Finder"
  tell disk "$vol"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 546}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set background picture of opts to file ".background:background.png"
    set position of item "$name" of container window to {170, 215}
    set position of item "Applications" of container window to {430, 215}
    -- Park dot-files (visible whenever the user shows hidden files) below the
    -- window so they can't pile up over the title text.
    set dotNames to {".background", ".fseventsd", ".Trashes", ".DS_Store", ".VolumeIcon.icns"}
    repeat with i from 1 to count of dotNames
      try
        set position of item (item i of dotNames) of container window to {100 + (i - 1) * 110, 700}
      end try
    end repeat
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
    then laid_out=1; break; fi
    echo "   Finder layout attempt $attempt failed (transient); retrying…" >&2
    sleep 2
  done
  if [ -z "$laid_out" ]; then
    echo "error: could not apply the DMG window layout via Finder (grant this" >&2
    echo "       terminal Automation access to Finder in System Settings > Privacy)." >&2
    hdiutil detach "$dev" -force >/dev/null 2>&1 || true
    return 1
  fi

  # Finder applies the layout to its in-memory view state and flushes the
  # volume's .DS_Store lazily — detaching before the flush ships a DMG with an
  # EMPTY layout (this happened: the osascript succeeded, yet the converted
  # image had a .DS_Store with no icvp/Iloc records at all). Poll for the
  # actual on-disk records (icvp = icon-view options incl. background picture,
  # Iloc = icon positions) and re-nudge Finder until they land.
  local flushed=""
  for nudge in 1 2 3; do
    for _ in 1 2 3 4 5 6 7 8; do
      if grep -aq icvp "/Volumes/$vol/.DS_Store" 2>/dev/null && \
         grep -aq Iloc "/Volumes/$vol/.DS_Store" 2>/dev/null; then flushed=1; break 2; fi
      sleep 1
    done
    echo "   layout not flushed to .DS_Store yet (nudge $nudge); prodding Finder…" >&2
    osascript -e "tell application \"Finder\" to open disk \"$vol\"" \
              -e "tell application \"Finder\" to update disk \"$vol\" without registering applications" \
              -e 'delay 1' \
              -e "tell application \"Finder\" to close window of disk \"$vol\"" >/dev/null 2>&1 || true
  done
  if [ -z "$flushed" ]; then
    echo "error: Finder never flushed the window layout to the DMG's .DS_Store." >&2
    hdiutil detach "$dev" -force >/dev/null 2>&1 || true
    return 1
  fi

  # Eject through Finder (it flushes pending view state before unmounting),
  # falling back to hdiutil if Finder won't let go.
  sync
  osascript -e "tell application \"Finder\" to eject disk \"$vol\"" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do [ -d "/Volumes/$vol" ] || break; sleep 1; done
  hdiutil detach "$dev" >/dev/null 2>&1 || hdiutil detach "$dev" -force >/dev/null 2>&1 || true

  rm -f "$out"
  hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$out" >/dev/null
  rm -f "$rw"

  # Trust nothing: mount the finished image read-only and prove the layout is
  # really inside, so an unstyled DMG can never ship silently again.
  local mnt="build/dmg-verify" ok=""
  rm -rf "$mnt"; mkdir -p "$mnt"
  hdiutil attach -readonly -nobrowse -mountpoint "$mnt" "$out" >/dev/null
  if grep -aq icvp "$mnt/.DS_Store" 2>/dev/null && grep -aq Iloc "$mnt/.DS_Store" 2>/dev/null \
     && [ -f "$mnt/.background/background.png" ]; then ok=1; fi
  hdiutil detach "$mnt" >/dev/null 2>&1 || hdiutil detach "$mnt" -force >/dev/null 2>&1 || true
  rm -rf "$mnt"
  if [ -z "$ok" ]; then
    echo "error: the styled layout did not persist into $out (.DS_Store lacks its records)." >&2
    return 1
  fi
  echo "   styled layout verified inside $out"
}

# Pass 1 goes through a THROWAWAY staging image (not $DMG) purely to notarize the
# app. Keeping it off $DMG means a later failure (e.g. the Finder layout step)
# can't leave a plain, un-styled Beamhook.dmg lying around masquerading as the
# real one — $DMG is only ever written by the styled make_dmg below.
STAGING_DMG="build/Beamhook-staging.dmg"
echo "==> Packaging staging DMG for notarization"
rm -f "$STAGING_DMG" "$DMG"
hdiutil create -volname "Beamhook" -srcfolder "$APP" -ov -format UDZO "$STAGING_DMG" >/dev/null

echo "==> Notarizing the app (this can take a few minutes)"
notarize "$STAGING_DMG"

echo "==> Stapling the notarization ticket to the app"
xcrun stapler staple "$APP"
rm -f "$STAGING_DMG"

# Re-pack so the DMG contains the *stapled* app. This changes the DMG's hash, so
# it must be notarized again before it can be stapled — you can only staple an
# artifact that was itself submitted. Two submissions is the price of shipping a
# DMG where BOTH the app and the disk image carry offline-verifiable tickets.
echo "==> Repackaging DMG with the stapled app (drag-to-Applications layout)"
make_dmg_background
make_dmg "$APP" "$DMG"

# Code-sign the DMG itself (not just the app inside). Notarization alone makes a
# DMG open cleanly, but signing it gives the disk image its own Developer ID
# signature — so the Gatekeeper assessment below reports the real verdict instead
# of "no usable signature", and the download is signed + notarized + stapled.
echo "==> Signing the DMG with Developer ID"
codesign --force --sign "$DEVID" --timestamp "$DMG"

echo "==> Notarizing the final DMG (this can take a few minutes)"
notarize "$DMG"

echo "==> Stapling the notarization ticket to the DMG"
xcrun stapler staple "$DMG"

echo "==> Verifying the finished DMG (expect: 'validate action worked' + 'accepted')"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | head -3 || true

echo ""
echo "Done. Upload this file to Gumroad / GitHub Releases:"
echo "    $DMG"
