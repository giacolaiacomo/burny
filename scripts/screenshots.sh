#!/bin/zsh
# Regenerate the README images (docs/*.png) from the live UI and your real current limits.
set -e
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc -Osize Sources/main.swift -o "$TMP/burny"
"$TMP/burny" --icon "$TMP/icon.png" 512
VALUES=$("$TMP/burny" --snapshot "$TMP/popover-dark.png" dark en)
"$TMP/burny" --snapshot "$TMP/popover-light.png" en
"$TMP/burny" --snapshot "$TMP/settings-dark.png" dark settings en
cp "$TMP/icon.png" docs/icon.png
sips -Z 256 docs/icon.png >/dev/null
swift scripts/compose.swift "$TMP" "$TMP" ${=VALUES}
# JPEG keeps the README light (the PNGs are 1–3 MB each)
sips -s format jpeg -s formatOptions 82 "$TMP/hero.png" --out docs/hero.jpg >/dev/null
sips -s format jpeg -s formatOptions 82 "$TMP/screens.png" --out docs/screens.jpg >/dev/null
# GitHub social preview: 1280x640, must stay under 1 MB
sips -z 640 1280 -s format jpeg -s formatOptions 88 "$TMP/hero.png" --out docs/social-preview.jpg >/dev/null
