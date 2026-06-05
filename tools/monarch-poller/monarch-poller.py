#!/usr/bin/env python3
"""
MacMonitor Monarch poller — hourly LaunchAgent, confined to MacMonitor.

Writes ~/.config/macmonitor/monarch.json (last 6 months: income/expense,
assets/liabilities, net worth) for the MONARCH tab. Auth comes from
~/.config/macmonitor/monarch_token (a Monarch GraphQL token — grab it from
an app.monarchmoney.com session: localStorage persist:root → user.token).
Exits silently until that token exists.
"""
import json, os, sys, datetime, urllib.request

TOK_PATH = os.path.expanduser("~/.config/macmonitor/monarch_token")
OUT_PATH = os.path.expanduser("~/.config/macmonitor/monarch.json")
if not os.path.exists(TOK_PATH):
    sys.exit(0)
TOKEN = open(TOK_PATH).read().strip()

def gql(operation, query, variables=None):
    req = urllib.request.Request(
        "https://api.monarchmoney.com/graphql",
        data=json.dumps({"operationName": operation, "query": query,
                         "variables": variables or {}}).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": f"Token {TOKEN}",
                 "Client-Platform": "web",
                 "User-Agent": "macmonitor-monarch-poller"})
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.loads(r.read().decode())
    if out.get("errors"):
        raise RuntimeError(out["errors"][0].get("message", "graphql error"))
    return out["data"]

today = datetime.date.today()
start = (today.replace(day=1) - datetime.timedelta(days=160)).replace(day=1)  # ~6 months back
months, income, expense, assets, liab, net = [], [], [], [], [], []

try:
    # Cashflow by month (sumIncome / sumExpense aggregates)
    cf = gql("Web_GetCashFlowPage", """
      query Web_GetCashFlowPage($filters: TransactionFilterInput) {
        byMonth: aggregates(filters: $filters, groupBy: ["month"]) {
          groupBy { month __typename }
          summary { sumIncome sumExpense __typename }
          __typename
        }
      }""", {"filters": {"search": "", "categories": [], "accounts": [], "tags": [],
                          "startDate": start.isoformat(), "endDate": today.isoformat()}})
    rows = sorted(cf["byMonth"], key=lambda r: r["groupBy"]["month"])[-6:]
    for r in rows:
        m = r["groupBy"]["month"]                      # "2026-01-01"
        months.append(datetime.date.fromisoformat(m).strftime("%b"))
        income.append(round(float(r["summary"]["sumIncome"]), 2))
        expense.append(round(abs(float(r["summary"]["sumExpense"])), 2))

    # Net worth + assets/liabilities from monthly account-type snapshots
    sn = gql("Common_GetSnapshotsByAccountType", """
      query Common_GetSnapshotsByAccountType($startDate: Date!, $timeframe: Timeframe!) {
        snapshotsByAccountType(startDate: $startDate, timeframe: $timeframe) {
          accountType month balance __typename
        }
        accountTypes { name group __typename }
      }""", {"startDate": start.isoformat(), "timeframe": "month"})
    groups = {t["name"]: t["group"] for t in sn.get("accountTypes", [])}
    bym = {}
    for row in sn["snapshotsByAccountType"]:
        m = row["month"][:7]
        g = groups.get(row["accountType"], "asset")
        bym.setdefault(m, {"asset": 0.0, "liability": 0.0})
        bym[m][g if g in ("asset", "liability") else "asset"] += float(row["balance"])
    keys = sorted(bym)[-6:]
    assets = [round(bym[k]["asset"], 2) for k in keys]
    liab = [round(abs(bym[k]["liability"]), 2) for k in keys]
    net = [round(a - l, 2) for a, l in zip(assets, liab)]
    if not months:                                     # cashflow failed but snapshots worked
        months = [datetime.date.fromisoformat(k + "-01").strftime("%b") for k in keys]
except Exception as e:
    sys.stderr.write(f"monarch poller: {e}\n")
    sys.exit(1)

json.dump({"updated": datetime.datetime.now().timestamp(), "months": months,
           "income": income, "expense": expense,
           "assets": assets, "liabilities": liab, "netWorth": net},
          open(OUT_PATH, "w"), indent=1)
print("monarch.json written:", months)
