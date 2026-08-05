#!/bin/bash
# Pilot Witness Recorder (UserPromptSubmit, WP-484 Ф56, 05.08.2026)
#
# Проблема, которую решает: шаг session-reflection Quick Close раньше принимал
# `answer` из --input закрывающего агента без проверки, кто его реально написал --
# судья и нарушитель совпадали (3 рецидива за один день, MAJOR fault). Этот хук
# пишет каждое настоящее сообщение пилота в отдельный файл-свидетель; хендлер
# session-reflection-append.sh берёт ответ ТОЛЬКО отсюда, вход агента в answer
# больше не попадает вообще (WP-484.md §Ф56, консенсус с Codex+Kimi 05.08).
#
# Пассивный рекодер: НИКОГДА не блокирует ввод пилота (exit всегда 0) -- гарантия
# честности живёт в fail-closed поведении хендлера append (witness пуст без
# доверенного маркера автономного запуска => блок закрытия), не в этом хуке.
#
# Контракт UserPromptSubmit (Claude Code): stdin JSON {"session_id", "prompt", ...}.
set -uo pipefail

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$SESSION_ID" ] || exit 0
SESSION_ID_SAFE=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID_SAFE" ] || exit 0

PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
[ -n "$PROMPT" ] || exit 0

IWE_ROOT="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
WITNESS_DIR="$IWE_ROOT/.iwe-runtime/pilot-witness"
mkdir -p "$WITNESS_DIR" 2>/dev/null || exit 0
chmod 700 "$WITNESS_DIR" 2>/dev/null || true

WITNESS_FILE="$WITNESS_DIR/$SESSION_ID_SAFE.jsonl"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -cn --arg ts "$TS" --arg session_id "$SESSION_ID" --arg text "$PROMPT" \
  '{ts: $ts, session_id: $session_id, text: $text}' >> "$WITNESS_FILE" 2>/dev/null
chmod 600 "$WITNESS_FILE" 2>/dev/null || true

exit 0
