#!/usr/bin/env bash
#
# Stops and removes HighFive for the current user.
#
set -euo pipefail

APP_NAME="HighFive"
BUNDLE_ID="com.ranbam.highfive"
DEST="$HOME/Applications/$APP_NAME.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

echo "==> Stopping agent"
launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true

echo "==> Removing files"
rm -rf "$DEST" "$AGENT"
rm -f  "$HOME/Library/Logs/$APP_NAME.log" \
       "$HOME/Library/Logs/$APP_NAME.out.log" \
       "$HOME/Library/Logs/$APP_NAME.err.log"

echo "==> Removed. (Accessibility entry for HighFive can be deleted in System Settings.)"
