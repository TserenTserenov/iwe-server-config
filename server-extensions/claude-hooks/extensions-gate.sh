#!/bin/bash
# Extensions Gate Hook
# Event: PreToolUse (matcher: Edit, Write)
# Блокирует прямое редактирование .claude/skills/ и memory/protocol-*.md
#
# Исключения:
#   - FMT-exocortex-template (шаблон — всегда разрешён)
#   - author_mode: true в params.yaml (автор шаблона — source-of-truth в IWE,
#     пропагация в FMT через template-sync.sh)

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Проверяем: это L1 файл?
if echo "$FILE_PATH" | grep -qE '\.claude/skills/|memory/protocol-'; then

  # Исключение 1: FMT-exocortex-template — всегда разрешён
  if echo "$FILE_PATH" | grep -q 'FMT-exocortex-template'; then
    exit 0
  fi

  # Исключение 2: author_mode в params.yaml
  WORKSPACE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
  if [ -f "$WORKSPACE_DIR/params.yaml" ] && grep -qE '^author_mode:\s*true' "$WORKSPACE_DIR/params.yaml" 2>/dev/null; then
    exit 0
  fi

  # Блокировать для обычных пользователей
  echo '{"decision": "block", "reason": "⛔ Extensions Gate: платформенные (L1) и пользовательские (L3) файлы — разные слои. Правило (CLAUDE.md §9): Авторская кастомизация → extensions/*.md. Платформенное изменение → FMT-exocortex-template → update.sh. Смешение слоёв = хрупкость при обновлении. Создай или обнови нужный файл в extensions/."}'
  exit 0
fi

# Разрешить редактирование обычных файлов
echo '{}'
exit 0
