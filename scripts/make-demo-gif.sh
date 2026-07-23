#!/usr/bin/env bash
#
# Convert a screen recording into the README/landing demo GIF.
#
#   ./scripts/make-demo-gif.sh demo.mov [out.gif] [width]
#
# Record the .mov with ⌘⇧5 → "Record Selected Portion" (a ~1000×700 region
# around the menu bar's right end works well), then run this. Uses ffmpeg's
# two-pass palette so text stays crisp; 12 fps keeps the file small.
#
# Suggested 20–25s choreography (practice once before recording):
#   1. Start with a YouTube tab visible and Spotify open.
#   2. Press play — YouTube starts (the pain).
#   3. Click the Beamhook hook icon, pick Spotify — "Spotify hooked" HUD.
#   4. Press play — Spotify plays, YouTube doesn't move.
#   5. Press next; nudge a volume key to flash the volume HUD.
#   6. (Optional) Open the menu, click Unhook — keys handed back to macOS.
set -euo pipefail

IN="${1:?usage: make-demo-gif.sh recording.mov [out.gif] [width]}"
OUT="${2:-docs/demo.gif}"
WIDTH="${3:-800}"
FPS=12

command -v ffmpeg >/dev/null || { echo "error: ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

PALETTE="$(mktemp -d -t beamhook-palette)/palette.png"
FILTERS="fps=$FPS,scale=$WIDTH:-1:flags=lanczos"

ffmpeg -v warning -i "$IN" -vf "$FILTERS,palettegen=stats_mode=diff" -update 1 -frames:v 1 -y "$PALETTE"
ffmpeg -v warning -i "$IN" -i "$PALETTE" \
  -lavfi "$FILTERS,paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -y "$OUT"
rm -rf "$(dirname "$PALETTE")"

ls -lh "$OUT" | awk '{print $9": "$5}'
echo "If it's over ~4 MB, retry with a smaller width: ./scripts/make-demo-gif.sh $IN $OUT 640"
