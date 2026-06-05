#!/bin/bash
# Install the MacMonitor Monarch poller as a per-user LaunchAgent (hourly).
set -e
SUPPORT="$HOME/Library/Application Support/MacMonitor"
SRC="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HOME/Library/LaunchAgents/de.modularequity.macmonitor.monarchpoller.plist"

mkdir -p "$SUPPORT" "$HOME/.config/macmonitor" "$HOME/Library/LaunchAgents"
cp "$SRC/monarch-poller.py" "$SUPPORT/monarch-poller.py"

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>de.modularequity.macmonitor.monarchpoller</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$SUPPORT/monarch-poller.py</string>
  </array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>/tmp/macmonitor-monarchpoller.log</string>
</dict></plist>
PLIST

launchctl bootout "gui/$(id -u)/de.modularequity.macmonitor.monarchpoller" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Monarch poller LaunchAgent installed (hourly)."
if [ ! -f "$HOME/.config/macmonitor/monarch_token" ]; then
  echo "  → paste a Monarch GraphQL token into ~/.config/macmonitor/monarch_token to go live."
fi
