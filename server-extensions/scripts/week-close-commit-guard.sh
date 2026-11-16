#!/usr/bin/env bash
# routing: helper  called-by=week-close  deterministic=true
# see WP-484 Ф4b — protects Week Close's final commit+push from concurrent-session races.
#
# Week Close 19.07 found this happening live: the final commit+push of the governance
# repo had to be re-run 3 times because parallel agent sessions (Kimi/others) kept
# committing+pushing to the same repo between this session's `git status` check and its
# own commit. Week Close is a long (~30 min), manual ritual — other sessions touching the
# same repo during that window is not a fluke, it's the expected case, same root cause
# WP-484 already fixed for Day Open (git-dirty-guard.sh, 2026-07-19).
#
# Unlike git-dirty-guard.sh (which decides whether an ALREADY dirty tree is a stale
# mirror safe to reset), this script wraps the ACT of committing+pushing this session's
# own specific files: pull --rebase right before staging (so the base is fresh), then
# retry commit+push a bounded number of times if push is rejected by someone else's
# concurrent push — each retry re-applies the same pathspec, so it never touches files
# outside what THIS session changed, no matter what landed on origin in between.
#
# Usage:
#   week-close-commit-guard.sh <repo-path> <commit-message> <file1> [file2 ...]
# Exit codes:
#   0 = committed and pushed (possibly after 1+ retries)
#   1 = nothing to commit (pathspec produced an empty diff AND HEAD already matches
#       origin — not an error, just a no-op)
#   2 = usage/repo error, or retries exhausted without a successful push (real conflict —
#       needs a human, printed to stderr)

set -uo pipefail

# The "HEAD already on origin" verdict below (merge-base --is-ancestor) must not trust
# local replacement refs or legacy grafts: a forged object can make an undelivered
# commit look pushed, so the commit is silently never delivered (WP-7 Ф161).
export GIT_NO_REPLACE_OBJECTS=1
export GIT_GRAFT_FILE=/dev/null/iwe-no-grafts

MAX_RETRIES=3

if [ "$#" -lt 3 ]; then
  echo "Использование: week-close-commit-guard.sh <repo-path> <commit-message> <file1> [file2 ...]" >&2
  exit 2
fi

REPO="$1"; shift
MSG="$1"; shift
FILES=("$@")

cd "$REPO" 2>/dev/null || { echo "week-close-commit-guard: не удалось перейти в $REPO" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "week-close-commit-guard: $REPO — не git-репозиторий" >&2; exit 2; }

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || { echo "week-close-commit-guard: detached HEAD в $REPO, отказ" >&2; exit 2; }

# WP-530 Ф150 (б). The main DS-my-strategy checkout is advanced only by
# tsekh1-git-sync.sh, which claims the paths first. There this script does not
# pull, stage, commit or push in the checkout itself:
#   1. it commits the listed files in a temporary linked worktree (the
#      repository's commit hooks run as for any commit),
#   2. publishes that commit through ds-publish.sh,
#   3. under ds-commit.lock writes the published version into each listed file
#      that still holds exactly what was committed (compared with the
#      committed blob, not with origin: Fable H1 of 15.11),
#   4. asks the sync for a pass. The sync admits working-tree files that are
#      byte-equal to its fast-forward target (dirty-ff-admission.py), so the
#      checkout catches up and the files never show an older version (Fable M3).
# Any other checkout keeps the loop below unchanged.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sync-owned-canon.sh
. "$SCRIPT_DIR/lib/sync-owned-canon.sh" \
  || { echo "week-close-commit-guard: нет $SCRIPT_DIR/lib/sync-owned-canon.sh — не могу отличить основную копию, отказ" >&2; exit 2; }

# entry_of <rev> <path>: "<mode> <blob>" or "absent".
entry_of() {
  local line
  line=$(git ls-tree "$1" -- "$2")
  [ -n "$line" ] || { echo absent; return; }
  echo "$(echo "$line" | cut -d' ' -f1) $(echo "$line" | cut -d' ' -f3 | cut -f1)"
}

# file_entry <file> <repo-path>: "<mode> <blob>" as Git would record <file> at
# <repo-path> (a symlink as 120000 + its target), "absent", or "other" (directory).
file_entry() {
  local mode=100644
  if [ -L "$1" ]; then echo "120000 $(printf '%s' "$(readlink -- "$1")" | git hash-object --stdin)"; return; fi
  if [ -e "$1" ] && [ ! -f "$1" ]; then echo other; return; fi
  [ -e "$1" ] || { echo absent; return; }
  [ -x "$1" ] && mode=100755
  echo "$mode $(git hash-object --path="$2" -- "$1")"
}

# index_entry <path>: "<mode> <blob>" of the main checkout's index entry, or "absent".
index_entry() {
  local line
  line=$(git ls-files -s -- ":(literal)$1")
  [ -n "$line" ] || { echo absent; return; }
  echo "$(echo "$line" | cut -d' ' -f1) $(echo "$line" | cut -d' ' -f2)"
}

# published_in_range <path> <"mode blob">: is this exactly a version of the
# path committed in (HEAD, origin/$BRANCH]? The same rule the sync applies
# (dirty-ff-admission.py published_versions), so a file this script calls
# published is one the sync fast-forwards over.
published_in_range() {
  local commit
  for commit in $(git log --format=%H --no-renames "HEAD..origin/$BRANCH" -- ":(literal)$1"); do
    [ "$(entry_of "$commit" "$1")" = "$2" ] && return 0
  done
  return 1
}

# check_files: every listed path is a repository-relative file the sync can
# later fast-forward over; refusals happen before anything is committed.
#   - exists in the checkout or in HEAD (a typo must not drop out, Fable M1);
#   - not a directory, not under machine/ledger/ (journal writers do not take
#     ds-commit.lock, so the sync never treats them as published);
#   - its index entry equals HEAD (a staged change blocks the sync, review С1).
# Absolute paths inside the checkout are made relative (review Н4).
check_files() {
  local i path top
  top=$(pwd -P)
  for i in "${!FILES[@]}"; do
    path="${FILES[$i]}"
    case "$path" in
      /*)
        # Compare physical paths: on macOS /var is a symlink to /private/var,
        # so a logical argument never matches `pwd -P`. Only the directory is
        # resolved; the file name stays as given (a symlink file is committed
        # as itself). A folder that no longer exists (a deleted file whose
        # folder went with it) keeps the textual comparison.
        local dir phys
        if dir=$(cd "${path%/*}/" 2>/dev/null && pwd -P); then
          phys="$dir/${path##*/}"
        else
          phys="$path"
        fi
        case "$phys" in
          "$top"/*) path="${phys#"$top"/}" ;;
          *) echo "week-close-commit-guard: путь вне хранилища: $path" >&2; return 2 ;;
        esac
        ;;
    esac
    FILES[i]="$path"
    if [ ! -e "$path" ] && [ ! -L "$path" ] && [ "$(entry_of HEAD "$path")" = absent ]; then
      echo "week-close-commit-guard: нет такого файла ни в копии, ни в HEAD: $path" >&2; return 2
    fi
    if [ -d "$path" ] && [ ! -L "$path" ]; then
      echo "week-close-commit-guard: указан каталог, нужны файлы: $path" >&2; return 2
    fi
    case "$path" in
      machine/ledger/*) echo "week-close-commit-guard: журнал событий публикует свой писатель, не закрытие недели: $path" >&2; return 2 ;;
    esac
    if [ "$(index_entry "$path")" != "$(entry_of HEAD "$path")" ]; then
      echo "week-close-commit-guard: файл стоит в индексе основной копии (git add/rm) — синхронизация его не пропустит, нужна ручная проверка: $path" >&2; return 2
    fi
  done
}

# commit_in_worktree <scratch> <path>...: commits the given paths on HEAD in a
# temporary linked worktree, so the repository's commit hooks run; prints the
# new commit. Exit 2 = error.
commit_in_worktree() {
  local wt="$1/wt" path rc=0
  shift
  git worktree add -q --detach "$wt" HEAD >&2 || return 2
  for path in "$@"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      mkdir -p -- "$wt/$(dirname -- "$path")" && cp -P -p -- "$path" "$wt/$path" || rc=2
    else
      rm -f -- "$wt/$path"
    fi
  done
  if [ "$rc" -eq 0 ] && git -C "$wt" add -A -- "$@" >&2; then
    if git -C "$wt" diff --cached --quiet; then
      echo "week-close-commit-guard: во временной копии пустой коммит" >&2; rc=2
    elif git -C "$wt" commit -q -m "$MSG" >&2; then
      git -C "$wt" rev-parse HEAD
    else
      echo "week-close-commit-guard: git commit во временной копии не прошёл (хуки коммита?)" >&2; rc=2
    fi
  else
    rc=2
  fi
  git worktree remove --force "$wt" >&2 || echo "week-close-commit-guard: временная копия $wt не удалена" >&2
  return "$rc"
}

# put_published <path> <"mode blob"> <scratch-file>: link the published
# version in only while the path is free (ln refuses an existing path).
put_published() {
  local path="$1" mode="${2%% *}" blob="${2#* }" scratch="$3"
  mkdir -p -- "$(dirname -- "$path")" || return 1
  git cat-file blob "$blob" > "$scratch" || return 1
  [ "$mode" = 100755 ] && chmod +x "$scratch"
  ln -- "$scratch" "$path" 2>/dev/null || { rm -f -- "$scratch"; return 1; }
  rm -f -- "$scratch"
}

# hand_over_published <lock>: for each listed file still holding the bytes
# recorded before the commit (OURS[i], same index as FILES), write the
# published version (origin/$BRANCH) in its place. Under ds-commit.lock, the
# lock the sync takes around its fast-forward. The file is renamed into .git
# first (atomic) and the moved copy compared with the record, so an edit
# written meanwhile lands in a fresh file that is kept. The moved copy is
# dropped only after the published version is in place and the copy is
# compared once more (a writer holding it open may have appended, review Н1).
# Prints the kept paths; they keep the sync blocked until someone looks.
hand_over_published() {
  local lock="$1" hold i path ours published held n=0 kept=()
  hold="$(git rev-parse --absolute-git-dir)/week-close-handover/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$hold" "${lock%/*}" || return 1
  exec 7>"$lock" || return 1
  flock -w 30 7 || { exec 7>&-; rmdir "$hold"; echo "week-close-commit-guard: ds-commit.lock занят 30 с — опубликованная версия не записана; повторите команду" >&2; return 1; }
  for i in "${!FILES[@]}"; do
    path="${FILES[$i]}"
    ours="${OURS[$i]}"
    published=$(entry_of "origin/$BRANCH" "$path")
    [ "$published" = "$ours" ] && continue          # already what the sync moves to
    [ "$ours" = "$(entry_of HEAD "$path")" ] && continue  # untouched: an ordinary fast-forward path
    case "${ours%% *}/${published%% *}" in
      100644/100644|100644/100755|100755/100644|100755/100755|absent/100644|absent/100755) ;;
      *) kept+=("$path"); continue ;;  # only plain files are written here
    esac
    [ "$(file_entry "$path" "$path")" = "$ours" ] || { kept+=("$path"); continue; }
    n=$((n + 1))
    held=""
    if [ "$ours" != absent ]; then
      held="$hold/$n"
      mv -- "$path" "$held" || { kept+=("$path"); continue; }
      if [ "$(file_entry "$held" "$path")" != "$ours" ]; then
        # Returned without overwriting: ln refuses a path recreated meanwhile (review Н2).
        ln -- "$held" "$path" 2>/dev/null && rm -f -- "$held"
        kept+=("$path"); continue
      fi
    fi
    if ! put_published "$path" "$published" "$hold/new-$n"; then
      kept+=("$path"); continue  # a writer recreated the path: theirs stays, ours stays in $hold
    fi
    if [ -n "$held" ] && [ "$(file_entry "$held" "$path")" = "$ours" ]; then
      rm -f -- "$held"
    fi
  done
  exec 7>&-
  rmdir "$hold" 2>/dev/null || echo "week-close-commit-guard: копии файлов, изменённых во время передачи, сохранены в $hold" >&2
  if [ "${#kept[@]}" -gt 0 ]; then
    echo "week-close-commit-guard: ВНИМАНИЕ: оставлены в основной копии без замены опубликованной версией, синхронизация на них остановится: ${kept[*]}"
  fi
  return 0
}

publish_from_main_checkout() {
  local iwe commit i path ours to_commit=() unresolved=() already=0 rc=0 publish_rc=0
  iwe="${IWE_ROOT:-$(cd "$REPO/.." && pwd)}"
  SCRATCH=$(mktemp -d) || exit 2
  trap 'rm -rf "$SCRATCH"' EXIT

  check_files || exit 2
  git fetch -q origin "$BRANCH" || { echo "week-close-commit-guard: git fetch origin $BRANCH не прошёл" >&2; exit 2; }
  git merge-base --is-ancestor HEAD "origin/$BRANCH" 2>/dev/null \
    || { echo "week-close-commit-guard: основная копия опережает origin/$BRANCH или разошлась с ним — после заморозки так быть не должно, нужна ручная проверка" >&2; exit 2; }

  # Record each file before committing. A file equal to HEAD needs nothing; one
  # equal to a version already published in (HEAD, origin] was published by an
  # earlier attempt or another session: it is not committed again, only handed
  # over (review С2: a retry finishes the hand-over instead of failing).
  OURS=()
  for i in "${!FILES[@]}"; do
    path="${FILES[$i]}"
    ours=$(file_entry "$path" "$path")
    OURS[i]="$ours"
    if [ "$ours" = "$(entry_of HEAD "$path")" ]; then
      continue
    elif published_in_range "$path" "$ours"; then
      already=$((already + 1))
    else
      to_commit+=("$path")
    fi
  done

  if [ "${#to_commit[@]}" -eq 0 ] && [ "$already" -eq 0 ]; then
    echo "week-close-commit-guard: указанные файлы не отличаются от HEAD — нечего коммитить"
    exit 1
  fi
  if [ "${#to_commit[@]}" -gt 0 ]; then
    commit=$(commit_in_worktree "$SCRATCH" "${to_commit[@]}") || rc=$?
    [ "$rc" -eq 0 ] || exit 2
    DS_PUBLISH_CANON_SYNC=caller bash "$REPO/scripts/ds-publish.sh" "$REPO" normal \
      --from-commit "$commit" --mode retry-wrapper --reason "week-close: $MSG" || publish_rc=$?
    if [ "$publish_rc" -ne 0 ]; then
      echo "week-close-commit-guard: публикация через ds-publish.sh не прошла (код $publish_rc; 22 — конфликт содержимого с origin) — основная копия не тронута, коммит $commit сохранён, нужна ручная проверка" >&2
      exit 2
    fi
    echo "week-close-commit-guard: опубликовано через ds-publish.sh"
    git fetch -q origin "$BRANCH" || { echo "week-close-commit-guard: после публикации fetch не прошёл — опубликованная версия не записана; повторите команду" >&2; rc=3; }
  else
    echo "week-close-commit-guard: файлы уже опубликованы прошлой попыткой — доделываю передачу основной копии"
  fi

  if [ "$rc" -eq 0 ]; then
    hand_over_published "$iwe/.claude/state/ds-commit.lock" \
      || echo "week-close-commit-guard: опубликованная версия не записана — файлы оставлены как есть" >&2
  fi
  # A file still holding our bytes that no published commit has (origin merged
  # it, and the hand-over did not happen) blocks the sync: not a success (third
  # review С1). Someone else's later edit is not counted here.
  unresolved=()
  for i in "${!FILES[@]}"; do
    path="${FILES[$i]}"
    ours=$(file_entry "$path" "$path")
    if [ "$ours" = "${OURS[$i]}" ] && [ "$ours" != "$(entry_of HEAD "$path")" ] \
        && ! published_in_range "$path" "$ours"; then
      unresolved+=("$path")
    fi
  done
  # The sync runs in its own environment (server timer, Mac backstop), never
  # inside this session: this process may hold the caller's locks.
  # shellcheck source=/dev/null
  if . "$REPO/scripts/lib/canon-sync-request.sh" 2>/dev/null; then
    echo "week-close-commit-guard: $(IWE_WORKSPACE="$iwe" canon_sync_request)"
  else
    echo "week-close-commit-guard: перемотку основной копии сделает периодическая синхронизация" >&2
  fi
  if [ "${#unresolved[@]}" -gt 0 ]; then
    echo "week-close-commit-guard: опубликовано, но в основной копии остались неопубликованные версии этих файлов — синхронизация на них остановится, нужна ручная проверка: ${unresolved[*]}" >&2
    exit 2
  fi
  # Exit 1 keeps the ritual's contract "already done on a previous attempt".
  [ "${#to_commit[@]}" -gt 0 ] || exit 1
  exit 0
}

if sync_owned_canon "$REPO"; then
  publish_from_main_checkout
fi

attempt=1
while [ "$attempt" -le "$MAX_RETRIES" ]; do
  echo "week-close-commit-guard: попытка $attempt/$MAX_RETRIES"

  # Свежая база перед стейджингом — если кто-то уже закоммитил и запушил между попытками,
  # эта правка это подтянет, не оставляя коммит на устаревшем родителе. --autostash: Week
  # Close обычно оставляет незакоммиченными файлы ВНЕ текущего pathspec (шаги 1-10 ещё не
  # все застейджены) — живой тест подтвердил, что голый `pull --rebase` отказывается
  # работать на такой (легитимно грязной для других файлов) копии.
  if ! git pull --rebase --autostash origin "$BRANCH" 2>&1; then
    echo "week-close-commit-guard: git pull --rebase --autostash не прошёл — вероятно конфликт rebase или конфликт автостеша; нужна ручная проверка" >&2
    exit 2
  fi

  # `pull --rebase --autostash` возвращает 0, даже если сам rebase прошёл, а откат
  # autostash обратно упал в конфликт (cold-review находка, WP-484 Ф4b, воспроизведено
  # живьём: rebase — fast-forward, применение стеша — отдельная операция после, её
  # конфликт не влияет на код возврата pull). Без этой проверки `git add` ниже застейджил
  # бы файл с сырыми конфликт-маркерами `<<<<<<<`/`=======`/`>>>>>>>` как обычный текст,
  # а `git commit` их не ловит — коммит и push ушли бы молча с битым содержимым.
  if [ -n "$(git stash list)" ]; then
    echo "week-close-commit-guard: после pull остался неприменённый autostash — откат других изменений в конфликт с origin, нужна ручная проверка (git stash list, git status)" >&2
    exit 2
  fi

  git add "${FILES[@]}" || { echo "week-close-commit-guard: git add не прошёл для указанных файлов" >&2; exit 2; }

  if git diff --cached --quiet -- "${FILES[@]}"; then
    # Пустой diff означает "нечего коммитить" ТОЛЬКО если HEAD уже совпадает с origin — иначе
    # это предыдущая попытка этого же цикла: закоммитила локально, но push словил reject ДО
    # rebase (см. заголовок цикла), rebase перенёс коммит вперёд, и теперь его просто нужно
    # допушить, а не считать работу отсутствующей (живой тест на синтетической гонке поймал
    # именно этот случай — без этой проверки скрипт молча выходил с "нечего коммитить", хотя
    # коммит реально не долетел до origin).
    if git merge-base --is-ancestor HEAD "origin/$BRANCH" 2>/dev/null; then
      echo "week-close-commit-guard: пустой diff по указанным файлам и HEAD уже на origin — нечего коммитить"
      exit 1
    fi
    echo "week-close-commit-guard: пустой diff, но HEAD опережает origin/$BRANCH — коммит уже сделан на предыдущей попытке, допушиваю"
  else
    if ! git commit -m "$MSG" -- "${FILES[@]}"; then
      echo "week-close-commit-guard: git commit не прошёл" >&2
      exit 2
    fi
  fi

  if git push origin "$BRANCH"; then
    echo "week-close-commit-guard: закоммичено и запушено на попытке $attempt"
    exit 0
  fi

  echo "week-close-commit-guard: push отклонён (попытка $attempt/$MAX_RETRIES) — вероятно параллельная сессия запушила первой, повторяю с pull --rebase"
  attempt=$((attempt + 1))
done

echo "week-close-commit-guard: push не прошёл после $MAX_RETRIES попыток — реальный конфликт, нужна ручная проверка (git status, git log --oneline -5)" >&2
exit 2
