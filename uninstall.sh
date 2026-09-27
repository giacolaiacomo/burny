#!/bin/zsh
# Stop Headroom and remove the app, its login agent, settings and cache.
LABEL=com.headroom.menubar
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Headroom.app" "$HOME/Library/Caches/Headroom"
defaults delete "$LABEL" 2>/dev/null || true
echo "✓ Headroom removed."
