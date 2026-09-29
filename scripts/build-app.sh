#!/bin/zsh
# Build Burny.app at the given path (default: ./build/Burny.app). Used by install.sh and the Homebrew formula.
set -e
cd "$(dirname "$0")/.."
command -v swiftc >/dev/null || { echo "swiftc not found — run: xcode-select --install"; exit 1; }

APP="${1:-build/Burny.app}"
VERSION=$(grep -m1 '^let appVersion' Sources/main.swift | cut -d'"' -f2)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -Osize Sources/main.swift -module-cache-path "$WORK/modules" -o "$APP/Contents/MacOS/Burny"
strip -x "$APP/Contents/MacOS/Burny"

# App icon, drawn by the app itself
mkdir -p "$WORK/AppIcon.iconset"
for s in 16 32 128 256 512; do
  "$APP/Contents/MacOS/Burny" --icon "$WORK/AppIcon.iconset/icon_${s}x${s}.png" $s
  "$APP/Contents/MacOS/Burny" --icon "$WORK/AppIcon.iconset/icon_${s}x${s}@2x.png" $((s * 2))
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Burny</string>
  <key>CFBundleIdentifier</key><string>com.burny.menubar</string>
  <key>CFBundleExecutable</key><string>Burny</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP" 2>/dev/null || true   # ad-hoc signature, local use only
