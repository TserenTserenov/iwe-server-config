#!/usr/bin/env bash
# Regression for WP-538 (incident 2026-10-09/10): canon-refresh.sh must flush
# a pure append to a contract-declared "append" path by committing it, and
# must never touch a path whose already-committed bytes changed in any way.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/scripts/canon-refresh.sh"
REAL_GIT=$(command -v git)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/canon-refresh-append-smoke.XXXXXX")
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
  mkdir -p "$seed/machine/ledger/day/2026/10"
  printf 'line one\n' > "$seed/machine/ledger/day/2026/10/day-2026-10-09.yaml"
  "$REAL_GIT" -C "$seed" add machine
  "$REAL_GIT" -C "$seed" commit -qm initial
  "$REAL_GIT" -C "$seed" branch -M main
  "$REAL_GIT" -C "$seed" remote add origin "$origin"
  "$REAL_GIT" -C "$seed" push -q -u origin main
  "$REAL_GIT" -C "$origin" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" clone -q "$origin" "$clone"
  "$REAL_GIT" -C "$clone" config user.name fixture
  "$REAL_GIT" -C "$clone" config user.email fixture@example.invalid
  printf '%s\n' "$origin"
}

CONTRACT="$TEST_ROOT/automation-contract.conf"
cat > "$CONTRACT" <<'EOF'
wp-reopen-gate	wp-reopen-gate.sh	machine/ledger/day/*/*/*.yaml	append
EOF

LEDGER=machine/ledger/day/2026/10/day-2026-10-09.yaml

# --- Scenario 1: pure append on an otherwise-clean, up-to-date checkout ->
# committed, HEAD advances by exactly one commit, disk content unchanged. --
new_origin_and_clone case1 >/dev/null
CLONE1="$TEST_ROOT/case1-clone"
PRE1_HEAD=$("$REAL_GIT" -C "$CLONE1" rev-parse HEAD)
printf 'line one\nline two (appended)\n' > "$CLONE1/$LEDGER"
out1=$(AUTOMATION_CONTRACT_FILE="$CONTRACT" bash "$SCRIPT" "$CLONE1" main 2>&1)
rc1=$?
assert_eq "case1 exit code" "0" "$rc1"
assert_contains "case1 diagnostic" "$out1" "committed append-only writes"
assert_eq "case1 HEAD advanced by one" "1" "$("$REAL_GIT" -C "$CLONE1" rev-list --count "$PRE1_HEAD..HEAD")"
assert_eq "case1 tree clean" "" "$("$REAL_GIT" -C "$CLONE1" status --porcelain)"
assert_eq "case1 disk content preserved" "line one
line two (appended)" "$(cat "$CLONE1/$LEDGER")"
assert_eq "case1 committed content matches disk" "line one
line two (appended)" "$("$REAL_GIT" -C "$CLONE1" show "HEAD:$LEDGER")"

# --- Scenario 2: a byte in the middle of the already-committed prefix
# changed (not a pure append) -> left untouched, nothing committed. --------
new_origin_and_clone case2 >/dev/null
CLONE2="$TEST_ROOT/case2-clone"
PRE2_HEAD=$("$REAL_GIT" -C "$CLONE2" rev-parse HEAD)
printf 'line ONE (edited)\nline two (appended)\n' > "$CLONE2/$LEDGER"
out2=$(AUTOMATION_CONTRACT_FILE="$CONTRACT" bash "$SCRIPT" "$CLONE2" main 2>&1)
rc2=$?
assert_eq "case2 exit code" "0" "$rc2"
assert_contains "case2 diagnostic" "$out2" "tree not clean"
assert_eq "case2 HEAD unchanged" "$PRE2_HEAD" "$("$REAL_GIT" -C "$CLONE2" rev-parse HEAD)"
assert_eq "case2 edit kept on disk, not committed" "line ONE (edited)
line two (appended)" "$(cat "$CLONE2/$LEDGER")"
assert_contains "case2 still dirty" "$("$REAL_GIT" -C "$CLONE2" status --porcelain)" "$LEDGER"

# --- Scenario 3: file truncated below the old committed length -> left
# untouched (head -c on a short file yields a shorter stream than old
# content, cmp fails, same fail-closed path as scenario 2). ----------------
new_origin_and_clone case3 >/dev/null
CLONE3="$TEST_ROOT/case3-clone"
PRE3_HEAD=$("$REAL_GIT" -C "$CLONE3" rev-parse HEAD)
printf '' > "$CLONE3/$LEDGER"
out3=$(AUTOMATION_CONTRACT_FILE="$CONTRACT" bash "$SCRIPT" "$CLONE3" main 2>&1)
rc3=$?
assert_eq "case3 exit code" "0" "$rc3"
assert_contains "case3 diagnostic" "$out3" "tree not clean"
assert_eq "case3 HEAD unchanged" "$PRE3_HEAD" "$("$REAL_GIT" -C "$CLONE3" rev-parse HEAD)"

# --- Scenario 4: append-only flush lands, then the plain ff-only path sees
# HEAD now has a commit origin doesn't -> refuses cleanly, append commit
# stays local (a separate, already-existing job pushes it later). ----------
new_origin_and_clone case4 >/dev/null
CLONE4="$TEST_ROOT/case4-clone"
SEED4="$TEST_ROOT/case4-seed"
printf 'line one\n' >> "$SEED4/machine/other.txt" 2>/dev/null || true
mkdir -p "$SEED4/inbox"
printf 'unrelated upstream change\n' > "$SEED4/inbox/WP-9001.md"
"$REAL_GIT" -C "$SEED4" add inbox
"$REAL_GIT" -C "$SEED4" commit -qm "origin moves ahead on an unrelated path"
"$REAL_GIT" -C "$SEED4" push -q
"$REAL_GIT" -C "$CLONE4" fetch -q origin
PRE4_HEAD=$("$REAL_GIT" -C "$CLONE4" rev-parse HEAD)
printf 'line one\nline two (appended)\n' > "$CLONE4/$LEDGER"
out4=$(AUTOMATION_CONTRACT_FILE="$CONTRACT" bash "$SCRIPT" "$CLONE4" main 2>&1)
rc4=$?
assert_eq "case4 exit code" "0" "$rc4"
assert_contains "case4 diagnostic" "$out4" "committed append-only writes"
assert_contains "case4 diagnostic" "$out4" "not a pure staleness case"
assert_eq "case4 HEAD advanced by exactly one (the flush, not origin's commit)" "1" \
  "$("$REAL_GIT" -C "$CLONE4" rev-list --count "$PRE4_HEAD..HEAD")"
assert_eq "case4 tree clean" "" "$("$REAL_GIT" -C "$CLONE4" status --porcelain)"
assert_eq "case4 inbox file not pulled in by this script" "0" \
  "$([ -f "$CLONE4/inbox/WP-9001.md" ] && echo 1 || echo 0)"

# --- Scenario 5: a path with a non-ASCII byte in its name -> core.quotePath
# (on by default) would have quoted it under plain --porcelain=v1 line
# parsing, making every downstream lookup miss silently (cold review,
# WP-538 round 4, High finding #1). -z/NUL parsing must see the real path. -
new_origin_and_clone case5 >/dev/null
CLONE5="$TEST_ROOT/case5-clone"
NONASCII_LEDGER="machine/ledger/day/2026/10/день-2026-10-09.yaml"
mkdir -p "$CLONE5/machine/ledger/day/2026/10"
printf 'line one\n' > "$CLONE5/$NONASCII_LEDGER"
"$REAL_GIT" -C "$CLONE5" add "$NONASCII_LEDGER"
"$REAL_GIT" -C "$CLONE5" commit -qm "seed a non-ASCII append-only path"
PRE5_HEAD=$("$REAL_GIT" -C "$CLONE5" rev-parse HEAD)
printf 'line one\nline two (appended)\n' > "$CLONE5/$NONASCII_LEDGER"
out5=$(AUTOMATION_CONTRACT_FILE="$CONTRACT" bash "$SCRIPT" "$CLONE5" main 2>&1)
rc5=$?
assert_eq "case5 exit code" "0" "$rc5"
assert_contains "case5 diagnostic" "$out5" "committed append-only writes"
assert_eq "case5 HEAD advanced by one" "1" "$("$REAL_GIT" -C "$CLONE5" rev-list --count "$PRE5_HEAD..HEAD")"
assert_eq "case5 tree clean" "" "$("$REAL_GIT" -C "$CLONE5" status --porcelain)"

# --- Scenario 6: `git commit` itself fails (a rejecting commit-msg hook) ->
# the failure is logged, not swallowed (cold review, High finding #2); the
# path stays staged, HEAD does not move. -----------------------------------
new_origin_and_clone case6 >/dev/null
CLONE6="$TEST_ROOT/case6-clone"
PRE6_HEAD=$("$REAL_GIT" -C "$CLONE6" rev-parse HEAD)
mkdir -p "$CLONE6/.git/hooks"
printf '#!/bin/sh\nexit 1\n' > "$CLONE6/.git/hooks/commit-msg"
chmod +x "$CLONE6/.git/hooks/commit-msg"
printf 'line one\nline two (appended)\n' > "$CLONE6/$LEDGER"
out6=$(AUTOMATION_CONTRACT_FILE="$CONTRACT" bash "$SCRIPT" "$CLONE6" main 2>&1)
rc6=$?
assert_eq "case6 exit code" "0" "$rc6"
assert_contains "case6 diagnostic names the failure, not a generic refusal" "$out6" "git commit failed after staging"
assert_eq "case6 HEAD unchanged" "$PRE6_HEAD" "$("$REAL_GIT" -C "$CLONE6" rev-parse HEAD)"
assert_contains "case6 path left staged, not lost" "$("$REAL_GIT" -C "$CLONE6" diff --cached --name-only)" "$LEDGER"

# --- Scenario 7: two append-only paths dirty in the same run -> both land
# in the one commit (not two, not one-and-skip-the-other). -----------------
new_origin_and_clone case7 >/dev/null
CLONE7="$TEST_ROOT/case7-clone"
LEDGER7B=machine/ledger/day/2026/10/day-2026-10-10.yaml
printf 'line one\n' > "$CLONE7/$LEDGER7B"
"$REAL_GIT" -C "$CLONE7" add "$LEDGER7B"
"$REAL_GIT" -C "$CLONE7" commit -qm "seed a second append-only path"
PRE7_HEAD=$("$REAL_GIT" -C "$CLONE7" rev-parse HEAD)
printf 'line one\nappended A\n' > "$CLONE7/$LEDGER"
printf 'line one\nappended B\n' > "$CLONE7/$LEDGER7B"
out7=$(AUTOMATION_CONTRACT_FILE="$CONTRACT" bash "$SCRIPT" "$CLONE7" main 2>&1)
rc7=$?
assert_eq "case7 exit code" "0" "$rc7"
assert_eq "case7 exactly one commit for both paths" "1" "$("$REAL_GIT" -C "$CLONE7" rev-list --count "$PRE7_HEAD..HEAD")"
assert_eq "case7 tree clean" "" "$("$REAL_GIT" -C "$CLONE7" status --porcelain)"
assert_eq "case7 first path committed" "line one
appended A" "$("$REAL_GIT" -C "$CLONE7" show "HEAD:$LEDGER")"
assert_eq "case7 second path committed" "line one
appended B" "$("$REAL_GIT" -C "$CLONE7" show "HEAD:$LEDGER7B")"

echo "PASS: canon-refresh-append-only-smoke.sh (7 scenarios)"
