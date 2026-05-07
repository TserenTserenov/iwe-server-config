#!/usr/bin/env bash
# sync-strategy-files.sh — точечный sync inbox/WP-*.md и current/*.md для DS-my-strategy.
#
# WP-7 фаза S-C (7 мая 2026). Wrapper над `git fetch + git checkout origin/main -- $files`.
#
# Зачем:
#   - DS-my-strategy на сервере исключён из auto-pull (DIRTY почти всегда из-за
#     iwe-sync-fleeting-notes timer каждые 2 мин правит inbox/fleeting-notes.md).
#   - Но другие файлы (inbox/WP-*.md и current/*.md) нужны свежими для
#     active-WP-sweep (WP-283 Шаг E) и других server-side агентов.
#
# Стратегия:
#   - git fetch origin (offline-safe — exit 0 если нет сети)
#   - Для каждого файла из allowlist: проверить отличие от remote → git checkout
#   - Не трогает inbox/fleeting-notes.md (его обновляет sync-files.sh раз в 2 мин)
#   - Не делает full pull (избегает конфликта с dirty fleeting-notes)
#
# Запуск: через iwe-sync-strategy-files.timer (раз в 10 мин).

set -euo pipefail

REPO_PATH="${1:-/home/tseren/IWE/DS-my-strategy}"
cd "$REPO_PATH"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
REMOTE="origin"
TS=$(date '+%Y-%m-%d %H:%M:%S')

# Fetch only — без pull/merge
if ! git fetch "$REMOTE" "$BRANCH" --quiet 2>/dev/null; then
  echo "$TS [sync-strategy-files] fetch failed (offline?)" >&2
  exit 0
fi

# Glob список файлов для синхронизации (read-only в сторону сервера).
# git ls-tree не поддерживает glob magic — используем grep-фильтр.
FILES_TO_SYNC=()
ALL_FILES=$(git ls-tree -r --name-only "${REMOTE}/${BRANCH}" 2>/dev/null)

# inbox/WP-*.md — карточки рабочих продуктов
while IFS= read -r line; do
  FILES_TO_SYNC+=("$line")
done < <(echo "$ALL_FILES" | grep -E '^inbox/WP-.*\.md$' || true)

# current/*.md — план недели + DayPlan (если есть)
while IFS= read -r line; do
  FILES_TO_SYNC+=("$line")
done < <(echo "$ALL_FILES" | grep -E '^current/[^/]+\.md$' || true)

# MEMORY.md — индекс активных РП (обновляется memory-active-wp-update.sh ежедневно)
if echo "$ALL_FILES" | grep -qx "MEMORY.md"; then
  FILES_TO_SYNC+=("MEMORY.md")
fi

if [ "${#FILES_TO_SYNC[@]}" -eq 0 ]; then
  echo "$TS [sync-strategy-files] no files matched"
  exit 0
fi

SYNCED=0
SKIPPED=0
FAILED=0

for FILE in "${FILES_TO_SYNC[@]}"; do
  # Skip fleeting-notes — у него отдельный sync (не наш скоп)
  case "$FILE" in
    inbox/fleeting-notes.md) continue ;;
  esac

  # Проверяем — отличается ли локальная версия от remote
  REMOTE_HASH=$(git rev-parse "${REMOTE}/${BRANCH}:${FILE}" 2>/dev/null || echo "missing")
  if [ "$REMOTE_HASH" = "missing" ]; then
    continue
  fi

  if [ -f "$FILE" ]; then
    LOCAL_HASH=$(git hash-object "$FILE" 2>/dev/null || echo "none")
    if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi

  # Update file from remote
  if git checkout "${REMOTE}/${BRANCH}" -- "$FILE" 2>/dev/null; then
    SYNCED=$((SYNCED + 1))
  else
    FAILED=$((FAILED + 1))
    echo "$TS [sync-strategy-files] FAIL: $FILE" >&2
  fi
done

echo "$TS [sync-strategy-files] synced=$SYNCED skipped=$SKIPPED failed=$FAILED"
exit 0
