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
# Validation happens at write time (allowed step_id, monotonic), never blocks —
# anomalies go to a separate integrity log. day-close step 11 (R23) reads both
# logs and marks the day's metric untrustworthy on any anomaly, but does not
# block the closure itself. Postponing the check to "reconstruct a plausible
# timestamp at the end" was considered and rejected — that produces a synthetic
# distribution that looks real, which is exactly the "нет данных → явный
# маркер, никогда тихая подмена" invariant this WP was built around.
#
# Attempts (peer-session 2026-08-21-02-day-close-anomaly-classes, F2):
# every start gets a unique attempt_id, every end carries closes_attempt_id.
# A repeated start with an unclosed previous attempt first appends an explicit
# `end ... action=abandoned` for that attempt — restart after a crashed close
# is a normal scenario, not an integrity anomaly, and the starts==ends
# invariant survives verbatim. All read-check-append sequences run under a
# lock so two concurrent closers cannot interleave attempt state.
#
# Usage:
#   day-close-step-log.sh start <step_id>
#   day-close-step-log.sh end <step_id>

set -euo pipefail
export TZ=UTC

ALLOWED_STEPS="0.5 0.6 2a 2b 2c 2d 2g 3 4b 4v 4-lessons 5 5b 6 9a 9b 10 11"

LOG_DIR="$HOME/logs"
STEPS_LOG="$LOG_DIR/day-close-steps.log"
INTEGRITY_LOG="$LOG_DIR/day-close-integrity.log"
STATE_DIR="$LOG_DIR/.day-close-step-state"
LOCK_FILE="$STATE_DIR/.lock"

usage() {
  echo "Использование: day-close-step-log.sh start|end <step_id>" >&2
  echo "Разрешённые step_id: $ALLOWED_STEPS" >&2
  exit 1
}

# Внутренний вход: тело под уже взятым flock (см. run_locked). Форма с тремя
# аргументами — пропускаем обычный разбор, диспетчер внизу файла (после
# определения locked_body).
if [ "${1:-}" = "--locked-body" ]; then
  [ $# -eq 3 ] || usage
  ACTION="$2"
  STEP_ID="$3"
else
  [ $# -eq 2 ] || usage
  ACTION="$1"
  STEP_ID="$2"
fi

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
  echo "$(date "+%Y-%m-%d %H:%M:%S") | day-close-integrity | step=$STEP_ID action=$ACTION | $1" >> "$INTEGRITY_LOG"
}

# flock на macOS — из homebrew, на Linux — штатный; shlock — запасной путь BSD.
# Без обоих продолжаем без блокировки: потеря — гонка attempt-строк в логе,
# не данные пользователя; такой degrade честнее, чем отказ логирования.
run_locked() {
  if command -v flock >/dev/null 2>&1; then
    flock "$LOCK_FILE" "$0" --locked-body "$ACTION" "$STEP_ID"
    exit $?
  elif command -v shlock >/dev/null 2>&1; then
    # Отдельный путь от flock-файла: shlock хранит PID и откажется от чужого
    # содержимого flock-файла; общий путь превращал бы смену механизма в тихий
    # отказ блокировки (review-01 Medium).
    local shlock_file="$LOCK_FILE.shlock"
    local lock_acquired=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if shlock -f "$shlock_file" -p $$ 2>/dev/null; then lock_acquired=1; break; fi
      sleep 0.2
    done
    if [ "$lock_acquired" = "1" ]; then
      trap 'rm -f "$shlock_file"' EXIT
      locked_body "$ACTION" "$STEP_ID"
      exit $?
    fi
    log_integrity "shlock не взят за 2с — запись без блокировки (degrade)"
  else
    log_integrity "ни flock, ни shlock недоступны — запись без блокировки (degrade)"
  fi
  locked_body "$ACTION" "$STEP_ID"
  exit $?
}

locked_body() {
  local action="$1" step_id="$2"
  local now_ts now_human attempt_id prev_ts prev_attempt
  now_ts="$(date +%s)"
  now_human="$(date "+%Y-%m-%d %H:%M:%S")"

  # review-01 Medium: allowed-проверка живёт здесь — единственном месте, под
  # lock; раньше внешний вызов и --locked-body делали её оба (двойная
  # integrity-запись, первая — вне lock).
  is_allowed_step || log_integrity "unknown step_id (not in allowed list)"

  if [ "$action" = "start" ]; then
    if [ -f "$STATE_FILE" ]; then
      # Незакрытая попытка: фиксируем abandoned end ДО нового start, чтобы
      # starts==ends держался буквально, а первая попытка не терялась из истории.
      prev_ts="$(cut -d' ' -f1 "$STATE_FILE")"
      prev_attempt="$(cut -d' ' -f2- "$STATE_FILE")"
      # Legacy state (до attempt-формата) хранит только ts; битый файл не должен
      # ронять логирование под set -e — duration тогда честно unknown.
      case "$prev_ts" in
        ''|*[!0-9]*) prev_dur="unknown" ;;
        *) prev_dur="abandoned-after-$((now_ts - prev_ts))s" ;;
      esac
      echo "$now_human | day-close-steps | end $step_id | ts=$now_ts | action=abandoned | closes_attempt_id=${prev_attempt:-legacy} | duration=$prev_dur" >> "$STEPS_LOG"
      rm -f "$STATE_FILE"
    fi
    attempt_id="$(uuidgen)"
    echo "$now_ts $attempt_id" > "$STATE_FILE"
    echo "$now_human | day-close-steps | start $step_id | ts=$now_ts | attempt_id=$attempt_id" >> "$STEPS_LOG"
    return 0
  fi

  # action = end
  if [ ! -f "$STATE_FILE" ]; then
    log_integrity "end without a matching start"
    echo "$now_human | day-close-steps | end $step_id | ts=$now_ts | closes_attempt_id=unknown | duration=unknown(no-start)" >> "$STEPS_LOG"
    return 0
  fi

  prev_ts="$(cut -d' ' -f1 "$STATE_FILE")"
  prev_attempt="$(cut -d' ' -f2- "$STATE_FILE")"
  case "$prev_ts" in
    ''|*[!0-9]*)
      log_integrity "corrupt state file (non-numeric start ts)"
      echo "$now_human | day-close-steps | end $step_id | ts=$now_ts | closes_attempt_id=${prev_attempt:-unknown} | duration=unknown(corrupt-state)" >> "$STEPS_LOG"
      ;;
    *)
      if [ "$now_ts" -lt "$prev_ts" ]; then
        log_integrity "non-monotonic: end ts ($now_ts) earlier than start ts ($prev_ts)"
        echo "$now_human | day-close-steps | end $step_id | ts=$now_ts | closes_attempt_id=$prev_attempt | duration=non-monotonic" >> "$STEPS_LOG"
      else
        echo "$now_human | day-close-steps | end $step_id | ts=$now_ts | closes_attempt_id=$prev_attempt | duration=$((now_ts - prev_ts))s" >> "$STEPS_LOG"
      fi
      ;;
  esac
  rm -f "$STATE_FILE"
}

if [ "${1:-}" = "--locked-body" ]; then
  # Внутренний вход: тело под уже взятым flock (см. run_locked).
  locked_body "$2" "$3"
  exit $?
fi

run_locked "$ACTION" "$STEP_ID"
