#!/bin/zsh
# Build Burny.app into ~/Applications and start it at login (LaunchAgent).
set -e
cd "$(dirname "$0")"

APP="$HOME/Applications/Burny.app"
LABEL=com.burny.menubar
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
echo "→ Building…"
./scripts/build-app.sh "$APP"

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Burny</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 1
launchctl enable "gui/$(id -u)/$LABEL"   # in case "Open at login" was switched off
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "✓ Burny installed in ~/Applications and running — look at your menu bar."
