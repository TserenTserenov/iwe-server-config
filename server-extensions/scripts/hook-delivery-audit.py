#!/usr/bin/env python3
"""Audit whether hook additionalContext actually reached the model (WP-7 F299).

The Claude Code harness keeps a hook's additionalContext inline only up to
PLATFORM_HOOK_CONTEXT_CHAR_LIMIT characters; longer output is written to
tool-results/hook-*-additionalContext.txt and the transcript records a
"<persisted-output>" stub with a 2 KB preview. This script reads transcripts
(~/.claude/projects/*/*.jsonl), counts hook injections in a time window, and
reports how many were persisted instead of delivered.

Verdict (agreed in peer session 2026-11-05-05-wp7-system-prompt-budget):
  FAIL — persisted share > 5 % of injections (at least two persisted), or one
         hook persisted >= 3 times in a row within a session;
  WARN — at least one persisted injection;
  PASS — everything delivered inline.
Exit code: 1 on FAIL, 0 otherwise (WARN is reported, not blocking).
"""

import argparse
import collections
import datetime
import glob
import json
import os
import re
import sys

LIB = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", ".claude", "hooks", "lib"
)
sys.path.insert(0, LIB)
from platform_limits import PLATFORM_HOOK_CONTEXT_CHAR_LIMIT

FAIL_RATIO = 0.05
FAIL_STREAK = 3
PERSISTED = "<persisted-output>"
SIZE = re.compile(r"Output too large \(([\d.]+)KB\)")
PREVIEW = "Preview (first 2KB):\n"


def signature(text):
    """First non-empty line of the hook's own text: identifies the hook across turns."""
    if text.startswith(PERSISTED) and PREVIEW in text:
        text = text.split(PREVIEW, 1)[1]
    for line in text.splitlines():
        if line.strip():
            return line.strip()[:60]
    return "(empty)"


def parse_time(value):
    try:
        # "Z" suffix is parsed natively only since Python 3.11; macOS hosts may be older.
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))  # noqa: FURB162
    except (AttributeError, ValueError):
        return None


def scan(projects_dir, since):
    """Yield (session, timestamp, signature, persisted, chars) for hook injections after since."""
    cutoff = since.timestamp()
    # Main-session transcripts live at <projects>/<project>/<session>.jsonl; subagent
    # transcripts sit deeper and never receive UserPromptSubmit hook context.
    for path in glob.glob(os.path.join(projects_dir, "*", "*.jsonl")):
        if os.path.getmtime(path) < cutoff:
            continue
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if '"hook_additional_context"' not in line:
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                attachment = record.get("attachment") or {}
                when = parse_time(record.get("timestamp"))
                if (
                    attachment.get("type") != "hook_additional_context"
                    or when is None
                    or when < since
                ):
                    continue
                for text in attachment.get("content") or []:
                    if not isinstance(text, str):
                        continue
                    persisted = text.startswith(PERSISTED)
                    size = SIZE.search(text) if persisted else None
                    chars = int(float(size.group(1)) * 1024) if size else len(text)
                    yield (
                        record.get("sessionId", os.path.basename(path)),
                        when,
                        signature(text),
                        persisted,
                        chars,
                    )


def audit(events):
    total = persisted = persisted_chars = 0
    by_hook = collections.Counter()
    streaks = collections.defaultdict(int)
    max_streak, max_streak_hook = 0, ""
    for session, _when, sig, is_persisted, chars in sorted(
        events, key=lambda e: (e[0], e[1])
    ):
        total += 1
        key = (session, sig)
        if is_persisted:
            persisted += 1
            persisted_chars += chars
            by_hook[sig] += 1
            streaks[key] += 1
            if streaks[key] > max_streak:
                max_streak, max_streak_hook = streaks[key], sig
        else:
            streaks[key] = 0
    ratio = persisted / total if total else 0.0
    # A single persisted injection is a warning even in a small sample (1 of 10 > 5 %).
    if (ratio > FAIL_RATIO and persisted > 1) or max_streak >= FAIL_STREAK:
        verdict = "FAIL"
    elif persisted:
        verdict = "WARN"
    else:
        verdict = "PASS"
    return {
        "verdict": verdict,
        "injections": total,
        "persisted": persisted,
        "persisted_ratio": round(ratio, 4),
        "persisted_chars": persisted_chars,
        "persisted_streak_max": max_streak,
        "persisted_streak_hook": max_streak_hook,
        "persisted_by_hook": dict(by_hook.most_common(5)),
        "limit_chars": PLATFORM_HOOK_CONTEXT_CHAR_LIMIT,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description="Hook delivery audit (WP-7 F299)")
    parser.add_argument("--hours", type=float, default=24.0)
    parser.add_argument(
        "--projects-dir", default=os.path.expanduser("~/.claude/projects")
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    now = datetime.datetime.now(datetime.timezone.utc)  # noqa: UP017 - older macOS python3
    since = now - datetime.timedelta(hours=args.hours)
    report = audit(scan(args.projects_dir, since))
    if args.json:
        print(json.dumps(report, ensure_ascii=False))
    else:
        print(
            f"{report['verdict']}: hook injections {report['injections']} in {args.hours:g}h, "
            f"persisted (not delivered) {report['persisted']} "
            f"({report['persisted_ratio']:.1%}, ~{report['persisted_chars']} chars), "
            f"max streak {report['persisted_streak_max']}, limit {report['limit_chars']} chars/hook"
        )
        for sig, count in report["persisted_by_hook"].items():
            print(f"  persisted {count}x: {sig}")
    return 1 if report["verdict"] == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main())
