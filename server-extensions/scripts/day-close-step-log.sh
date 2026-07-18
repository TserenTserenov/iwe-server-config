#!/bin/bash
# day-close-step-log.sh — dc_start/dc_end boundary logging for Day Close (WP-484).
#
# Peer-session 2026-07-18-13: day-close.sh only times 1 of ~20 protocol steps
# (backup/reindex/linear/sessions) — the real weight is in the governance batch
# (2a-2g) and the multiplier step (6), which have never been measured. This
# script gives those steps real wall-clock data without adding a new blocking
# gate to the ritual itself — history of this WP (git-lock 17.07, checklist
# false-positive 18.07) shows new hard gates around day-close create new
# failure modes more often than they prevent them.
#
# Validation happens at write time (allowed step_id, monotonic, no duplicate
# start), never blocks — anomalies go to a separate integrity log. day-close
# step 11 (R23) reads both logs and marks the day's metric untrustworthy on
# any anomaly, but does not block the closure itself. Postponing the check to
# "reconstruct a plausible timestamp at the end" was considered and rejected —
# that produces a synthetic distribution that looks real, which is exactly
# the "нет данных → явный маркер, никогда тихая подмена" invariant this WP
# was built around.
#
# Usage:
#   day-close-step-log.sh start <step_id>
#   day-close-step-log.sh end <step_id>

set -euo pipefail
export TZ=UTC

ALLOWED_STEPS="0.5 0.6 2a 2b 2c 2d 2g 3 4b 4v 4-lessons 5 6 9a 9b 10 11"

LOG_DIR="$HOME/logs"
STEPS_LOG="$LOG_DIR/day-close-steps.log"
INTEGRITY_LOG="$LOG_DIR/day-close-integrity.log"
STATE_DIR="$LOG_DIR/.day-close-step-state"

usage() {
  echo "Использование: day-close-step-log.sh start|end <step_id>" >&2
  echo "Разрешённые step_id: $ALLOWED_STEPS" >&2
  exit 1
}

[ $# -eq 2 ] || usage
ACTION="$1"
STEP_ID="$2"

case "$ACTION" in
  start|end) ;;
  *) usage ;;
esac

# step_id used verbatim in a file path below — reject path-breaking characters
# up front (defense-in-depth; all real callers in day-close/SKILL.md are static
# strings, but a typo'd "2g/../.." should fail loud, not write outside STATE_DIR).
case "$STEP_ID" in
  */*|*..*|"") usage ;;
esac

mkdir -p "$LOG_DIR" "$STATE_DIR"

NOW_TS="$(date +%s)"
NOW_HUMAN="$(date "+%Y-%m-%d %H:%M:%S")"
# Не датой в имени: шаг, чей start пришёлся на 23:59, а end — на 00:01 следующих
# суток, иначе не найдёт свой файл состояния (найдено ревью 18.07) — start/end
# внутри одного прогона closer'а всегда парные по step_id, дата не нужна для
# поиска, только для записи в логи ниже.
STATE_FILE="$STATE_DIR/$STEP_ID.start"

is_allowed_step() {
  for s in $ALLOWED_STEPS; do
    [ "$s" = "$STEP_ID" ] && return 0
  done
  return 1
}

log_integrity() {
  echo "$NOW_HUMAN | day-close-integrity | step=$STEP_ID action=$ACTION | $1" >> "$INTEGRITY_LOG"
}

is_allowed_step || log_integrity "unknown step_id (not in allowed list)"

if [ "$ACTION" = "start" ]; then
  if [ -f "$STATE_FILE" ]; then
    log_integrity "duplicate start without matching end (previous start overwritten)"
  fi
  echo "$NOW_TS" > "$STATE_FILE"
  echo "$NOW_HUMAN | day-close-steps | start $STEP_ID | ts=$NOW_TS" >> "$STEPS_LOG"
  exit 0
fi

# ACTION = end
if [ ! -f "$STATE_FILE" ]; then
  log_integrity "end without a matching start"
  echo "$NOW_HUMAN | day-close-steps | end $STEP_ID | ts=$NOW_TS | duration=unknown(no-start)" >> "$STEPS_LOG"
  exit 0
fi

START_TS="$(cat "$STATE_FILE")"
if [ "$NOW_TS" -lt "$START_TS" ]; then
  log_integrity "non-monotonic: end ts ($NOW_TS) earlier than start ts ($START_TS)"
  echo "$NOW_HUMAN | day-close-steps | end $STEP_ID | ts=$NOW_TS | duration=non-monotonic" >> "$STEPS_LOG"
else
  echo "$NOW_HUMAN | day-close-steps | end $STEP_ID | ts=$NOW_TS | duration=$((NOW_TS - START_TS))s" >> "$STEPS_LOG"
fi
rm -f "$STATE_FILE"
