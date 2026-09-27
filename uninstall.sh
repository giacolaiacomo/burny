#!/bin/zsh
# Stop Burny and remove the app, its login agent, settings and cache.
LABEL=com.burny.menubar
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Burny.app" "$HOME/Library/Caches/Burny"
defaults delete "$LABEL" 2>/dev/null || true
echo "✓ Burny removed."
