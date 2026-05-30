# Installation & First Launch Guide

This guide walks you through installing MacMonitor and getting past the first-launch security prompt on modern macOS.

If you've ever installed an app that isn't from the App Store and seen a dialog with only **Move to Trash** and **Cancel** buttons, this guide is for you.

---

## Table of Contents

1. [Install](#install)
2. [First Launch — What the Prompt Looks Like](#first-launch--what-the-prompt-looks-like)
3. [Allow MacMonitor in System Settings](#allow-macmonitor-in-system-settings)
4. [Verify MacMonitor Is Running](#verify-macmonitor-is-running)
5. [The Privileged Helper](#the-privileged-helper)
6. [Uninstall](#uninstall)
7. [Troubleshooting](#troubleshooting)

---

## Install

Pick one of three install methods. All three end up at the same place — `/Applications/Macmonitor.app` plus a privileged helper at `/Users/Shared/MacMonitor/macmonitor-helper`.

### Method 1 — Homebrew Cask (recommended)

```bash
brew tap ryyansafar/macmonitor https://github.com/ryyansafar/MacMonitor
brew install --cask macmonitor
```

The Cask handles the quarantine flag and installs the privileged helper automatically. You may be prompted for your Mac password once during the postflight step so the helper can be copied to `/Users/Shared/MacMonitor/`.

### Method 2 — One-line installer

```bash
curl -fsSL https://raw.githubusercontent.com/ryyansafar/MacMonitor/main/install.sh | bash
```

### Method 3 — Manual DMG download

1. Download **MacMonitor-2.0.2.dmg** from the [latest release](https://github.com/ryyansafar/MacMonitor/releases/latest).
2. Double-click the DMG to mount it.
3. Drag **Macmonitor.app** onto the **Applications** folder.
4. Double-click **Install.command** inside the DMG. This clears the quarantine flag and installs the helper. Enter your Mac password when prompted.
5. Eject the DMG.

---

## First Launch — What the Prompt Looks Like

MacMonitor is open source and built without a paid Apple Developer ID, so it is **not notarised**. The first time you (or `Macmonitor.app`'s LaunchAgent on login) try to open it, macOS Gatekeeper steps in.

### On macOS Sequoia (15) and later

On Sequoia and Tahoe, Apple removed the old "right-click → Open" shortcut. The very first launch shows a dialog like this:

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│   "Macmonitor" Not Opened                               │
│                                                         │
│   Apple could not verify "Macmonitor" is free of        │
│   malware that may harm your Mac or compromise your     │
│   privacy.                                              │
│                                                         │
│              [ Move to Trash ]   [ Cancel ]             │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**There is no Open Anyway button in this dialog.** That is intentional — Apple wants you to make the decision in System Settings, not in a popup. Click **Cancel** (do **not** click Move to Trash) and continue with the next section.

### On macOS Sonoma (14) and earlier

On older macOS the dialog has three buttons (Move to Trash / Cancel / Open Anyway-ish). If you see an Open button you can use it directly. If you only see Move to Trash and Cancel, click Cancel and continue with the next section.

---

## Allow MacMonitor in System Settings

After clicking **Cancel**, do this:

1. Open the Apple menu → **System Settings…** (on older macOS this is called **System Preferences**).
2. In the sidebar, click **Privacy & Security**.
3. **Scroll all the way down** in the right-hand pane. Past Location Services, Contacts, Calendar, Files & Folders, Full Disk Access, every other privacy section, FileVault, App Management, Developer Tools, and finally past the **Allow applications downloaded from** row.
4. At the very bottom of Privacy & Security you will see a message:

   ```
   "Macmonitor" was blocked to protect your Mac.
                                                  [ Open Anyway ]
   ```

   It only appears for about an hour after the most recent blocked launch attempt, so do this step right after the Cancel above.

5. Click **Open Anyway**.
6. macOS will prompt for your Touch ID or Mac password to confirm.
7. A second dialog appears: *"macOS cannot verify the developer of 'Macmonitor'. Are you sure you want to open it?"*. Click **Open**.

MacMonitor will launch and its icon will appear in the menu bar. You only have to do this once — after the first approved launch, macOS remembers your decision and never asks again for this version of the app.

> **If you don't see "Open Anyway" at the bottom of Privacy & Security:** the entry expires after a while, and it only appears after you've actually tried to launch the app. Open Finder → Applications, double-click Macmonitor, click Cancel on the Gatekeeper popup, then come back to Privacy & Security — the Open Anyway button will be there.

---

## Verify MacMonitor Is Running

You should see a small temperature reading (e.g. `52°C`) in your menu bar within a few seconds of allowing the app.

Click the menu bar icon to open the popover dashboard. You should see:

- CPU temperature
- GPU temperature
- E-core / P-core / S-core utilisation (S-core only appears on M5 and later)
- Per-core grid (E01, P01, S01, …)
- Fan RPM (or hidden on fanless MacBook Air)
- Memory pressure
- DRAM bandwidth
- Disk I/O
- Network throughput
- Battery health (laptops only)

If the temperature reading is empty or the dashboard shows `--°` instead of numbers, see [Troubleshooting](#troubleshooting) below.

---

## The Privileged Helper

MacMonitor ships with a small companion binary called `macmonitor-helper`. It is a ~75 KB Mach-O executable that reads Apple's private IOReport interface, which requires root privileges to sample CPU/GPU power data and per-cluster frequencies.

Two copies of the helper exist on disk after install:

| Path | Owner | Purpose |
| --- | --- | --- |
| `/Applications/Macmonitor.app/Contents/MacOS/macmonitor-helper` | your user | Bundled with the app. Source binary. |
| `/Users/Shared/MacMonitor/macmonitor-helper` | `root` | Runtime copy with `setuid`-style invocation via `sudo`. The app shells out to this path with passwordless `sudo` so it can read IOReport without prompting you on every sample. |

Both files are byte-identical. The shared copy is owned by root because the Homebrew postflight (or the `Install.command` script) used `sudo cp` to install it.

The helper is compiled from a single source file (`helper/macmonitor-helper.m`) linked against the private `IOReport.framework`. You can audit it in the repo — it has no network access, no file I/O, and no behaviour other than printing a JSON blob of sensor readings to stdout once per invocation.

---

## Uninstall

### Homebrew Cask

```bash
brew uninstall --cask macmonitor
brew untap ryyansafar/macmonitor   # optional, removes the tap
```

This removes the app, the shared helper, and the sudoers rule.

### Manual

```bash
# Quit the app first
osascript -e 'quit app "Macmonitor"'

# Remove the app and helper
sudo rm -rf /Applications/Macmonitor.app
sudo rm -rf /Users/Shared/MacMonitor
sudo rm -f /etc/sudoers.d/macmonitor-helper

# Remove preferences and caches
rm -f ~/Library/Preferences/rybo.Macmonitor.plist
rm -rf ~/Library/Application\ Support/Macmonitor
rm -rf ~/Library/Caches/rybo.Macmonitor
```

---

## Troubleshooting

### Brew install fails with `cp: ...macmonitor-helper: No such file or directory`

You're on an older release (v2.0.1 or earlier) where the helper wasn't bundled in the DMG. Upgrade to v2.0.2+:

```bash
brew untap ryyansafar/macmonitor
brew tap ryyansafar/macmonitor https://github.com/ryyansafar/MacMonitor
brew install --cask macmonitor
```

### Dashboard shows `--°` instead of CPU/GPU temperatures

This means the privileged helper isn't running. Check:

```bash
ls -la /Users/Shared/MacMonitor/macmonitor-helper
sudo /Users/Shared/MacMonitor/macmonitor-helper
```

The second command should print a JSON blob with `cpuTemp`, `gpuTemp`, `pClusterFreqMHz`, etc. If the file doesn't exist, reinstall via Homebrew or run `Install.command` from the DMG again. If it exists but errors, file an issue with the error output.

### "Open Anyway" is missing from Privacy & Security

The button only appears after a blocked launch attempt and disappears after about an hour. Try to open MacMonitor from Applications first, hit Cancel on the Gatekeeper popup, then immediately go back to Privacy & Security and scroll to the very bottom.

### MacMonitor opens but the menu bar icon is invisible

Your menu bar is full. macOS Sonoma+ hides menu bar items when the notch encroaches on them. Quit some other menu bar apps (Bartender, Hidden Bar, etc.) or use [Ice](https://github.com/jordanbaird/Ice) to manage menu bar real estate.

### Launch is blocked again after a macOS update

Major macOS updates sometimes re-quarantine unsigned apps. Re-run the Privacy & Security → Open Anyway flow, or simply reinstall via `brew reinstall --cask macmonitor`.

### I want to launch from Terminal to see debug output

```bash
/Applications/Macmonitor.app/Contents/MacOS/Macmonitor
```

You'll see lines like `[helper] isExecutable=true path=...` and `[metrics] cpuTemp=52.2 …`. Press Ctrl+C to quit.

---

## Still stuck?

Open an issue at [github.com/ryyansafar/MacMonitor/issues](https://github.com/ryyansafar/MacMonitor/issues) with:

- macOS version (`sw_vers -productVersion`)
- Chip name (`sysctl -n machdep.cpu.brand_string`)
- MacMonitor version (`defaults read /Applications/Macmonitor.app/Contents/Info.plist CFBundleShortVersionString`)
- Output of `/Applications/Macmonitor.app/Contents/MacOS/Macmonitor` from Terminal (paste the first ~20 lines)

---

## Support the project

If MacMonitor saved you from buying a paid alternative, consider supporting development:

- Portfolio: [ryyansafar.site](https://ryyansafar.site)
- GitHub: [github.com/ryyansafar](https://github.com/ryyansafar)
- Buy Me a Coffee: [buymeacoffee.com/ryyansafar](https://buymeacoffee.com/ryyansafar)
- PayPal: [paypal.com/paypalme/ryyansafar](https://www.paypal.com/paypalme/ryyansafar)
- Razorpay: [razorpay.me/@ryyansafar](https://razorpay.me/@ryyansafar)
