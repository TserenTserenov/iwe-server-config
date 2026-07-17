#!/bin/bash
# Extension hook for render_yesterday() (scripts/day-open-scaffold.sh).
# L1 calls this file if it exists and executable; prints nothing if it doesn't.
# Author-only: sources personal health data (WP-470), not shipped in FMT-exocortex-template.
#
# Known limitation (peer-session 2026-07-09-08-day-open-sleep-correction, consensus turn 3):
# resting_heart_rate can have multiple rows per date — Apple recomputes the daily
# aggregate and resends a refined value later. We pick the latest by received_at
# (freshest revision), not the latest by time-of-day and not the minimum value.
set -euo pipefail

YDAY="${1:?usage: day-open.summary-extra.sh YYYY-MM-DD}"
DB="$HOME/Library/IWE/health-data/health.db"
LOG="$HOME/IWE/DS-my-strategy/logs/day-open-summary-extra.err.log"

# bug-2026-07-17: stderr шёл в /dev/null, пропажа строки в DayPlan 16.07 осталась необъяснима постфактум.
mkdir -p "$(dirname "$LOG")"

if [ ! -f "$DB" ]; then
  echo "$(date -u +%FT%TZ) YDAY=$YDAY: health.db отсутствует по пути $DB" >>"$LOG"
  exit 0
fi

# date column is stored as "YYYY-MM-DD HH:MM:SS +HHMM" (no colon in the offset) —
# sqlite's date()/strftime() can't parse that offset and silently return NULL,
# so match on the leading 10 chars instead of date(date)='$YDAY'.
HR=$(sqlite3 "$DB" \
  "SELECT qty FROM health_metrics
   WHERE metric_name='resting_heart_rate' AND substr(date,1,10)='$YDAY'
   ORDER BY received_at DESC LIMIT 1;" 2>>"$LOG") || HR=""

SLEEP_H=$(sqlite3 "$DB" \
  "SELECT ROUND(COALESCE(json_extract(extra_json,'\$.core'),0)
              + COALESCE(json_extract(extra_json,'\$.deep'),0)
              + COALESCE(json_extract(extra_json,'\$.rem'),0), 2)
   FROM health_metrics
   WHERE metric_name='sleep_analysis' AND substr(date,1,10)='$YDAY'
   -- Pillow — основной трекер сна (WP-470); received_at DESC — тай-брейк на случай
   -- нескольких записей Pillow за одну ночь, как уже наблюдалось у resting_heart_rate выше.
   ORDER BY CASE source WHEN 'Pillow' THEN 0 ELSE 1 END, received_at DESC LIMIT 1;" 2>>"$LOG") || SLEEP_H=""

SLEEP_STR=""
if [ -n "$SLEEP_H" ] && awk -v h="$SLEEP_H" 'BEGIN{exit !(h>0)}'; then
  SLEEP_STR=$(awk -v h="$SLEEP_H" 'BEGIN{m=int(h*60+0.5); printf "%dч %dм", int(m/60), m%60}')
fi

HR_STR=""
[ -n "$HR" ] && HR_STR="${HR%.*} уд/мин"

# Swimming — part of the 12-metric set the pilot approved 2026-07-15 (WP-470 Ф4), already
# written to health.db by receiver/parse_to_sqlite.py, but never surfaced here until now
# (bug found 2026-07-17). Optional line: silence on a non-swimming day is not a data gap.
# Apple Watch reports one row per length/segment (confirmed live: 26 rows = 1000m on
# 2026-07-15), so this sums the day instead of taking the latest row like HR/sleep above.
SWIM=$(sqlite3 "$DB" \
  "SELECT ROUND(SUM(qty), 0) FROM health_metrics
   WHERE metric_name='swimming_distance' AND substr(date,1,10)='$YDAY';" 2>>"$LOG") || SWIM=""

SWIM_UNIT=$(sqlite3 "$DB" \
  "SELECT unit FROM health_metrics
   WHERE metric_name='swimming_distance' AND substr(date,1,10)='$YDAY' LIMIT 1;" 2>>"$LOG") || SWIM_UNIT=""

SWIM_STR=""
if [ -n "$SWIM" ] && awk -v v="$SWIM" 'BEGIN{exit !(v>0)}'; then
  SWIM_STR="${SWIM%.*}${SWIM_UNIT:+ $SWIM_UNIT}"
fi

if [ -z "$SLEEP_STR" ] && [ -z "$HR_STR" ]; then
  echo "_Сон и пульс покоя: нет данных за $YDAY (WP-470 в процессе)_"
  exit 0
fi

OUT="**Сон:** ${SLEEP_STR:-нет данных} | **Пульс покоя:** ${HR_STR:-нет данных}"
[ -n "$SWIM_STR" ] && OUT="$OUT | **Плавание:** ${SWIM_STR}"
echo "$OUT"
