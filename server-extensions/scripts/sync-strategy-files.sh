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

# Peer session 2026-09-21-17-wp7-f163-ancestry-hardening (Claude+Codex), WP-7
# Ф163: both the repo-level `merge-base --is-ancestor` (REPO_DIVERGED) and the
# file-level `git rev-list HEAD --not origin/branch -- <file>` in
# is_own_stale_mirror() must be blind to local replacement refs and legacy
# grafts. Without this, a forged origin/<branch> makes a real, unpublished
# edit to a synced file (e.g. a WP card) look like this script's own stale
# mirror and get silently overwritten -- reproduced live (WP-7 Ф163 report).
export GIT_NO_REPLACE_OBJECTS=1
export GIT_GRAFT_FILE=/dev/null/iwe-no-grafts

REPO_PATH="${1:-/home/tseren/IWE/DS-my-strategy}"
SCRIPT_DIR="${BASH_SOURCE[0]}"; case "$SCRIPT_DIR" in */*) SCRIPT_DIR="${SCRIPT_DIR%/*}" ;; *) SCRIPT_DIR=. ;; esac; case "$SCRIPT_DIR" in /*) ;; *) SCRIPT_DIR="./$SCRIPT_DIR" ;; esac; SCRIPT_DIR=$(cd "$SCRIPT_DIR" >/dev/null 2>&1 && pwd && printf x); SCRIPT_DIR="${SCRIPT_DIR%x}"; SCRIPT_DIR="${SCRIPT_DIR%$'\n'}"   # computed before the cd below, without dirname (a minimal PATH has none) and without CDPATH; the marker x keeps a newline at the end of a directory name: the lock library is found next to this script
cd "$REPO_PATH"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "[sync-strategy-files] $REPO_PATH is not a git repo" >&2
  exit 2
}
GIT_DIR=$(git rev-parse --absolute-git-dir && printf x); GIT_DIR="${GIT_DIR%x}"; GIT_DIR="${GIT_DIR%$'\n'}"   # the marker x keeps a newline at the end of the name (the lock is made where the guard says)
# The lock itself (the takeover rule: only when the owner is PROVEN gone; the owner record; the release: only a lock with our token) lives
# in scripts/lib/dirty-guard-lock.sh, shared by the five guard scripts (WP-530 Ф81 remainder, peer session 2026-10-02-01). What THIS script
# does when the lock is busy stays here.
DGLOCK_LIB="$SCRIPT_DIR/lib/dirty-guard-lock.sh"
unset DGLOCK_LIB_READY   # a marker inherited from the environment must not vouch for a library that was cut short
# shellcheck source=lib/dirty-guard-lock.sh
if [ -r "$DGLOCK_LIB" ] && . "$DGLOCK_LIB" && [ "${DGLOCK_LIB_READY:-}" = 1 ]; then :; else
  echo "sync-strategy-files: the lock library is missing or unusable: $DGLOCK_LIB (scripts/ and scripts/lib/ are updated together); nothing was done" >&2
  exit 1
fi
# shellcheck disable=SC2034  # read by lib/dirty-guard-lock.sh
DGLOCK_PREFIX="[sync-strategy-files]"   # this script has always written its name in brackets
trap 'dglock_release' EXIT   # set BEFORE the lock is asked for: a signal that arrives between the library's mkdir and its owner record must still remove the empty directory
rc=0; dglock_acquire "$GIT_DIR" sync-strategy-files || rc=$?   # on the left of ||: safe under set -e
case "$rc" in
  0) ;;
  1) echo "[sync-strategy-files] lock busy (guard or canon-refresh running), skipping this cycle -- $DGLOCK_REASON" >&2; exit 0 ;;
  *) echo "[sync-strategy-files] $DGLOCK_REASON" >&2; exit 1 ;;
esac

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

HAVE_FILES_TO_SYNC=true
if [ "${#FILES_TO_SYNC[@]}" -eq 0 ]; then
  # origin/main itself has zero paths matching our scope right now (every WP card and
  # current/*.md gone at once -- plausible for current/ alone after a Day Close archives
  # the last plan) -- the update loop below has nothing to do, but a path this script
  # mirrored earlier can still be sitting stale in the canon and the removal loop below
  # must still run for it (WP-530, found 04.10.2026 by Codex review: this exit used to
  # skip removal entirely, undoing the whole point of the fix on exactly the shape it
  # was meant to cover).
  HAVE_FILES_TO_SYNC=false
  echo "$TS [sync-strategy-files] no files matched on origin/main for the update loop" >&2
fi

# A staged path is OUR stale mirror -- refreshable without data loss -- only
# when every check of the peer-agreed contract passes (WP-5 F42-B recurrence,
# peer-session 2026-09-12-17: Codex arbitration + Kimi hardening):
#   1. worktree content == index content (no unstaged edits on the path);
#   2. path is inside this script's own sync scope (guaranteed by the caller --
#      the function is only reached for FILES_TO_SYNC entries);
#   3. index blob differs from the current origin blob (refresh is meaningful);
#   4. index blob is some PAST origin/main version of this path (bounded scan --
#      mirrors are always recent, 200 revisions is plenty);
#   5. index blob does not appear in local-only commits of this path -- a
#      deliberate local revert to an old origin version is human work, not a
#      mirror (peer-agreed replacement for an "authorship" check, which staged
#      blobs do not carry).
is_own_stale_mirror() {
  local file="$1"
  git diff --quiet -- "$file" 2>/dev/null || return 1

  local index_blob remote_blob
  index_blob=$(git rev-parse ":${file}" 2>/dev/null) || return 1
  remote_blob=$(git rev-parse "${REMOTE}/${BRANCH}:${file}" 2>/dev/null) || return 1
  [ "$index_blob" != "$remote_blob" ] || return 1

  local rev matched=false
  for rev in $(git rev-list -n 200 "${REMOTE}/${BRANCH}" -- "$file"); do
    if [ "$(git rev-parse "${rev}:${file}" 2>/dev/null)" = "$index_blob" ]; then
      matched=true
      break
    fi
  done
  [ "$matched" = true ] || return 1

  for rev in $(git rev-list HEAD --not "${REMOTE}/${BRANCH}" -- "$file"); do
    if [ "$(git rev-parse "${rev}:${file}" 2>/dev/null)" = "$index_blob" ]; then
      return 1
    fi
  done
  return 0
}

SYNCED=0
SKIPPED=0
SKIPPED_DIRTY=0
SKIPPED_AHEAD=0
FAILED=0
REMOVED=0
SKIPPED_REMOVE_DIRTY=0
SKIPPED_REMOVE_AHEAD=0

if [ "$HAVE_FILES_TO_SYNC" = true ]; then

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
  # "чисто" — безвредно. Не трогаем, что бы ни было на remote — кроме одного
  # доказуемого случая: наше же протухшее зеркало (см. is_own_stale_mirror).
  if ! git diff --quiet HEAD -- "$FILE" 2>/dev/null; then
    if is_own_stale_mirror "$FILE"; then
      # Refresh our own stale mirror to the current origin content. Without
      # this, a mirror staged from an older origin tip is treated as "dirty"
      # forever, canon-refresh stops recognizing the tree as a single-tip
      # mirror, and tsekh1-git-sync deadlocks (WP-5 F42-B recurrence,
      # peer-session 2026-09-12-17, Kimi+Codex contract).
      if git checkout "${REMOTE}/${BRANCH}" -- "$FILE" 2>/dev/null; then
        SYNCED=$((SYNCED + 1))
        echo "$TS [sync-strategy-files] refreshed own stale mirror: $FILE" >&2
      else
        FAILED=$((FAILED + 1))
        echo "$TS [sync-strategy-files] FAIL refreshing stale mirror: $FILE" >&2
      fi
      continue
    fi
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
fi

# is_own_removed_mirror: generalises is_own_stale_mirror() above to a path origin/main has
# removed ENTIRELY (not just advanced) -- a mirror this script itself staged from some past
# origin tip is not "dirty" just because origin went on to delete the path (Codex review,
# 04.10.2026: the first version of this fix used a bare `git diff HEAD` dirty-check here, which
# misclassified exactly the shape that caused the original incident -- the canon's DayPlan had
# already been refreshed to the pre-archival origin content by this same mirror logic, so it
# differed from HEAD and was treated as human work forever).
is_own_removed_mirror() {
  local file="$1" index_blob
  git diff --quiet -- "$file" 2>/dev/null || return 1   # worktree must equal the index -- no unstaged edit on top
  index_blob=$(git rev-parse ":${file}" 2>/dev/null) || return 1   # must be staged -- nothing of ours to recognise otherwise

  # Bounded scan (same 200-revision limit as is_own_stale_mirror() above): mirrors are always
  # from a recent origin tip, and an unbounded walk on a long-lived path's full history would be
  # a real cost (Codex review, 04.10.2026).
  local rev matched=false
  for rev in $(git rev-list -n 200 "${REMOTE}/${BRANCH}" -- "$file" 2>/dev/null); do
    if [ "$(git rev-parse "${rev}:${file}" 2>/dev/null)" = "$index_blob" ]; then
      matched=true
      break
    fi
  done
  [ "$matched" = true ] || return 1

  local ahead_revs
  # A failed check (not "no local-only commits") must not be read as "safe to remove" -- same
  # fail-closed principle as the pipeline fix above, applied here since this is new code from the
  # same review (Codex, 04.10.2026).
  ahead_revs=$(git rev-list HEAD --not "${REMOTE}/${BRANCH}" -- "$file" 2>/dev/null) || return 1
  for rev in $ahead_revs; do
    [ "$(git rev-parse "${rev}:${file}" 2>/dev/null)" = "$index_blob" ] && return 1
  done
  return 0
}

# A tracked path this script's scope covers but origin/main no longer has at all
# (renamed or deleted there -- WP-530, found 04.10.2026: current/DayPlan *.md stayed
# staged forever after Day Close moved it to archive/day-plans/, and the published-
# ledger transaction refuses any staged path it cannot resolve on origin) is removed
# here, under the same two guards as a content update above: a path with local work
# (dirty) or an unpublished local commit (ahead) is left for a human/publish to settle.
# git ls-files, not `git ls-tree HEAD`: a mirror this script staged but never committed
# (origin deleted the path before the next commit landed) lives only in the index, and
# `ls-tree HEAD` would silently never see it -- the second defect Codex's review found.
TRACKED_IN_SCOPE=$(git ls-files -- inbox current MEMORY.md 2>/dev/null \
  | grep -E '^(inbox/WP-.*\.md|current/[^/]+\.md|MEMORY\.md)$' || true)
while IFS= read -r FILE; do
  [ -n "$FILE" ] || continue
  case "$FILE" in inbox/fleeting-notes.md) continue ;; esac
  # Still present on origin under this exact path: the update loop above owns it.
  git rev-parse -q --verify "${REMOTE}/${BRANCH}:${FILE}" >/dev/null 2>&1 && continue

  if git diff --quiet HEAD -- "$FILE" 2>/dev/null; then
    :   # clean relative to HEAD -- ordinary case, fall through to the ahead-guard below
  elif is_own_removed_mirror "$FILE"; then
    :   # our own stale mirror, now orphaned by origin deleting the path entirely
  else
    SKIPPED_REMOVE_DIRTY=$((SKIPPED_REMOVE_DIRTY + 1))
    continue
  fi
  if [ "$REPO_DIVERGED" = true ]; then
    # -n 1, no pipe to grep (Codex review 04.10.2026, reproduced with 1500 local commits): `git
    # rev-list ... | grep -q .` lets grep exit the instant it reads one match and close the pipe;
    # under `pipefail`, git's own SIGPIPE exit (141) then OUTRANKS grep's real "found a match" (0),
    # so a long unpublished history silently looked like "no local work" and the guard let the
    # deletion through. `-n 1` caps git's own work and removes the pipe entirely -- a failed check
    # (not "zero matches", an actual git error) also defaults to NOT removing.
    if ! LOCAL_ONLY_REV=$(git rev-list -n 1 HEAD --not "${REMOTE}/${BRANCH}" -- "$FILE" 2>/dev/null); then
      SKIPPED_REMOVE_AHEAD=$((SKIPPED_REMOVE_AHEAD + 1))
      continue
    fi
    if [ -n "$LOCAL_ONLY_REV" ]; then
      # A local-only commit touched this path (edited or itself removed/moved it) and has
      # not reached origin yet -- that is git history we must not race past.
      SKIPPED_REMOVE_AHEAD=$((SKIPPED_REMOVE_AHEAD + 1))
      continue
    fi
  fi
  # -f: both guards above already proved this safe (clean vs HEAD, or our own stale mirror of a
  # past origin tip) -- plain `git rm` refuses whenever the index differs from HEAD, which is
  # exactly the own-stale-mirror shape by design, not a reason to leave the path stuck.
  if git rm -q -f -- "$FILE" 2>/dev/null; then
    REMOVED=$((REMOVED + 1))
    echo "$TS [sync-strategy-files] removed (gone on origin/main): $FILE" >&2
  else
    FAILED=$((FAILED + 1))
    echo "$TS [sync-strategy-files] FAIL removing: $FILE" >&2
  fi
done <<< "$TRACKED_IN_SCOPE"

if [ "$((SKIPPED_DIRTY + SKIPPED_AHEAD + SKIPPED_REMOVE_DIRTY + SKIPPED_REMOVE_AHEAD))" -gt 0 ]; then
  echo "$TS [sync-strategy-files] WARN: $SKIPPED_DIRTY file(s) skipped-dirty, $SKIPPED_AHEAD file(s) skipped-ahead, $SKIPPED_REMOVE_DIRTY file(s) skipped-remove-dirty, $SKIPPED_REMOVE_AHEAD file(s) skipped-remove-ahead (local work not yet committed/pushed)" >&2
fi

echo "$TS [sync-strategy-files] synced=$SYNCED skipped=$SKIPPED skipped_dirty=$SKIPPED_DIRTY skipped_ahead=$SKIPPED_AHEAD removed=$REMOVED skipped_remove_dirty=$SKIPPED_REMOVE_DIRTY skipped_remove_ahead=$SKIPPED_REMOVE_AHEAD failed=$FAILED"
exit 0
