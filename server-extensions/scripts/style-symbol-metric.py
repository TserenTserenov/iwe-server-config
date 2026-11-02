#!/usr/bin/env python3
"""Weekly metric for rule A13.1 on pilot-visible Claude replies (РП-388 Ф36 шаг 4).

Per day: replies, items, share of items with an unexplained code name, backtick
spans split into addresses / code names / other, quoted spans, links. Two
grains: every visible text block of a human turn, and the last block only.
The classifier is the one the style hook uses (.claude/hooks/a13_1_symbols.py).

    style-symbol-metric.py --since 2026-10-24 --until 2026-11-01 \
        --exclude-session <id> --host-label tsekh --json base.json
"""
import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

HOOKS_DIR = Path(__file__).resolve().parent.parent / ".claude" / "hooks"
sys.path.insert(0, str(HOOKS_DIR))
import a13_1_symbols as rule  # noqa: E402
from a13_1_symbols import HEADLESS_ENTRYPOINTS, turns  # noqa: E402

DEFAULT_ROOTS = ["~/.claude/projects/-home-tseren-IWE*"]
QUOTE_RE = re.compile(r'«[^»\n]{1,200}»|"[^"\n]{1,200}"')
LINK_RE = re.compile(r'\]\([^)\s]+\)|(?<!\()https?://\S+')
COUNTERS = ("replies", "items", "items_with_symbol", "bt_address", "bt_symbol", "bt_other", "quotes", "links")


def measure(text, stats):
    stats["replies"] += 1
    for item in rule.split_items(text):
        stats["items"] += 1
        if rule.find_symbols(item):
            stats["items_with_symbol"] += 1
    body = rule.strip_fences(text)
    for match in rule.BACKTICK_RE.finditer(body):
        stats["bt_" + rule.classify_token(match.group(1))] += 1
    stats["quotes"] += len(QUOTE_RE.findall(rule.BACKTICK_RE.sub("", body)))
    stats["links"] += len(LINK_RE.findall(body))


def kept_paths(paths, excluded):
    """Drop transcripts whose file name (session id) is in `excluded`."""
    return [path for path in paths if Path(path).stem not in set(excluded)]


def collect(paths, since, until, entrypoints=None):
    grains = {"all_blocks": defaultdict(lambda: dict.fromkeys(COUNTERS, 0)),
              "last_block": defaultdict(lambda: dict.fromkeys(COUNTERS, 0))}
    for path in paths:
        for day, blocks in turns(path, entrypoints):
            if not day or not since <= day <= until:
                continue
            for text in blocks:
                measure(text, grains["all_blocks"][day])
            measure(blocks[-1], grains["last_block"][day])
    return {name: dict(sorted(days.items())) for name, days in grains.items()}


def ratios(stats):
    replies, items = stats["replies"] or 1, stats["items"] or 1
    return {
        "symbol_item_share": round(stats["items_with_symbol"] / items, 3),
        "backticks_per_reply": round((stats["bt_address"] + stats["bt_symbol"] + stats["bt_other"]) / replies, 2),
        "addresses_per_reply": round(stats["bt_address"] / replies, 2),
        "symbols_per_reply": round(stats["bt_symbol"] / replies, 2),
        "quotes_per_reply": round(stats["quotes"] / replies, 2),
        "links_per_reply": round(stats["links"] / replies, 2),
    }


def totals(days):
    """Counters summed over the window first, ratios after: days weigh by size."""
    summed = dict.fromkeys(COUNTERS, 0)
    for stats in days.values():
        for key in COUNTERS:
            summed[key] += stats[key]
    return {**summed, **ratios(summed)}


def print_table(name, days):
    print(f"\n{name}")
    print("date        replies  items  sym_item_share  bt/reply  addr/reply  sym/reply  quotes/reply  links/reply")
    for day, stats in days.items():
        r = ratios(stats)
        print(f"{day}  {stats['replies']:7d}  {stats['items']:5d}  {r['symbol_item_share']:14.3f}  "
              f"{r['backticks_per_reply']:8.2f}  {r['addresses_per_reply']:10.2f}  {r['symbols_per_reply']:9.2f}  "
              f"{r['quotes_per_reply']:12.2f}  {r['links_per_reply']:11.2f}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--since", required=True, help="first day, YYYY-MM-DD (message timestamp, UTC)")
    parser.add_argument("--until", required=True, help="last day, YYYY-MM-DD, inclusive")
    parser.add_argument("--root", action="append", help="transcript project dir glob (repeatable)")
    parser.add_argument("--exclude-session", action="append", default=[], help="session id to skip (repeatable)")
    parser.add_argument("--host-label", default="unknown")
    parser.add_argument("--json", help="write the full result here")
    args = parser.parse_args(argv)
    if any(not session.strip() for session in args.exclude_session):
        parser.error("--exclude-session needs a session id, got an empty value")

    roots = args.root or DEFAULT_ROOTS
    found = sorted({p for root in roots for p in glob.glob(os.path.join(os.path.expanduser(root), "*.jsonl"))})
    paths = kept_paths(found, args.exclude_session)
    entrypoints = set()
    grains = collect(paths, args.since, args.until, entrypoints)
    for name, days in grains.items():
        print_table(name, days)

    if args.json:
        def digest(path):
            return hashlib.sha256(Path(path).read_bytes()).hexdigest()[:12]

        result = {
            "rule": rule.ITEM_RULE,
            "classifier_sha256": digest(rule.__file__),
            "script_sha256": digest(__file__),
            "day_tz": "UTC",
            "freeze_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            "since": args.since,
            "until": args.until,
            "host_label": args.host_label,
            "excluded_sessions": args.exclude_session,
            "transcripts": len(paths),
            "entrypoints_seen": sorted(entrypoints),
            "entrypoints_skipped": sorted(entrypoints & HEADLESS_ENTRYPOINTS),
            "totals": {name: totals(days) for name, days in grains.items()},
            "grains": {name: {day: {**stats, **ratios(stats)} for day, stats in days.items()}
                       for name, days in grains.items()},
        }
        Path(args.json).write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
