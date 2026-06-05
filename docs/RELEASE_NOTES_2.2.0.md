# MacMonitor 2.2.0

## [2.2.0] — 2026-06-05

### The "Control Center" Release

Six HUD tabs, real iMessage send, contact-name resolution, a per-account Gmail
modal, self-contained mail polling, persisted window position, and liquid-fill
UI throughout. Everything below is new since 2.1.3.

### Added — user-facing

- **iMessage (iMSG) tab now sends.** Hitting Send actually delivers (the
  Automation consent prompt finally surfaces). Opening a conversation jumps
  straight to the newest message, and a **red unread badge** rides the iMSG tab.
- **Contact names.** The iMSG tab resolves phone numbers and emails to your
  Contacts names instead of showing raw `+1…` handles.
- **Per-account launcher modal.** Clicking a launcher button with linked
  accounts (e.g. Gmail) opens a modal listing each account with **its own red
  flag**; the button shows the **sum**, so the cumulative count is traceable.
- **HUD remembers where you put it** — exact position *and* monitor — and
  restores there after an update or reinstall.
- **Liquid animated fills** on every bar and slider; a **battery-shaped volume
  slider** replaces the old Vol−/Vol+ buttons.

### Changed

- **Gmail badge now reflects Inbox-unread** (matches the number Gmail shows),
  not all-mail-including-archived. Fixed a case that showed `12`/`99+` when the
  real inbox-unread was `2`.
- **iMSG unread badge counts only the last 30 days** of incoming unread — the
  Mac's Messages DB hoards hundreds of ancient `is_read=0` rows that would
  otherwise read `99+`.
- **Badge polling is fully self-contained.** Removed the external Claude
  scheduled task; a bundled LaunchAgent (`de.modularequity.macmonitor.mailpoller`)
  now polls IMAP every 5 minutes.

### Fixed

- Header drag was sticky / jumped — now tracks the cursor 1:1 via absolute
  screen coordinates.
- HUD defaulted to locked with no visible unlock; now defaults unlocked with a
  lock/unlock switch in the header.

### Developer notes — where things live

**`MessagesTab.swift`**
- `MessagesStore.send(_:)` routes the AppleScript through a child
  `/usr/bin/osascript` `Process` so an agent (LSUIElement) app can surface the
  "control Messages" Automation prompt.
- `ContactsResolver` (CNContactStore) builds `phone[last10]→name` and
  `email→name` maps. It flips `NSApp.setActivationPolicy(.regular)` +
  `activate` for the **first** Contacts TCC prompt (agent apps can't prompt
  otherwise), then reverts to `.accessory` in the completion handler.
- `queryUnread(_:)` → `SELECT COUNT(*) … is_from_me=0 AND is_read=0 AND
  (date/1000000000 + 978307200) > strftime('%s','now','-30 days')`
  (Apple-epoch nanosecond conversion) → `@Published unreadCount`.
- `queryConversations(_:)` now selects `display_name` and `chat_identifier`
  separately and resolves the name in Swift via `ContactsResolver`.

**`AppDelegate.swift`**
- `showHUD()` restores `hudFrameSaved-<style>` (`NSStringFromRect`) **before**
  AppKit autosave / device defaults; the header drag `.onEnded` writes the
  frame to UserDefaults, so position survives reinstalls.
- `LauncherAccount` model + `AccountPopover` view; `BadgeStore.total(for:)`
  sums per-account badges; `HUDTabButton` gained a red `badge` overlay wired to
  `MessagesStore.unreadCount`.

**Build / packaging**
- New `INFOPLIST_KEY_NSContactsUsageDescription` (both build configs).
- `mail-poller.py` (stdlib `imaplib`, `INBOX` `UNSEEN`) + `install_mail_poller.sh`
  installs the LaunchAgent and a `~/.config/macmonitor/mail.json` template.

### Data structures (reference)

| Thing | Shape / location |
|---|---|
| Launcher config | `LauncherItem { name, url, badge?, accounts:[LauncherAccount{ name, url, badge? }] }` → UserDefaults `rybo.Macmonitor → hudLaunchers` (JSON) |
| Badge counts | `~/.config/macmonitor/badges/<kind>.count` (plain integer) |
| Mail poller config | `~/.config/macmonitor/mail.json` → `{ accounts:[{ badge, host, email, app_password, mailbox, query }] }` |
| HUD position | UserDefaults `hudFrameSaved-full` / `hudFrameSaved-compact` (`NSStringFromRect`) |
| Messages source | `~/Library/Messages/chat.db` → `chat`, `message`, `chat_message_join` |

