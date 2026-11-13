#!/usr/bin/env bash
# WP-530 Ф150 (И-8/И-9): the main DS-my-strategy checkout is advanced only by
# tsekh1-git-sync.sh, which claims the paths first. canon-refresh.sh and
# canon-reconcile.sh must leave such a checkout untouched (HEAD, tree and stash
# list) and refuse when their predicate library is missing, while any other
# checkout -- including a linked worktree of DS-my-strategy -- keeps the old
# behaviour.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REFRESH="$ROOT_DIR/scripts/canon-refresh.sh"
RECONCILE="$ROOT_DIR/scripts/canon-reconcile.sh"
REAL_GIT=$(command -v git)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/canon-sync-owned.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
# shellcheck source=../lib/sync-owned-canon.sh
. "$ROOT_DIR/scripts/lib/sync-owned-canon.sh"

SCENARIOS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() {
  [ "$2" = "$3" ] || fail "$1 — expected '$2', got '$3'"
  SCENARIOS=$((SCENARIOS + 1))
}
assert_contains() {
  case "$2" in *"$3"*) SCENARIOS=$((SCENARIOS + 1)) ;; *) fail "$1 — missing '$3' in: $2" ;; esac
}

# <origin-name> <case> -> prints the clone path; origin is advanced by one commit
clone_behind() {
  local origin="$TEST_ROOT/$2/$1.git" seed="$TEST_ROOT/$2/seed" clone="$TEST_ROOT/$2/clone"
  mkdir -p "$TEST_ROOT/$2"
  "$REAL_GIT" init --bare -q "$origin"
  "$REAL_GIT" init -q "$seed"
  "$REAL_GIT" -C "$seed" config user.name fixture
  "$REAL_GIT" -C "$seed" config user.email fixture@example.invalid
  printf 'initial\n' > "$seed/tracked.txt"
  "$REAL_GIT" -C "$seed" add tracked.txt
  "$REAL_GIT" -C "$seed" commit -qm initial
  "$REAL_GIT" -C "$seed" branch -M main
  "$REAL_GIT" -C "$seed" remote add origin "$origin"
  "$REAL_GIT" -C "$seed" push -q -u origin main
  "$REAL_GIT" -C "$origin" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" clone -q "$origin" "$clone"
  "$REAL_GIT" -C "$clone" config user.name fixture
  "$REAL_GIT" -C "$clone" config user.email fixture@example.invalid
  printf 'second\n' >> "$seed/tracked.txt"
  "$REAL_GIT" -C "$seed" commit -qam second
  "$REAL_GIT" -C "$seed" push -q
  printf '%s\n' "$clone"
}

# 1. the predicate: main clone protected, linked worktree and other repos not
MAIN=$(clone_behind DS-my-strategy pred)
sync_owned_canon "$MAIN" && r=yes || r=no
assert_eq "main DS-my-strategy clone is protected" yes "$r"
sync_owned_canon "$MAIN/." && r=yes || r=no
assert_eq "protection does not depend on how the path is spelled" yes "$r"
"$REAL_GIT" -C "$MAIN" worktree add -q -b iso "$TEST_ROOT/pred/linked" HEAD
sync_owned_canon "$TEST_ROOT/pred/linked" && r=yes || r=no
assert_eq "linked worktree of DS-my-strategy is not protected" no "$r"
OTHER=$(clone_behind MC-sessions pred-other)
sync_owned_canon "$OTHER" && r=yes || r=no
assert_eq "another repository is not protected" no "$r"
sync_owned_canon "$TEST_ROOT/nowhere" && r=yes || r=no
assert_eq "a missing directory is not protected" no "$r"

# 2. canon-refresh: protected clean behind clone stays put, other repo fast-forwards
C=$(clone_behind DS-my-strategy refresh)
before=$("$REAL_GIT" -C "$C" rev-parse HEAD)
out=$(bash "$REFRESH" "$C" main 2>&1)
assert_contains "canon-refresh defers on the main checkout" "$out" "deferred"
assert_eq "canon-refresh leaves HEAD" "$before" "$("$REAL_GIT" -C "$C" rev-parse HEAD)"
O=$(clone_behind MC-sessions refresh-other)
bash "$REFRESH" "$O" main >/dev/null 2>&1
assert_eq "canon-refresh still fast-forwards another repo" \
  "$("$REAL_GIT" -C "$O" rev-parse origin/main)" "$("$REAL_GIT" -C "$O" rev-parse HEAD)"

# 3. canon-reconcile: dirty protected clone -- no stash, no merge, tree intact
C=$(clone_behind DS-my-strategy reconcile)
printf 'local edit\n' >> "$C/tracked.txt"
before=$("$REAL_GIT" -C "$C" rev-parse HEAD)
out=$(bash "$RECONCILE" "$C" main 2>&1)
assert_contains "canon-reconcile defers on the main checkout" "$out" "deferred"
assert_eq "canon-reconcile leaves HEAD" "$before" "$("$REAL_GIT" -C "$C" rev-parse HEAD)"
assert_eq "canon-reconcile makes no stash" "" "$("$REAL_GIT" -C "$C" stash list)"
assert_eq "canon-reconcile keeps the local edit" " M tracked.txt" "$("$REAL_GIT" -C "$C" status --porcelain)"
O=$(clone_behind MC-sessions reconcile-other)
bash "$RECONCILE" "$O" main >/dev/null 2>&1
assert_eq "canon-reconcile still fast-forwards another repo" \
  "$("$REAL_GIT" -C "$O" rev-parse origin/main)" "$("$REAL_GIT" -C "$O" rev-parse HEAD)"

# 4. the owner flag keeps the mirror cleanup open but never the fast-forward
C=$(clone_behind DS-my-strategy owner)
before=$("$REAL_GIT" -C "$C" rev-parse HEAD)
out=$(bash "$REFRESH" "$C" main --owner-sync 2>&1)
assert_contains "canon-refresh --owner-sync still defers the merge" "$out" "deferred"
assert_eq "canon-refresh --owner-sync leaves HEAD" "$before" "$("$REAL_GIT" -C "$C" rev-parse HEAD)"
rc=0; out=$(bash "$REFRESH" "$C" main --force 2>&1) || rc=$?
assert_eq "canon-refresh rejects an unknown third argument" 2 "$rc"

# 5. fail closed when the predicate library is missing
FAKE="$TEST_ROOT/fake-scripts"; mkdir -p "$FAKE/lib"
cp "$REFRESH" "$RECONCILE" "$FAKE/"
cp "$ROOT_DIR/scripts/lib/automation-contract.sh" "$ROOT_DIR/scripts/lib/dirty-guard-lock.sh" "$FAKE/lib/"
C=$(clone_behind MC-sessions nolib)
before=$("$REAL_GIT" -C "$C" rev-parse HEAD)
for tool in canon-refresh canon-reconcile; do
  rc=0; bash "$FAKE/$tool.sh" "$C" main >/dev/null 2>&1 || rc=$?
  assert_eq "$tool without the library exits 1" 1 "$rc"
  assert_eq "$tool without the library leaves HEAD" "$before" "$("$REAL_GIT" -C "$C" rev-parse HEAD)"
done

echo "PASS: canon-sync-owned-barrier-smoke.sh ($SCENARIOS scenarios)"
