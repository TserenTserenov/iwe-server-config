#!/bin/bash
# memory-repo-autocommit.sh — after Write/Edit into the memory/ git repo, commit
# that one file narrowly, immediately (WP-530, peer-session
# 2026-09-11-13-memory-repo-drift-cleanup, consensus with Kimi).
# Event: PostToolUse (matcher: Write|Edit|MultiEdit)
#
# Назначение: контракт S-53 требует «узкий Edit -> сразу commit» в memory/, но
# ничего это раньше не enforced — коммиты копились неделями (до 6 дней дрейфа
# на 27 файлах от многих параллельных сессий, найдено и разобрано в сессии
# выше). memory/ — самостоятельный git-репозиторий (не подкаталог кода), не
# вложен ни в один код-репо — поэтому риска захватить в один коммит файлы из
# разных репозиториев здесь нет физически, коммит отсюда никогда не заденет код.
#
# Принципы:
#   - Никогда не блокирует операцию (exit 0 всегда — коммит побочный эффект).
#   - Коммитит РОВНО изменённый файл через pathspec, не весь working tree.
#   - Нет реального diff после Write/Edit -> тихо выходим, пустых коммитов не создаём.
#   - Push не делает — у этого репозитория нет git remote (локальное хранилище).

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:${PATH:-}"

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_response.filePath // empty')
[ -z "$FILE_PATH" ] && exit 0
[ -f "$FILE_PATH" ] || exit 0

# Реальный (симлинк-разрешённый) путь к репозиторию памяти — тот же приоритет,
# что уже применяет memory-exocortex-sync.sh: симлинк $WORKSPACE_DIR/memory
# первичен (не зависит от Claude Code slugification правил), MEMORY_SRC — fallback.
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/IWE}"
HOME_SLUG=$(echo "$HOME" | tr '/_.' '-')
MEMORY_SRC="${IWE_MEMORY_SRC:-$HOME/.claude/projects/${HOME_SLUG}-IWE/memory}"

if [ -z "${IWE_MEMORY_SRC:-}" ] && [ -d "$WORKSPACE_DIR/memory" ]; then
    MEMORY_REAL=$(cd "$WORKSPACE_DIR/memory" 2>/dev/null && pwd -P) || exit 0
else
    MEMORY_REAL=$(cd "$MEMORY_SRC" 2>/dev/null && pwd -P) || exit 0
fi

# Файл должен физически лежать внутри memory/ (включая подкаталоги, напр. fpf-cards/, reference/)
FILE_REAL="$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd -P)/$(basename "$FILE_PATH")" || exit 0
case "$FILE_REAL" in
    "$MEMORY_REAL"/*) ;;
    *) exit 0 ;;
esac

REL_PATH="${FILE_REAL#"$MEMORY_REAL"/}"

# Узкий add + проверка реального staged-diff (не только "файл тронут" — Edit
# мог быть no-op или откатить правку до исходного состояния).
git -C "$MEMORY_REAL" add -- "$REL_PATH" 2>/dev/null
git -C "$MEMORY_REAL" diff --cached --quiet -- "$REL_PATH" 2>/dev/null && exit 0

git -C "$MEMORY_REAL" commit -m "auto(memory): $(basename "$REL_PATH")" -- "$REL_PATH" >/dev/null 2>&1

exit 0
