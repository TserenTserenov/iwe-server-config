#!/bin/bash
# access-claim-stop-reminder.sh
# Event: Stop
# Назначение: real-time напоминание при непроверенном заявлении «нет доступа».
# Архитектура: тонкая обёртка над .claude/detectors/detector_access_claim.sh,
# зеркалит p5-stop-reminder.sh (тот же принцип warn-before-block: action
# всегда block — это напоминание в следующий ход, не запрет текущего).
#
# WP-555 (peer-session с Codex, 2026-08-25). Третий рецидив паттерна «нет
# доступа», хотя пилот его поправляет и агент тут же находит и делает —
# см. feedback_check_tools_before_asking.md. Известный архитектурный предел
# (Codex, ход 1-3): Stop срабатывает ПОСЛЕ того, как ответ уже отрендерен
# пилоту — это не DLP и не отменяет уже показанный текст. Цель этого хука —
# устранить необходимость пилоту самому указывать на доступ: агент
# самокорректируется тем же ходом, до ответа пилота.
#
# Защита от infinite loop: stop_hook_active в INPUT JSON.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  echo '{}'
  exit 0
fi

STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  echo '{}'
  exit 0
fi

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
DETECTOR="$IWE_ROOT/.claude/detectors/detector_access_claim.sh"

if [ ! -x "$DETECTOR" ]; then
  echo '{}'
  exit 0
fi

DETECTOR_OUT=$(echo "$INPUT" | "$DETECTOR" 2>/dev/null || true)

if [ -z "$DETECTOR_OUT" ]; then
  echo '{}'
  exit 0
fi

COUNT=$(echo "$DETECTOR_OUT" | jq -r '.payload.count // 0' 2>/dev/null)
FIRST_EX=$(echo "$DETECTOR_OUT" | jq -r '.payload.examples[0] // empty' 2>/dev/null)

if [ -z "$COUNT" ] || [ "$COUNT" = "0" ] || [ "$COUNT" = "null" ]; then
  echo '{}'
  exit 0
fi

# --- Логировать событие в gate_log ---
GATE_LOG="$IWE_ROOT/.claude/logs/gate_log.jsonl"
mkdir -p "$(dirname "$GATE_LOG")" 2>/dev/null || true
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
LOG_ENTRY=$(jq -nc \
  --arg ts "$TIMESTAMP" \
  --arg sid "$SESSION_ID" \
  --arg count "$COUNT" \
  '{ts: $ts, gate: "access-claim-stop-reminder", session_id: $sid,
    fired: true, action: "block", pattern: "ACCESS_CLAIM",
    count: ($count|tonumber)}' 2>/dev/null || true)
[ -n "$LOG_ENTRY" ] && echo "$LOG_ENTRY" >> "$GATE_LOG" 2>/dev/null || true

# --- WP-272 Ф2.5: интеграция с rule-engine (R23 audit F4) ---
RULE_ENGINE="$IWE_ROOT/.claude/hooks/rule-engine.sh"
if [ -x "$RULE_ENGINE" ] && [ -n "$FIRST_EX" ]; then
  EX_TRUNC=$(printf '%s' "$FIRST_EX" | head -c 500)
  RULE_CTX=$(printf '%s' "$EX_TRUNC" | python3 -c '
import sys, json
text = sys.stdin.read()
print(json.dumps({"response_text": text, "source": "access-claim-stop-reminder", "count": '"$COUNT"'}, ensure_ascii=False))
' 2>/dev/null)
  if [ -n "$RULE_CTX" ]; then
    RULE_EVENT="response_emitted" RULE_CONTEXT="$RULE_CTX" "$RULE_ENGINE" dispatch >/dev/null 2>&1 || true
  fi
fi

# --- Сформировать reason для block ---
REASON="Заявление «нет доступа/сделай вручную» ${COUNT} раз(а) в этом ходу без вызова Bash/ToolSearch/MCP. feedback_check_tools_before_asking.md: «нет доступа» — проверяемое утверждение, не данность (рецидив 10.06, 04.07, 25.08.2026). Прежде чем финализировать ответ: проверь конкретный канал (ToolSearch/Bash/SSH/MCP) — см. memory/reference_access_verification_playbook.md — и либо найди способ и сделай сейчас, либо явно напиши какая именно проверка дала отказ."
if [ -n "$FIRST_EX" ] && [ "$FIRST_EX" != "null" ]; then
  REASON="${REASON} Пример: «${FIRST_EX}»."
fi

jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'

exit 0
