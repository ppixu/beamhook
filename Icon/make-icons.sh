#!/usr/bin/env bash
#
# make-icons.sh
#
# Regenerates every asset-catalog PNG from the two editable master images:
#   Icon/master-1024.png    — the 1024x1024 app-icon master
#   Icon/menubar-master.png — the monochrome menubar template glyph
#
# It resizes them with `sips` into:
#   Sources/Beamhook/Assets.xcassets/AppIcon.appiconset/    (full macOS icon set)
#   Sources/Beamhook/Assets.xcassets/MenuBarIcon.imageset/  (18pt template @1x/@2x)
#
# After running this, run `xcodegen generate` so Xcode picks up any new files.
#
set -euo pipefail

# Resolve directories relative to this script so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_MASTER="$SCRIPT_DIR/master-1024.png"
MENU_MASTER="$SCRIPT_DIR/menubar-master.png"

APPICON_DIR="$REPO_ROOT/Sources/Beamhook/Assets.xcassets/AppIcon.appiconset"
MENUBAR_DIR="$REPO_ROOT/Sources/Beamhook/Assets.xcassets/MenuBarIcon.imageset"

for f in "$APP_MASTER" "$MENU_MASTER"; do
  if [[ ! -f "$f" ]]; then
    echo "error: missing master image: $f" >&2
    exit 1
  fi
done

mkdir -p "$APPICON_DIR" "$MENUBAR_DIR"

# App icon: (pixel-dimension  output-filename) pairs for every (size, scale).
#   16x16   @1x ->  16    @2x ->  32
#   32x32   @1x ->  32    @2x ->  64
#   128x128 @1x -> 128    @2x -> 256
#   256x256 @1x -> 256    @2x -> 512
#   512x512 @1x -> 512    @2x -> 1024
app_targets=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

echo "Generating app icons -> $APPICON_DIR"
for entry in "${app_targets[@]}"; do
  px="${entry%%:*}"
  name="${entry##*:}"
  sips -z "$px" "$px" "$APP_MASTER" --out "$APPICON_DIR/$name" >/dev/null
  echo "  $name (${px}x${px})"
done

# Menubar: 18pt template @1x (18px) and @2x (36px).
echo "Generating menubar icons -> $MENUBAR_DIR"
sips -z 18 18 "$MENU_MASTER" --out "$MENUBAR_DIR/menubar.png" >/dev/null
echo "  menubar.png (18x18)"
sips -z 36 36 "$MENU_MASTER" --out "$MENUBAR_DIR/menubar@2x.png" >/dev/null
echo "  menubar@2x.png (36x36)"

echo "Done."
