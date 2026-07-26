#!/bin/bash
# Extension hook for Week Close (extensions/week-close.after.focustodo.md).
# Prints the "Фокус (РП-470)" section for WeekReport: 7-day totals + trend
# (first half vs second half of the week) + honest coverage marker.
# Author-only: sources personal Focus To-Do data (WP-470), not shipped in
# FMT-exocortex-template.
#
# Source format: single JSON export file, same contract as day-open.focustodo-extra.sh
# (gyozalab/focustodo-mcp SyncResponse, verified against upstream src/types.ts 2026-07-26).
#
# Usage: week-close.focustodo-extra.sh YYYY-MM-DD YYYY-MM-DD  (week start, week end — Mon..Sun)
set -euo pipefail

WEEK_START="${1:?usage: week-close.focustodo-extra.sh YYYY-MM-DD_start YYYY-MM-DD_end}"
WEEK_END="${2:?usage: week-close.focustodo-extra.sh YYYY-MM-DD_start YYYY-MM-DD_end}"
EXPORT_DIR="$HOME/.local/share/iwe/focustodo-exports"
LOG="$HOME/IWE/DS-my-strategy/logs/day-open-summary-extra.err.log"

mkdir -p "$(dirname "$LOG")" "$EXPORT_DIR"

EXPORT_FILE=$(find "$EXPORT_DIR" -maxdepth 1 -name 'export-*.json' 2>/dev/null | sort | tail -1)
if [ -z "$EXPORT_FILE" ]; then
  echo "$(date -u +%FT%TZ) WEEK=$WEEK_START..$WEEK_END: нет экспорта Focus To-Do в $EXPORT_DIR" >>"$LOG"
  echo "_Фокус (РП-470): нет данных за $WEEK_START..$WEEK_END — экспорт не найден_"
  exit 0
fi

python3 - "$EXPORT_FILE" "$WEEK_START" "$WEEK_END" <<'PYEOF'
import json
import sys
from datetime import date, datetime, timedelta, timezone

export_file, start_str, end_str = sys.argv[1:]
start = date.fromisoformat(start_str)
end = date.fromisoformat(end_str)
lo_ms = int(datetime(start.year, start.month, start.day, tzinfo=timezone.utc).timestamp() * 1000)
hi_ms = int((datetime(end.year, end.month, end.day, tzinfo=timezone.utc) + timedelta(days=1)).timestamp() * 1000)

with open(export_file, encoding="utf-8") as f:
    data = json.load(f)

sec_by_day = {}
count_by_day = {}
for p in data.get("pomodoros", []):
    end_date = p.get("endDate", 0)
    if not (lo_ms <= end_date < hi_ms):
        continue
    day = datetime.fromtimestamp(end_date / 1000, tz=timezone.utc).date().isoformat()
    sec_by_day[day] = sec_by_day.get(day, 0) + p.get("interval", 0)
    count_by_day[day] = count_by_day.get(day, 0) + 1

total_days = (end - start).days + 1
covered = len(sec_by_day)
if not covered:
    print(f"_Фокус (РП-470): нет данных за {start_str}..{end_str}_")
    sys.exit(0)


def half_sum(d, lo, hi):
    return sum(v for k, v in d.items() if lo.isoformat() <= k <= hi.isoformat())


def trend(cur_total, prev_total, step_min):
    diff_min = (cur_total - prev_total) / 60
    if diff_min >= step_min:
        return f"↑ (+{diff_min:.0f}м)"
    if diff_min <= -step_min:
        return f"↓ ({diff_min:.0f}м)"
    return "→ стабильно"


mid = start + timedelta(days=(end - start).days // 2)
first_half = half_sum(sec_by_day, start, mid)
second_half = half_sum(sec_by_day, mid + timedelta(days=1), end)
t_focus = trend(second_half, first_half, 30)

total_sec = sum(sec_by_day.values())
total_pomos = sum(count_by_day.values())
h, m = divmod(total_sec // 60, 60)

print("## Фокус (РП-470)\n")
print(f"Покрытие: данные за {covered} из {total_days} дней недели.\n")
print("| Метрика | За неделю | Тренд (1-я → 2-я половина недели) |")
print("|---|---|---|")
print(f"| Время в фокусе | {h}ч {m}м | {t_focus} |")
print(f"| Помидоров | {total_pomos} | — |")
PYEOF
