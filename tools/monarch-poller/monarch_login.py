#!/usr/bin/env python3
"""Monarch token login using browser-style headers (the bot UA 404s).

Password (and OTP if MFA) come from 1Password at runtime; the resulting
long-lived token is written to ~/.config/macmonitor/monarch_token so the
hourly poller can run headless without Chrome or Keychain.
"""
import json, os, subprocess, sys, urllib.request, urllib.error

OP_ITEM = "va7se5fi4o5j3qosfwvmzkrinm"
DEVICE_UUID = "cb20fa2b-49f6-4ceb-bfd1-d4f7db195915"     # from the Chrome session
TOKEN_OUT = os.path.expanduser("~/.config/macmonitor/monarch_token")
LOGIN = "https://api.monarch.com/auth/login/"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")


def op(*args):
    r = subprocess.run(["op", "item", "get", OP_ITEM, *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def post(body):
    req = urllib.request.Request(LOGIN, data=json.dumps(body).encode(), headers={
        "Content-Type": "application/json", "Accept": "application/json",
        "User-Agent": UA, "Origin": "https://app.monarch.com",
        "Referer": "https://app.monarch.com/", "device-uuid": DEVICE_UUID,
        "Client-Platform": "web"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode() or "{}")


def main():
    email, password = op("--fields", "label=username"), op("--fields", "label=password", "--reveal")
    if not email or not password:
        print("FAIL: no creds from 1Password"); return 1
    body = {"username": email, "password": password, "trusted_device": True, "supports_mfa": True}
    st, data = post(body)
    if st in (401, 403) or (data.get("error_code") in ("MFA_REQUIRED",)) or "totp" in str(data).lower():
        otp = op("--otp")
        if not otp:
            print(f"FAIL: MFA required (status {st}) but no OTP on the 1Password item"); return 2
        body["totp"] = otp
        st, data = post(body)
    tok = data.get("token")
    if st == 200 and tok:
        os.makedirs(os.path.dirname(TOKEN_OUT), exist_ok=True)
        with open(TOKEN_OUT, "w") as f:
            f.write(tok)
        os.chmod(TOKEN_OUT, 0o600)
        print("TOKEN_SAVED len", len(tok))
        return 0
    print(f"FAIL: status={st} body={str(data)[:200]}")
    return 3


if __name__ == "__main__":
    sys.exit(main())
