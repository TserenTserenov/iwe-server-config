#!/usr/bin/env bash
# canon-reconcile.sh's job is narrower than canon-refresh.sh's: it also
# handles a purely-behind checkout whose tracked files are dirty, but only
# ever discards the dirty content when it's provably superseded (byte-
# identical to what origin already has once fast-forwarded). Real,
# never-published content must survive in the stash untouched. These
# scenarios exercise exactly that boundary — the guard logic (mid-rebase,
# detached HEAD, branch mismatch) is copied from canon-refresh.sh and
# already covered by canon-refresh-fast-forward-smoke.sh, not re-tested here.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/scripts/canon-reconcile.sh"
REAL_GIT=$(command -v git)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/canon-reconcile-smoke.XXXXXX")
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
  printf 'initial\n' > "$seed/file.md"
  "$REAL_GIT" -C "$seed" add file.md
  "$REAL_GIT" -C "$seed" commit -qm initial
  "$REAL_GIT" -C "$seed" branch -M main
  "$REAL_GIT" -C "$seed" remote add origin "$origin"
  "$REAL_GIT" -C "$seed" push -q -u origin main
  "$REAL_GIT" -C "$origin" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" clone -q "$origin" "$clone"
  "$REAL_GIT" -C "$clone" config user.name fixture
  "$REAL_GIT" -C "$clone" config user.email fixture@example.invalid
}

advance_seed() {
  local seed="$1" content="$2" msg="$3"
  printf '%s\n' "$content" > "$seed/file.md"
  "$REAL_GIT" -C "$seed" add file.md
  "$REAL_GIT" -C "$seed" commit -qm "$msg"
  "$REAL_GIT" -C "$seed" push -q
}

# --- Scenario 1: clean and purely behind -> fast-forwards -----------------
new_origin_and_clone case1
CLONE1="$TEST_ROOT/case1-clone"
SEED1="$TEST_ROOT/case1-seed"
advance_seed "$SEED1" "second" "second commit"
REMOTE_HEAD1=$("$REAL_GIT" -C "$SEED1" rev-parse HEAD)
out1=$(bash "$SCRIPT" "$CLONE1" main 2>&1)
rc1=$?
assert_eq "case1 exit code" "0" "$rc1"
assert_contains "case1 diagnostic" "$out1" "fast-forwarded"
assert_eq "case1 HEAD advanced" "$REMOTE_HEAD1" "$("$REAL_GIT" -C "$CLONE1" rev-parse HEAD)"

# --- Scenario 2: already at origin -> no-op --------------------------------
out2=$(bash "$SCRIPT" "$CLONE1" main 2>&1)
rc2=$?
assert_eq "case2 exit code" "0" "$rc2"
assert_contains "case2 diagnostic" "$out2" "already at origin"

# --- Scenario 3: dirty tracked file, but content is provably superseded ---
# (equals what origin's next commit turns out to contain) -> auto-resolved,
# stash dropped, no trace left.
new_origin_and_clone case3
CLONE3="$TEST_ROOT/case3-clone"
SEED3="$TEST_ROOT/case3-seed"
printf 'draft never committed here\n' > "$CLONE3/file.md"
advance_seed "$SEED3" "draft never committed here" "someone else published the same draft"
out3=$(bash "$SCRIPT" "$CLONE3" main 2>&1)
rc3=$?
assert_eq "case3 exit code" "0" "$rc3"
assert_contains "case3 diagnostic" "$out3" "already superseded"
assert_eq "case3 disk matches new origin" "draft never committed here" "$(cat "$CLONE3/file.md")"
assert_eq "case3 tree clean" "" "$("$REAL_GIT" -C "$CLONE3" status --porcelain)"
assert_eq "case3 no stash left behind" "" "$("$REAL_GIT" -C "$CLONE3" stash list)"

# --- Scenario 4: dirty tracked file with REAL never-published content ------
# origin moves on to something else entirely -> fast-forwards the tree, but
# the real edit must survive in the stash, not be discarded.
new_origin_and_clone case4
CLONE4="$TEST_ROOT/case4-clone"
SEED4="$TEST_ROOT/case4-seed"
printf 'a real unpublished edit\n' > "$CLONE4/file.md"
advance_seed "$SEED4" "something unrelated entirely" "origin moves on unrelated"
set +e
out4=$(bash "$SCRIPT" "$CLONE4" main 2>&1)
rc4=$?
set -e
assert_eq "case4 exit code" "1" "$rc4"
assert_contains "case4 diagnostic" "$out4" "left in stash for manual review"
assert_eq "case4 disk shows new origin content" "something unrelated entirely" "$(cat "$CLONE4/file.md")"
assert_eq "case4 real edit preserved in stash" "a real unpublished edit" "$("$REAL_GIT" -C "$CLONE4" show stash@{0}:file.md)"
assert_contains "case4 stash present" "$("$REAL_GIT" -C "$CLONE4" stash list)" "canon-reconcile"

# --- Scenario 5: diverged history (local has an unpushed commit) -> refuses,
# nothing touched, no stash created.
new_origin_and_clone case5
CLONE5="$TEST_ROOT/case5-clone"
SEED5="$TEST_ROOT/case5-seed"
printf 'local only\n' > "$CLONE5/local.txt"
"$REAL_GIT" -C "$CLONE5" add local.txt
"$REAL_GIT" -C "$CLONE5" commit -qm "local-only commit"
LOCAL_HEAD5=$("$REAL_GIT" -C "$CLONE5" rev-parse HEAD)
advance_seed "$SEED5" "remote advanced too" "remote advances independently"
set +e
out5=$(bash "$SCRIPT" "$CLONE5" main 2>&1)
rc5=$?
set -e
assert_eq "case5 exit code" "1" "$rc5"
assert_contains "case5 diagnostic" "$out5" "history diverged"
assert_eq "case5 HEAD unchanged" "$LOCAL_HEAD5" "$("$REAL_GIT" -C "$CLONE5" rev-parse HEAD)"
assert_eq "case5 no stash created" "" "$("$REAL_GIT" -C "$CLONE5" stash list)"

# --- Scenario 6: two dirty files blocking the same fast-forward, one
# superseded and one real -> the real one keeps the whole stash alive (git
# stash is all-or-nothing per entry), and the script must report it rather
# than claim a clean resolution. Both paths must actually appear in git's own
# "would be overwritten" list, so origin has to move BOTH of them (a path
# origin leaves untouched never blocks a fast-forward at all, regardless of
# local dirt on it — that's a different, unrelated case, not this one).
new_origin_and_clone case6
CLONE6="$TEST_ROOT/case6-clone"
SEED6="$TEST_ROOT/case6-seed"
mkdir -p "$SEED6/second"
printf 'second file initial\n' > "$SEED6/second/other.md"
"$REAL_GIT" -C "$SEED6" add second/other.md
"$REAL_GIT" -C "$SEED6" commit -qm "add second file"
"$REAL_GIT" -C "$SEED6" push -q
"$REAL_GIT" -C "$CLONE6" pull -q
mkdir -p "$CLONE6/second"
printf 'superseded draft\n' > "$CLONE6/file.md"
printf 'a real edit nobody published\n' > "$CLONE6/second/other.md"
printf 'superseded draft\n' > "$SEED6/file.md"
printf 'second file, published differently\n' > "$SEED6/second/other.md"
"$REAL_GIT" -C "$SEED6" add file.md second/other.md
"$REAL_GIT" -C "$SEED6" commit -qm "publish the draft and advance second file too"
"$REAL_GIT" -C "$SEED6" push -q
set +e
out6=$(bash "$SCRIPT" "$CLONE6" main 2>&1)
rc6=$?
set -e

assert_eq "case6 exit code" "1" "$rc6"
assert_contains "case6 diagnostic" "$out6" "second/other.md"
assert_eq "case6 real edit preserved on disk-equivalent path" \
  "a real edit nobody published" "$("$REAL_GIT" -C "$CLONE6" show stash@{0}:second/other.md)"

# --- Scenario 7: a live lock (own pid, alive) is respected, nothing touched.
# Wired into ds-publish.sh's post-publish step now (WP-530 Ф33) means this
# can run concurrently with canon-refresh.sh/git-dirty-guard.sh on the same
# repo — they share one lock directory precisely so only one of them mutates
# the tree at a time.
new_origin_and_clone case7
CLONE7="$TEST_ROOT/case7-clone"
SEED7="$TEST_ROOT/case7-seed"
advance_seed "$SEED7" "second" "second commit"
LIVE_LOCK_HEAD=$("$REAL_GIT" -C "$CLONE7" rev-parse HEAD)
CLONE7_GIT_DIR=$("$REAL_GIT" -C "$CLONE7" rev-parse --absolute-git-dir)
mkdir -p "$CLONE7_GIT_DIR/dirty-guard.lock"
printf 'host=%s\npid=%s\n' "${HOSTNAME:-$(hostname)}" "$$" > "$CLONE7_GIT_DIR/dirty-guard.lock/owner"
out7=$(bash "$SCRIPT" "$CLONE7" main 2>&1)
rc7=$?
assert_eq "case7 exit code" "0" "$rc7"
assert_contains "case7 diagnostic" "$out7" "lock busy"
assert_eq "case7 HEAD untouched under live lock" "$LIVE_LOCK_HEAD" "$("$REAL_GIT" -C "$CLONE7" rev-parse HEAD)"
[ -d "$CLONE7_GIT_DIR/dirty-guard.lock" ] || fail "case7 live lock directory must survive a losing contender"
rm -rf "$CLONE7_GIT_DIR/dirty-guard.lock"

# --- Scenario 8: a stale lock (dead pid) is reclaimed and reconciliation proceeds
new_origin_and_clone case8
CLONE8="$TEST_ROOT/case8-clone"
SEED8="$TEST_ROOT/case8-seed"
advance_seed "$SEED8" "second" "second commit"
REMOTE_HEAD8=$("$REAL_GIT" -C "$SEED8" rev-parse HEAD)
CLONE8_GIT_DIR=$("$REAL_GIT" -C "$CLONE8" rev-parse --absolute-git-dir)
mkdir -p "$CLONE8_GIT_DIR/dirty-guard.lock"
printf 'host=%s\npid=999999\n' "${HOSTNAME:-$(hostname)}" > "$CLONE8_GIT_DIR/dirty-guard.lock/owner"
out8=$(bash "$SCRIPT" "$CLONE8" main 2>&1)
rc8=$?
assert_eq "case8 exit code" "0" "$rc8"
assert_contains "case8 diagnostic" "$out8" "reclaiming stale lock"
assert_eq "case8 fast-forwarded after reclaim" "$REMOTE_HEAD8" "$("$REAL_GIT" -C "$CLONE8" rev-parse HEAD)"
[ ! -d "$CLONE8_GIT_DIR/dirty-guard.lock" ] || fail "case8 lock directory left behind after success"

echo "PASS: canon-reconcile-smoke.sh (8 scenarios)"
