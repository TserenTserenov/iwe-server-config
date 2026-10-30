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
# Real git-dir of the frozen checkout (a file `.git` in a linked worktree, a directory otherwise).
ROOTGIT="$(git -C "$ROOT" rev-parse --absolute-git-dir)"
SPACED="$TMP_DIR/dir with space"
git init -q "$SPACED"

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

# РП-561 Ф54, 29.10: the target is the real index file, not the hook's cwd.
# False block: the staging happens in another repo inside a subshell.
expect "subshell cd to another repo (was a false block)" pass  "$ROOT" "(cd $OTHER && git add a.md)"
expect "subshell cd to linked worktree"                  pass  "$ROOT" "(cd $WT && git add a.md)"
expect "-C chain stays relative to the previous -C"      pass  "$ROOT" "git -C $TMP_DIR -C other add a.md"
expect "path with spaces in -C"                          pass  "$ROOT" "git -C '$SPACED' add a.md"
expect "'-C' as a pathspec is not an option"             pass  "$OTHER" "git add -- -C"
expect "assigned variable resolves to another repo"      pass  "$ROOT" "T=$OTHER; git -C \"\$T\" add a.md"
# Bypass: the staging reaches the frozen index from outside.
expect "subshell cd into the frozen checkout"            block "$OTHER" "(cd $ROOT && git add a.md)"
expect "cd to other repo, then -C back to the canon"     block "$OTHER" "(cd $OTHER && git -C $ROOT add a.md)"
expect "cd with ';' may have failed: cwd stays possible" block "$ROOT" "(cd $OTHER; git add a.md)"
expect "subshell cd is lost after the parenthesis"       block "$ROOT" "(cd $OTHER && true); git add a.md"
expect "subshell cd into the canon is lost afterwards"   pass  "$OTHER" "(cd $ROOT); git add a.md"
expect "GIT_DIR prefix aims at the frozen git-dir"       block "$OTHER" "GIT_DIR=$ROOTGIT git add a.md"
expect "--git-dir aims at the frozen git-dir"            block "$OTHER" "git --git-dir=$ROOTGIT add a.md"
expect "--git-dir with a foreign --work-tree"            block "$OTHER" "git --git-dir $ROOTGIT --work-tree=$OTHER add a.md"
expect "GIT_INDEX_FILE aims at the frozen index"         block "$OTHER" "GIT_INDEX_FILE=$ROOTGIT/index git add a.md"
expect "exported GIT_DIR aims at the frozen git-dir"     block "$OTHER" "export GIT_DIR=$ROOTGIT; git add a.md"
expect "env wrapper sets GIT_DIR"                        block "$OTHER" "env GIT_DIR=$ROOTGIT git add a.md"
expect "assigned variable resolves to the canon"         block "$OTHER" "T=$ROOT; git -C \"\$T\" add a.md"
expect "staging at the end of a pipeline"                block "$ROOT" "echo a.md | git add --pathspec-from-file=-"
# Unknown target: blocked (pilot decision 29.10), whatever the cwd.
expect "-C with an unknown shell variable"               block "$OTHER" 'git -C "$TARGET" add a.md'
expect "-C with a command substitution"                  block "$OTHER" 'git -C $(pwd) add a.md'
expect "loop variable in -C"                             block "$OTHER" 'for r in a b; do git -C "$r" add f; done'
expect "unknown GIT_DIR value"                           block "$OTHER" 'GIT_DIR=$X git add a.md'
expect "unknown global option before add"                block "$OTHER" 'git $OPTS add a.md'
expect "unknown global option, no staging"               pass  "$OTHER" 'git $OPTS status'
expect "freeze off: unknown target is allowed"           pass  "$OTHER" 'git -C "$TARGET" add a.md' "IWE_FROZEN_CANONICAL_PATH="
# Cold review by Codex (round 4): forms found to slip through the first version.
expect "-C joined with its path"                         block "$OTHER" "git -C$ROOT add a.md"
expect "bash -c runs staging in the canon"               block "$ROOT" "bash -c 'git add a.md'"
expect "bash -c with cd to another repo"                 pass  "$ROOT" "bash -c 'cd $OTHER && git add a.md'"
expect "sh -c with -C into the canon"                    block "$OTHER" "sh -c \"git -C $ROOT add a.md\""
expect "eval of a staging call in the canon"             block "$ROOT" "eval 'git add a.md'"
expect "bash -c with an unknown command text"            block "$OTHER" 'bash -c "$CMD"; git add a.md'
expect "conditional export of GIT_INDEX_FILE"            block "$ROOT" "false && export GIT_INDEX_FILE=/tmp/alt-index; git add a.md"
expect "export inside a pipeline is lost"                block "$ROOT" "export GIT_INDEX_FILE=/tmp/alt-index | cat; git add a.md"
expect "env -u removes the exported GIT_INDEX_FILE"      block "$ROOT" "export GIT_INDEX_FILE=/tmp/alt-index; env -u GIT_INDEX_FILE git add a.md"
expect "cd -- <other repo>"                              pass  "$ROOT" "(cd -- $OTHER && git add a.md)"
expect "cd -P -- <canon> from elsewhere"                 block "$OTHER" "(cd -P -- $ROOT && git add a.md)"
expect "inherited GIT_INDEX_FILE aims at the canon"      block "$OTHER" "git add a.md" "GIT_INDEX_FILE=$ROOTGIT/index"
expect "benign assignment before -C"                     pass  "$ROOT" "D=$OTHER; git -C \"\$D\" add a.md"

# expect_msg $1=desc $2=cwd $3=command $4=env assignment $5=substring the block message must have
# $6=substring it must NOT have (РП-518: the hint depends on which canon is frozen)
expect_msg() {
  local desc="$1" cwd="$2" cmd="$3" envset="$4" must="$5" mustnot="$6" msg
  msg=$(jq -n --arg c "$cmd" --arg d "$cwd" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
    | env "$envset" bash "$HOOK" 2>&1 >/dev/null)
  if printf '%s' "$msg" | grep -qF -- "$must" && ! printf '%s' "$msg" | grep -qF -- "$mustnot"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc (message: $msg)"
  fi
}
expect_msg "frozen workspace root: hint names the root route"  "$ROOT"  "git add scripts/x.sh" "NOOP=1" \
  "--close-path quick-close" "cd DS-my-strategy &&"
expect_msg "frozen workspace root: hint names the publish-only path" "$ROOT" "git add scripts/x.sh" "NOOP=1" \
  "--close-path publish-only" "cd DS-my-strategy &&"
expect_msg "frozen governance repo: hint keeps the DS-my-strategy route" "$OTHER" "git add a.md" "IWE_FROZEN_CANONICAL_PATH=$OTHER" \
  "cd DS-my-strategy &&" "--close-path quick-close"

git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null

echo "frozen-staging: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
