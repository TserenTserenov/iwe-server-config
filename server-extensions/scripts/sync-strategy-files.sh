#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
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
#   - Не трогает файл, если в нём есть незакоммиченная правка (dirty guard) или
#     локальный ещё не запушенный коммит (ahead guard) — иначе `git checkout
#     origin/main -- $FILE` затирает работу, которая ещё не успела уйти на GitHub
#     (peer-session 2026-08-08-05-wp406-card-clobber-source, 3 живых инцидента:
#     WP-506 дважды 07-08.08, WP-406+WP-504 08.08).
#
# Запуск: через iwe-sync-strategy-files.timer (раз в 10 мин).
#
# Lock (WP-538 Ф5а, 2026-09-03): this script's own `git checkout origin/
# $BRANCH -- $FILE` calls stage content that can end up byte-identical to
# origin while HEAD stays behind — canon-refresh.sh recognizes that exact
# shape as a safe, known-automation mirror and resolves it with a `git reset
# --soft`. That recovery snapshot must not be taken mid-checkout-loop here,
# so this script takes the same $GIT_DIR/dirty-guard.lock that git-dirty-
# guard.sh and canon-refresh.sh already share (mkdir-based; whichever
# acquires it first runs to completion before the other's mkdir succeeds).
# Non-blocking, same as canon-refresh.sh: a busy lock just skips this tick,
# the timer tries again in 10 minutes.

set -euo pipefail

REPO_PATH="${1:-/home/tseren/IWE/DS-my-strategy}"
cd "$REPO_PATH"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "[sync-strategy-files] $REPO_PATH is not a git repo" >&2
  exit 2
}
GIT_DIR=$(git rev-parse --absolute-git-dir)
LOCK_DIR="$GIT_DIR/dirty-guard.lock"
LOCK_META="$LOCK_DIR/owner"
HOSTNAME_NOW="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -f "$LOCK_META" ]; then
    OTHER_HOST=$(awk -F= '$1=="host"{print $2}' "$LOCK_META" 2>/dev/null)
    OTHER_PID=$(awk -F= '$1=="pid"{print $2}' "$LOCK_META" 2>/dev/null)
    if [ "$OTHER_HOST" = "$HOSTNAME_NOW" ] && [ -n "$OTHER_PID" ] && ! kill -0 "$OTHER_PID" 2>/dev/null; then
      echo "[sync-strategy-files] reclaiming stale lock (pid=$OTHER_PID on $OTHER_HOST no longer running)" >&2
      rm -rf "$LOCK_DIR" 2>/dev/null
    fi
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "[sync-strategy-files] lock busy (guard or canon-refresh running), skipping this cycle" >&2
    exit 0
  fi
fi
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT
printf 'host=%s\npid=%s\n' "$HOSTNAME_NOW" "$$" > "$LOCK_META"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
REMOTE="origin"
TS=$(date '+%Y-%m-%d %H:%M:%S')

# Fetch only — без pull/merge
if ! git fetch "$REMOTE" "$BRANCH" --quiet 2>/dev/null; then
  echo "$TS [sync-strategy-files] fetch failed (offline?)" >&2
  exit 0
fi

# Repo-wide ahead/diverged check: если HEAD не входит в предки origin/branch,
# у репо есть локальные коммиты, которых нет на remote (обычный случай —
# незапушенный коммит любого агента/пилота в этом рабочем дереве). В этом
# режиме нельзя доверять по-файловому сравнению «отличается от remote» —
# отличие может значить «моя правка ещё не запушена», а не «я отстал».
REPO_DIVERGED=false
if ! git merge-base --is-ancestor HEAD "${REMOTE}/${BRANCH}" 2>/dev/null; then
  REPO_DIVERGED=true
fi

# Glob список файлов для синхронизации (read-only в сторону сервера).
# git ls-tree не поддерживает glob magic — используем grep-фильтр.
#
# Этот список — source of truth для automation-contract.conf (WP-538 Ф5а):
# scripts/tests/automation-contract-consistency-smoke.sh проверяет репрезентативные
# пути с обеих сторон (не полную формальную эквивалентность — grep-паттерны
# ниже — это regex, где "." переходит "/", а contract-файл сознательно
# ограничен ровно одним уровнем вложенности на "*", см. automation-contract.sh;
# расхождение на глубже вложенных путях безопасно проваливается в отказ, не
# в ложное разрешение). canon-refresh.sh доверяет contract-файлу при решении,
# можно ли без коммита продвинуть HEAD поверх зеркала, который оставляет этот
# скрипт — узнаваемое расхождение (для путей, которые реально встречаются)
# сделало бы то решение неверным в обе стороны.
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

# day-rhythm-config.yaml (news/calendar, server-mode Day Open): the branch that
# used to sync exocortex/day-rhythm-config.yaml here was dead code — that path
# was never tracked in git, so `git ls-tree` could never match it and the file
# never actually reached the server this way (WP-526, found 2026-08-31). The
# config now lives in .iwe-runtime/ (also outside git) on both Mac and the
# server; cross-machine delivery for it is an open gap, not solved by this
# script — see WP-526 "Осталось".

if [ "${#FILES_TO_SYNC[@]}" -eq 0 ]; then
  echo "$TS [sync-strategy-files] no files matched"
  exit 0
fi

SYNCED=0
SKIPPED=0
SKIPPED_DIRTY=0
SKIPPED_AHEAD=0
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

  # Dirty guard: рабочее дерево (staged или unstaged) отличается от HEAD для
  # этого пути — значит есть незакоммиченная правка ИЛИ удаление именно этого
  # файла (git rm/mv или голый rm без коммита — `git diff HEAD` ловит оба:
  # для отсутствующего на диске, но отслеживаемого в HEAD пути он тоже вернёт
  # "отличается"). Для путей, никогда не отслеживавшихся локально, вернёт
  # "чисто" — безвредно. Не трогаем, что бы ни было на remote.
  if ! git diff --quiet HEAD -- "$FILE" 2>/dev/null; then
    SKIPPED_DIRTY=$((SKIPPED_DIRTY + 1))
    continue
  fi

  # Ahead guard: файл чист относительно HEAD, но у репо есть незапушенные
  # коммиты (REPO_DIVERGED), и committed-версия этого пути в HEAD отличается
  # от remote (включая случай "HEAD его не содержит вовсе" — например, файл
  # был удалён локальным коммитом) — похоже на локальный коммит по этому
  # файлу (правку или удаление), который ещё не ушёл на GitHub. Затирать/
  # воскрешать его было бы тихим откатом уже сохранённой работы.
  # Компромисс: если divergence на самом деле вызван СОВСЕМ другим файлом, а
  # этот путь просто новый на remote — тоже пропустим, пока репо не перестанет
  # расходиться (safety > freshness, тот же принцип, что и выше для dirty).
  if [ "$REPO_DIVERGED" = true ]; then
    HEAD_HASH=$(git rev-parse "HEAD:${FILE}" 2>/dev/null || echo "missing")
    if [ "$HEAD_HASH" != "$REMOTE_HASH" ]; then
      SKIPPED_AHEAD=$((SKIPPED_AHEAD + 1))
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

if [ "$((SKIPPED_DIRTY + SKIPPED_AHEAD))" -gt 0 ]; then
  echo "$TS [sync-strategy-files] WARN: $SKIPPED_DIRTY file(s) skipped-dirty, $SKIPPED_AHEAD file(s) skipped-ahead (local work not yet committed/pushed)" >&2
fi

echo "$TS [sync-strategy-files] synced=$SYNCED skipped=$SKIPPED skipped_dirty=$SKIPPED_DIRTY skipped_ahead=$SKIPPED_AHEAD failed=$FAILED"
exit 0
