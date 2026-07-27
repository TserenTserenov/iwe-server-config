#!/bin/bash
# Extension hook for Month Close (extensions/month-close.after.focustodo.md).
# Builds the "Фокус (РП-470)" section — weekly table + month total + trend + honest
# coverage marker — and writes it to a LOCAL non-git file:
#   ~/Library/IWE/focustodo-data/month-summaries/YYYY-MM.md
# stdout carries only a value-free pointer line for `archive/MonthClose YYYY-MM.md`.
# Same residency reasoning as month-close.summary-extra.sh (health, WP-469): MonthClose
# is git-tracked and pushed — personal Focus To-Do values must never appear in it.
# Author-only: sources personal Focus To-Do data (WP-470), not shipped in
# FMT-exocortex-template.
#
# Source format: single JSON export file, same contract as day-open.focustodo-extra.sh
# (gyozalab/focustodo-mcp SyncResponse, verified against upstream src/types.ts 2026-07-26).
#
# Usage: month-close.focustodo-extra.sh YYYY-MM
set -euo pipefail

MONTH="${1:?usage: month-close.focustodo-extra.sh YYYY-MM}"
EXPORT_DIR="$HOME/.local/share/iwe/focustodo-exports"
LOG="$HOME/IWE/DS-my-strategy/logs/day-open-summary-extra.err.log"
SUMMARY_DIR="$HOME/Library/IWE/focustodo-data/month-summaries"
OUTFILE="$SUMMARY_DIR/$MONTH.md"

mkdir -p "$(dirname "$LOG")" "$EXPORT_DIR" "$SUMMARY_DIR"

EXPORT_FILE=$(find "$EXPORT_DIR" -maxdepth 1 -name 'export-*.json' 2>/dev/null | sort | tail -1)
if [ -z "$EXPORT_FILE" ]; then
  echo "$(date -u +%FT%TZ) MONTH=$MONTH: нет экспорта Focus To-Do в $EXPORT_DIR" >>"$LOG"
  echo "_Фокус (РП-470): нет данных за $MONTH — экспорт не найден_"
  exit 0
fi

python3 - "$EXPORT_FILE" "$MONTH" >"$OUTFILE" <<'PYEOF'
import calendar
import json
import sys
from datetime import date, datetime, timedelta, timezone

export_file, month = sys.argv[1], sys.argv[2]
year, mon = map(int, month.split("-"))
first = date(year, mon, 1)
last = date(year, mon, calendar.monthrange(year, mon)[1])
horizon = min(last, date.today())

lo_ms = int(datetime(first.year, first.month, first.day, tzinfo=timezone.utc).timestamp() * 1000)
hi_ms = int((datetime(horizon.year, horizon.month, horizon.day, tzinfo=timezone.utc) + timedelta(days=1)).timestamp() * 1000)

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

total_days = (horizon - first).days + 1
covered = len(sec_by_day)
if not covered:
    print(f"_Фокус (РП-470): нет данных за {month}_")
    sys.exit(0)

weeks = []
wk_start = first - timedelta(days=first.weekday())
while wk_start <= horizon:
    wk_end = min(wk_start + timedelta(days=6), horizon)
    lo, hi = max(wk_start, first), wk_end
    iso = wk_start.isocalendar()
    weeks.append((f"W{iso.week:02d}", lo, hi))
    wk_start += timedelta(days=7)


def week_sum(d, lo, hi):
    return sum(v for k, v in d.items() if lo.isoformat() <= k <= hi.isoformat())


lines = []
for name, lo, hi in weeks:
    sec = week_sum(sec_by_day, lo, hi)
    cnt = week_sum(count_by_day, lo, hi)
    h, m = divmod(sec // 60, 60)
    rng = f"{lo.strftime('%d.%m')}–{hi.strftime('%d.%m')}"
    lines.append(f"| {name} ({rng}) | {h}ч {m}м | {cnt} |")

m_sec = sum(sec_by_day.values())
m_pomos = sum(count_by_day.values())
m_h, m_m = divmod(m_sec // 60, 60)

# Trend compares week TOTALS, so a week clipped short (month boundary, or the
# still-running current week) must be excluded — otherwise a week with fewer days
# summed reads as a cliff-drop against a full week, not as a change in focus. 4+
# days (more than half a 7-day week) is the cutoff for "enough days to compare".
valid_weeks = [w for w in weeks if week_sum(sec_by_day, w[1], w[2]) > 0 and (w[2] - w[1]).days + 1 >= 4]
t_focus = "—"
if len(valid_weeks) >= 2:
    first_wk, last_wk = valid_weeks[0], valid_weeks[-1]
    diff_min = (week_sum(sec_by_day, last_wk[1], last_wk[2]) - week_sum(sec_by_day, first_wk[1], first_wk[2])) / 60
    t_focus = ("↑" if diff_min >= 15 else "↓" if diff_min <= -15 else "→") + f" ({diff_min:+.0f}м/нед)"

print("## Фокус (РП-470)\n")
print(f"> Покрытие: данные за {covered} из {total_days} дней периода.")
print()
print("| Неделя | Время в фокусе | Помидоров |")
print("|---|---|---|")
print("\n".join(lines))
print(f"| **Итог месяца** | **{m_h}ч {m_m}м** | **{m_pomos}** |")
print()
print(f"Тренд (первая → последняя неделя с данными): {t_focus}.")
PYEOF

echo "_Фокус (РП-470): срез месяца записан локально вне git — \`~/Library/IWE/focustodo-data/month-summaries/$MONTH.md\` (значения в MonthClose не публикуются)_"
