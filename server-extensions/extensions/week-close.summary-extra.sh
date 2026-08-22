#!/bin/bash
# Extension hook for Week Close (extensions/week-close.after.health.md).
# Prints only a value-free pointer for WeekReport.
# Author-only: sources personal health data (WP-470), not shipped in FMT-exocortex-template.
#
# Residency (WP-469): WeekReport is git-tracked. Health values stay in health.db
# and are recomputed locally on demand; stdout must never contain metric values.
#
# Usage: week-close.summary-extra.sh YYYY-MM-DD YYYY-MM-DD  (week start, week end — Mon..Sun)
set -euo pipefail

WEEK_START="${1:?usage: week-close.summary-extra.sh YYYY-MM-DD_start YYYY-MM-DD_end}"
WEEK_END="${2:?usage: week-close.summary-extra.sh YYYY-MM-DD_start YYYY-MM-DD_end}"
DB="$HOME/Library/IWE/health-data/health.db"
LOG="$HOME/IWE/DS-my-strategy/logs/day-open-summary-extra.err.log"

mkdir -p "$(dirname "$LOG")"

if [ ! -f "$DB" ]; then
  echo "$(date -u +%FT%TZ) WEEK=$WEEK_START..$WEEK_END: health.db отсутствует по пути $DB" >>"$LOG"
  echo "_Здоровье (РП-470): нет данных за $WEEK_START..$WEEK_END — health.db не найден_"
  exit 0
fi

echo "_Здоровье (РП-470): данные за $WEEK_START..$WEEK_END хранятся локально вне git — \`~/Library/IWE/health-data/health.db\` (резидентность WP-469; значения в WeekReport не публикуются)_"
