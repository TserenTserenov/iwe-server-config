#!/bin/bash
# test-destructive-guard-frozen-staging.sh — РП-561 Ф54: `git add <path>` and
# `git restore --staged` are refused inside a frozen canonical checkout (the
# index is shared, a foreign commit would swallow the staged files) and allowed
# in every other repo, including an isolated worktree.
#
# Запуск: bash .claude/hooks/tests/test-destructive-guard-frozen-staging.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/destructive-guard.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP_DIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# An unrelated repo and a linked worktree of ROOT: both must stay writable.
OTHER="$TMP_DIR/other"
git init -q "$OTHER"
WT="$TMP_DIR/worktree"
git -C "$ROOT" worktree add -q --detach "$WT" HEAD 2>/dev/null

# expect $1=desc $2=want(block|pass) $3=cwd $4=command [$5=env assignment]
expect() {
  local desc="$1" want="$2" cwd="$3" cmd="$4" envset="${5:-NOOP=1}" got rc
  jq -n --arg c "$cmd" --arg d "$cwd" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
    | env "$envset" bash "$HOOK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] && got=block || got=pass
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc (want $want, got $got, rc=$rc)"
  fi
}

expect "git add <path> in frozen root"            block "$ROOT" "git add scripts/x.sh"
expect "git restore --staged in frozen root"      block "$ROOT" "git restore --staged scripts/x.sh"
expect "git restore -S in frozen root"            block "$ROOT" "git restore -S scripts/x.sh"
expect "git -C <frozen root> add from elsewhere"  block "$OTHER" "git -C $ROOT add a.md"
expect "git add in unrelated repo"                pass  "$OTHER" "git add a.md"
expect "git add in linked worktree"               pass  "$WT" "git add a.md"
expect "freeze switched off by empty override"    pass  "$ROOT" "git add scripts/x.sh" "IWE_FROZEN_CANONICAL_PATH="
expect "git status is not staging"                pass  "$ROOT" "git status"
expect "git restore without --staged"             pass  "$ROOT" "git restore file.txt"
expect "quoted text is not a git call"            pass  "$ROOT" "echo git add foo"

git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null

echo "frozen-staging: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
