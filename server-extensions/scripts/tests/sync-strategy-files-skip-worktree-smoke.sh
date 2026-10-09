#!/usr/bin/env bash
# sync-strategy-files-skip-worktree-smoke.sh — WP-538/545 (09.10.2026, пир-сессия
# Claude+Kimi+Codex). Проверяет новый режим (skip-worktree + сайдкар-хеш), не
# дублируя sync-strategy-files-stale-mirror-smoke.sh (тот покрывает старый путь).
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]}"; case "$SCRIPT_DIR" in */*) SCRIPT_DIR="${SCRIPT_DIR%/*}" ;; *) SCRIPT_DIR=. ;; esac
SYNC_SCRIPT="${1:-$SCRIPT_DIR/../sync-strategy-files.sh}"
[ -x "$SYNC_SCRIPT" ] || chmod +x "$SYNC_SCRIPT" 2>/dev/null || true

PASS=0
FAIL=0
check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

setup_repo_with_history() {
  # Два настоящих коммита (v1 -> v2) на main=origin (remote=self), чтобы
  # is_own_stale_mirror() нашёл v1 в rev-list origin/main -- file.
  local repo="$1"
  mkdir -p "$repo/inbox/WP-1"
  git init -q "$repo"
  git -C "$repo" config user.email t@t.local
  git -C "$repo" config user.name t
  echo "v1" > "$repo/inbox/WP-1/WP-1.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m v1
  echo "v2 (текущий origin)" > "$repo/inbox/WP-1/WP-1.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m v2
  git -C "$repo" remote add origin "$repo"
  # Застейдить v1 поверх HEAD=v2, не коммитя -- ровно форма "протухшего
  # зеркала": index == прошлая origin-версия, HEAD/worktree уже на v2.
  git -C "$repo" show "HEAD~1:inbox/WP-1/WP-1.md" > "$repo/inbox/WP-1/WP-1.md"
  git -C "$repo" add inbox/WP-1/WP-1.md
}

setup_repo() {
  local repo="$1"
  mkdir -p "$repo/inbox/WP-1"
  git init -q "$repo"
  git -C "$repo" config user.email t@t.local
  git -C "$repo" config user.name t
  echo "v1" > "$repo/inbox/WP-1/WP-1.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m init
  git -C "$repo" remote add origin "$repo"
}

run_sync() {
  local repo="$1"
  "$SYNC_SCRIPT" "$repo" 2>&1
}

## Сценарий 1 — миграция: путь уже застейджен как собственное зеркало (checkout из origin,
## не закоммичено) -> первый прогон должен перевести его на skip-worktree.
WORK1=$(mktemp -d)
setup_repo_with_history "$WORK1/repo"

OUT1=$(run_sync "$WORK1/repo")
IS_SKIP=$(git -C "$WORK1/repo" ls-files -v -- inbox/WP-1/WP-1.md | grep -c '^S ' || true)
check "сценарий 1: путь переведён на skip-worktree после миграции" "1" "$IS_SKIP"
echo "$OUT1" | grep -q "migrated=1" && echo "PASS: сценарий 1: лог показывает migrated=1" && PASS=$((PASS+1)) \
  || { echo "FAIL: сценарий 1: лог не показывает migrated=1: $OUT1"; FAIL=$((FAIL+1)); }

## Сценарий 2 — повторный тик без изменений: skip-worktree путь, содержимое не менялось,
## совпадает с origin -> должен быть skipped, не synced, сайдкар не трогается.
OUT2=$(run_sync "$WORK1/repo")
echo "$OUT2" | grep -q "skipped=1" && echo "PASS: сценарий 2: повторный тик -- skipped=1" && PASS=$((PASS+1)) \
  || { echo "FAIL: сценарий 2: $OUT2"; FAIL=$((FAIL+1)); }

## Сценарий 3 — ручная правка: пилот меняет содержимое skip-worktree-пути напрямую (не
## через скрипт) -> следующий тик НЕ должен перезаписать её и обязан снять skip-worktree.
echo "РУЧНАЯ ПРАВКА ПИЛОТА" > "$WORK1/repo/inbox/WP-1/WP-1.md"
OUT3=$(run_sync "$WORK1/repo")
CONTENT_AFTER=$(cat "$WORK1/repo/inbox/WP-1/WP-1.md")
check "сценарий 3: ручная правка НЕ перезаписана" "РУЧНАЯ ПРАВКА ПИЛОТА" "$CONTENT_AFTER"
IS_SKIP_AFTER=$(git -C "$WORK1/repo" ls-files -v -- inbox/WP-1/WP-1.md | grep -c '^S ' || true)
check "сценарий 3: skip-worktree снят после расхождения" "0" "$IS_SKIP_AFTER"
echo "$OUT3" | grep -q "skipped_manual=1" && echo "PASS: сценарий 3: лог показывает skipped_manual=1" && PASS=$((PASS+1)) \
  || { echo "FAIL: сценарий 3: $OUT3"; FAIL=$((FAIL+1)); }

## Сценарий 4 — fail-closed: skip-worktree установлен, но сайдкар отсутствует (повреждён/
## удалён) -> следующий тик обязан трактовать это как расхождение, не как "первый запуск".
WORK2=$(mktemp -d)
setup_repo_with_history "$WORK2/repo"
run_sync "$WORK2/repo" >/dev/null 2>&1   # первый прогон: мигрирует + создаёт сайдкар
GIT_DIR2=$(git -C "$WORK2/repo" rev-parse --absolute-git-dir)
rm -rf "$GIT_DIR2/sync-strategy-written"   # ломаем сайдкар (имя файла -- хеш пути, не плоская конкатенация)
OUT4=$(run_sync "$WORK2/repo")
echo "$OUT4" | grep -q "skipped_manual=1" && echo "PASS: сценарий 4 (fail-closed): отсутствующий сайдкар трактован как расхождение" && PASS=$((PASS+1)) \
  || { echo "FAIL: сценарий 4: $OUT4"; FAIL=$((FAIL+1)); }

## Сценарий 5 — настоящая работа, НЕ зеркало: путь застейджен с содержимым, которого НЕТ ни
## в одной версии origin -> миграция не должна его трогать (is_own_stale_mirror = false).
WORK3=$(mktemp -d)
setup_repo "$WORK3/repo"
echo "НАСТОЯЩАЯ РАБОТА ПИЛОТА, НЕ ПУБЛИКОВАЛОСЬ" > "$WORK3/repo/inbox/WP-1/WP-1.md"
git -C "$WORK3/repo" add inbox/WP-1/WP-1.md
OUT5=$(run_sync "$WORK3/repo")
IS_SKIP5=$(git -C "$WORK3/repo" ls-files -v -- inbox/WP-1/WP-1.md | grep -c '^S ' || true)
check "сценарий 5: настоящая работа НЕ переведена на skip-worktree" "0" "$IS_SKIP5"
STAGED_CONTENT=$(git -C "$WORK3/repo" show :inbox/WP-1/WP-1.md)
check "сценарий 5: застейдженное содержимое не тронуто" "НАСТОЯЩАЯ РАБОТА ПИЛОТА, НЕ ПУБЛИКОВАЛОСЬ" "$STAGED_CONTENT"

rm -rf "$WORK1" "$WORK2" "$WORK3"

## Сценарий 6 — проход удаления с skip-worktree-путём, который правили вручную:
## путь мигрирован (skip-worktree), ПОТОМ origin (настоящий отдельный remote,
## не self) удаляет его полностью, И пилот правит содержимое на диске вручную
## между тиками. Следующий тик не должен удалить файл с ручной правкой
## (Codex review: removal-проход раньше не сверял содержимое с сайдкаром для
## skip-worktree-путей -- git diff/status не видят такие пути в принципе).
WORK4=$(mktemp -d)
mkdir -p "$WORK4/origin.git"
git init -q --bare "$WORK4/origin.git"
git clone -q "$WORK4/origin.git" "$WORK4/seed" 2>/dev/null
mkdir -p "$WORK4/seed/inbox/WP-1"
git -C "$WORK4/seed" config user.email t@t.local
git -C "$WORK4/seed" config user.name t
echo "v1" > "$WORK4/seed/inbox/WP-1/WP-1.md"
git -C "$WORK4/seed" add -A
git -C "$WORK4/seed" commit -q -m v1
echo "v2 (текущий origin)" > "$WORK4/seed/inbox/WP-1/WP-1.md"
git -C "$WORK4/seed" add -A
git -C "$WORK4/seed" commit -q -m v2
git -C "$WORK4/seed" push -q origin HEAD:main 2>/dev/null || git -C "$WORK4/seed" push -q origin HEAD:master

git clone -q "$WORK4/origin.git" "$WORK4/repo" 2>/dev/null
git -C "$WORK4/repo" config user.email t@t.local
git -C "$WORK4/repo" config user.name t
# Застейдить v1 поверх HEAD=v2 -- форма "протухшего зеркала", как в остальных сценариях.
git -C "$WORK4/repo" show "HEAD~1:inbox/WP-1/WP-1.md" > "$WORK4/repo/inbox/WP-1/WP-1.md"
git -C "$WORK4/repo" add inbox/WP-1/WP-1.md

run_sync "$WORK4/repo" >/dev/null 2>&1   # мигрирует путь на skip-worktree, worktree=v2, сайдкар=hash(v2)
IS_MIGRATED6=$(git -C "$WORK4/repo" ls-files -v -- inbox/WP-1/WP-1.md | grep -c '^S ' || true)
check "сценарий 6: путь мигрирован перед проверкой удаления" "1" "$IS_MIGRATED6"

# Origin (отдельный клон, имитирует другую сессию) удаляет путь полностью и пушит.
git clone -q "$WORK4/origin.git" "$WORK4/other-session" 2>/dev/null
git -C "$WORK4/other-session" config user.email t@t.local
git -C "$WORK4/other-session" config user.name t
git -C "$WORK4/other-session" rm -q inbox/WP-1/WP-1.md
git -C "$WORK4/other-session" commit -q -m "removed on origin by another session"
git -C "$WORK4/other-session" push -q origin HEAD:main 2>/dev/null || git -C "$WORK4/other-session" push -q origin HEAD:master

# Пилот правит содержимое вручную в локальном repo, не трогая git.
echo "РУЧНАЯ ПРАВКА ПИЛОТА ПОСЛЕ УДАЛЕНИЯ НА ORIGIN" > "$WORK4/repo/inbox/WP-1/WP-1.md"

OUT6=$(run_sync "$WORK4/repo")
CONTENT6=$(cat "$WORK4/repo/inbox/WP-1/WP-1.md" 2>/dev/null || echo "ФАЙЛ УДАЛЁН")
check "сценарий 6: ручная правка НЕ удалена вместе с путём" "РУЧНАЯ ПРАВКА ПИЛОТА ПОСЛЕ УДАЛЕНИЯ НА ORIGIN" "$CONTENT6"
echo "$OUT6" | grep -q "removed=0" && echo "PASS: сценарий 6: removed=0 (файл не удалён)" && PASS=$((PASS+1)) \
  || { echo "FAIL: сценарий 6: $OUT6"; FAIL=$((FAIL+1)); }

rm -rf "$WORK4"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
