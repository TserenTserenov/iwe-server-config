#!/usr/bin/env python3
"""Zulip listener: long-polls the event queue and appends every message to a JSONL inbox."""
import base64
import configparser
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

RC = os.path.expanduser("~/.secrets/zuliprc")
INBOX = os.path.expanduser("~/.local/state/zulip/inbox.jsonl")
INBOX_MAX_BYTES = 5 * 1024 * 1024  # rotate to inbox.jsonl.1 (one generation kept)
PILOT_MENTION = "@**Tseren|9**"  # Zulip user id 9; a plain "@**Tseren**" mention is matched too
PILOT_MENTION_PLAIN = "@**Tseren**"

cfg = configparser.ConfigParser()
cfg.read(RC)
SITE = cfg["api"]["site"].rstrip("/")
EMAIL = cfg["api"]["email"]
AUTH = "Basic " + base64.b64encode(f"{EMAIL}:{cfg['api']['key']}".encode()).decode()


def call(method, path, params=None, timeout=100):
    data = urllib.parse.urlencode(params or {}).encode() if method == "POST" else None
    url = SITE + path + ("?" + urllib.parse.urlencode(params) if method == "GET" and params else "")
    req = urllib.request.Request(url, data=data, method=method, headers={"Authorization": AUTH, "User-Agent": "iwe-zulip-listener/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return json.load(e)


def register():
    r = call("POST", "/api/v1/register", {
        "event_types": json.dumps(["message"]),
        "all_public_streams": "true",
    })
    if r.get("result") != "success":
        raise RuntimeError(f"register failed: {r}")
    return r["queue_id"], r["last_event_id"]


def store(m, flags):
    rec = {
        "id": m["id"], "ts": m["timestamp"], "type": m["type"],
        "stream": m.get("display_recipient") if m["type"] == "stream" else None,
        "topic": m.get("subject"), "sender": m["sender_full_name"],
        "sender_email": m["sender_email"], "content": m["content"],
        "mentioned": "mentioned" in flags or m["type"] == "private",
        "mentions_pilot": PILOT_MENTION in m["content"] or PILOT_MENTION_PLAIN in m["content"],
    }
    os.makedirs(os.path.dirname(INBOX), exist_ok=True)
    if os.path.exists(INBOX) and os.path.getsize(INBOX) > INBOX_MAX_BYTES:
        os.replace(INBOX, INBOX + ".1")
    with open(INBOX, "a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(f"stored #{rec['id']} {rec['stream']}/{rec['topic']} from {rec['sender']}", flush=True)


def main():
    queue, last = register()
    print(f"queue {queue} registered as {EMAIL}", flush=True)
    while True:
        try:
            r = call("GET", "/api/v1/events", {"queue_id": queue, "last_event_id": last})
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            print(f"poll error: {e}; retry in 10s", file=sys.stderr, flush=True)
            time.sleep(10)
            continue
        if r.get("result") != "success":
            print(f"events error: {r}; re-registering", file=sys.stderr, flush=True)
            time.sleep(5)
            queue, last = register()
            continue
        for ev in r["events"]:
            last = max(last, ev["id"])
            if ev["type"] == "message" and ev["message"]["sender_email"] != EMAIL:
                store(ev["message"], ev.get("flags", []))


if __name__ == "__main__":
    main()
