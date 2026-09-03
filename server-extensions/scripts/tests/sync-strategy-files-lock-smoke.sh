#!/usr/bin/env bash
# Regression for WP-538 Ф5а: sync-strategy-files.sh must share the same
# $GIT_DIR/dirty-guard.lock as git-dirty-guard.sh and canon-refresh.sh
# (round-4 design consensus, Kimi+Codex, 2026-09-03) so canon-refresh.sh's
# automation-mirror recovery never takes its snapshot mid-checkout-loop.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/scripts/sync-strategy-files.sh"
CANON_REFRESH="$ROOT_DIR/scripts/canon-refresh.sh"
REAL_GIT=$(command -v git)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sync-strategy-files-lock-smoke.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] || fail "$label — expected '$expected', got '$actual'"
}

assert_contains() {
  local label="$1" text="$2" needle="$3"
  case "$text" in
    *"$needle"*) ;;
    *) fail "$label — missing '$needle' in: $text" ;;
  esac
}

new_origin_and_clone() {
  local name="$1" origin seed clone
  origin="$TEST_ROOT/$name-origin.git"
  seed="$TEST_ROOT/$name-seed"
  clone="$TEST_ROOT/$name-clone"
  "$REAL_GIT" init --bare -q "$origin"
  "$REAL_GIT" init -q "$seed"
  "$REAL_GIT" -C "$seed" config user.name fixture
  "$REAL_GIT" -C "$seed" config user.email fixture@example.invalid
  mkdir -p "$seed/inbox" "$seed/current"
  printf 'card v1\n' > "$seed/inbox/WP-1.md"
  "$REAL_GIT" -C "$seed" add inbox/WP-1.md
  "$REAL_GIT" -C "$seed" commit -qm initial
  "$REAL_GIT" -C "$seed" branch -M main
  "$REAL_GIT" -C "$seed" remote add origin "$origin"
  "$REAL_GIT" -C "$seed" push -q -u origin main
  "$REAL_GIT" -C "$origin" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" clone -q "$origin" "$clone"
  "$REAL_GIT" -C "$clone" config user.name fixture
  "$REAL_GIT" -C "$clone" config user.email fixture@example.invalid
}

# --- Scenario 1: no lock held -> acquires, syncs, releases ------------------
new_origin_and_clone case1
CLONE1="$TEST_ROOT/case1-clone"
SEED1="$TEST_ROOT/case1-seed"
printf 'card v2\n' > "$SEED1/inbox/WP-1.md"
"$REAL_GIT" -C "$SEED1" add inbox/WP-1.md
"$REAL_GIT" -C "$SEED1" commit -qm "advance WP-1"
"$REAL_GIT" -C "$SEED1" push -q
out1=$(bash "$SCRIPT" "$CLONE1" 2>&1)
rc1=$?
assert_eq "case1 exit code" "0" "$rc1"
assert_contains "case1 diagnostic" "$out1" "synced=1"
assert_eq "case1 card content updated" "card v2" "$(cat "$CLONE1/inbox/WP-1.md")"
GIT_DIR1=$("$REAL_GIT" -C "$CLONE1" rev-parse --absolute-git-dir)
[ ! -d "$GIT_DIR1/dirty-guard.lock" ] || fail "case1 lock directory left behind after success"

# --- Scenario 2: lock already held by a live process -> skips the cycle,
# touches nothing ------------------------------------------------------------
new_origin_and_clone case2
CLONE2="$TEST_ROOT/case2-clone"
SEED2="$TEST_ROOT/case2-seed"
printf 'card v2\n' > "$SEED2/inbox/WP-1.md"
"$REAL_GIT" -C "$SEED2" add inbox/WP-1.md
"$REAL_GIT" -C "$SEED2" commit -qm "advance WP-1"
"$REAL_GIT" -C "$SEED2" push -q
GIT_DIR2=$("$REAL_GIT" -C "$CLONE2" rev-parse --absolute-git-dir)
mkdir -p "$GIT_DIR2/dirty-guard.lock"
printf 'host=%s\npid=%s\n' "${HOSTNAME:-$(hostname)}" "$$" > "$GIT_DIR2/dirty-guard.lock/owner"
out2=$(bash "$SCRIPT" "$CLONE2" 2>&1)
rc2=$?
assert_eq "case2 exit code" "0" "$rc2"
assert_contains "case2 diagnostic" "$out2" "lock busy"
assert_eq "case2 card content unchanged" "card v1" "$(cat "$CLONE2/inbox/WP-1.md")"
[ -d "$GIT_DIR2/dirty-guard.lock" ] || fail "case2 live lock directory must survive a losing contender"
rm -rf "$GIT_DIR2/dirty-guard.lock"

# --- Scenario 3: canon-refresh.sh sees this script's live lock (cross-tool
# serialization actually shared, not just claimed in a comment) -------------
new_origin_and_clone case3
CLONE3="$TEST_ROOT/case3-clone"
GIT_DIR3=$("$REAL_GIT" -C "$CLONE3" rev-parse --absolute-git-dir)
mkdir -p "$GIT_DIR3/dirty-guard.lock"
printf 'host=%s\npid=%s\n' "${HOSTNAME:-$(hostname)}" "$$" > "$GIT_DIR3/dirty-guard.lock/owner"
canon_out=$(bash "$CANON_REFRESH" "$CLONE3" main 2>&1)
assert_contains "canon-refresh sees sync-strategy-files' live lock" "$canon_out" "lock busy"
rm -rf "$GIT_DIR3/dirty-guard.lock"

echo "PASS: sync-strategy-files-lock-smoke.sh (3 scenarios)"
