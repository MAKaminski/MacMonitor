#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  MacMonitor (Kaminski fork) — One-line Installer
#  Usage: curl -fsSL https://raw.githubusercontent.com/MAKaminski/MacMonitor/main/install.sh | bash
#
#  Downloads the latest release DMG, installs to /Applications, clears
#  quarantine, launches the app, verifies the widget registered, and cleans
#  up after itself — nothing left to delete.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO="MAKaminski/MacMonitor"
APP_NAME="Macmonitor"
INSTALL_DIR="/Applications"

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m'
D='\033[2m' NC='\033[0m' BOLD='\033[1m'
step() { echo -e "  ${B}→${NC}  $1"; }
ok()   { echo -e "  ${G}✓${NC}  $1"; }
warn() { echo -e "  ${Y}!${NC}  $1"; }
fail() { echo -e "  ${R}✗${NC}  $1"; echo ""; exit 1; }

echo ""
echo -e "${BOLD}${B}  MacMonitor Installer (MAKaminski fork)${NC}"
echo -e "${D}  ──────────────────────────────────────────${NC}"
echo ""

# ── 1. System checks ──────────────────────────────────────────────────────────
step "Checking system..."
[[ "$(uname -m)" == "arm64" ]] || fail "Apple Silicon required (M1 or later). Intel Macs are not supported."
OS_VER=$(sw_vers -productVersion)
OS_MAJOR=$(echo "$OS_VER" | cut -d. -f1)
(( OS_MAJOR >= 13 )) || fail "macOS 13 Ventura or later required (you have $OS_VER)."
(( OS_MAJOR >= 14 )) || warn "Desktop widget placement needs macOS 14+; on 13 the widget lives in Notification Center."
ok "Apple Silicon · macOS $OS_VER"

# ── 2. Resolve latest release DMG ─────────────────────────────────────────────
step "Finding latest release..."
DMG_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | cut -d'"' -f4)
[[ -n "$DMG_URL" ]] || fail "No DMG asset found. Check https://github.com/$REPO/releases"
ok "Found: ${DMG_URL##*/}"

# ── 3. Download ───────────────────────────────────────────────────────────────
step "Downloading..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
DMG_PATH="$TMP_DIR/MacMonitor.dmg"
curl -fsSL --progress-bar "$DMG_URL" -o "$DMG_PATH" || fail "Download failed."
ok "Downloaded"

# ── 4. Install ────────────────────────────────────────────────────────────────
step "Installing $APP_NAME.app to $INSTALL_DIR..."
MOUNT_POINT=$(hdiutil attach "$DMG_PATH" -nobrowse -noautoopen \
  | awk -F'\t' '/\/Volumes\//{gsub(/^[[:space:]]+/,"",$NF); print $NF}')
[[ -n "$MOUNT_POINT" ]] || fail "Could not mount DMG."

pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "${INSTALL_DIR:?}/$APP_NAME.app"
cp -R "$MOUNT_POINT/$APP_NAME.app" "$INSTALL_DIR/"
hdiutil detach "$MOUNT_POINT" -quiet
xattr -rd com.apple.quarantine "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true
ok "Installed (quarantine cleared — no Gatekeeper dance needed)"

# ── 5. Launch + verify widget ─────────────────────────────────────────────────
step "Launching..."
open "$INSTALL_DIR/$APP_NAME.app"
sleep 2
if pluginkit -mAvp com.apple.widgetkit-extension 2>/dev/null | grep -qi macmonitor; then
    ok "Widget extension registered"
else
    warn "Widget not registered yet — it appears after first launch; run 'killall chronod' if it lags."
fi

echo ""
echo -e "  ${G}${BOLD}All done!${NC}  MacMonitor is in your menu bar."
echo ""
echo -e "  ${D}Add the desktop widget: right-click desktop → Edit Widgets → MacMonitor${NC}"
echo -e "  ${D}Launch at login: System Settings → General → Login Items → add MacMonitor${NC}"
echo ""
