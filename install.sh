#!/usr/bin/env bash
#
# Installs HighFive for the current user:
#   - builds the app
#   - copies it to ~/Applications
#   - installs a LaunchAgent so it starts at login and stays running
#
# After installing you must allow it in
#   System Settings > Privacy & Security > Accessibility
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="HighFive"
BUNDLE_ID="com.ranbam.highfive"
DEST="$HOME/Applications/$APP_NAME.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

"$ROOT/build.sh"

echo "==> Installing to $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$ROOT/build/$APP_NAME.app" "$DEST"

echo "==> Writing LaunchAgent $AGENT"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/Contents/MacOS/$APP_NAME</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/$APP_NAME.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/$APP_NAME.err.log</string>
</dict>
</plist>
PLIST

# start it
launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || launchctl load -w "$AGENT"
# bootstrap can race with the copy above, so make sure it is actually running
launchctl kickstart -k "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true

echo
echo "==> Installed and running."
echo "    No permissions needed unless the action is 'shortcut' (Accessibility)."
echo "    Change what it does:  HighFive --action raycast|app|shortcut"
echo "    Logs: ~/Library/Logs/$APP_NAME.log"
