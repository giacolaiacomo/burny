#!/bin/zsh
# Stop AI Usage Bar and remove the app, the login agent and its cache.
LABEL=com.aiusagebar
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/AI Usage Bar.app" "$HOME/Library/Caches/ai-usage-bar"
defaults delete "$LABEL" 2>/dev/null || true
echo "AI Usage Bar rimosso."
