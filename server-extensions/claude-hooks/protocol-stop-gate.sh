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

# lower_text: Unicode-safe lowercasing (GNU tr does not fold Cyrillic); tr if the lib is absent.
. "${BASH_SOURCE[0]%/*}/lib/text-lower.sh" 2>/dev/null || lower_text() { tr '[:upper:]' '[:lower:]'; }
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

# A Stop hook's feedback triggers another Stop event. Suppress advisory context
# on that follow-up, while still evaluating real blocking gates below.
STOP_FEEDBACK_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)

TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
# Fallback (WP-484 Ф148, same defect class as close-runner-gate.sh/
# close-gate-reminder.sh, bug-2026-08-31-close-runner-gate-empty-session-id-
# breaks-witness-mapping): an empty Stop-event .session_id used to skip the
# ENTIRE close-obligation check below (`[ -n "$SESSION_ID" ]` at the guard just
# past this block) -- silently letting a session end while an obligation is
# still armed, which is the exact failure this Ф74б chain exists to prevent.
# close_obligation.py's own _validated_name() still rejects a malformed value
# downstream (cmd_stop_check), so no extra charset check is duplicated here.
[ -z "$SESSION_ID" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && SESSION_ID="$CLAUDE_CODE_SESSION_ID"

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
# F228: serialize this entire producer with release, including sentinel writes
# outside close_obligation. An inherited FD is checked, never just an env flag.
LOCAL_RELEASE_CLI="$IWE_ROOT/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/scripts/session_local_release.py"
if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != unknown ] && [ -f "$LOCAL_RELEASE_CLI" ]; then
  if ! IWE_ROOT="$IWE_ROOT" python3 "$LOCAL_RELEASE_CLI" hook-check --agent claude-code --harness-session-id "$SESSION_ID" >/dev/null 2>&1; then
    printf '%s' "$INPUT" | IWE_ROOT="$IWE_ROOT" python3 "$LOCAL_RELEASE_CLI" hook \
      --agent claude-code --harness-session-id "$SESSION_ID" --event Stop -- bash "$0"
    exit $?
  fi
fi

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
    # CLOSE_INTENT_SENTINEL embeds SESSION_ID directly in a path (path
    # traversal, same class as f8a8596d1, WP-484) -- OBLIGATION_FILE below
    # does not need the same guard, it's keyed by a sha256 hex digest of
    # SESSION_ID, which is always a safe charset regardless of input.
    CLOSE_INTENT_SENTINEL=""
    case "$SESSION_ID" in
      *[!A-Za-z0-9._-]*) : ;;
      *) CLOSE_INTENT_SENTINEL="/tmp/iwe-close-intent/${SESSION_ID}.flag" ;;
    esac
    OBLIGATION_HASH=$(printf '%s' "$SESSION_ID" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:32])' 2>/dev/null)
    OBLIGATION_FILE="${IWE_RUNTIME_DIR:-$IWE_ROOT/.iwe-runtime}/close-obligation/${OBLIGATION_HASH}.json"   # same dir close_obligation.py writes; IWE_RUNTIME is the host name
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
  if [ "$STOP_FEEDBACK_ACTIVE" = "true" ]; then
    OBLIGATION_CTX=""
  elif [ "$OBLIGATION_ACTION" = "warn" ]; then
    OBLIGATION_CTX="⚠️ CLOSE-OBLIGATION [warn] (Ф74б): ${OBLIGATION_REASON} — упомяни это предупреждение в ответе пилоту явно."
  elif [ -n "$OBLIGATION_NOTE" ]; then
    # These allow notes only describe a completed or exempt gate. Feeding them
    # back to Claude would spend another turn at every peer-session Stop.
    case "$OBLIGATION_ACTION:$OBLIGATION_NOTE" in
      "allow:close_path=peer-session — раннер не требуется, Stop-гейт пропускает" \
      | "allow:close_path=peer-session (obligation взведено внутри пир-сессии) — раннер не требуется, Stop-гейт пропускает" \
      | "allow:close obligation verified and cleared") ;;
      *) OBLIGATION_CTX="CLOSE-OBLIGATION (Ф74б): $OBLIGATION_NOTE" ;;
    esac
  fi
fi

# Exit without a protocol verdict: still hand the obligation context (note/warn)
# to the pilot if there is one.
emit_obligation_only() {
  if [ -n "$OBLIGATION_CTX" ]; then
    jq -nc --arg ctx "$OBLIGATION_CTX" \
      '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'
  else
    echo '{}'
  fi
  exit 0
}

# --- Шаг 1: был ли вызов протокольного скилла? ---
# Порт из FMT-exocortex-template (issues #758, #862, #1311; WP-568, 24.10):
# в транскрипте Claude Code tool_use лежит в .message.content[], транскрипт —
# JSONL (jq -s). До порта корневой хук искал tool_use на верхнем уровне строки
# и не находил протокольный скилл ни в одной реальной сессии (гейт был мёртв
# с 08.08). Skill и args берутся из ОДНОГО, последнего вызова.
PROTOCOL_CALL_JSON=$(jq -s -c '
  [.[] | select((.message.role // "assistant") == "assistant") | .message.content[]?]
  | map(select(.type == "tool_use" and .name == "Skill"))
  | map(select((.input.skill // "") | test("^(day-open|day-close|run-protocol|wp-new)$")))
  | .[-1] // empty
' "$TRANSCRIPT_PATH" 2>/dev/null)

if [ -z "$PROTOCOL_CALL_JSON" ] || [ "$PROTOCOL_CALL_JSON" = "null" ]; then
  emit_obligation_only
fi

PROTOCOL_SKILL=$(printf '%s' "$PROTOCOL_CALL_JSON" | jq -r '.input.skill // empty')

# --- Шаг 1б: Quick Close без таск-листа по дизайну (issue #1311) ---
# Отсутствующий args = Quick Close; нестроковый args — не Quick Close (fail-closed).
IS_QUICK_CLOSE=0
if [ "$PROTOCOL_SKILL" = "run-protocol" ]; then
  ARGS_KIND=$(printf '%s' "$PROTOCOL_CALL_JSON" | jq -r '.input.args | type')
  ARGS_NORM=""
  if [ "$ARGS_KIND" = "string" ]; then
    ARGS_NORM=$(printf '%s' "$PROTOCOL_CALL_JSON" | jq -r '.input.args' \
      | lower_text \
      | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')
  fi
  # Root practice also passes flags or a note after "close" ("close --skip-reflection",
  # "close --wp WP-N", "close — <пояснение>"; the ПСЗ/СЗ shorthand). Template matches only
  # bare "close"/"close session"; here the first word decides, unless it names a heavier
  # scale (WP-568, 24.10: replaying real transcripts, the bare match blocked 3 of 8 Quick Closes).
  if [ "$ARGS_KIND" = "null" ] || [ "$ARGS_KIND" = "string" ]; then
    read -r ARGS_W1 ARGS_W2 _ <<< "$ARGS_NORM"
    if [ -z "$ARGS_W1" ]; then
      IS_QUICK_CLOSE=1
    elif [ "$ARGS_W1" = "close" ]; then
      case "${ARGS_W2:-}" in
        day|week|month|день|неделя|неделю|месяц) ;;
        *) IS_QUICK_CLOSE=1 ;;
      esac
    fi
  fi
fi
[ "$IS_QUICK_CLOSE" = "1" ] && emit_obligation_only

# --- Шаг 2: был ли таск-лист с ≥3 items? ---
# TodoWrite заменён TaskCreate/TaskUpdate (issue #862); явная нумерация
# «Шаг N из M» в ответах ассистента — равноправный признак. Считаем только
# сообщения ассистента.
# $1 = tool name; prints one count per tool_use (batch length, or 1 for a single task).
count_task_tool() {
  jq -s -r --arg tool "$1" '
    [.[] | select((.message.role // "assistant") == "assistant") | .message]
    | .[] | .content[]?
    | select(.type == "tool_use" and .name == $tool)
    | .input
    | if (.tasks // .task_list // .items) | type == "array" then
        (.tasks // .task_list // .items) | length
      elif (.tasks // .task_list // .items) != null then
        1
      elif (.name // .title // .description // .status) then
        1
      else
        0
      end
  ' "$TRANSCRIPT_PATH" 2>/dev/null
}

TODO_MAX=$(jq -s -r '
  [.[] | select((.message.role // "assistant") == "assistant") | .message]
  | .[] | .content[]?
  | select(.type == "tool_use" and .name == "TodoWrite")
  | .input.todos
  | if type == "array" then length else 0 end
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | sort -n | tail -1)
TODO_MAX="${TODO_MAX:-0}"

# Separate TaskCreate calls are separate steps (sum); TaskUpdate calls may
# repeat one task (max).
TASK_CREATE_MAX=$(count_task_tool TaskCreate | awk '{s+=$1} END {print s+0}')
TASK_UPDATE_MAX=$(count_task_tool TaskUpdate | sort -n | tail -1)
TASK_UPDATE_MAX="${TASK_UPDATE_MAX:-0}"

STEP_MAX=$(jq -s -r '
  [.[] | select((.message.role // "assistant") == "assistant") | .message]
  | .[] | .content[]?
  | select(.type == "text" and (.text // "") != "")
  | .text
' "$TRANSCRIPT_PATH" 2>/dev/null \
  | grep -oiE '(шаг|step)[[:space:]]+[0-9]+[[:space:]]+(из|of)[[:space:]]+[0-9]+' \
  | grep -oiE '[0-9]+$' \
  | sort -n | tail -1)
STEP_MAX="${STEP_MAX:-0}"

LIST_MAX=$(( TODO_MAX + TASK_CREATE_MAX ))
if [ "$TASK_UPDATE_MAX" -gt "$LIST_MAX" ]; then LIST_MAX="$TASK_UPDATE_MAX"; fi
if [ "$STEP_MAX" -gt "$LIST_MAX" ]; then LIST_MAX="$STEP_MAX"; fi

THRESHOLD=3

# --- Шаг 3: логировать событие ---
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FIRED=0
if [ "$LIST_MAX" -lt "$THRESHOLD" ]; then
  FIRED=1
fi

LOG_ENTRY=$(jq -nc \
  --arg ts "$TIMESTAMP" \
  --arg sid "$SESSION_ID" \
  --arg skill "$PROTOCOL_SKILL" \
  --arg todo_max "$TODO_MAX" \
  --arg list_max "$LIST_MAX" \
  --arg threshold "$THRESHOLD" \
  --arg fired "$FIRED" \
  '{ts: $ts, gate: "protocol-stop-gate", session_id: $sid, skill: $skill,
    todo_max: ($todo_max|tonumber), list_max: ($list_max|tonumber), threshold: ($threshold|tonumber),
    fired: ($fired == "1"), action: "warn",
    pattern: "P9"}' 2>/dev/null || true)

if [ -n "$LOG_ENTRY" ]; then
  echo "$LOG_ENTRY" >> "$GATE_LOG" 2>/dev/null || true
fi

# --- Шаг 4: формировать итоговое решение ---
# Всегда объединяем с контекстом обязательства, если он есть. Если protocol fired,
# возвращаем decision:block; если obligation дал warn/note, добавляем additionalContext.
if [ "$FIRED" = "1" ]; then
  PROTOCOL_REASON="⚠️ PROTOCOL-STOP-GATE [warn]: Скилл '$PROTOCOL_SKILL' был вызван, но таск-лист с ≥$THRESHOLD задачами (TodoWrite/TaskCreate или «Шаг N из M») не найден (найдено: $LIST_MAX). Протокол требует таск-лист ДО начала исполнения. Действие: создай таск-лист с шагами скилла и пройди протокол заново. (gate_log: $GATE_LOG)"
  if [ -n "$OBLIGATION_CTX" ]; then
    jq -nc \
      --arg reason "$PROTOCOL_REASON" \
      --arg ctx "$OBLIGATION_CTX" \
      '{decision: "block", reason: $reason,
        hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'
  else
    jq -nc --arg reason "$PROTOCOL_REASON" '{decision: "block", reason: $reason}'
  fi
else
  if [ -n "$OBLIGATION_CTX" ]; then
    jq -nc --arg ctx "$OBLIGATION_CTX" \
      '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'
  else
    echo '{}'
  fi
fi

exit 0
