#!/bin/bash
# p5-stop-reminder.sh
# Event: Stop
# Назначение: Real-time напоминание при срабатывании P5 (запрос разрешения).
# Архитектура: тонкая обёртка над .claude/detectors/detector_permission_request.sh.
#   Детектор эмитит JSON-event (count + примеры). Враппер парсит count, при count>0
#   возвращает Stop-decision=block с напоминанием → инжектится в следующий ход.
# Принцип warn-before-block: action всегда block (это и есть напоминание, не запрет).
#
# Защита от infinite loop: stop_hook_active в INPUT JSON (env-var не работает,
# Claude Code запускает каждый хук в свежем subprocess).
# Read-only кроме pass-through stdin/stdout.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  echo '{}'
  exit 0
fi

# --- Infinite loop guard через stop_hook_active в INPUT ---
# Если этот Stop-event сам инициирован прошлым decision:block — не блокируем
# повторно, иначе ping-pong.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  echo '{}'
  exit 0
fi

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
DETECTOR="$IWE_ROOT/.claude/detectors/detector_permission_request.sh"

if [ ! -x "$DETECTOR" ]; then
  echo '{}'
  exit 0
fi

# --- Изолировать ассистент-сообщения ПОСЛЕДНЕГО ХОДА ---
# Детектор проектировался для сессионной агрегации (tail -30 строк JSONL).
# Для real-time блок-на-Stop нам нужны assistant-сообщения текущего хода —
# от последнего user-сообщения до конца транскрипта. Один ход может быть
# разбит на несколько JSONL-записей (text / tool_use / text), tail -1 потерял
# бы первую часть. Нужны все assistant-записи после последнего user.
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  echo '{}'
  exit 0
fi

# Найти номер последней строки с user-сообщением. Всё после неё — текущий ход.
# Используем nl для нумерации строк, фильтруем те, которые валидно парсятся в
# {role|type: "user"} через jq.
LAST_USER_LINE_NUM=$(awk '{print NR"\t"$0}' "$TRANSCRIPT_PATH" 2>/dev/null \
  | while IFS=$'\t' read -r ln content; do
      role=$(printf '%s' "$content" | jq -r '.role // .type // empty' 2>/dev/null)
      [ "$role" = "user" ] && echo "$ln"
    done | tail -1)

if [ -n "$LAST_USER_LINE_NUM" ]; then
  # Всё после последнего user-сообщения
  CURRENT_TURN_ASSISTANT=$(awk -v start="$((LAST_USER_LINE_NUM + 1))" 'NR >= start' "$TRANSCRIPT_PATH" 2>/dev/null \
    | jq -c 'select(.role == "assistant" or .type == "assistant")' 2>/dev/null)
else
  # Нет user-сообщений — берём всё (раньше старта диалога), скорее всего ничего
  CURRENT_TURN_ASSISTANT=$(jq -c 'select(.role == "assistant" or .type == "assistant")' \
    "$TRANSCRIPT_PATH" 2>/dev/null)
fi

if [ -z "$CURRENT_TURN_ASSISTANT" ]; then
  echo '{}'
  exit 0
fi

# Пишем во временный transcript строки текущего хода
TMP_TRANSCRIPT=$(mktemp /tmp/p5_last_assistant.XXXX.jsonl)
trap 'rm -f "$TMP_TRANSCRIPT"' EXIT
printf '%s\n' "$CURRENT_TURN_ASSISTANT" > "$TMP_TRANSCRIPT"

# Подменяем transcript_path в INPUT на временный
PATCHED_INPUT=$(echo "$INPUT" | jq --arg tp "$TMP_TRANSCRIPT" '.transcript_path = $tp')

# Запустить детектор с патченным INPUT
DETECTOR_OUT=$(echo "$PATCHED_INPUT" | "$DETECTOR" 2>/dev/null || true)

# Детектор молчит — нет срабатывания
if [ -z "$DETECTOR_OUT" ]; then
  echo '{}'
  exit 0
fi

# Извлечь count и first example
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
  '{ts: $ts, gate: "p5-stop-reminder", session_id: $sid,
    fired: true, action: "block", pattern: "P5",
    count: ($count|tonumber)}' 2>/dev/null || true)
[ -n "$LOG_ENTRY" ] && echo "$LOG_ENTRY" >> "$GATE_LOG" 2>/dev/null || true

# --- WP-272 Ф2.5: интеграция с rule-engine (R23 audit F4) ---
# Эмитировать в общий journal rule-engine как AR.002 warn-event,
# чтобы rule-classifier.py (Haiku R23) мог проверить FP.
# Это устраняет «двойной hook»: вместо двух журналов (gate_log + rule-engine)
# имеем единый источник для async-классификатора.
RULE_ENGINE="$IWE_ROOT/.claude/hooks/rule-engine.sh"
if [ -x "$RULE_ENGINE" ] && [ -n "$FIRST_EX" ]; then
  # Сократить пример до 500 chars и safely escape для JSON
  EX_TRUNC=$(printf '%s' "$FIRST_EX" | head -c 500)
  RULE_CTX=$(printf '%s' "$EX_TRUNC" | python3 -c '
import sys, json
text = sys.stdin.read()
print(json.dumps({"response_text": text, "source": "p5-stop-reminder", "count": '"$COUNT"'}, ensure_ascii=False))
' 2>/dev/null)
  if [ -n "$RULE_CTX" ]; then
    RULE_EVENT="response_emitted" RULE_CONTEXT="$RULE_CTX" "$RULE_ENGINE" dispatch >/dev/null 2>&1 || true
  fi
fi

# --- Сформировать reason для block ---
REASON="P5 (DP.FM.010): запрос разрешения у пользователя сработал ${COUNT} раз(а) в последнем ответе. Правило 6 CLAUDE.md / Правило 1 feedback_behaviour.md: действуй автономно — задание → выполни → отчитайся, не задавай вопросов «хотите?»/«продолжить?»/«записать?»/«применить?»."
if [ -n "$FIRST_EX" ] && [ "$FIRST_EX" != "null" ]; then
  REASON="${REASON} Пример: «${FIRST_EX}»."
fi

# --- Stop decision=block → reason инжектится в следующий turn ---
jq -nc --arg r "$REASON" '{decision: "block", reason: $r}'

exit 0
