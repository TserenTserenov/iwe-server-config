#!/bin/bash
# Extension hook for Strategy Session (extensions/strategy-session.after.health.md).
# Prints the "Здоровье (РП-470)" section for discovery context: 30-day average + trend
# (first half vs second half of the period) + honest coverage marker.
# Author-only: sources personal health data (WP-470), not shipped in FMT-exocortex-template.
#
# Same per-day selection rules as day-open/week-close/month-close summary-extra.sh:
#   - sleep: Pillow row preferred, tie-break by received_at;
#   - resting HR: latest row by received_at (Apple resends refined daily aggregates);
#   - swimming: SUM per day (Apple Watch writes one row per length, not one per day).
#
# Note: this duplicates the monthly average already in MonthClose (WP-470 Ф5, решение
# 18.07) — decision 25.07 was to keep it as a standalone informational section here too,
# since Strategy Session reads its own recent window (30 days), not the calendar month
# MonthClose closes, and discovery needs the number available without opening a
# different file.
#
# Usage: strategy-session.summary-extra.sh YYYY-MM-DD YYYY-MM-DD  (period start, end)
set -euo pipefail

PERIOD_START="${1:?usage: strategy-session.summary-extra.sh YYYY-MM-DD_start YYYY-MM-DD_end}"
PERIOD_END="${2:?usage: strategy-session.summary-extra.sh YYYY-MM-DD_start YYYY-MM-DD_end}"
DB="$HOME/Library/IWE/health-data/health.db"
LOG="$HOME/IWE/DS-my-strategy/logs/day-open-summary-extra.err.log"

mkdir -p "$(dirname "$LOG")"

if [ ! -f "$DB" ]; then
  echo "$(date -u +%FT%TZ) PERIOD=$PERIOD_START..$PERIOD_END: health.db отсутствует по пути $DB" >>"$LOG"
  echo "_Здоровье (РП-470): нет данных за $PERIOD_START..$PERIOD_END — health.db не найден_"
  exit 0
fi

python3 - "$DB" "$PERIOD_START" "$PERIOD_END" <<'PYEOF'
import json
import sqlite3
import sys
from datetime import date, timedelta

db_path, start_str, end_str = sys.argv[1:]
start = date.fromisoformat(start_str)
end = date.fromisoformat(end_str)

conn = sqlite3.connect(db_path)
cur = conn.cursor()


def days_with(metric):
    cur.execute(
        "SELECT DISTINCT substr(date,1,10) FROM health_metrics "
        "WHERE metric_name=? AND substr(date,1,10)>=? AND substr(date,1,10)<=?",
        (metric, start_str, end_str),
    )
    return {r[0] for r in cur.fetchall()}


sleep_by_day = {}
cur.execute(
    "SELECT substr(date,1,10), extra_json, source, received_at FROM health_metrics "
    "WHERE metric_name='sleep_analysis' AND substr(date,1,10)>=? AND substr(date,1,10)<=? "
    "ORDER BY substr(date,1,10), CASE source WHEN 'Pillow' THEN 0 ELSE 1 END, received_at DESC",
    (start_str, end_str),
)
for d, extra, source, _ in cur.fetchall():
    if d in sleep_by_day:
        continue
    try:
        j = json.loads(extra or "{}")
        tot = sum(float(j.get(k) or 0) for k in ("core", "deep", "rem"))
    except (ValueError, TypeError):
        tot = 0.0
    if tot > 0:
        sleep_by_day[d] = tot

hr_by_day = {}
cur.execute(
    "SELECT substr(date,1,10), qty FROM health_metrics "
    "WHERE metric_name='resting_heart_rate' AND substr(date,1,10)>=? AND substr(date,1,10)<=? "
    "ORDER BY substr(date,1,10), received_at DESC",
    (start_str, end_str),
)
for d, qty in cur.fetchall():
    if d not in hr_by_day and qty:
        hr_by_day[d] = float(qty)

swim_by_day = {}
cur.execute(
    "SELECT substr(date,1,10), SUM(qty) FROM health_metrics "
    "WHERE metric_name='swimming_distance' AND substr(date,1,10)>=? AND substr(date,1,10)<=? "
    "GROUP BY substr(date,1,10)",
    (start_str, end_str),
)
for d, s in cur.fetchall():
    if s:
        swim_by_day[d] = float(s)

covered = days_with("sleep_analysis") | days_with("resting_heart_rate") | days_with("swimming_distance")
total_days = (end - start).days + 1
if not covered:
    print(f"_Здоровье (РП-470): нет данных за {start_str}..{end_str}_")
    sys.exit(0)


def avg(d):
    vals = list(d.values())
    return (sum(vals) / len(vals)) if vals else None


def fmt_sleep(h):
    return f"{h:.1f}ч" if h is not None else "—"


def fmt_hr(bpm):
    return f"{bpm:.0f}" if bpm is not None else "—"


p_sleep = avg(sleep_by_day)
p_hr = avg(hr_by_day)
p_swim = sum(swim_by_day.values()) if swim_by_day else 0.0
swim_days = len(swim_by_day)

mid = start + timedelta(days=(end - start).days // 2)


def half_avg(d, lo, hi):
    vals = [v for k, v in d.items() if lo.isoformat() <= k <= hi.isoformat()]
    return (sum(vals) / len(vals)) if vals else None


def trend(cur_avg, prev_avg, step):
    if cur_avg is None or prev_avg is None:
        return "—"
    diff = cur_avg - prev_avg
    if diff >= step:
        return f"↑ (+{diff:.1f})"
    if diff <= -step:
        return f"↓ ({diff:.1f})"
    return "→ стабильно"


t_sleep = trend(half_avg(sleep_by_day, mid + timedelta(days=1), end), half_avg(sleep_by_day, start, mid), 0.3)
t_hr = trend(half_avg(hr_by_day, mid + timedelta(days=1), end), half_avg(hr_by_day, start, mid), 2.0)

print("## Здоровье (РП-470)\n")
print(f"Покрытие: данные за {len(covered)} из {total_days} дней периода ({start_str}..{end_str}).\n")
print(f"| Метрика | Среднее за период | Тренд (1-я → 2-я половина периода) |")
print("|---|---|---|")
print(f"| Сон | {fmt_sleep(p_sleep)} | {t_sleep} |")
print(f"| Пульс покоя | {fmt_hr(p_hr)} | {t_hr} |")
swim_note = f"{p_swim/1000:.1f} км, {swim_days} дн. с заплывами" if p_swim > 0 else "—"
print(f"| Плавание | {swim_note} | — |")
PYEOF
