#!/usr/bin/env python3
"""
MacMonitor Monarch poller — hourly LaunchAgent, confined to MacMonitor.

Auth: rides the Chrome cookie session for app.monarch.com (browser_cookie3
decrypts Chrome's cookie store via Keychain; the session refreshes itself
whenever Michael uses Monarch in Chrome — no password, no token file).
Writes ~/.config/macmonitor/monarch.json for the MNRCH tab:
  { updated, months[], income[], expense[], assets[], liabilities[], netWorth[] }
"""
import datetime
import json
import os
import sys

import browser_cookie3
import requests

OUT = os.path.expanduser("~/.config/macmonitor/monarch.json")
API = "https://api.monarch.com/graphql"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")

try:
    jar = browser_cookie3.chrome(domain_name="monarch.com")
except Exception as e:                                     # noqa: BLE001
    sys.stderr.write(f"monarch poller: cookie read failed: {e}\n"); sys.exit(1)

csrf = next((c.value for c in jar if c.name == "csrftoken"), None)
if not csrf:
    sys.stderr.write("monarch poller: no csrftoken — log into app.monarch.com in Chrome\n")
    sys.exit(1)

s = requests.Session()
s.cookies = jar
HDRS = {"Content-Type": "application/json", "X-CSRFToken": csrf,
        "Origin": "https://app.monarch.com", "Referer": "https://app.monarch.com/",
        "User-Agent": UA}


def gql(query, variables=None):
    r = s.post(API, json={"query": query, "variables": variables or {}},
               headers=HDRS, timeout=30)
    out = r.json()
    if r.status_code != 200 or out.get("errors"):
        raise RuntimeError(f"HTTP {r.status_code}: {str(out)[:160]}")
    return out["data"]


today = datetime.date.today()
start = (today.replace(day=1) - datetime.timedelta(days=152)).replace(day=1)   # 6 calendar months

# 1) Cashflow by month
cf = gql("""query($filters: TransactionFilterInput) {
  aggregates(filters:$filters, groupBy:["month"]) {
    groupBy { month } summary { sumIncome sumExpense } } }""",
         {"filters": {"startDate": start.isoformat(), "endDate": today.isoformat()}})
rows = sorted(cf["aggregates"], key=lambda r: r["groupBy"]["month"])[-6:]
months = [datetime.date.fromisoformat(r["groupBy"]["month"]).strftime("%b %y") for r in rows]
income = [round(float(r["summary"]["sumIncome"] or 0), 2) for r in rows]
expense = [round(abs(float(r["summary"]["sumExpense"] or 0)), 2) for r in rows]

# 2) Assets / liabilities / net worth from monthly account-type snapshots
sn = gql("""query($startDate: Date!, $timeframe: Timeframe!) {
  snapshotsByAccountType(startDate:$startDate, timeframe:$timeframe) {
    accountType month balance }
  accountTypes { name group } }""",
         {"startDate": start.isoformat(), "timeframe": "month"})
group = {t["name"]: t["group"] for t in sn.get("accountTypes", [])}
bym = {}
for row in sn["snapshotsByAccountType"]:
    m = row["month"][:7]
    g = group.get(row["accountType"], "asset")
    bym.setdefault(m, {"asset": 0.0, "liability": 0.0})
    bym[m]["liability" if g == "liability" else "asset"] += float(row["balance"] or 0)
mkeys = [datetime.date(int(m[:4]), int(m[5:7]), 1) for m in sorted(bym)]
mkeys = [k for k in mkeys if k >= start][-6:]
assets = [round(bym[k.strftime("%Y-%m")]["asset"], 2) for k in mkeys]
liab = [round(abs(bym[k.strftime("%Y-%m")]["liability"]), 2) for k in mkeys]
net = [round(a - l, 2) for a, l in zip(assets, liab)]
if not months:
    months = [k.strftime("%b %y") for k in mkeys]

payload = {"updated": datetime.datetime.now().timestamp(), "months": months,
           "income": income, "expense": expense,
           "assets": assets, "liabilities": liab, "netWorth": net}
tmp = OUT + ".tmp"
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(tmp, "w") as f:
    json.dump(payload, f, indent=1)
os.replace(tmp, OUT)
print("monarch.json written:", months)
