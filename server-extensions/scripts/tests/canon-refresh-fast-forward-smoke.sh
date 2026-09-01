#!/usr/bin/env bash
# Regression for WP-484 AF: canon-refresh.sh fast-forwards a clean, purely-behind
# checkout and, symmetrically, must never touch a repo in any other state.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/scripts/canon-refresh.sh"
REAL_GIT=$(command -v git)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/canon-refresh-smoke.XXXXXX")
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
  printf '%s\n' "$origin"
}

advance_origin() {
  local seed="$1" msg="$2"
  printf '%s\n' "$msg" >> "$seed/tracked.txt"
  "$REAL_GIT" -C "$seed" add tracked.txt
  "$REAL_GIT" -C "$seed" commit -qm "$msg"
  "$REAL_GIT" -C "$seed" push -q
}

# --- Scenario 1: clean and purely behind -> fast-forwards ---------------
new_origin_and_clone case1 >/dev/null
CLONE1="$TEST_ROOT/case1-clone"
SEED1="$TEST_ROOT/case1-seed"
advance_origin "$SEED1" "second"
REMOTE_HEAD1=$("$REAL_GIT" -C "$SEED1" rev-parse HEAD)
out1=$(bash "$SCRIPT" "$CLONE1" main 2>&1)
rc1=$?
assert_eq "case1 exit code" "0" "$rc1"
assert_contains "case1 diagnostic" "$out1" "fast-forwarded"
assert_eq "case1 HEAD advanced" "$REMOTE_HEAD1" "$("$REAL_GIT" -C "$CLONE1" rev-parse HEAD)"
assert_eq "case1 tree stays clean" "" "$("$REAL_GIT" -C "$CLONE1" status --porcelain)"

# --- Scenario 2: already at origin -> no-op, quiet ------------------------
out2=$(bash "$SCRIPT" "$CLONE1" main 2>&1)
rc2=$?
assert_eq "case2 exit code" "0" "$rc2"
assert_contains "case2 diagnostic" "$out2" "already at origin"
assert_eq "case2 HEAD unchanged" "$REMOTE_HEAD1" "$("$REAL_GIT" -C "$CLONE1" rev-parse HEAD)"

# --- Scenario 3: dirty tree -> left untouched -----------------------------
new_origin_and_clone case3 >/dev/null
CLONE3="$TEST_ROOT/case3-clone"
SEED3="$TEST_ROOT/case3-seed"
advance_origin "$SEED3" "second"
DIRTY_HEAD_BEFORE=$("$REAL_GIT" -C "$CLONE3" rev-parse HEAD)
printf 'local edit\n' >> "$CLONE3/tracked.txt"
DIRTY_DIFF=$("$REAL_GIT" -C "$CLONE3" diff -- tracked.txt)
out3=$(bash "$SCRIPT" "$CLONE3" main 2>&1)
rc3=$?
assert_eq "case3 exit code" "0" "$rc3"
assert_contains "case3 diagnostic" "$out3" "tree not clean"
assert_eq "case3 HEAD unchanged" "$DIRTY_HEAD_BEFORE" "$("$REAL_GIT" -C "$CLONE3" rev-parse HEAD)"
assert_eq "case3 dirty diff preserved" "$DIRTY_DIFF" "$("$REAL_GIT" -C "$CLONE3" diff -- tracked.txt)"

# --- Scenario 4: clean but has local unpushed commit -> left untouched ---
new_origin_and_clone case4 >/dev/null
CLONE4="$TEST_ROOT/case4-clone"
printf 'local only\n' > "$CLONE4/local.txt"
"$REAL_GIT" -C "$CLONE4" add local.txt
"$REAL_GIT" -C "$CLONE4" commit -qm local-only
LOCAL_HEAD=$("$REAL_GIT" -C "$CLONE4" rev-parse HEAD)
out4=$(bash "$SCRIPT" "$CLONE4" main 2>&1)
rc4=$?
assert_eq "case4 exit code" "0" "$rc4"
assert_contains "case4 diagnostic" "$out4" "not a pure staleness case"
assert_eq "case4 HEAD unchanged" "$LOCAL_HEAD" "$("$REAL_GIT" -C "$CLONE4" rev-parse HEAD)"

# --- Scenario 5: mid-rebase -> refuses loudly -----------------------------
new_origin_and_clone case5 >/dev/null
CLONE5="$TEST_ROOT/case5-clone"
SEED5="$TEST_ROOT/case5-seed"
advance_origin "$SEED5" "second"
CLONE5_GIT_DIR=$("$REAL_GIT" -C "$CLONE5" rev-parse --absolute-git-dir)
mkdir -p "$CLONE5_GIT_DIR/rebase-merge"
REBASE_HEAD=$("$REAL_GIT" -C "$CLONE5" rev-parse HEAD)
set +e
out5=$(bash "$SCRIPT" "$CLONE5" main 2>&1)
rc5=$?
set -e
rmdir "$CLONE5_GIT_DIR/rebase-merge"
assert_eq "case5 exit code" "1" "$rc5"
assert_contains "case5 diagnostic" "$out5" "mid-rebase/merge"
assert_eq "case5 HEAD unchanged" "$REBASE_HEAD" "$("$REAL_GIT" -C "$CLONE5" rev-parse HEAD)"

# --- Scenario 6: stale lock (dead pid) is reclaimed and the fast-forward proceeds
new_origin_and_clone case6 >/dev/null
CLONE6="$TEST_ROOT/case6-clone"
SEED6="$TEST_ROOT/case6-seed"
advance_origin "$SEED6" "second"
REMOTE_HEAD6=$("$REAL_GIT" -C "$SEED6" rev-parse HEAD)
CLONE6_GIT_DIR=$("$REAL_GIT" -C "$CLONE6" rev-parse --absolute-git-dir)
mkdir -p "$CLONE6_GIT_DIR/dirty-guard.lock"
printf 'host=%s\npid=999999\n' "${HOSTNAME:-$(hostname)}" > "$CLONE6_GIT_DIR/dirty-guard.lock/owner"
out6=$(bash "$SCRIPT" "$CLONE6" main 2>&1)
rc6=$?
assert_eq "case6 stale-lock reclaim exit code" "0" "$rc6"
assert_contains "case6 stale-lock reclaim diagnostic" "$out6" "reclaiming stale lock"
assert_eq "case6 fast-forwarded after reclaim" "$REMOTE_HEAD6" "$("$REAL_GIT" -C "$CLONE6" rev-parse HEAD)"
[ ! -d "$CLONE6_GIT_DIR/dirty-guard.lock" ] || fail "case6 lock directory left behind after success"

# --- Scenario 7: a live lock (own pid, alive) is respected, nothing touched --
new_origin_and_clone case7 >/dev/null
CLONE7="$TEST_ROOT/case7-clone"
SEED7="$TEST_ROOT/case7-seed"
advance_origin "$SEED7" "second"
LIVE_LOCK_HEAD=$("$REAL_GIT" -C "$CLONE7" rev-parse HEAD)
CLONE7_GIT_DIR=$("$REAL_GIT" -C "$CLONE7" rev-parse --absolute-git-dir)
mkdir -p "$CLONE7_GIT_DIR/dirty-guard.lock"
# $$ (this test's own shell pid) is guaranteed alive for the duration of the run.
printf 'host=%s\npid=%s\n' "${HOSTNAME:-$(hostname)}" "$$" > "$CLONE7_GIT_DIR/dirty-guard.lock/owner"
out7=$(bash "$SCRIPT" "$CLONE7" main 2>&1)
rc7=$?
assert_eq "case7 live-lock exit code" "0" "$rc7"
assert_contains "case7 live-lock diagnostic" "$out7" "lock busy"
assert_eq "case7 HEAD untouched under live lock" "$LIVE_LOCK_HEAD" "$("$REAL_GIT" -C "$CLONE7" rev-parse HEAD)"
[ -d "$CLONE7_GIT_DIR/dirty-guard.lock" ] || fail "case7 live lock directory must survive a losing contender"
rm -rf "$CLONE7_GIT_DIR/dirty-guard.lock"

# --- Scenario 8: untracked-only tree is left untouched (not just tracked dirt)
new_origin_and_clone case8 >/dev/null
CLONE8="$TEST_ROOT/case8-clone"
SEED8="$TEST_ROOT/case8-seed"
advance_origin "$SEED8" "second"
UNTRACKED_HEAD=$("$REAL_GIT" -C "$CLONE8" rev-parse HEAD)
printf 'new untracked file\n' > "$CLONE8/untracked.txt"
out8=$(bash "$SCRIPT" "$CLONE8" main 2>&1)
rc8=$?
assert_eq "case8 exit code" "0" "$rc8"
assert_contains "case8 diagnostic" "$out8" "tree not clean"
assert_eq "case8 HEAD unchanged" "$UNTRACKED_HEAD" "$("$REAL_GIT" -C "$CLONE8" rev-parse HEAD)"
[ -f "$CLONE8/untracked.txt" ] || fail "case8 untracked file must survive untouched"

# --- Scenario 9: true divergence (local AND remote each have a unique commit)
new_origin_and_clone case9 >/dev/null
CLONE9="$TEST_ROOT/case9-clone"
SEED9="$TEST_ROOT/case9-seed"
printf 'local divergent commit\n' > "$CLONE9/local-only.txt"
"$REAL_GIT" -C "$CLONE9" add local-only.txt
"$REAL_GIT" -C "$CLONE9" commit -qm local-divergent
DIVERGED_LOCAL_HEAD=$("$REAL_GIT" -C "$CLONE9" rev-parse HEAD)
advance_origin "$SEED9" "remote divergent commit"
out9=$(bash "$SCRIPT" "$CLONE9" main 2>&1)
rc9=$?
assert_eq "case9 exit code" "0" "$rc9"
assert_contains "case9 diagnostic" "$out9" "not a pure staleness case"
assert_eq "case9 HEAD unchanged" "$DIVERGED_LOCAL_HEAD" "$("$REAL_GIT" -C "$CLONE9" rev-parse HEAD)"

# --- Scenario 10: canon-refresh and git-dirty-guard.sh actually see each
# other's lock (the fix for Codex's Critical/High cross-tool race finding —
# both must use the identical $GIT_DIR/dirty-guard.lock directory, not just
# claim to in a comment).
DIRTY_GUARD="$ROOT_DIR/scripts/git-dirty-guard.sh"
new_origin_and_clone case10 >/dev/null
CLONE10="$TEST_ROOT/case10-clone"
CLONE10_GIT_DIR=$("$REAL_GIT" -C "$CLONE10" rev-parse --absolute-git-dir)
mkdir -p "$CLONE10_GIT_DIR/dirty-guard.lock"
printf 'host=%s\npid=%s\n' "${HOSTNAME:-$(hostname)}" "$$" > "$CLONE10_GIT_DIR/dirty-guard.lock/owner"
canon_under_guard_lock=$(bash "$SCRIPT" "$CLONE10" main 2>&1)
assert_contains "canon-refresh sees dirty-guard's live lock" "$canon_under_guard_lock" "lock busy"
rm -rf "$CLONE10_GIT_DIR/dirty-guard.lock"

mkdir -p "$CLONE10_GIT_DIR/dirty-guard.lock"
printf 'host=%s\npid=%s\n' "${HOSTNAME:-$(hostname)}" "$$" > "$CLONE10_GIT_DIR/dirty-guard.lock/owner"
# git-dirty-guard.sh's own contract exits 1 (not 0) for a busy lock — capture
# under set +e like the other refusal scenarios above, or set -e would abort
# this whole test script on that exit code before the assertion ever runs.
set +e
guard_under_canon_lock=$(GIT_DIRTY_GUARD_TG_ALERTS=false bash "$DIRTY_GUARD" "$CLONE10" main 2>&1)
set -e
assert_contains "git-dirty-guard.sh sees canon-refresh's live lock" "$guard_under_canon_lock" "lock busy"
rm -rf "$CLONE10_GIT_DIR/dirty-guard.lock"

# --- Scenario 11: usage error (no repo arg) -> exit 2, documented code -----
set +e
usage_out=$(bash "$SCRIPT" 2>&1)
usage_rc=$?
set -e
assert_eq "case11 usage exit code" "2" "$usage_rc"
assert_contains "case11 usage diagnostic" "$usage_out" "usage:"

# --- Scenario 12: detached HEAD -> refuses with exit 2, nothing touched ----
new_origin_and_clone case12 >/dev/null
CLONE12="$TEST_ROOT/case12-clone"
"$REAL_GIT" -C "$CLONE12" checkout -q --detach HEAD
DETACHED_HEAD=$("$REAL_GIT" -C "$CLONE12" rev-parse HEAD)
set +e
detached_out=$(bash "$SCRIPT" "$CLONE12" main 2>&1)
detached_rc=$?
set -e
assert_eq "case12 detached HEAD exit code" "2" "$detached_rc"
assert_contains "case12 detached HEAD diagnostic" "$detached_out" "detached HEAD"
assert_eq "case12 detached HEAD unchanged" "$DETACHED_HEAD" "$("$REAL_GIT" -C "$CLONE12" rev-parse HEAD)"

# --- Scenario 13: explicit branch mismatch -> refuses with exit 2 ----------
new_origin_and_clone case13 >/dev/null
CLONE13="$TEST_ROOT/case13-clone"
"$REAL_GIT" -C "$CLONE13" checkout -qb feature
MISMATCH_MAIN=$("$REAL_GIT" -C "$CLONE13" rev-parse main)
MISMATCH_FEATURE=$("$REAL_GIT" -C "$CLONE13" rev-parse feature)
set +e
mismatch_out=$(bash "$SCRIPT" "$CLONE13" main 2>&1)
mismatch_rc=$?
set -e
assert_eq "case13 branch mismatch exit code" "2" "$mismatch_rc"
assert_contains "case13 branch mismatch diagnostic" "$mismatch_out" "checked-out branch is feature"
assert_eq "case13 mismatch preserves main" "$MISMATCH_MAIN" "$("$REAL_GIT" -C "$CLONE13" rev-parse main)"
assert_eq "case13 mismatch preserves feature" "$MISMATCH_FEATURE" "$("$REAL_GIT" -C "$CLONE13" rev-parse feature)"
assert_eq "case13 mismatch leaves feature checked out" "feature" "$("$REAL_GIT" -C "$CLONE13" branch --show-current)"

# --- Scenario 14: a broken `git status` fails closed, not clean ------------
new_origin_and_clone case14 >/dev/null
CLONE14="$TEST_ROOT/case14-clone"
SEED14="$TEST_ROOT/case14-seed"
advance_origin "$SEED14" "second"
BROKEN_STATUS_HEAD=$("$REAL_GIT" -C "$CLONE14" rev-parse HEAD)
STATUS_FAIL_BIN="$TEST_ROOT/status-fail-bin"
mkdir -p "$STATUS_FAIL_BIN"
cat > "$STATUS_FAIL_BIN/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "status" ]; then
  echo "fatal: injected status failure" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$STATUS_FAIL_BIN/git"
set +e
broken_status_out=$(PATH="$STATUS_FAIL_BIN:$PATH" bash "$SCRIPT" "$CLONE14" main 2>&1)
broken_status_rc=$?
set -e
assert_eq "case14 broken status exit code" "0" "$broken_status_rc"
assert_contains "case14 broken status diagnostic" "$broken_status_out" "tree not clean"
assert_eq "case14 broken status HEAD unchanged" "$BROKEN_STATUS_HEAD" "$("$REAL_GIT" -C "$CLONE14" rev-parse HEAD)"

echo "PASS: canon-refresh-fast-forward-smoke.sh (14 scenarios)"
