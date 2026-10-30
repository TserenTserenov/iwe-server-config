#!/usr/bin/env python3
"""Read-only Zulip access for agents: channel/topic history and the listener inbox.

The bot key is read inside this script from ~/.secrets/zuliprc and never printed,
so an agent calls the script instead of opening the secret file.

  zulip_read.py streams
  zulip_read.py history --stream mim-dev [--topic "Библиотека методов"] [--limit 50]
  zulip_read.py inbox [--limit 50]
  zulip_read.py wp 608 [--limit 20]   # topics listed in the WP card's `zulip_topics: ["stream/topic", ...]`
"""
import argparse
import base64
import configparser
import json
import os
import re
import urllib.parse
import urllib.request
from datetime import datetime, timezone

RC = os.path.expanduser("~/.secrets/zuliprc")
INBOX = os.path.expanduser("~/.local/state/zulip/inbox.jsonl")
WP_CARD = os.path.expanduser("~/IWE/DS-my-strategy/inbox/WP-{n}/WP-{n}.md")

cfg = configparser.ConfigParser()
cfg.read(RC)
SITE = cfg["api"]["site"].rstrip("/")
AUTH = "Basic " + base64.b64encode(f"{cfg['api']['email']}:{cfg['api']['key']}".encode()).decode()


def get(path, params=None):
    url = SITE + path + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, headers={"Authorization": AUTH, "User-Agent": "iwe-zulip-read/1.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def fmt(ts, stream, topic, sender, content):
    when = datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    return f"[{when}] {stream}/{topic} — {sender}:\n{content}\n"


def cmd_streams(_):
    for s in get("/api/v1/streams")["streams"]:
        print(s["name"])


def print_topic(stream, topic, limit):
    narrow = [{"operator": "stream", "operand": stream}]
    if topic:
        narrow.append({"operator": "topic", "operand": topic})
    r = get("/api/v1/messages", {
        "anchor": "newest", "num_before": limit, "num_after": 0,
        "narrow": json.dumps(narrow), "apply_markdown": "false",
    })
    if r["result"] != "success":
        raise SystemExit(f"zulip error: {r.get('msg')}")
    for m in r["messages"]:
        print(fmt(m["timestamp"], stream, m["subject"], m["sender_full_name"], m["content"]))


def cmd_history(a):
    print_topic(a.stream, a.topic, a.limit)


def cmd_wp(a):
    with open(WP_CARD.format(n=a.number)) as f:
        line = re.search(r"^zulip_topics:\s*(\[.*\])\s*$", f.read(), re.M)
    if not line:
        raise SystemExit(f"WP-{a.number} card has no zulip_topics field")
    for ref in json.loads(line.group(1)):
        stream, topic = ref.split("/", 1)
        print_topic(stream, topic, a.limit)


def cmd_inbox(a):
    if not os.path.exists(INBOX):
        raise SystemExit("inbox is empty: the listener has stored no messages yet")
    with open(INBOX) as f:
        rows = [json.loads(line) for line in f][-a.limit:]
    for m in rows:
        print(fmt(m["ts"], m["stream"] or "dm", m["topic"], m["sender"], m["content"]))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("streams").set_defaults(fn=cmd_streams)
    h = sub.add_parser("history")
    h.add_argument("--stream", required=True)
    h.add_argument("--topic")
    h.add_argument("--limit", type=int, default=50)
    h.set_defaults(fn=cmd_history)
    w = sub.add_parser("wp")
    w.add_argument("number", type=int)
    w.add_argument("--limit", type=int, default=20)
    w.set_defaults(fn=cmd_wp)
    i = sub.add_parser("inbox")
    i.add_argument("--limit", type=int, default=50)
    i.set_defaults(fn=cmd_inbox)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
