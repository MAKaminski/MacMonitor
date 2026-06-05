#!/usr/bin/env python3
"""
MacMonitor mail badge poller — confined to MacMonitor, no Claude dependency.

Reads ~/.config/macmonitor/mail.json, counts unread per account over IMAP
(Python's built-in imaplib), and writes ~/.config/macmonitor/badges/<badge>.count
which the MacMonitor HUD renders as a red badge. Run every 5 min by the
de.modularequity.macmonitor.mailpoller LaunchAgent.
"""
import imaplib, json, os, sys, datetime

CFG = os.path.expanduser("~/.config/macmonitor/mail.json")
BADGES = os.path.expanduser("~/.config/macmonitor/badges")
os.makedirs(BADGES, exist_ok=True)

if not os.path.exists(CFG):
    sys.exit(0)                       # no config yet — leave existing counts

try:
    cfg = json.load(open(CFG))
except Exception as e:
    sys.stderr.write(f"bad config: {e}\n"); sys.exit(1)

for acc in cfg.get("accounts", []):
    pw = (acc.get("app_password") or "").strip()
    badge = acc.get("badge")
    if not pw or pw.startswith("PASTE") or not badge:
        continue                       # not configured yet
    try:
        M = imaplib.IMAP4_SSL(acc.get("host", "imap.gmail.com"))
        M.login(acc["email"], pw)
        M.select(acc.get("mailbox", "INBOX"), readonly=True)
        crit = acc.get("query", "(UNSEEN)")
        days = acc.get("since_days")
        if days:
            since = (datetime.date.today() - datetime.timedelta(days=int(days))).strftime("%d-%b-%Y")
            crit = f'(UNSEEN SINCE "{since}")'
        typ, data = M.uid("search", None, crit)
        count = len(data[0].split()) if (data and data[0]) else 0
        with open(os.path.join(BADGES, f"{badge}.count"), "w") as f:
            f.write(str(count))
        M.logout()
    except Exception as e:
        sys.stderr.write(f"{badge}: {e}\n")
