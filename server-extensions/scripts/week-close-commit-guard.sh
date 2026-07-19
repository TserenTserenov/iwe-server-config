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
