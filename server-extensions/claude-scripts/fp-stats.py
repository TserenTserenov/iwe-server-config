#!/usr/bin/env python3
"""
fp-stats.py — агрегация метрики FP rate из classified-журнала rule-engine.

Читает ~/logs/rule-engine/YYYY-MM-DD-classified.jsonl, считает:
- Сколько срабатываний regex per rule
- Сколько agreement (LLM подтвердил violation)
- Сколько FP (LLM сказал ok)
- FP rate per rule

Используется при Week Close для ревизии правил с FP rate > 20%.

Использование:
  fp-stats.py [--date YYYY-MM-DD] [--week] [--all]
"""

import json
import sys
import argparse
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path

JOURNAL_DIR = Path.home() / "logs" / "rule-engine"


def load_classified_files(target_dates):
    files = []
    for d in target_dates:
        f = JOURNAL_DIR / f"{d}-classified.jsonl"
        if f.exists():
            files.append(f)
    return files


def aggregate(files):
    stats = defaultdict(lambda: {"total": 0, "agreement": 0, "false_positive": 0, "uncertain": 0})

    for f in files:
        with f.open(encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    continue
                rule = e.get("rule")
                if not rule or rule == "none":
                    continue
                llm = e.get("llm_verdict")
                stats[rule]["total"] += 1
                if llm == "violation":
                    stats[rule]["agreement"] += 1
                elif llm == "ok":
                    stats[rule]["false_positive"] += 1
                else:
                    stats[rule]["uncertain"] += 1
    return stats


def print_report(stats):
    print(f"\n{'Rule':<10} {'Total':<7} {'Agree':<7} {'FP':<5} {'FP%':<7} {'Uncert':<7} {'Verdict'}")
    print("-" * 70)

    flagged = []
    for rule in sorted(stats.keys()):
        s = stats[rule]
        total = s["total"]
        if total == 0:
            continue
        fp_rate = s["false_positive"] / total * 100
        verdict = "✅ healthy"
        if fp_rate > 20:
            verdict = "⚠️ REVISE (FP > 20%)"
            flagged.append(rule)
        elif fp_rate > 10:
            verdict = "⚠️ watch (FP > 10%)"

        print(f"{rule:<10} {total:<7} {s['agreement']:<7} {s['false_positive']:<5} {fp_rate:>5.1f}%  {s['uncertain']:<7} {verdict}")

    print()
    if flagged:
        print(f"⚠️ Правила к ревизии (FP rate > 20%): {', '.join(flagged)}")
    else:
        print("✅ Все правила работают в пределах нормы (FP rate ≤ 20%).")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", default=str(date.today()))
    parser.add_argument("--week", action="store_true", help="aggregate last 7 days")
    parser.add_argument("--all", action="store_true", help="aggregate all available dates")
    args = parser.parse_args()

    if args.all:
        files = sorted(JOURNAL_DIR.glob("*-classified.jsonl"))
    elif args.week:
        today = date.today()
        dates = [str(today - timedelta(days=i)) for i in range(7)]
        files = load_classified_files(dates)
    else:
        files = load_classified_files([args.date])

    if not files:
        print(f"No classified journals found.")
        return

    print(f"Aggregating {len(files)} file(s):")
    for f in files:
        print(f"  - {f.name}")

    stats = aggregate(files)
    if not stats:
        print("No rule activity found.")
        return

    print_report(stats)


if __name__ == "__main__":
    main()
