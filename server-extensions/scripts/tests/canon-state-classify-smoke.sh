#!/usr/bin/env bash
# canon-state-classify-smoke.sh — WP-538/545 (09.10.2026).
# Проверяет canon_state_path_class() на одноразовом git-репозитории с тремя
# заранее известными классами путей: зеркало (равно origin), служебная
# карточка очереди (RUN-*.md), настоящая незакоммиченная правка. Без
# изоляции по классу тест может молча деградировать до "не упал, но ничего
# не проверяет" (P1).
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]}"; case "$SCRIPT_DIR" in */*) SCRIPT_DIR="${SCRIPT_DIR%/*}" ;; *) SCRIPT_DIR=. ;; esac
LIB="$SCRIPT_DIR/../lib/canon-state.sh"
CONTRACT="$SCRIPT_DIR/../automation-contract.conf"
# shellcheck source=../lib/canon-state.sh
. "$LIB"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO/inbox/agent/tasks" "$REPO/current" "$REPO/docs"
git -C "$WORK" init -q "$REPO"
git -C "$REPO" config user.email test@test.local
git -C "$REPO" config user.name test

echo "mirror content, same on both sides" > "$REPO/current/DayPlan.md"
echo "original strategy text" > "$REPO/docs/Strategy.md"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "initial"

# A bare "remote" that is just the far side of HEAD~0 — pulling origin after
# this commit gives origin/main == HEAD, which is what canon_state_path_class
# compares the worktree blob against.
git -C "$REPO" remote add origin "$REPO"
git -C "$REPO" fetch -q origin main

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

cd "$REPO"

# Класс 1: mirror — рабочее дерево побайтно равно origin/main (committed, untouched).
CLASS=$(canon_state_path_class "current/DayPlan.md" "origin/main" "$CONTRACT")
check "файл, равный origin, классифицирован как mirror" "mirror" "$CLASS"

# Класс 2: queue — служебная карточка раннера inbox/agent/tasks/RUN-*.md (новый, untracked).
echo "task card" > "$REPO/inbox/agent/tasks/RUN-smoke-test.md"
CLASS=$(canon_state_path_class "inbox/agent/tasks/RUN-smoke-test.md" "origin/main" "$CONTRACT")
check "служебная карточка очереди классифицирована как queue" "queue" "$CLASS"

# Класс 3: real — файл отличается от origin и не матчит ни один allowlist.
echo "changed, not published anywhere" > "$REPO/docs/Strategy.md"
CLASS=$(canon_state_path_class "docs/Strategy.md" "origin/main" "$CONTRACT")
check "настоящая правка классифицирована как real" "real" "$CLASS"

# Сквозная проверка canon_state(): при двух реальных дырках (RUN-карточка +
# правка Strategy.md) итог должен отличить одну от другой, не слить их в
# одно число.
STATE_OUT=$(canon_state "$REPO")
QUEUE_N=$(echo "$STATE_OUT" | grep '^paths_queue:' | awk '{print $2}')
REAL_N=$(echo "$STATE_OUT" | grep '^paths_real:' | awk '{print $2}')
check "canon_state() насчитал ровно 1 служебную карточку" "1" "$QUEUE_N"
check "canon_state() насчитал ровно 1 настоящую правку" "1" "$REAL_N"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
