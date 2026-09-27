#!/bin/zsh
# Build Headroom.app into ~/Applications and start it at login (LaunchAgent).
set -e
cd "$(dirname "$0")"
command -v swiftc >/dev/null || { echo "swiftc not found — run: xcode-select --install"; exit 1; }

APP="$HOME/Applications/Headroom.app"
LABEL=com.headroom.menubar
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

echo "→ Building…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -Osize Sources/main.swift -o "$APP/Contents/MacOS/Headroom"
strip -x "$APP/Contents/MacOS/Headroom"

# App icon, drawn by the app itself
mkdir -p "$BUILD/AppIcon.iconset"
for s in 16 32 128 256 512; do
  "$APP/Contents/MacOS/Headroom" --icon "$BUILD/AppIcon.iconset/icon_${s}x${s}.png" $s
  "$APP/Contents/MacOS/Headroom" --icon "$BUILD/AppIcon.iconset/icon_${s}x${s}@2x.png" $((s * 2))
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleExecutable</key><string>Headroom</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP" 2>/dev/null || true   # ad-hoc signature, local use only

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Headroom</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 1
launchctl enable "gui/$(id -u)/$LABEL"   # in case "Open at login" was switched off
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "✓ Headroom installed in ~/Applications and running — look at your menu bar."
