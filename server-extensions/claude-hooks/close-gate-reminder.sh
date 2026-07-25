#!/bin/bash
# Close Gate Reminder Hook (v4 — session-bound close-intent sentinel, WP-482)
# Event: UserPromptSubmit
# Day Close → ПРЯМАЯ ИНСТРУКЦИЯ вызвать /run-protocol day-close (не напоминание).
# Session Close → compact-чеклист + sentinel для close-runner-gate.sh (PreToolUse).
# Read-only на прошлое (не меняет файлы репо), кроме одного sentinel в /tmp.
# Версия: 2026-04-03. Fix: multiline prompt ломал jq (6-й инцидент 3 апр).
#
# Sentinel (WP-482, 25.07.2026): текстовая инструкция «раннер — первое действие
# Quick Close» уже стояла в protocol-close.md с 17.07 — 24.07 LLM прочитал её
# буквально и всё равно продублировал шаги руками (найдено живьём, см. WP-482
# «Осталось» запись 24.07). Инструкция внутри текста, который сам же LLM
# интерпретирует, не может быть механизмом принуждения. Sentinel здесь —
# только маркер «в этой сессии объявлено намерение Close»; фактическую
# блокировку прямого `git commit` в обход раннера делает close-runner-gate.sh.

INPUT=$(cat)
# Устойчивость к многострочным промптам: literal \n в JSON value
# невалиден для jq. Заменяем все control chars на пробелы до парсинга.
SANITIZED=$(printf '%s' "$INPUT" | LC_ALL=C tr '\n\r\t' '   ')
PROMPT=$(printf '%s' "$SANITIZED" | jq -r '.prompt // empty' | tr '[:upper:]' '[:lower:]')
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"

# Day Close → ПРИНУДИТЕЛЬНЫЙ вызов /run-protocol
if echo "$PROMPT" | grep -qE '(итоги дня|закрываю день|закрывай день)'; then
  cat <<'EOF'
{"additionalContext": "⛔ БЛОКИРУЮЩЕЕ: Day Close выполняется ТОЛЬКО через skill /run-protocol с аргументом 'day-close'. ПЕРВОЕ И ЕДИНСТВЕННОЕ действие = вызвать Skill tool: skill='run-protocol', args='day-close'. НЕ читать protocol-close.md вручную. НЕ выполнять шаги самостоятельно. НЕ писать итоги без /run-protocol. Причина: 5 инцидентов пропуска шагов при ручном исполнении (15, 18, 19, 27 мар). /run-protocol гарантирует пошаговый TodoList + верификацию Haiku R23."}
EOF

# Session Close → /run-protocol close + sentinel для close-runner-gate.sh
elif echo "$PROMPT" | grep -qE '(закрывай|закрываю|заливай|запуши|закрывай сессию)'; then
  SENTINEL_DIR="/tmp/iwe-close-intent"
  mkdir -p "$SENTINEL_DIR" 2>/dev/null
  printf '{"session_id":"%s","created_at":"%s"}' \
    "$SESSION_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$SENTINEL_DIR/$SESSION_ID.flag" 2>/dev/null
  echo "[close-gate-reminder] session=$SESSION_ID close-intent sentinel written" >&2

  cat <<'EOF'
{"additionalContext": "⛔ БЛОКИРУЮЩЕЕ: Session Close выполняется ТОЛЬКО через skill /run-protocol с аргументом 'close'. ПЕРВОЕ И ЕДИНСТВЕННОЕ действие = вызвать Skill tool: skill='run-protocol', args='close'. НЕ выполнять шаги самостоятельно. /run-protocol гарантирует пошаговый TodoList + верификацию."}
EOF

else
  echo '{}'
fi
exit 0
