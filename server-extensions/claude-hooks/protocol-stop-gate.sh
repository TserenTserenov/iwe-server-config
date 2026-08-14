#!/bin/bash
# protocol-stop-gate.sh
# see DP.SC.025 (capture-bus), DP.SC.026 (мониторинг поведения), WP-229 Ф4
# Event: Stop
# Проверяет: если в сессии был вызов Skill (day-open|day-close|run-protocol|wp-new),
# то должен быть TodoWrite с ≥3 items. Иначе — block.
# Принцип warn-before-block: action=warn (промоция в block после 2 нед обкатки).
#
# Защита от infinite loop: переменная STOP_HOOK_ACTIVE.
# Read-only кроме gate_log.jsonl.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# --- WP-265 Ф5.2: cleanup dry-run sentinel on session end ---
if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    rm -f "/tmp/iwe-dry-run-${CLAUDE_SESSION_ID}.flag" 2>/dev/null || true
fi

# --- Infinite loop guard ---
if [ "${STOP_HOOK_ACTIVE:-}" = "1" ]; then
  echo '{}'
  exit 0
fi
export STOP_HOOK_ACTIVE=1

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  echo '{}'
  exit 0
fi

TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# Нет транскрипта — пропустить
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  echo '{}'
  exit 0
fi

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "${HOOK_DIR}/.." && pwd)"
# shellcheck source=../lib/iwe-env-bootstrap.sh
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" || exit 1
GATE_LOG="$IWE_ROOT/.claude/logs/gate_log.jsonl"
mkdir -p "$(dirname "$GATE_LOG")" 2>/dev/null || true

# --- WP-484 Ф74б (07.08.2026): автомат обязательства Quick Close ---
# Проверка ДО раннего выхода по «протокольный скилл не запускался»: рецидив
# 07.08 — Quick Close полностью в обход раннера — был именно сессией без
# протокольного скилла. Матрица состояний — в close_obligation.py stop-check
# (консенсус пир-сессии 2026-08-07-08, ход 4-6).
#
# Fail-closed: любой nonzero / невалидный JSON / отсутствующий CLI при наличии
# close-intent sentinel или close-obligation трактуется как block. Ветки warn/note
# НЕ делают ранний exit — контекст obligation сохраняется и дополняет итоговое
# решение protocol-skill/TodoWrite проверок.
OBLIGATION_CTX=""
OBLIGATION_ACTION=""
OBLIGATION_REASON=""
OBLIGATION_NOTE=""
OBLIGATION_CLI="$IWE_ROOT/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/scripts/close_obligation.py"
if [ -n "$SESSION_ID" ] && [ -f "$OBLIGATION_CLI" ]; then
  OBLIGATION_RC=0
  OBLIGATION_JSON=$(python3 "$OBLIGATION_CLI" stop-check --session-id "$SESSION_ID" 2>/dev/null) || OBLIGATION_RC=$?
  if [ "$OBLIGATION_RC" -ne 0 ] || [ -z "$OBLIGATION_JSON" ]; then
    # Fail-closed: CLI error/unparseable. Блокируем только если есть close-intent или obligation.
    CLOSE_INTENT_SENTINEL="/tmp/iwe-close-intent/${SESSION_ID}.flag"
    OBLIGATION_HASH=$(printf '%s' "$SESSION_ID" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:32])' 2>/dev/null)
    OBLIGATION_FILE="$IWE_RUNTIME/close-obligation/${OBLIGATION_HASH}.json"
    if [ -f "$CLOSE_INTENT_SENTINEL" ] || [ -f "$OBLIGATION_FILE" ]; then
      OBLIGATION_ACTION="block"
      OBLIGATION_REASON="close_obligation.py unavailable, returned rc=$OBLIGATION_RC or invalid output while close intent/obligation exists"
    fi
  else
    OBLIGATION_ACTION=$(printf '%s' "$OBLIGATION_JSON" | jq -r '.action // empty' 2>/dev/null)
    OBLIGATION_REASON=$(printf '%s' "$OBLIGATION_JSON" | jq -r '.reason // empty' 2>/dev/null)
    OBLIGATION_NOTE=$(printf '%s' "$OBLIGATION_JSON" | jq -r '.note // empty' 2>/dev/null)
  fi

  if [ "$OBLIGATION_ACTION" = "block" ]; then
    jq -nc --arg reason "🚫 CLOSE-OBLIGATION (Ф74б): ${OBLIGATION_REASON:-обязательство Quick Close не выполнено}" \
      '{decision: "block", reason: $reason}'
    exit 0
  fi
  if [ "$OBLIGATION_ACTION" = "warn" ]; then
    OBLIGATION_CTX="⚠️ CLOSE-OBLIGATION [warn] (Ф74б): ${OBLIGATION_REASON} — упомяни это предупреждение в ответе пилоту явно."
  elif [ -n "$OBLIGATION_NOTE" ]; then
    OBLIGATION_CTX="CLOSE-OBLIGATION (Ф74б): $OBLIGATION_NOTE"
  fi
fi

# --- Шаг 1: был ли вызов протокольного скилла? ---
PROTOCOL_SKILL=$(jq -r '
  select(.type == "tool_use" and .name == "Skill")
  | .input.skill // empty
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | grep -E '^(day-open|day-close|run-protocol|wp-new)$' \
  | head -1)

if [ -z "$PROTOCOL_SKILL" ]; then
  # Протокольный скилл не запускался — gate не нужен, но если есть контекст
  # обязательства (note/warn), его всё равно нужно передать пилоту.
  if [ -n "$OBLIGATION_CTX" ]; then
    jq -nc --arg ctx "$OBLIGATION_CTX" '{additionalContext: $ctx}'
  else
    echo '{}'
  fi
  exit 0
fi

# --- Шаг 2: был ли TodoWrite с ≥3 items? ---
TODO_MAX=$(jq -r '
  select(.type == "tool_use" and .name == "TodoWrite")
  | .input.todos
  | if type == "array" then length else 0 end
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | sort -n | tail -1)

TODO_MAX="${TODO_MAX:-0}"
THRESHOLD=3

# --- Шаг 3: логировать событие ---
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FIRED=0
if [ "$TODO_MAX" -lt "$THRESHOLD" ]; then
  FIRED=1
fi

LOG_ENTRY=$(jq -nc \
  --arg ts "$TIMESTAMP" \
  --arg sid "$SESSION_ID" \
  --arg skill "$PROTOCOL_SKILL" \
  --arg todo_max "$TODO_MAX" \
  --arg threshold "$THRESHOLD" \
  --arg fired "$FIRED" \
  '{ts: $ts, gate: "protocol-stop-gate", session_id: $sid, skill: $skill,
    todo_max: ($todo_max|tonumber), threshold: ($threshold|tonumber),
    fired: ($fired == "1"), action: "warn",
    pattern: "P9"}' 2>/dev/null || true)

if [ -n "$LOG_ENTRY" ]; then
  echo "$LOG_ENTRY" >> "$GATE_LOG" 2>/dev/null || true
fi

# --- Шаг 4: формировать итоговое решение ---
# Всегда объединяем с контекстом обязательства, если он есть. Если protocol fired,
# возвращаем decision:block; если obligation дал warn/note, добавляем additionalContext.
if [ "$FIRED" = "1" ]; then
  PROTOCOL_REASON="⚠️ PROTOCOL-STOP-GATE [warn]: Скилл '$PROTOCOL_SKILL' был вызван, но TodoWrite с ≥$THRESHOLD задачами не найден (найдено: $TODO_MAX). Протокол требует таск-лист ДО начала исполнения. Действие: создай TodoWrite с шагами скилла и пройди протокол заново. (gate_log: $GATE_LOG)"
  if [ -n "$OBLIGATION_CTX" ]; then
    jq -nc \
      --arg reason "$PROTOCOL_REASON" \
      --arg ctx "$OBLIGATION_CTX" \
      '{decision: "block", reason: $reason, additionalContext: $ctx}'
  else
    cat <<EOF
{"decision": "block", "reason": "$PROTOCOL_REASON"}
EOF
  fi
else
  if [ -n "$OBLIGATION_CTX" ]; then
    jq -nc --arg ctx "$OBLIGATION_CTX" '{additionalContext: $ctx}'
  else
    echo '{}'
  fi
fi

exit 0
