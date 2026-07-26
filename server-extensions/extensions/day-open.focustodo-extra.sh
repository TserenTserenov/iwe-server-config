#!/bin/bash
# Extension hook for render_yesterday() (scripts/day-open-scaffold.sh) — glob
# `day-open.*-extra.sh` (WP-470 26.07, системный фикс), не жёстко зашитое имя.
# L1 calls every executable day-open.*-extra.sh it finds; prints nothing if this
# file doesn't exist or isn't executable.
# Author-only: sources personal Focus To-Do data (WP-470), not shipped in
# FMT-exocortex-template.
#
# Same stdout-empty residency rule as day-open.summary-extra.sh (health, WP-469
# retrofit-audit 2026-07-24): DayPlan is git-tracked and pushed to GitHub — the
# daily summary goes to a local non-git file instead.
#
# Source format: single JSON export file written by a separate tool (staged
# 2026-07-26, not installed on this Mac yet — see WP-470.md "Focus To-Do"),
# expected shape = the `gyozalab/focustodo-mcp` SyncResponse (verified against
# upstream src/types.ts 2026-07-26):
#   { "pomodoros": [{ "taskId", "interval" (seconds), "endDate" (epoch ms), ... }],
#     "tasks":     [{ "id", "name", "projectId", "isFinished", ... }] }
# No export yet on this Mac → this hook logs and exits silently (same contract
# as health hook when health.db is missing).
set -euo pipefail

YDAY="${1:?usage: day-open.focustodo-extra.sh YYYY-MM-DD}"
EXPORT_DIR="$HOME/.local/share/iwe/focustodo-exports"
LOG="$HOME/IWE/DS-my-strategy/logs/day-open-summary-extra.err.log"
SUMMARY_DIR="$HOME/Library/IWE/focustodo-data/day-summaries"

mkdir -p "$(dirname "$LOG")" "$EXPORT_DIR"

EXPORT_FILE=$(find "$EXPORT_DIR" -maxdepth 1 -name 'export-*.json' 2>/dev/null | sort | tail -1)
if [ -z "$EXPORT_FILE" ]; then
  echo "$(date -u +%FT%TZ) YDAY=$YDAY: нет экспорта Focus To-Do в $EXPORT_DIR" >>"$LOG"
  exit 0
fi

OUT=$(python3 - "$EXPORT_FILE" "$YDAY" <<'PYEOF'
import json
import sys
from datetime import datetime, timedelta, timezone

export_file, yday = sys.argv[1], sys.argv[2]
day_start = datetime.strptime(yday, "%Y-%m-%d").replace(tzinfo=timezone.utc)
day_end = day_start + timedelta(days=1)
lo_ms, hi_ms = int(day_start.timestamp() * 1000), int(day_end.timestamp() * 1000)

with open(export_file, encoding="utf-8") as f:
    data = json.load(f)

pomos = [p for p in data.get("pomodoros", []) if lo_ms <= p.get("endDate", 0) < hi_ms]
if not pomos:
    print("")
    sys.exit(0)

focus_sec = sum(p.get("interval", 0) for p in pomos)
h, m = divmod(focus_sec // 60, 60)
print(f"**Фокус (Focus To-Do):** {h}ч {m}м, {len(pomos)} помидор{'ов' if len(pomos) != 1 else ''}")
PYEOF
) || { echo "$(date -u +%FT%TZ) YDAY=$YDAY: ошибка чтения экспорта $EXPORT_FILE" >>"$LOG"; exit 0; }

if [ -z "$OUT" ]; then
  echo "$(date -u +%FT%TZ) YDAY=$YDAY: нет помидоров за этот день в $EXPORT_FILE" >>"$LOG"
  exit 0
fi

mkdir -p "$SUMMARY_DIR"
printf '%s\n' "$OUT" >"$SUMMARY_DIR/$YDAY.md"
