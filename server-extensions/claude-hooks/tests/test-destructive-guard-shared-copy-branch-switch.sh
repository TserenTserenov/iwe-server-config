#!/bin/bash
# test-destructive-guard-shared-copy-branch-switch.sh — WP-484, bug-2026-11-17 fix 5:
# `git switch <branch>` / `git checkout <branch>` in the MAIN checkout of a shared copy
# (PACK-*, DS-IT-systems/* that the copy registry names reader/service on this host) is refused;
# going back to main, restoring files, a linked worktree, a working copy and any other repository
# pass. An unreadable registry keeps the protection (fail closed).
#
# Fixture command strings are fed as JSON `tool_input.command`, never run.
#
# Run: bash .claude/hooks/tests/test-destructive-guard-shared-copy-branch-switch.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/destructive-guard.sh"
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP_DIR=$(mktemp -d)
# The hook expands ~ and $HOME from ITS OWN $HOME. The delivery gate runs this test in a clone under
# the Mac's temp directory, outside the real home, so the hook gets a HOME that contains the clone.
TEST_HOME="$(dirname "$WORKSPACE_ROOT")"
PACK="$WORKSPACE_ROOT/PACK-guardtest-$$"
BOT="$WORKSPACE_ROOT/DS-IT-systems/guardtest-$$"
BOT2="$WORKSPACE_ROOT/DS-IT-systems/guardtest-newarch-$$"   # main branch is not main (the bot copy: new-architecture)
WORKING="$WORKSPACE_ROOT/DS-IT-systems/guardtest-working-$$"  # registered as a working copy on this host
UNLISTED="$WORKSPACE_ROOT/PACK-guardtest-unlisted-$$"         # in no registry entry for this host
PASS=0
FAIL=0
cleanup() {
  rm -rf "${TMP_DIR:?}" "${PACK:?}" "${BOT:?}" "${BOT2:?}" "${WORKING:?}" "${UNLISTED:?}"
  rmdir "$WORKSPACE_ROOT/DS-IT-systems" 2>/dev/null || true
}
trap cleanup EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mk_repo() {  # <dir>
  mkdir -p "$1"
  git init -q -b main "$1"
  echo seed > "$1/f.md"
  git -C "$1" add f.md
  git -C "$1" commit -q -m seed
  git -C "$1" branch feature
}
mk_repo "$PACK"
mk_repo "$BOT"
mk_repo "$WORKING"
mk_repo "$UNLISTED"
mk_repo "$TMP_DIR/other"
git -C "$PACK" worktree add -q "$TMP_DIR/linked" feature
# a copy cloned from an origin whose HEAD is new-architecture, with a second branch "pilot"
git init -q --bare -b new-architecture "$TMP_DIR/origin-newarch.git"
git clone -q "$TMP_DIR/origin-newarch.git" "$BOT2" 2>/dev/null
echo seed > "$BOT2/f.md"
git -C "$BOT2" add f.md
git -C "$BOT2" commit -q -m seed
git -C "$BOT2" push -q origin HEAD:new-architecture
git -C "$BOT2" remote set-head origin new-architecture >/dev/null 2>&1 || git -C "$BOT2" remote set-head origin -a >/dev/null 2>&1
git -C "$BOT2" branch pilot

# The copy registry the hook reads (variant A, 17.11): a fixture, not the real one, for a fixture host.
REGISTRY="$TMP_DIR/registry.json"
python3 - "$REGISTRY" "${PACK#"$WORKSPACE_ROOT"/}" "${BOT#"$WORKSPACE_ROOT"/}" "${BOT2#"$WORKSPACE_ROOT"/}" "${WORKING#"$WORKSPACE_ROOT"/}" "${UNLISTED#"$WORKSPACE_ROOT"/}" <<'PY_FIXTURE'
import json, sys
dst, pack, bot, bot2, working, unlisted = sys.argv[1:]
def repo(rid, cls, checkouts):
    return {"repo_id": rid, "class": cls, "checkouts": checkouts}
json.dump({"version": 1, "repos": [
    repo("pack", "reader", [{"host": "guardhost", "path": pack}]),
    repo("bot", "working", [{"host": "guardhost", "path": bot, "class": "service"}]),
    repo("bot2", "reader", [{"host": "guardhost", "path": bot2}]),
    repo("working", "working", [{"host": "guardhost", "path": working}]),
    repo("unlisted", "reader", [{"host": "otherhost", "path": unlisted}]),
]}, open(dst, "w"))
PY_FIXTURE
export IWE_REPO_REGISTRY_JSON="$REGISTRY" CONVERGENCE_HOST_ID=guardhost

# expect <desc> <want block|pass> <command> <cwd>
expect() {
  local desc="$1" want="$2" cmd="$3" cwd="$4" input got err_file="$TMP_DIR/err"
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$cmd" "$cwd")
  printf '%s' "$input" | HOME="$TEST_HOME" bash "$HOOK" >/dev/null 2>"$err_file"
  if [ "$?" -eq 2 ]; then got="block"; else got="pass"; fi
  # a refusal must come from THIS rule, not from another one that happens to match
  if [ "$got" = "block" ] && ! grep -q "в общей копии" "$err_file"; then
    got="block-by-another-rule"
  fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось $want, получено $got)"
    echo "  stderr: $(head -c 300 "$err_file")"
  fi
}

# === refused: leaving main in a shared copy ===
expect "pack: switch feature" block 'git switch feature' "$PACK"
expect "pack: checkout feature" block 'git checkout feature' "$PACK"
expect "pack: switch -c new" block 'git switch -c new' "$PACK"
expect "pack: checkout -b new" block 'git checkout -b new' "$PACK"
expect "pack: switch --detach" block 'git switch --detach' "$PACK"
expect "pack: -C from elsewhere" block "git -C $PACK switch feature" "$TMP_DIR"
expect "bot docs copy: switch feature" block 'git switch feature' "$BOT"
expect "pack: after &&" block 'git status && git switch feature' "$PACK"
expect "cd into the pack, then switch" block "(cd $PACK && git switch feature)" "$TMP_DIR"
expect "cd into the bot copy, then checkout" block "(cd $BOT && git checkout feature)" "$TMP_DIR"

# the shell expands ~ and $HOME before git runs; the hook only sees the text
HOME_REL="${PACK#"$TEST_HOME"}"
expect "tilde path with -C" block "git -C ~$HOME_REL switch feature" "$TMP_DIR"
expect "\$HOME path with -C" block 'git -C $HOME'"$HOME_REL"' switch feature' "$TMP_DIR"
expect "\${HOME} path with -C" block 'git -C ${HOME}'"$HOME_REL"' switch feature' "$TMP_DIR"
expect "cd with a tilde path" block "(cd ~$HOME_REL && git switch feature)" "$TMP_DIR"
expect "checkout <branch> -- with no path switches" block 'git checkout feature --' "$PACK"
expect "bot-like copy: switch to the other branch" block 'git switch pilot' "$BOT2"

# === allowed ===
expect "bot-like copy: back to its own main branch" pass 'git switch new-architecture' "$BOT2"
expect "bot-like copy: checkout its own main branch" pass 'git checkout new-architecture' "$BOT2"
expect "pack: restore a file without --" pass 'git checkout f.md' "$PACK"
expect "pack: restore from a branch with a path" pass 'git checkout feature -- f.md' "$PACK"
expect "pack: back to main" pass 'git switch main' "$PACK"
expect "pack: checkout main" pass 'git checkout main' "$PACK"
expect "pack: restore a file" pass 'git checkout -- f.md' "$PACK"
expect "pack: status" pass 'git status' "$PACK"
expect "linked worktree of a pack: free" pass 'git switch feature' "$TMP_DIR/linked"
expect "cd into the pack, then back to main" pass "(cd $PACK && git switch main)" "$TMP_DIR"
expect "cd into another repository, then switch" pass "(cd $TMP_DIR/other && git switch feature)" "$PACK"
expect "other repository: free" pass 'git switch feature' "$TMP_DIR/other"
expect "-C into another repository: free" pass "git -C $TMP_DIR/other switch feature" "$PACK"

# === variant A: the registry decides which copies are shared ===
expect "working copy on this host: switch is free" pass 'git switch feature' "$WORKING"
expect "copy registered only for another host: free" pass 'git switch feature' "$UNLISTED"
IWE_REPO_REGISTRY_JSON="$TMP_DIR/no-such-registry.json" \
  expect "registry missing: protection stays (fail closed)" block 'git switch feature' "$WORKING"
printf 'not json' > "$TMP_DIR/broken.json"
IWE_REPO_REGISTRY_JSON="$TMP_DIR/broken.json" \
  expect "registry broken: protection stays (fail closed)" block 'git switch feature' "$UNLISTED"

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS проверок"
  exit 0
fi
echo "FAILURES: $FAIL (прошло $PASS)"
exit 1
