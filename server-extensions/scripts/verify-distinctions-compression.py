#!/usr/bin/env python3
"""
Детектор ошибок сжатия различений (WP-450 Ф2).

Сканирует iwe_memory.db на паттерны confusion Tier-B различений.
Passive-режим (informational, observation).

Usage:
  scripts/verify-distinctions-compression.py [--db PATH] [--days N] [--enforce]

Options:
  --db PATH     Path to iwe_memory.db (default: DS-my-strategy/exocortex/agent-fault-profile/iwe_memory.db)
  --days N      Scan window in days (default: 14)
  --enforce     Alert mode (default: observation mode)
"""

import sys
import sqlite3
import argparse
from datetime import datetime, timedelta
from pathlib import Path

# Паттерны confusion по контексту WP-450
DISTINCTION_CONFUSION_PATTERNS = [
    r"перепутал различени",
    r"не различил",
    r"смешал tier",
    r"спутал tier",
    r"спутал различени",
]

def find_db_path(custom_path=None):
    """Найти iwe_memory.db."""
    if custom_path:
        p = Path(custom_path)
        if p.exists():
            return str(p)

    # Стандартный путь
    default = Path.home() / "IWE/DS-my-strategy/exocortex/agent-fault-profile/iwe_memory.db"
    if default.exists():
        return str(default)

    raise FileNotFoundError(f"iwe_memory.db not found (tried: {default})")

def scan_distinctions_confusion(db_path, days=14, enforce=False):
    """
    Сканировать базу на confusion Tier-B различений.

    Returns:
        dict with:
        - tagged: count with fault_subtype='distinction-confusion'
        - pattern_matched: count with pattern match (confidence=low)
        - threshold: N >= 3
        - alert: bool (threshold breached)
        - details: list of matches
    """

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Временное окно (last N days)
    try:
        # Python 3.12+
        cutoff = (datetime.now(datetime.UTC) - timedelta(days=days)).isoformat()
    except AttributeError:
        # Python 3.11 fallback
        from datetime import timezone
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()

    # 1. Tagged: explicit fault_subtype='distinction-confusion'
    cursor.execute(
        "SELECT id, content, created_at FROM facts "
        "WHERE fact_type='agent_fault' AND fault_subtype='distinction-confusion' AND created_at >= ? "
        "ORDER BY created_at DESC",
        (cutoff,)
    )
    tagged_rows = cursor.fetchall()

    # 2. Pattern-matched: no fault_subtype, but content matches patterns
    import re
    pattern_compiled = re.compile("|".join(DISTINCTION_CONFUSION_PATTERNS), re.IGNORECASE)

    cursor.execute(
        "SELECT id, content, created_at FROM facts "
        "WHERE fact_type='agent_fault' AND (fault_subtype IS NULL OR fault_subtype='') "
        "AND created_at >= ? "
        "ORDER BY created_at DESC",
        (cutoff,)
    )
    all_faults = cursor.fetchall()
    pattern_matched = [
        (row[0], row[1], row[2])
        for row in all_faults
        if pattern_compiled.search(row[1] or "")
    ]

    conn.close()

    total = len(tagged_rows) + len(pattern_matched)
    threshold_breached = total >= 3

    return {
        'tagged': len(tagged_rows),
        'pattern_matched': len(pattern_matched),
        'total': total,
        'threshold': 3,
        'threshold_breached': threshold_breached,
        'window_days': days,
        'cutoff_date': cutoff,
        'tagged_rows': tagged_rows,
        'pattern_matched_rows': pattern_matched,
        'enforce': enforce,
    }

def format_output(result):
    """Форматировать результат для логирования."""
    lines = [
        f"[verify-distinctions-compression] Window: {result['window_days']} days",
        f"Tagged (explicit fault_subtype): {result['tagged']}",
        f"Pattern-matched (fallback): {result['pattern_matched']}",
        f"Total: {result['total']} (threshold: {result['threshold']})",
    ]

    if result['threshold_breached']:
        if result['enforce']:
            lines.append("⚠️  ALERT: Threshold breached! Recommend: raise Tier-B to Tier-A for confused distinctions")
            return "\n".join(lines), 1
        else:
            lines.append("⚠️  OBSERVATION: Threshold breached (enforcement disabled)")
            return "\n".join(lines), 0
    else:
        lines.append("✅ OK: Compression within threshold")
        return "\n".join(lines), 0

def main():
    parser = argparse.ArgumentParser(description="Detect distinction confusion in iwe_memory.db")
    parser.add_argument("--db", default=None, help="Path to iwe_memory.db")
    parser.add_argument("--days", type=int, default=14, help="Scan window (days)")
    parser.add_argument("--enforce", action="store_true", help="Alert mode")
    parser.add_argument("--json", action="store_true", help="JSON output")

    args = parser.parse_args()

    try:
        db_path = find_db_path(args.db)
        result = scan_distinctions_confusion(db_path, days=args.days, enforce=args.enforce)

        if args.json:
            import json
            # Remove raw rows for JSON
            output = {
                'tagged': result['tagged'],
                'pattern_matched': result['pattern_matched'],
                'total': result['total'],
                'threshold': result['threshold'],
                'threshold_breached': result['threshold_breached'],
                'window_days': result['window_days'],
            }
            print(json.dumps(output))
            return 0 if not result['threshold_breached'] else (2 if args.enforce else 0)
        else:
            output, exit_code = format_output(result)
            print(output)
            return exit_code

    except FileNotFoundError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

if __name__ == "__main__":
    sys.exit(main())
