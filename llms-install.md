# MacMonitor — Agent Install Guide (llms-install.md)

Instructions for AI agents (Claude, Cline, Cursor, etc.) installing **MacMonitor** —
a menu-bar system monitor + desktop widget for Apple Silicon Macs — from this repo:
`https://github.com/MAKaminski/MacMonitor`.

## Requirements (check before installing)

- Apple Silicon Mac (`uname -m` → `arm64`). Intel is not supported.
- macOS 13+. Desktop widget placement needs macOS 14+ (on 13 it's Notification Center only).

## Path 1 — MCP server (preferred for agents)

This repo ships an MCP server. Add to the client's MCP config:

```json
{
  "mcpServers": {
    "macmonitor": {
      "command": "npx",
      "args": ["-y", "github:MAKaminski/MacMonitor"]
    }
  }
}
```

Tools exposed:

| Tool | What it does |
|---|---|
| `install_macmonitor` | Downloads the latest release DMG, installs to /Applications, clears quarantine, launches, verifies the widget registered, deletes the temp download. Idempotent — also serves as "update". |
| `macmonitor_status` | Installed version · app running? · widget registered with WidgetKit? |
| `uninstall_macmonitor` | Quits and removes the app; reports any manual cleanup. |

No DMG handling, no leftover files, no Gatekeeper dialog (quarantine is cleared during install).

## Path 2 — One-line shell install

If the agent has shell access but no MCP support:

```
curl -fsSL https://raw.githubusercontent.com/MAKaminski/MacMonitor/main/install.sh | bash
```

Same behavior as the MCP install tool. Cleans up after itself.

## Path 3 — Manual (human fallback)

1. Download `MacMonitor-<version>.dmg` from [Releases](https://github.com/MAKaminski/MacMonitor/releases).
2. Open the DMG → drag **Macmonitor** to **Applications** → double-click **Install.command** (clears quarantine).
3. Launch Macmonitor from Applications.

## Post-install verification

```
pluginkit -mAvp com.apple.widgetkit-extension | grep -i macmonitor   # widget registered?
pgrep -x Macmonitor                                                   # app running?
```

To place the widget: right-click desktop → **Edit Widgets** → **MacMonitor** → drag
Small / Medium / Large. If the widget doesn't appear in the gallery: `killall chronod`,
then reopen Edit Widgets.

## Notes for agents

- The app is ad-hoc signed (not notarized). The install paths above clear quarantine, so
  users never see the Gatekeeper "Move to Trash" dialog.
- First app launch asks for admin approval **once** to install the privileged helper
  (powers GPU/temps/power in the menu-bar dashboard). The desktop widget does NOT need
  the helper — it samples CPU/MEM/network/battery in-process.
- Widget refresh is ~5 s (WidgetKit platform ceiling). The menu-bar dashboard streams
  kernel metrics at 0.5 s.
- Uninstall: quit app, `rm -rf /Applications/Macmonitor.app`, and optionally
  `sudo rm -rf /Users/Shared/MacMonitor` (helper) + `sudo rm -f /etc/sudoers.d/macmonitor-helper`.
