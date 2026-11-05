#!/usr/bin/env python3
"""Rule usefulness report for trimming the hot instruction core (WP-7 F299, block 2).

Read-only. For every rule of PACK-agent-rules it joins:
  criticality / criticality_review   — from the rule's own front matter;
  exposures, prevented, last_seen     — from the rule-engine journal
                                        (~/logs/rule-engine/YYYY-MM-DD.jsonl):
                                        exposure = any verdict, prevented = warn or block;
  hot_mentions                        — lines of the hot files that name the rule id,
                                        a rough stand-in for its cost in the hot core.

A rule is a candidate for MOVING out of the hot core (never deletion — pilot's
decision 2026-11-05) only when all hold: criticality C2 confirmed by the pilot,
status active, its own journal span (first to last event) of at least MIN_DAYS days, exposures > 0 and
prevented == 0. A rule without journal data is never a candidate: no data is
not evidence of uselessness.

Until plan block 4 (the explicit rule map in CLAUDE.md) this list is a report
only; nothing is moved on its basis.
"""

import argparse
import collections
import datetime
import glob
import json
import os
import re
import sys

IWE_ROOT = os.environ.get("IWE_ROOT", os.path.expanduser("~/IWE"))
RULES_DIR = os.path.join(IWE_ROOT, "PACK-agent-rules", "rules")
JOURNAL_DIR = os.environ.get(
    "RULE_JOURNAL_DIR", os.path.expanduser("~/logs/rule-engine")
)
# Same hot set as scripts/hot-budget-ratchet.py: what the harness loads every session
# (CLAUDE.md and every .claude/rules/**/*.md, recursively), plus the governance repo's
# CLAUDE.md that the workspace also loads.
HOT_PATTERNS = ("CLAUDE.md", ".claude/rules/**/*.md", "DS-my-strategy/CLAUDE.md")
MIN_DAYS = 14
RULE_FILE = re.compile(r"^(AR|SR)\.\d+.*\.md$")
FIELD = re.compile(r"^([a-z_]+):\s*(.*)$")
JOURNAL_FILE = re.compile(r"^\d{4}-\d{2}-\d{2}\.jsonl$")


def front_matter(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---", 4)
    fields = {}
    for line in text[4:end].splitlines():
        match = FIELD.match(line)
        if match:
            fields[match.group(1)] = match.group(2).strip().strip("'\"")
    return fields


def load_rules(rules_dir):
    rules = {}
    for name in sorted(os.listdir(rules_dir)):
        if RULE_FILE.match(name):
            fields = front_matter(os.path.join(rules_dir, name))
            if fields.get("id"):
                rules[fields["id"]] = fields
    return rules


def load_journal(journal_dir):
    """Per rule: exposures, prevented, last_seen; plus the set of journal days."""
    stats = collections.defaultdict(
        lambda: {"exposures": 0, "prevented": 0, "first_seen": "", "last_seen": ""}
    )
    days = set()
    for path in glob.glob(os.path.join(journal_dir, "*.jsonl")):
        if not JOURNAL_FILE.match(os.path.basename(path)):
            continue  # *-classified.jsonl are derived copies of the same events
        days.add(os.path.basename(path)[:10])
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                rule = event.get("rule")
                if not rule or not str(rule).startswith(("AR.", "SR.")):
                    continue
                entry = stats[rule]
                entry["exposures"] += 1
                if event.get("verdict") in ("warn", "block"):
                    entry["prevented"] += 1
                ts = str(event.get("ts", ""))
                if ts[:10].count("-") != 2:
                    continue  # not an ISO timestamp: cannot place the event in time
                entry["last_seen"] = max(entry["last_seen"], ts)
                entry["first_seen"] = (
                    min(entry["first_seen"], ts) if entry["first_seen"] else ts
                )
    return stats, days


def hot_mentions(root):
    counts = collections.Counter()
    paths = {
        p
        for pattern in HOT_PATTERNS
        for p in glob.glob(os.path.join(root, pattern), recursive=True)
    }
    for path in sorted(paths):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                for rule in set(re.findall(r"\b(?:AR|SR)\.\d{3}\b", line)):
                    counts[rule] += 1
    return counts


def observed_days(data):
    """Days from the rule's first to its last journal event (its own observation span)."""
    if not data["first_seen"]:
        return 0
    try:
        first = datetime.date.fromisoformat(data["first_seen"][:10])
        last = datetime.date.fromisoformat(data["last_seen"][:10])
    except ValueError:
        print(
            f"rule-usefulness: unreadable journal timestamp {data['first_seen']!r}",
            file=sys.stderr,
        )
        return 0
    return (last - first).days + 1


def candidate(rule, data):
    return (
        rule.get("criticality") == "C2"
        and rule.get("criticality_review") == "confirmed"
        and rule.get("status") == "active"
        and data["exposures"] > 0
        and data["prevented"] == 0
        and observed_days(data) >= MIN_DAYS
    )


def build(rules_dir, journal_dir, root):
    rules = load_rules(rules_dir)
    stats, days = load_journal(journal_dir)
    mentions = hot_mentions(root)
    rows = []
    for rule_id, rule in rules.items():
        data = stats.get(
            rule_id, {"exposures": 0, "prevented": 0, "first_seen": "", "last_seen": ""}
        )
        rows.append(
            {
                "id": rule_id,
                "criticality": rule.get("criticality", "—"),
                "review": rule.get("criticality_review", "—"),
                "status": rule.get("status", "—"),
                "data_status": "journal" if data["exposures"] else "none",
                "exposures": data["exposures"],
                "prevented": data["prevented"],
                "last_seen": data["last_seen"][:10],
                "hot_mentions": mentions.get(rule_id, 0),
                "observed_days": observed_days(data),
                "candidate": candidate(rule, data),
            }
        )
    return rows, len(days)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Rule usefulness report (WP-7 F299)")
    parser.add_argument("--rules-dir", default=RULES_DIR)
    parser.add_argument("--journal-dir", default=JOURNAL_DIR)
    parser.add_argument(
        "--root", default=IWE_ROOT, help="workspace root with the hot files"
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    rows, journal_days = build(args.rules_dir, args.journal_dir, args.root)
    if args.json:
        print(
            json.dumps(
                {"journal_days": journal_days, "rules": rows}, ensure_ascii=False
            )
        )
        return 0
    with_data = [r for r in rows if r["data_status"] == "journal"]
    by_class = collections.Counter((r["criticality"], r["review"]) for r in rows)
    print(
        f"Правил: {len(rows)}; с данными журнала: {len(with_data)}; дней журнала: {journal_days}"
    )
    print(
        "Критичность: "
        + ", ".join(f"{c}/{r} {n}" for (c, r), n in sorted(by_class.items()))
    )
    print(
        "Перенос из ядра — только после блока 4 (карта правил); до этого список ниже — отчёт."
    )
    print(
        "\n| Правило | Критичность | Проверено | Показы | Предотвращено | Последнее | В ядре | Кандидат |"
    )
    print("|---|---|---|---|---|---|---|---|")
    for r in sorted(rows, key=lambda r: (r["data_status"] != "journal", r["id"])):
        if r["data_status"] == "journal" or r["hot_mentions"]:
            print(
                f"| {r['id']} | {r['criticality']} | {r['review']} | {r['exposures']} | {r['prevented']} "
                f"| {r['last_seen'] or '—'} | {r['hot_mentions']} | {'да' if r['candidate'] else 'нет'} |"
            )
    print(
        f"\nОстальные {sum(1 for r in rows if r['data_status'] == 'none' and not r['hot_mentions'])} правил: "
        "нет данных журнала и нет упоминаний в ядре — не кандидаты."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
