#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
//  MacMonitor MCP server
//
//  Lets an AI agent install, check, and remove MacMonitor (menu-bar system
//  monitor + desktop widget for Apple Silicon) directly from the latest
//  GitHub release — download, mount, install, quarantine-clear, launch, and
//  cleanup happen in one tool call. No DMG is left behind.
//
//  Client config (e.g. Claude / Cline / Cursor):
//    { "mcpServers": { "macmonitor": {
//        "command": "npx", "args": ["-y", "github:MAKaminski/MacMonitor"] } } }
// ─────────────────────────────────────────────────────────────────────────────

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { execSync } from "node:child_process";

const REPO = "MAKaminski/MacMonitor";
const APP = "/Applications/Macmonitor.app";

function sh(script, timeoutMs = 300_000) {
  try {
    const out = execSync(script, {
      shell: "/bin/bash",
      encoding: "utf8",
      timeout: timeoutMs,
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { ok: true, out: (out || "").trim() };
  } catch (e) {
    const out = [e.stdout, e.stderr, e.message].filter(Boolean).join("\n");
    return { ok: false, out: out.trim() };
  }
}

const text = (s) => ({ content: [{ type: "text", text: s }] });

const server = new McpServer({ name: "macmonitor", version: "2.1.0" });

server.tool(
  "install_macmonitor",
  "Install (or update) MacMonitor on this Mac from the latest GitHub release: " +
    "downloads the DMG to a temp dir, installs Macmonitor.app to /Applications, " +
    "clears quarantine, launches the app, verifies the desktop widget registered, " +
    "and deletes the temp download. Requires Apple Silicon + macOS 13+.",
  async () => {
    const script = `
set -euo pipefail
[ "$(uname -m)" = "arm64" ] || { echo "ERROR: Apple Silicon required (M1 or later)."; exit 1; }
OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$OS_MAJOR" -ge 13 ] || { echo "ERROR: macOS 13+ required."; exit 1; }
URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep -o '"browser_download_url": *"[^"]*\\.dmg"' | head -1 | cut -d '"' -f4)
[ -n "$URL" ] || { echo "ERROR: no DMG asset on latest release — see https://github.com/${REPO}/releases"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "Downloading: $URL"
curl -fsSL "$URL" -o "$TMP/MacMonitor.dmg"
MNT=$(hdiutil attach "$TMP/MacMonitor.dmg" -nobrowse -noautoopen | awk -F'\\t' '/\\/Volumes\\//{gsub(/^[[:space:]]+/,"",$NF); print $NF}')
[ -n "$MNT" ] || { echo "ERROR: could not mount DMG"; exit 1; }
pkill -x Macmonitor 2>/dev/null || true
rm -rf "${APP}"
cp -R "$MNT/Macmonitor.app" /Applications/
hdiutil detach "$MNT" -quiet
xattr -rd com.apple.quarantine "${APP}" 2>/dev/null || true
open "${APP}"
sleep 2
if pluginkit -mAvp com.apple.widgetkit-extension 2>/dev/null | grep -qi macmonitor; then
  echo "WIDGET: registered"
else
  echo "WIDGET: not registered yet (appears after first launch; 'killall chronod' forces a rescan)"
fi
VER=$(defaults read "${APP}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
echo "INSTALLED: MacMonitor v$VER at ${APP} (temp files cleaned up)"
echo "NEXT: right-click desktop -> Edit Widgets -> MacMonitor -> drag Small/Medium/Large"
`;
    const r = sh(script);
    return text(r.ok ? r.out : `Install failed:\n${r.out}`);
  }
);

server.tool(
  "macmonitor_status",
  "Check MacMonitor on this Mac: installed version, whether the app is running, " +
    "and whether the desktop widget extension is registered with WidgetKit.",
  async () => {
    const script = `
if [ -d "${APP}" ]; then
  VER=$(defaults read "${APP}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
  echo "APP: installed (v$VER) at ${APP}"
else
  echo "APP: not installed"
fi
pgrep -xq Macmonitor && echo "PROCESS: running" || echo "PROCESS: not running"
if pluginkit -mAvp com.apple.widgetkit-extension 2>/dev/null | grep -qi macmonitor; then
  echo "WIDGET: registered"
else
  echo "WIDGET: not registered"
fi
`;
    const r = sh(script, 30_000);
    return text(r.out);
  }
);

server.tool(
  "uninstall_macmonitor",
  "Remove MacMonitor from this Mac: quit the app and delete /Applications/Macmonitor.app. " +
    "Notes anything that needs manual cleanup (the privileged helper, if installed).",
  async () => {
    const script = `
pkill -x Macmonitor 2>/dev/null || true
if [ -d "${APP}" ]; then rm -rf "${APP}"; echo "REMOVED: ${APP}"; else echo "APP: was not installed"; fi
killall chronod 2>/dev/null || true
if [ -e "/Users/Shared/MacMonitor/macmonitor-helper" ]; then
  echo "NOTE: privileged helper remains at /Users/Shared/MacMonitor (remove with: sudo rm -rf /Users/Shared/MacMonitor)"
fi
echo "DONE"
`;
    const r = sh(script, 30_000);
    return text(r.out);
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
