#!/bin/bash
# instruction-style-gate.sh
# Event: PreToolUse (matcher: Edit|Write)
# see DP.SC.050, section «Пошаговая инструкция для человека» (pilot decision 11.11.2026, WP-529 Ф270)
#
# The communication style reaches the agent in rotating parts (inject-communication-style.sh), so
# the rule for step-by-step instructions may be absent at the moment an instruction is written; the
# 0.42 tester guide went out without places, with several commands per block. This gate stops the
# FIRST write of a text document that looks like an instruction for a person (a shell/PowerShell
# code block plus an imperative such as «нажми»/«откройте»), shows the rule, and lets the agent
# write again after checking the text: a repeated write of the same file in the same session passes.
#
# Rule text comes from the owner (PACK-digital-platform communication-style-base.md); no copy here.
# Owner missing or unreadable -> pass with a warning on stderr (the gate must not block on itself).

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }
INPUT=$(cat 2>/dev/null || echo '{}')

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
case "$FILE_PATH" in
  *.md|*.markdown|*.txt) : ;;
  *) echo '{}'; exit 0 ;;
esac

# Write carries the whole text, Edit only the replacement.
TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // empty' 2>/dev/null)
[ -n "$TEXT" ] || { echo '{}'; exit 0; }

# An instruction for a person = a command block to run + a second-person imperative.
printf '%s' "$TEXT" | grep -qiE '^[[:space:]]*```[[:space:]]*(bash|sh|zsh|shell|console|powershell|ps1|cmd)[[:space:]]*$' \
  || { echo '{}'; exit 0; }
# Capitals spelled out: hooks may run in the C locale, where -i does not fold Cyrillic.
printf '%s' "$TEXT" | grep -qE '(нажми|Нажми|открой|Открой|вставь|Вставь|введи|Введи|выбери|Выбери|скопируй|Скопируй|выполни|Выполни|запусти|Запусти)' \
  || { echo '{}'; exit 0; }

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
STATE_DIR="$PROJECT_DIR/.claude/state"
STATE_FILE="$STATE_DIR/instruction-style-checked-$SESSION_ID"
KEY=$(printf '%s' "$FILE_PATH" | shasum -a 256 2>/dev/null | cut -c1-16)
[ -n "$KEY" ] || KEY=$(printf '%s' "$FILE_PATH" | cksum | cut -d' ' -f1)
if [ -f "$STATE_FILE" ] && grep -qx "$KEY" "$STATE_FILE" 2>/dev/null; then
  echo '{}'; exit 0
fi

OWNER="${IWE_INSTRUCTION_STYLE_SOURCE:-$PROJECT_DIR/PACK-digital-platform/pack/digital-platform/02-domain-entities/communication-style-base.md}"
# The section runs from its bold title to the next blank line followed by another bold title.
RULE=$(awk '/^\*\*Пошаговая инструкция для человека\*\*/ {on=1}
            on && /^$/ {blank=1; next}
            on && blank && /^\*\*/ {exit}
            on {if (blank) {print ""; blank=0}; print}' "$OWNER" 2>/dev/null)
if [ -z "$RULE" ]; then
  echo "instruction-style-gate: WARN правило не найдено в $OWNER — запись пропущена без проверки" >&2
  echo '{}'; exit 0
fi

mkdir -p "$STATE_DIR"
echo "$KEY" >> "$STATE_FILE"
find "$STATE_DIR" -name 'instruction-style-checked-*' -mmin +1440 -delete 2>/dev/null || true

REASON="Похоже на пошаговую инструкцию для человека ($FILE_PATH). Перед записью сверь текст с правилом ниже и запиши снова — повторная запись этого файла пройдёт.

$RULE"
jq -n --arg r "$REASON" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $r
  }
}'
