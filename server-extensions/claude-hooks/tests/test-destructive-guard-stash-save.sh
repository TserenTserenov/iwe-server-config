#!/bin/bash
# test-destructive-guard-stash-save.sh — regression corpus for the AR.306 stash-save block (WP-170, 02.10):
# in a PRIMARY (shared) checkout, `git stash` that saves the whole tree (no explicit own paths) or
# sweeps untracked/ignored files (-u/-a/--all) must be refused; the same commands in a LINKED
# worktree (one session's own tree) and the read-only stash subcommands must pass.
#
# Fixtures are real temporary git repos; command strings are fed as JSON `tool_input.command`,
# never embedded in this test's own shell commands (same isolation as the neighbouring suites).
#
# Запуск: bash .claude/hooks/tests/test-destructive-guard-stash-save.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/destructive-guard.sh"
TMP_DIR=$(mktemp -d)
PRIMARY="$TMP_DIR/primary"
LINKED="$TMP_DIR/linked"
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

git init -q "$PRIMARY"
git -C "$PRIMARY" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init
git -C "$PRIMARY" worktree add -q "$LINKED" -b linked-branch

# expect $1=desc $2=want(block|pass) $3=command_text $4=cwd
expect() {
  local desc="$1" want="$2" cmd="$3" cwd="$4"
  local input got_exit got err_file="$TMP_DIR/err.$$"
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$cmd" "$cwd")
  printf '%s' "$input" | bash "$HOOK" >/dev/null 2>"$err_file"
  got_exit=$?
  if [ "$got_exit" -eq 2 ]; then got="block"; else got="pass"; fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось $want, получено $got, exit=$got_exit)"
    echo "  stderr: $(cat "$err_file")"
  fi
}

# === primary (shared) checkout: refused ===
expect "голый git stash в общем чекауте блокируется" block "git -C $PRIMARY stash" "$TMP_DIR"
expect "git stash -u блокируется" block "git -C $PRIMARY stash -u" "$TMP_DIR"
expect "git stash --include-untracked блокируется" block "git -C $PRIMARY stash --include-untracked" "$TMP_DIR"
expect "git stash -a блокируется" block "git -C $PRIMARY stash -a" "$TMP_DIR"
expect "git stash --all блокируется" block "git -C $PRIMARY stash push --all" "$TMP_DIR"
expect "git stash push без путей блокируется" block "git -C $PRIMARY stash push -m wip" "$TMP_DIR"
expect "git stash save без путей блокируется" block "git -C $PRIMARY stash save wip" "$TMP_DIR"
expect "склеенные флаги -ua блокируются" block "git -C $PRIMARY stash push -ua" "$TMP_DIR"
expect "-u даже со списком путей блокируется (правило: никогда -u)" block "git -C $PRIMARY stash push -u -- file.txt" "$TMP_DIR"
expect "stash в цепочке команд блокируется" block "echo start && git -C $PRIMARY stash -u && echo done" "$TMP_DIR"
expect "cwd внутри общего чекаута без -C блокируется" block "git stash -u" "$PRIMARY"

# review-driven bypasses (Codex + Kimi, 02.10): global options before `stash`, explicit git-dir/work-tree, `save --`
expect "глобальная опция --no-pager перед stash не обходит блок" block "git --no-pager -C $PRIMARY stash -u" "$TMP_DIR"
expect "--literal-pathspecs перед stash не обходит блок" block "git --literal-pathspecs -C $PRIMARY stash -u" "$TMP_DIR"
expect "--git-dir/--work-tree при cwd вне репо не обходят блок" block "git --git-dir=$PRIMARY/.git --work-tree=$PRIMARY stash -u" "$TMP_DIR"
expect "git stash save -- file: save не принимает pathspec, блокируется" block "git -C $PRIMARY stash save -- file.txt" "$TMP_DIR"
expect "git stash push --staged без путей блокируется" block "git -C $PRIMARY stash push --staged" "$TMP_DIR"

# === primary checkout: allowed forms ===
expect "git stash push -- <свои пути> проходит" pass "git -C $PRIMARY stash push -- file.txt" "$TMP_DIR"
expect "git stash push -m msg -- <свои пути> проходит" pass "git -C $PRIMARY stash push -m wip -- file.txt other.txt" "$TMP_DIR"
expect "git stash push <путь> без -- проходит" pass "git -C $PRIMARY stash push file.txt" "$TMP_DIR"
expect "git stash list проходит" pass "git -C $PRIMARY stash list" "$TMP_DIR"
expect "git stash show проходит" pass "git -C $PRIMARY stash show" "$TMP_DIR"
expect "git stash drop проходит" pass "git -C $PRIMARY stash drop" "$TMP_DIR"

expect "push --pathspec-from-file=<файл> считается явным списком путей" pass "git -C $PRIMARY stash push --pathspec-from-file=paths.txt" "$TMP_DIR"
expect "push --pathspec-from-file <файл> (раздельная форма) проходит" pass "git -C $PRIMARY stash push --pathspec-from-file paths.txt" "$TMP_DIR"
expect "push --staged -- <пути> проходит" pass "git -C $PRIMARY stash push --staged -- file.txt" "$TMP_DIR"
expect "push --keep-index -- <пути> проходит" pass "git -C $PRIMARY stash push --keep-index -- file.txt" "$TMP_DIR"
expect "--no-pager и -C с push -- <пути> проходит" pass "git --no-pager -C $PRIMARY stash push -- file.txt" "$TMP_DIR"

# the same segmenter gap hid the older checks too: global options before the subcommand
expect "git --no-pager reset --hard больше не обходит блок reset" block "git --no-pager -C $PRIMARY reset --hard" "$TMP_DIR"
expect "git --no-pager push --force больше не обходит блок push" block "git --no-pager push --force origin main" "$TMP_DIR"
expect "git --no-pager add -A больше не обходит блок add" block "git --no-pager -C $PRIMARY add -A" "$TMP_DIR"
expect "git --no-pager status остаётся разрешённым" pass "git --no-pager -C $PRIMARY status" "$TMP_DIR"

# informational global options print a path and exit: no stash runs (verified against real git, Codex round 2)
expect "git --html-path stash -u ничего не запускает и не блокируется" pass "git --html-path stash -u" "$PRIMARY"
expect "git --no-pager log остаётся разрешённым" pass "git --no-pager -C $PRIMARY log --oneline -1" "$TMP_DIR"
expect "git -c user.name=x commit не читается как stash" pass "git -c user.name=x -C $PRIMARY commit -m wip" "$TMP_DIR"

# environment / config that redirect git to another tree: the linked-worktree exemption cannot be proven (documented limitation closed 02.10)
expect "GIT_DIR перед командой при cwd в связанном дереве не даёт исключения" block "GIT_DIR=$PRIMARY/.git git stash -u" "$LINKED"
expect "GIT_WORK_TREE перед командой при cwd в связанном дереве блокируется" block "GIT_WORK_TREE=$PRIMARY git stash" "$LINKED"
expect "export GIT_DIR=...; git stash -u блокируется" block "export GIT_DIR=$PRIMARY/.git; git stash -u" "$LINKED"
expect "-c core.worktree=<основной> при -C в связанное дерево блокируется" block "git -c core.worktree=$PRIMARY -C $LINKED stash -u" "$TMP_DIR"
expect "GIT_DIR перед командой со списком своих путей проходит" pass "GIT_DIR=$PRIMARY/.git git stash push -- file.txt" "$LINKED"
expect "посторонняя переменная GIT_AUTHOR_NAME не лишает исключения связанного дерева" pass "GIT_AUTHOR_NAME=x git -C $LINKED stash -u" "$TMP_DIR"

expect "явный --work-tree на основной при -C в связанное дерево блокируется" block "git --work-tree=$PRIMARY -C $LINKED stash -u" "$TMP_DIR"
expect "declare -x GIT_DIR=...; git stash -u блокируется" block "declare -x GIT_DIR=$PRIMARY/.git; git stash -u" "$LINKED"
expect "env GIT_DIR=... git stash -u блокируется" block "env GIT_DIR=$PRIMARY/.git git stash -u" "$LINKED"

# === linked worktree (one session's own tree): allowed ===
expect "git stash -u в связанном worktree проходит" pass "git -C $LINKED stash -u" "$TMP_DIR"
expect "голый git stash в связанном worktree проходит" pass "git -C $LINKED stash" "$TMP_DIR"
expect "cwd внутри связанного worktree без -C проходит" pass "git stash -u" "$LINKED"

# === unrelated commands stay untouched ===
expect "обычный git status проходит" pass "git -C $PRIMARY status" "$TMP_DIR"
expect "слово stash в тексте коммита не читается как команда" pass "git -C $PRIMARY log --oneline -1 --grep=stash" "$TMP_DIR"

echo "stash-save: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
