#!/usr/bin/env bash
#
# make-icons.sh
#
# Regenerates every asset-catalog PNG from the editable master images:
#   Icon/master-1024.png     — the 1024x1024 app-icon master
#   Icon/menubar-plain.png   — the monochrome menubar template glyph (optional,
#                              see the note on the plain hook below)
#   Icon/menubar-<slug>.png  — one per badged source (Spotify, Safari, …)
#
# It resizes them with `sips` into:
#   Sources/Beamhook/Assets.xcassets/AppIcon.appiconset/          (full macOS icon set)
#   Sources/Beamhook/Assets.xcassets/MenuBarIcon.imageset/        (18pt template @1x/@2x)
#   Sources/Beamhook/Assets.xcassets/MenuBarIcon-<Name>.imageset/ (ditto, per source)
#
# After running this, run `xcodegen generate` so Xcode picks up any new files.
#
set -euo pipefail

# Resolve directories relative to this script so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_MASTER="$SCRIPT_DIR/master-1024.png"
# The plain hook is deliberately NOT derived from menubar-master.png: that file
# has an opaque off-white background, and a menubar template keeps only the alpha
# channel — regenerating from it would turn the hook into a solid black tile.
MENU_MASTER="$SCRIPT_DIR/menubar-plain.png"

ASSETS_DIR="$REPO_ROOT/Sources/Beamhook/Assets.xcassets"
APPICON_DIR="$ASSETS_DIR/AppIcon.appiconset"
MENUBAR_DIR="$ASSETS_DIR/MenuBarIcon.imageset"

# Badged menubar glyphs: (source-slug  asset-catalog-name) pairs. The asset names
# are the raw values of MenuBarGlyph in BeamhookKit — keep the two in step.
# menubar-podcasts.png is intentionally absent: Apple Podcasts has no AppleScript
# dictionary, so it cannot be a Beamhook target.
menubar_targets=(
  "safari:MenuBarIcon-Safari"
  "chrome:MenuBarIcon-Chrome"
  "youtube:MenuBarIcon-YouTube"
  "spotify:MenuBarIcon-Spotify"
  "applemusic:MenuBarIcon-AppleMusic"
)

if [[ ! -f "$APP_MASTER" ]]; then
  echo "error: missing master image: $APP_MASTER" >&2
  exit 1
fi

for entry in "${menubar_targets[@]}"; do
  slug="${entry%%:*}"
  if [[ ! -f "$SCRIPT_DIR/menubar-$slug.png" ]]; then
    echo "error: missing master image: $SCRIPT_DIR/menubar-$slug.png" >&2
    exit 1
  fi
done

mkdir -p "$APPICON_DIR" "$MENUBAR_DIR"

# Every menubar imageset is an 18pt template; only the pixels differ.
write_imageset_contents() {
  cat > "$1/Contents.json" <<'JSON'
{
  "images" : [
    {
      "idiom" : "universal",
      "scale" : "1x",
      "filename" : "menubar.png"
    },
    {
      "idiom" : "universal",
      "scale" : "2x",
      "filename" : "menubar@2x.png"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}
JSON
}

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
echo "Generating menubar icons -> $ASSETS_DIR"

if [[ -f "$MENU_MASTER" ]]; then
  sips -z 18 18 "$MENU_MASTER" --out "$MENUBAR_DIR/menubar.png" >/dev/null
  sips -z 36 36 "$MENU_MASTER" --out "$MENUBAR_DIR/menubar@2x.png" >/dev/null
  write_imageset_contents "$MENUBAR_DIR"
  echo "  MenuBarIcon (18x18, 36x36)"
else
  echo "  MenuBarIcon: skipped — no $MENU_MASTER, keeping the committed asset."
fi

for entry in "${menubar_targets[@]}"; do
  slug="${entry%%:*}"
  name="${entry##*:}"
  dir="$ASSETS_DIR/$name.imageset"
  mkdir -p "$dir"
  sips -z 18 18 "$SCRIPT_DIR/menubar-$slug.png" --out "$dir/menubar.png" >/dev/null
  sips -z 36 36 "$SCRIPT_DIR/menubar-$slug.png" --out "$dir/menubar@2x.png" >/dev/null
  write_imageset_contents "$dir"
  echo "  $name (18x18, 36x36)"
done

echo "Done."
