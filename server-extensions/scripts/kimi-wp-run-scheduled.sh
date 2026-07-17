#!/usr/bin/env bash
# see DP.SC.192, DP.ROLE.086 — WP-487
#
# kimi-wp-run-scheduled.sh <id> — исполнитель отложенного запуска РП.
# Вызывается launchd в заданное время. Шаги:
#   1. прочитать задание из queue.tsv
#   2. session-guard open → preflight (kimi) → headless-запуск агента под таймаутом
#   3. статус (done/failed/timeout) → report.md + queue.tsv
#   4. session-guard close, самоудаление одноразовой задачи launchd
#
# Предохранитель токенов: wall-clock таймаут (perl alarm, default 50 мин) +
# --max-turns у claude. Падение одного РП не влияет на остальную очередь.

set -uo pipefail  # без -e: любой сбой должен завершаться отчётом, а не тихой смертью

ID="${1:-}"
[ -n "$ID" ] || { echo "ERROR: usage: kimi-wp-run-scheduled.sh <id>" >&2; exit 1; }

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
QUEUE_DIR="$IWE_ROOT/.iwe-runtime/wp-queue"
QUEUE_FILE="$QUEUE_DIR/queue.tsv"
LOG_DIR="$IWE_ROOT/.iwe-runtime/logs/wp-queue"
PLIST="$HOME/Library/LaunchAgents/ai.iwe.wp-queue.$ID.plist"
LABEL="ai.iwe.wp-queue.$ID"
LOG="$LOG_DIR/$ID.log"
REPORT="$LOG_DIR/report.md"

mkdir -p "$LOG_DIR"
cd "$IWE_ROOT" || exit 1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# --- прочитать задание ------------------------------------------------------
ROW=$(grep "^$ID"$'\t' "$QUEUE_FILE" || true)
[ -n "$ROW" ] || { log "ERROR: id $ID not found in queue.tsv"; exit 1; }
WP=$(echo "$ROW" | cut -f3)
AGENT=$(echo "$ROW" | cut -f4)
TIMEOUT_MIN=$(echo "$ROW" | cut -f5)
MAX_TURNS=$(echo "$ROW" | cut -f6)
TIMEOUT_SEC=$(( TIMEOUT_MIN * 60 ))

set_status() {  # set_status <new-status>
  local tmp; tmp=$(mktemp)
  awk -F'\t' -v OFS='\t' -v id="$ID" -v st="$1" '$1==id {$7=st} {print}' "$QUEUE_FILE" > "$tmp" && mv "$tmp" "$QUEUE_FILE"
}

cleanup() {  # выгрузить и удалить одноразовую задачу launchd
  # ВАЖНО: unload собственной задачи посылает SIGTERM текущему процессу —
  # поэтому сначала удаляем plist, unload делаем ПОСЛЕДНИМ действием скрипта.
  rm -f "$PLIST"
  launchctl remove "$LABEL" >/dev/null 2>&1 || true
}

report_line() {  # report_line <status> <note>
  printf -- '- **%s** `%s` — %s via %s: **%s** (%s). Лог: `.iwe-runtime/logs/wp-queue/%s.log`\n' \
    "$(date '+%Y-%m-%d %H:%M')" "$ID" "$WP" "$AGENT" "$1" "$2" "$ID" >> "$REPORT"
}

log "=== scheduled run $ID: $WP via $AGENT (timeout ${TIMEOUT_MIN}m) ==="
set_status running

# --- dry-run (тестовый режим: не запускает LLM, проверяет launchd+plumbing) ---
if [ "${IWE_WP_QUEUE_DRYRUN:-0}" = "1" ]; then
  log "DRY-RUN: simulating agent run (no LLM call)"
  sleep 2
  set_status done-dryrun
  report_line done-dryrun "dry-run, no LLM call"
  log "=== done: $ID (done-dryrun) ==="
  cleanup  # последнее действие: unload убивает текущий процесс
  exit 0
fi

# --- session-guard open -----------------------------------------------------
IS_TASK=0
[[ "$WP" =~ ^TASK- ]] && IS_TASK=1
if [ "$IS_TASK" = "1" ]; then
  # задача без РП: housekeeping-сессия (без ORZ, без WP Gate)
  if ! bash "$IWE_ROOT/scripts/session-guard.sh" open --housekeeping "sched-$ID" --agent "$AGENT" >>"$LOG" 2>&1; then
    log "ERROR: session-guard open (housekeeping) failed"
    set_status failed; report_line failed "session-guard open failed"; cleanup; exit 1
  fi
  [ -f "$QUEUE_DIR/$ID.prompt" ] || { log "ERROR: TASK without prompt file"; set_status failed; report_line failed "TASK without prompt"; bash "$IWE_ROOT/scripts/session-guard.sh" close --housekeeping "sched-$ID" --agent "$AGENT" >>"$LOG" 2>&1; cleanup; exit 1; }
  PROMPT_FILE="$QUEUE_DIR/$ID.prompt"
elif ! bash "$IWE_ROOT/scripts/session-guard.sh" open \
      --wp "$WP" --task "Scheduled run ($ID)" --slug "sched-$ID" \
      --files "DS-my-strategy/inbox/$WP/$WP.md" --agent "$AGENT" >>"$LOG" 2>&1; then
  log "ERROR: session-guard open failed"
  set_status failed; report_line failed "session-guard open failed"; cleanup; exit 1
fi

# --- промпт -----------------------------------------------------------------
if [ "$IS_TASK" != "1" ]; then
PROMPT_FILE="$QUEUE_DIR/$ID.prompt"
if [ ! -f "$PROMPT_FILE" ]; then
  PROMPT_FILE=$(mktemp)
  cat > "$PROMPT_FILE" <<EOF
Автономный запуск по расписанию (планировщик WP-487, DP.SC.192). WP Gate для этого РП уже согласован пилотом заранее — Ритуал согласования не требуется, работай сразу.

Задача: выполни рабочий продукт $WP. Первым делом прочитай контекст: ~/IWE/DS-my-strategy/inbox/$WP/$WP.md. Иерархия доверия: код → документы → WP context.

Правила автономного прогона:
- Работай только по этому РП, не начинай других задач.
- Если заблокирован решением пилота — запиши blocker в frontmatter контекст-файла РП (DS-my-strategy/inbox/$WP/$WP.md) и завершись, не жди.
- Git: стейджь только конкретные свои файлы (никаких git add -A/-u/.), trailer Co-Authored-By по своему агенту.
- Не начинай операций, которые могут не уложиться в оставшееся время — тебя принудительно завершат по таймауту.
- По завершении обнови статус фаз в frontmatter контекст-файла РП и запиши краткий итог в ORZ сессии.
EOF
fi
fi  # IS_TASK

# --- запуск агента под таймаутом --------------------------------------------
RC=0
case "$AGENT" in
  kimi)
    KIMI_BIN="$(command -v kimi 2>/dev/null || true)"
    if [ -z "$KIMI_BIN" ]; then
      for c in "$HOME/Library/Application Support/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi"; do
        [ -x "$c" ] && KIMI_BIN="$c" && break
      done
    fi
    if [ -z "$KIMI_BIN" ]; then
      log "ERROR: kimi binary not found"
      set_status failed; report_line failed "kimi binary not found"
      bash "$IWE_ROOT/scripts/session-guard.sh" close --agent "$AGENT" >>"$LOG" 2>&1
      cleanup; exit 1
    fi
    # preflight: проверяет, что сессия открыта (мы только что открыли)
    bash "$IWE_ROOT/scripts/kimi-standalone-preflight.sh" >>"$LOG" 2>&1 || log "WARN: preflight non-zero, continuing"
    # OAuth-refresh lockf — сериализация параллельных kimi (паттерн из kimi-peer-adapter.sh)
    LOCK_DIR="/tmp/kimi-peer-locks"; mkdir -p "$LOCK_DIR"
    LOCKF_PREFIX=()
    command -v lockf >/dev/null 2>&1 && LOCKF_PREFIX=(lockf -k -t 90 "$LOCK_DIR/kimi-oauth-refresh.lock")
    log "starting kimi (timeout ${TIMEOUT_SEC}s, max-steps 100)"
    "${LOCKF_PREFIX[@]+"${LOCKF_PREFIX[@]}"}" perl -e 'my $t=shift; alarm $t; exec @ARGV' -- "$TIMEOUT_SEC" \
      "$KIMI_BIN" --quiet --yolo --max-steps-per-turn "${IWE_WP_QUEUE_MAX_STEPS:-100}" < "$PROMPT_FILE" >>"$LOG" 2>&1
    RC=$?
    ;;
  claude)
    CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
    if [ -z "$CLAUDE_BIN" ]; then
      log "ERROR: claude binary not found"
      set_status failed; report_line failed "claude binary not found"
      bash "$IWE_ROOT/scripts/session-guard.sh" close --agent "$AGENT" >>"$LOG" 2>&1
      cleanup; exit 1
    fi
    log "starting claude (timeout ${TIMEOUT_SEC}s, max-turns $MAX_TURNS)"
    perl -e 'my $t=shift; alarm $t; exec @ARGV' -- "$TIMEOUT_SEC" \
      "$CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" --max-turns "$MAX_TURNS" --dangerously-skip-permissions >>"$LOG" 2>&1
    RC=$?
    ;;
  *)
    log "ERROR: unknown agent $AGENT"; RC=1 ;;
esac

# --- результат ---------------------------------------------------------------
case "$RC" in
  0)   STATUS=done;    NOTE="exit 0" ;;
  142|124) STATUS=timeout; NOTE="killed by ${TIMEOUT_MIN}m timeout (exit $RC)" ;;
  *)   STATUS=failed;  NOTE="exit $RC" ;;
esac
log "finished: $STATUS (exit $RC)"
set_status "$STATUS"
report_line "$STATUS" "$NOTE"

# --- session-guard close + самоудаление задачи -------------------------------
if [ "$IS_TASK" = "1" ]; then
  bash "$IWE_ROOT/scripts/session-guard.sh" close --housekeeping "sched-$ID" --agent "$AGENT" >>"$LOG" 2>&1 || log "WARN: session-guard close non-zero"
else
  bash "$IWE_ROOT/scripts/session-guard.sh" close --agent "$AGENT" >>"$LOG" 2>&1 || log "WARN: session-guard close non-zero"
fi
[ -f "$QUEUE_DIR/$ID.prompt" ] && rm -f "$QUEUE_DIR/$ID.prompt"
log "=== done: $ID ($STATUS) ==="
cleanup  # последнее действие: unload убивает текущий процесс
exit 0
