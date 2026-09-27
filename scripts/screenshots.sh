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
swift scripts/compose.swift "$TMP" docs ${=VALUES}
