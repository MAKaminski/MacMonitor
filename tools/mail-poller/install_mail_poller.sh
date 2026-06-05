#!/bin/bash
# Install the MacMonitor mail badge poller as a per-user LaunchAgent (5-min).
# Confined to MacMonitor — no Claude scheduled task involved.
set -e
SUPPORT="$HOME/Library/Application Support/MacMonitor"
SRC="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HOME/Library/LaunchAgents/de.modularequity.macmonitor.mailpoller.plist"
CFG="$HOME/.config/macmonitor/mail.json"

mkdir -p "$SUPPORT" "$HOME/.config/macmonitor/badges" "$HOME/Library/LaunchAgents"
cp "$SRC/mail-poller.py" "$SUPPORT/mail-poller.py"

# config template (only if absent — never clobber a configured one)
if [ ! -f "$CFG" ]; then
cat > "$CFG" <<JSON
{
  "accounts": [
    {
      "badge": "gmail",
      "host": "imap.gmail.com",
      "email": "mkaminski1337@gmail.com",
      "app_password": "PASTE_GMAIL_APP_PASSWORD_HERE",
      "mailbox": "INBOX",
      "query": "(UNSEEN)"
    }
  ]
}
JSON
  chmod 600 "$CFG"
  echo "Wrote config template: $CFG"
  echo "  → create a Gmail App Password at https://myaccount.google.com/apppasswords"
  echo "  → paste it into app_password, then this poller goes live."
fi

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>de.modularequity.macmonitor.mailpoller</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$SUPPORT/mail-poller.py</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>/tmp/macmonitor-mailpoller.log</string>
</dict></plist>
PLIST

launchctl bootout "gui/$(id -u)/de.modularequity.macmonitor.mailpoller" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "LaunchAgent installed and started (runs every 5 min)."
