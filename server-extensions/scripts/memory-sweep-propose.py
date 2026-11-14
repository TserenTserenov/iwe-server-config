#!/usr/bin/env python3
"""Propose a memory sweep "keep / move / delete" for the pilot (WP-7 F309).

Implements the exit rules of memory-lifecycle-spec.md section 6a: a memory
entry leaves the memory when it became a rule (moved to a pack or the core),
turned out to be domain knowledge (moved to a pack), or is obsolete (its work
product is closed, a check replaced it, it is wrong). Only the pilot decides;
this script proposes and changes nothing.

Mechanical signals (a proposal, never a verdict):
  delete?  project entry whose every referenced work product is closed;
  review   lesson older than --min-age days whose every referenced work
           product is closed (became a rule? keep? delete?);
  new      entries created in the last --since days: check them against the
           entry test (three questions of section 6a).

Usage:
  memory-sweep-propose.py --memory DIR --registry WP-REGISTRY.md [--since 7]
                          [--min-age 30] [--limit 40] [--all]
"""

import argparse
import datetime as dt
import re
import sys
from pathlib import Path

WP_REF = re.compile(r"(?:WP|РП)[-\s]?(\d{1,4})(?!\d)", re.I)
CLOSED_ROW = re.compile(r"^\|\s*~~(\d+)~~\s*\|.*\|\s*(?:✅|❌)\s*\|", re.M)
NAME_LINE = re.compile(r"^description:\s*(.*)$", re.M)
SKIP = {"MEMORY.md", "MEMORY-warm.md", "memory-lifecycle-spec.md"}


def closed_work_products(registry):
    return {int(n) for n in CLOSED_ROW.findall(registry.read_text(encoding="utf-8"))}


def entry_kind(path):
    return path.name.split("_", 1)[0] if "_" in path.name else "other"


def referenced(path, text):
    head = path.name + " " + " ".join(NAME_LINE.findall(text[:3000]))
    return {int(n) for n in WP_REF.findall(head)}


def classify(path, closed, today, since, min_age):
    text = path.read_text(encoding="utf-8", errors="replace")
    kind = entry_kind(path)
    refs = referenced(path, text)
    age = (today - dt.date.fromtimestamp(path.stat().st_mtime)).days
    all_closed = bool(refs) and refs <= closed
    if kind == "project" and all_closed:
        return "delete?", f"все РП закрыты: {', '.join(f'РП-{n}' for n in sorted(refs))}"
    if kind == "lessons" and all_closed and age >= min_age:
        return "review", f"{age} дн., все РП закрыты: {', '.join(f'РП-{n}' for n in sorted(refs))}"
    if age < since:
        return "new", "проверить по тесту входа (§6а)"
    return None, ""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--memory", type=Path, required=True)
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--since", type=int, default=7)
    parser.add_argument("--min-age", type=int, default=30)
    parser.add_argument("--limit", type=int, default=40, help="rows per group in the report")
    parser.add_argument("--all", action="store_true", help="no row limit")
    args = parser.parse_args()
    if not args.memory.is_dir() or not args.registry.is_file():
        print("memory-sweep-propose: --memory must be a folder and --registry a file", file=sys.stderr)
        return 2

    closed = closed_work_products(args.registry)
    today = dt.date.today()
    groups = {"delete?": [], "review": [], "new": []}
    kinds = {}
    for path in sorted(args.memory.glob("*.md")):
        if path.name in SKIP:
            continue
        kinds[entry_kind(path)] = kinds.get(entry_kind(path), 0) + 1
        verdict, why = classify(path, closed, today, args.since, args.min_age)
        if verdict:
            groups[verdict].append((path.name, why))

    print(f"# Разбор памяти — предложение на {today.isoformat()}\n")
    print("Записей по видам: " + ", ".join(f"{k} {v}" for k, v in sorted(kinds.items(), key=lambda kv: -kv[1])) + "\n")
    titles = {
        "delete?": "Кандидаты на удаление (запись о работе, все её РП закрыты; закрытый РП ≠ решённая проблема — проверить, не живой ли это факт)",
        "review": f"На разбор: уроки старше {args.min_age} дней по закрытым РП — стали правилом, оставить или удалить?",
        "new": f"Новые за {args.since} дней — проверить по тесту входа",
    }
    for verdict, rows in groups.items():
        print(f"## {titles[verdict]} — {len(rows)}\n")
        shown = rows if args.all else rows[: args.limit]
        for name, why in shown:
            print(f"- `{name}` — {why}")
        if len(shown) < len(rows):
            print(f"- … ещё {len(rows) - len(shown)} (полный список: --all)")
        print()
    print("Решает пилот: «удалить», «перенести в правило/пак» или «оставить» — по группам или по строкам.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
