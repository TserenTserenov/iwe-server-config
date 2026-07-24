#!/bin/bash
# Extension hook for Month Close (extensions/month-close.after.health.md).
# Builds the "Здоровье (РП-470)" section — weekly table + month total + trend + honest
# coverage marker — and writes it to a LOCAL non-git file:
#   ~/Library/IWE/health-data/month-summaries/YYYY-MM.md
# stdout carries only a value-free pointer line for `archive/MonthClose YYYY-MM.md`.
# Residency (WP-469 retrofit-audit, WP-7 phase DayPlan-Health-Residency, 2026-07-24):
# MonthClose is git-tracked and pushed — health values must never appear in it.
# Author-only: sources personal health data (WP-470), not shipped in FMT-exocortex-template.
#
# Design (approved by pilot 2026-07-18, discussion in chat):
#   - вид "недели + тренд": месяц — горизонт динамики, одна средняя цифра её скрывает;
#   - те же три метрики, что в дне/неделе (сон, пульс покоя, плавание) — единая картина
#     на всех масштабах;
#   - маркер покрытия обязателен: поток REST идёт с 07.07, июль покрыт не полностью —
#     мнимая полнота хуже честного "N из D дней".
#
# Per-day selection mirrors day-open.summary-extra.sh exactly:
#   - sleep: Pillow row preferred, tie-break by received_at (several Pillow rows per night
#     happen, same as resting_heart_rate refined revisions — see day hook header);
#   - resting HR: latest row by received_at (Apple resends refined daily aggregates);
#   - swimming: SUM per day (Apple Watch writes one row per length, not one per day).
#
# Usage: month-close.summary-extra.sh YYYY-MM
set -euo pipefail

MONTH="${1:?usage: month-close.summary-extra.sh YYYY-MM}"
DB="$HOME/Library/IWE/health-data/health.db"
LOG="$HOME/IWE/DS-my-strategy/logs/day-open-summary-extra.err.log"

# bug-2026-07-17 taught: stderr must land in a log file, not /dev/null — a silently
# missing line is unexplainable post factum.
mkdir -p "$(dirname "$LOG")"

SUMMARY_DIR="$HOME/Library/IWE/health-data/month-summaries"
OUTFILE="$SUMMARY_DIR/$MONTH.md"

if [ ! -f "$DB" ]; then
  echo "$(date -u +%FT%TZ) MONTH=$MONTH: health.db отсутствует по пути $DB" >>"$LOG"
  echo "_Здоровье (РП-470): нет данных за $MONTH — health.db не найден_"
  exit 0
fi

mkdir -p "$SUMMARY_DIR"
python3 - "$DB" "$MONTH" >"$OUTFILE" <<'PYEOF'
import calendar
import json
import sqlite3
import sys
from datetime import date, timedelta

db_path, month = sys.argv[1], sys.argv[2]
year, mon = map(int, month.split("-"))
first = date(year, mon, 1)
last = date(year, mon, calendar.monthrange(year, mon)[1])
# Coverage horizon: a month closed after its end counts all days; the running month
# counts up to today (Jul-2026 closed on 18.07 → "N из 18", not "N из 31").
horizon = min(last, date.today())

conn = sqlite3.connect(db_path)
cur = conn.cursor()

def days_with(metric):
    cur.execute(
        "SELECT DISTINCT substr(date,1,10) FROM health_metrics "
        "WHERE metric_name=? AND substr(date,1,7)=?",
        (metric, month),
    )
    return {r[0] for r in cur.fetchall()}

# --- Sleep: one row per day (Pillow first, then latest received_at), core+deep+rem hours ---
sleep_by_day = {}
cur.execute(
    "SELECT substr(date,1,10), extra_json, source, received_at FROM health_metrics "
    "WHERE metric_name='sleep_analysis' AND substr(date,1,7)=? "
    "ORDER BY substr(date,1,10), CASE source WHEN 'Pillow' THEN 0 ELSE 1 END, received_at DESC",
    (month,),
)
for d, extra, source, _ in cur.fetchall():
    if d in sleep_by_day:  # first row per day wins (ordering above encodes the day-hook rule)
        continue
    try:
        j = json.loads(extra or "{}")
        tot = sum(float(j.get(k) or 0) for k in ("core", "deep", "rem"))
    except (ValueError, TypeError):
        tot = 0.0
    if tot > 0:
        sleep_by_day[d] = tot

# --- Resting HR: latest revision per day ---
hr_by_day = {}
cur.execute(
    "SELECT substr(date,1,10), qty FROM health_metrics "
    "WHERE metric_name='resting_heart_rate' AND substr(date,1,7)=? "
    "ORDER BY substr(date,1,10), received_at DESC",
    (month,),
)
for d, qty in cur.fetchall():
    if d not in hr_by_day and qty:
        hr_by_day[d] = float(qty)

# --- Swimming: sum meters per day ---
swim_by_day = {}
cur.execute(
    "SELECT substr(date,1,10), SUM(qty) FROM health_metrics "
    "WHERE metric_name='swimming_distance' AND substr(date,1,7)=? GROUP BY substr(date,1,10)",
    (month,),
)
for d, s in cur.fetchall():
    if s:
        swim_by_day[d] = float(s)

covered = days_with("sleep_analysis") | days_with("resting_heart_rate") | days_with("swimming_distance")
total_days = (horizon - first).days + 1
if not covered:
    print(f"_Здоровье (РП-470): нет данных за {month} (поток запущен 07.07 или база пуста)_")
    sys.exit(0)

# --- ISO weeks of the month (Mon-Sun), clipped to [first, horizon] ---
weeks = []
wk_start = first - timedelta(days=first.weekday())
while wk_start <= horizon:
    wk_end = min(wk_start + timedelta(days=6), horizon)
    lo, hi = max(wk_start, first), wk_end
    iso = wk_start.isocalendar()
    weeks.append((f"W{iso.week:02d}", lo, hi))
    wk_start += timedelta(days=7)

def avg(d, lo, hi):
    vals = [v for k, v in d.items() if lo.isoformat() <= k <= hi.isoformat()]
    return (sum(vals) / len(vals)) if vals else None

def total(d, lo, hi):
    vals = [v for k, v in d.items() if lo.isoformat() <= k <= hi.isoformat()]
    return sum(vals) if vals else None

def fmt_sleep(h):
    return f"{h:.1f}ч" if h is not None else "—"

def fmt_hr(bpm):
    return f"{bpm:.0f}" if bpm is not None else "—"

def fmt_km(m):
    return f"{m/1000:.1f} км" if m is not None else "—"

lines = []
for name, lo, hi in weeks:
    s = avg(sleep_by_day, lo, hi)
    h = avg(hr_by_day, lo, hi)
    w = total(swim_by_day, lo, hi)
    rng = f"{lo.strftime('%d.%m')}–{hi.strftime('%d.%m')}"
    lines.append(f"| {name} ({rng}) | {fmt_sleep(s)} | {fmt_hr(h)} | {fmt_km(w)} |")

m_sleep = avg(sleep_by_day, first, horizon)
m_hr = avg(hr_by_day, first, horizon)
m_swim = total(swim_by_day, first, horizon) or 0.0
swim_days = len(swim_by_day)

# --- Trend: first vs last week WITH data; thresholds keep noise out ---
def trend(cur_avg, first_avg, step):
    if cur_avg is None or first_avg is None:
        return "—"
    diff = cur_avg - first_avg
    if diff >= step:
        return f"↑ (+{diff:.1f})"
    if diff <= -step:
        return f"↓ ({diff:.1f})"
    return "→ стабильно"

valid_weeks = [w for w in weeks if avg(sleep_by_day, w[1], w[2]) is not None
               or avg(hr_by_day, w[1], w[2]) is not None]
first_wk, last_wk = (valid_weeks[0], valid_weeks[-1]) if valid_weeks else (None, None)
t_sleep = t_hr = t_swim = "—"
if first_wk and last_wk and first_wk != last_wk:
    t_sleep = trend(avg(sleep_by_day, last_wk[1], last_wk[2]),
                    avg(sleep_by_day, first_wk[1], first_wk[2]), 0.3)
    t_hr = trend(avg(hr_by_day, last_wk[1], last_wk[2]),
                 avg(hr_by_day, first_wk[1], first_wk[2]), 2.0)
    f_swim = total(swim_by_day, first_wk[1], first_wk[2])
    l_swim = total(swim_by_day, last_wk[1], last_wk[2])
    if f_swim is not None and l_swim is not None:
        diff_km = (l_swim - f_swim) / 1000
        t_swim = ("↑" if diff_km >= 0.5 else "↓" if diff_km <= -0.5 else "→") + f" ({diff_km:+.1f} км/нед)"

print(f"## Здоровье (РП-470)\n")
print(f"> Покрытие: данные за {len(covered)} из {total_days} дней периода"
      + (" (поток запущен 07.07 — первый полный месяц будет в августе)." if month == "2026-07" else "."))
print()
print("| Неделя | Сон, средн. | Пульс покоя, средн. | Плавание |")
print("|---|---|---|---|")
print("\n".join(lines))
swim_note = f"{m_swim/1000:.1f} км, {swim_days} дн. с заплывами" if m_swim > 0 else "—"
print(f"| **Итог месяца** | **{fmt_sleep(m_sleep)}** | **{fmt_hr(m_hr)}** | **{swim_note}** |")
print()
print(f"Тренд (первая → последняя неделя): сон {t_sleep}, пульс {t_hr}, плавание {t_swim}.")
PYEOF

# Value-free pointer — the only thing MonthClose (git-tracked) is allowed to carry.
echo "_Здоровье (РП-470): срез месяца записан локально вне git — \`~/Library/IWE/health-data/month-summaries/$MONTH.md\` (резидентность WP-469; значения в MonthClose не публикуются)_"
