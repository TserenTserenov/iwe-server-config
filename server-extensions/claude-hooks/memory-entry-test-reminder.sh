#!/bin/bash
# memory-entry-test-reminder.sh — PreToolUse(Write): entry test before a NEW memory file
# (WP-7 F309; rules: memory/memory-lifecycle-spec.md section 6a, pilot's decision 14.11.2026).
#
# Memory grew to 1 779 files because nothing asked "should this be in memory at
# all?" at write time. Before a Write that creates a new file in a memory folder
# this hook adds the three entry questions to the context. It never blocks:
# existing files, the index (MEMORY*.md) and any other path pass silently.
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }

INPUT=$(cat 2>/dev/null || echo '{}')
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$FILE" ] || { echo '{}'; exit 0; }

case "$(basename "$FILE")" in MEMORY*.md) echo '{}'; exit 0 ;; esac
[ -e "$FILE" ] && { echo '{}'; exit 0; }

DIR=$(cd "$(dirname "$FILE")" 2>/dev/null && pwd -P) || { echo '{}'; exit 0; }
PROJECT_MEMORY=$(cd "${CLAUDE_PROJECT_DIR:-$HOME/IWE}/memory" 2>/dev/null && pwd -P)
case "$DIR" in
  "$HOME"/.claude/projects/*/memory | "$HOME"/.claude/projects/*/memory/* \
    | "${PROJECT_MEMORY:-/nonexistent}" | "${PROJECT_MEMORY:-/nonexistent}"/*) ;;
  *) echo '{}'; exit 0 ;;
esac

jq -n --arg ctx "Новая запись в память — тест входа (memory-lifecycle-spec.md §6а, решение пилота 14.11.2026). Пиши, только если все три «да»: (1) это поправка или предпочтение пилота, адрес внешнего ресурса или факт о среде, который иначе пришлось бы повторять? (2) это изменит поведение агента в нескольких будущих сессиях и разных задачах? (3) этого нет в паке, ядре правил, карточке РП, документации репозитория или автоматической проверке? Не пишется: статус работы, история коммитов, знание о предмете (→ пак), устройство кода (→ документация), разбор инцидента, уже закрытого исправлением и проверкой. Хоть одно «нет» — не создавай файл, положи знание туда, где ему место." \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}'
exit 0
