#!/bin/zsh
# Regenerate the README images and animation (docs/) from the real UI, filled with made-up demo data
# so that no real project names or numbers end up in them.
set -e
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc -Osize Sources/main.swift -o "$TMP/burny"
"$TMP/burny" --icon "$TMP/icon.png" 512
VALUES=$("$TMP/burny" --snapshot "$TMP/popover-dark.png" dark en demo)
"$TMP/burny" --snapshot "$TMP/popover-light.png" en demo >/dev/null
"$TMP/burny" --snapshot "$TMP/settings-dark.png" dark settings en demo >/dev/null
"$TMP/burny" --snapshot "$TMP/breakdown-dark.png" dark breakdown en demo >/dev/null
cp "$TMP/icon.png" docs/icon.png
sips -Z 256 docs/icon.png >/dev/null
swift scripts/compose.swift "$TMP" "$TMP" ${=VALUES}
# JPEG keeps the README light (the PNGs are 1–3 MB each)
sips -s format jpeg -s formatOptions 82 "$TMP/hero.png" --out docs/hero.jpg >/dev/null
sips -s format jpeg -s formatOptions 82 "$TMP/screens.png" --out docs/screens.jpg >/dev/null
# GitHub social preview: 1280x640, must stay under 1 MB
sips -z 640 1280 -s format jpeg -s formatOptions 88 "$TMP/hero.png" --out docs/social-preview.jpg >/dev/null
# Animation: GIF for the README (one shared palette), MP4 for social posts
ffmpeg -loglevel error -y -framerate 10 -i "$TMP/frames/f%04d.png" -vf "scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" docs/demo.gif
ffmpeg -loglevel error -y -framerate 10 -i "$TMP/frames/f%04d.png" -vf "fps=30,format=yuv420p" -c:v libx264 -crf 20 -movflags +faststart docs/demo.mp4
ls -lh docs
