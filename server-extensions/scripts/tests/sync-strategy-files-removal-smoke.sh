#!/usr/bin/env bash
# Regression for WP-530 (found 04.10.2026): a tracked inbox/WP-*.md or current/*.md path that
# origin/main no longer has at all (renamed or deleted there, e.g. Day Close moving a DayPlan to
# archive/day-plans/) must be removed by sync-strategy-files.sh, not left staged forever -- that
# stuck shape made the published-ledger transaction refuse to reconcile the canon (sync-strategy-
# files-stale-mirror-smoke.sh covers the sibling "content changed" shape; this covers "path gone").
# Same two guards as a content update: a path with local uncommitted work, or an unpublished local
# commit on that exact path, is left alone.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="${SYNC_STRATEGY_FILES_UNDER_TEST:-$ROOT_DIR/scripts/sync-strategy-files.sh}"
REAL_GIT=$(command -v git)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sync-strategy-files-removal-smoke.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$2" = "$3" ] || fail "$1 — expected '$2', got '$3'"; }
assert_contains() { case "$2" in *"$3"*) ;; *) fail "$1 — missing '$3' in: $2" ;; esac; }

new_origin_and_clone() {
  local name="$1" origin seed clone
  origin="$TEST_ROOT/$name-origin.git"; seed="$TEST_ROOT/$name-seed"; clone="$TEST_ROOT/$name-clone"
  "$REAL_GIT" init --bare -q "$origin"
  "$REAL_GIT" init -q "$seed"
  "$REAL_GIT" -C "$seed" config user.name fixture
  "$REAL_GIT" -C "$seed" config user.email fixture@example.invalid
  mkdir -p "$seed/inbox" "$seed/current"
  printf 'plan v1\n' > "$seed/current/DayPlan 2026-10-03.md"
  printf 'card v1\n' > "$seed/inbox/WP-1.md"
  "$REAL_GIT" -C "$seed" add -A
  "$REAL_GIT" -C "$seed" commit -qm initial
  "$REAL_GIT" -C "$seed" branch -M main
  "$REAL_GIT" -C "$seed" remote add origin "$origin"
  "$REAL_GIT" -C "$seed" push -q -u origin main
  "$REAL_GIT" -C "$origin" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" clone -q "$origin" "$clone"
  "$REAL_GIT" -C "$clone" config user.name fixture
  "$REAL_GIT" -C "$clone" config user.email fixture@example.invalid
}

# --- Scenario 1: origin moved the DayPlan away (git mv) -> the stale path is removed ---
new_origin_and_clone case1
CLONE1="$TEST_ROOT/case1-clone"; SEED1="$TEST_ROOT/case1-seed"
mkdir -p "$SEED1/archive/day-plans"
"$REAL_GIT" -C "$SEED1" mv "current/DayPlan 2026-10-03.md" "archive/day-plans/DayPlan 2026-10-03.md"
"$REAL_GIT" -C "$SEED1" commit -qm "day-close: archive DayPlan"
"$REAL_GIT" -C "$SEED1" push -q
out1=$(bash "$SCRIPT" "$CLONE1" 2>&1); rc1=$?
assert_eq "case1 exit code" "0" "$rc1"
assert_contains "case1 diagnostic" "$out1" "removed=1"
[ ! -e "$CLONE1/current/DayPlan 2026-10-03.md" ] || fail "case1 stale path still on disk"
! "$REAL_GIT" -C "$CLONE1" ls-files --error-unmatch "current/DayPlan 2026-10-03.md" >/dev/null 2>&1 \
  || fail "case1 stale path still tracked"
[ "$(cat "$CLONE1/inbox/WP-1.md")" = "card v1" ] || fail "case1 unrelated file touched"

# --- Scenario 2: origin deleted the path outright (not renamed) -> removed the same way ---
new_origin_and_clone case2
CLONE2="$TEST_ROOT/case2-clone"; SEED2="$TEST_ROOT/case2-seed"
"$REAL_GIT" -C "$SEED2" rm -q "current/DayPlan 2026-10-03.md"
"$REAL_GIT" -C "$SEED2" commit -qm "drop stale plan"
"$REAL_GIT" -C "$SEED2" push -q
out2=$(bash "$SCRIPT" "$CLONE2" 2>&1)
assert_contains "case2 diagnostic" "$out2" "removed=1"
[ ! -e "$CLONE2/current/DayPlan 2026-10-03.md" ] || fail "case2 stale path still on disk"

# --- Scenario 3: local edit on the stale path (dirty) -> left alone ---
new_origin_and_clone case3
CLONE3="$TEST_ROOT/case3-clone"; SEED3="$TEST_ROOT/case3-seed"
mkdir -p "$SEED3/archive/day-plans"
"$REAL_GIT" -C "$SEED3" mv "current/DayPlan 2026-10-03.md" "archive/day-plans/DayPlan 2026-10-03.md"
"$REAL_GIT" -C "$SEED3" commit -qm "day-close: archive DayPlan"
"$REAL_GIT" -C "$SEED3" push -q
printf 'plan v1\nlocal edit\n' > "$CLONE3/current/DayPlan 2026-10-03.md"
out3=$(bash "$SCRIPT" "$CLONE3" 2>&1)
assert_contains "case3 diagnostic" "$out3" "skipped_remove_dirty=1"
[ -f "$CLONE3/current/DayPlan 2026-10-03.md" ] || fail "case3 dirty local edit was removed"
assert_eq "case3 local edit preserved" "plan v1
local edit" "$(cat "$CLONE3/current/DayPlan 2026-10-03.md")"

# --- Scenario 4: local commit on the stale path not yet on origin (ahead) -> left alone ---
new_origin_and_clone case4
CLONE4="$TEST_ROOT/case4-clone"; SEED4="$TEST_ROOT/case4-seed"
mkdir -p "$SEED4/archive/day-plans"
"$REAL_GIT" -C "$SEED4" mv "current/DayPlan 2026-10-03.md" "archive/day-plans/DayPlan 2026-10-03.md"
"$REAL_GIT" -C "$SEED4" commit -qm "day-close: archive DayPlan"
"$REAL_GIT" -C "$SEED4" push -q
printf 'plan v1\nlocal commit\n' > "$CLONE4/current/DayPlan 2026-10-03.md"
"$REAL_GIT" -C "$CLONE4" add "current/DayPlan 2026-10-03.md"
"$REAL_GIT" -C "$CLONE4" commit -qm "local unpublished edit"
# A second, unrelated file (outside this script's sync scope) diverges the repo so
# REPO_DIVERGED is true for the ahead-guard path, without itself entering the removal loop.
printf 'local only\n' > "$CLONE4/other.txt"
"$REAL_GIT" -C "$CLONE4" add "other.txt"
"$REAL_GIT" -C "$CLONE4" commit -qm "unrelated local commit"
out4=$(bash "$SCRIPT" "$CLONE4" 2>&1)
assert_contains "case4 diagnostic" "$out4" "skipped_remove_ahead=1"
[ -f "$CLONE4/current/DayPlan 2026-10-03.md" ] || fail "case4 unpublished local commit's path was removed"

# --- Scenario 5: already clean (path really gone, nothing tracked) -> idempotent, no-op ---
out1b=$(bash "$SCRIPT" "$CLONE1" 2>&1)
assert_contains "case1 second run diagnostic" "$out1b" "removed=0"

echo "== 6. the mirror already refreshed this very path to an older origin tip (dirty vs HEAD), THEN origin deletes the path entirely -> own stale mirror is recognised and removed"
new_origin_and_clone case6
CLONE6="$TEST_ROOT/case6-clone"; SEED6="$TEST_ROOT/case6-seed"
# Advance origin once (so the clone's mirror-refresh lands on a PAST origin tip, not the latest).
printf 'plan v2\n' > "$SEED6/current/DayPlan 2026-10-03.md"
"$REAL_GIT" -C "$SEED6" add "current/DayPlan 2026-10-03.md"
"$REAL_GIT" -C "$SEED6" commit -qm "advance plan"
"$REAL_GIT" -C "$SEED6" push -q
bash "$SCRIPT" "$CLONE6" >/dev/null 2>&1   # this script's own run refreshes the mirror to "plan v2"
assert_eq "case6 mirror refreshed" "plan v2" "$(cat "$CLONE6/current/DayPlan 2026-10-03.md")"
# Now origin archives the plan away entirely -- the clone's mirror is for a tip that predates this.
mkdir -p "$SEED6/archive/day-plans"
"$REAL_GIT" -C "$SEED6" mv "current/DayPlan 2026-10-03.md" "archive/day-plans/DayPlan 2026-10-03.md"
"$REAL_GIT" -C "$SEED6" commit -qm "day-close: archive DayPlan"
"$REAL_GIT" -C "$SEED6" push -q
out6=$(bash "$SCRIPT" "$CLONE6" 2>&1)
assert_contains "case6 diagnostic" "$out6" "removed=1"
[ ! -e "$CLONE6/current/DayPlan 2026-10-03.md" ] || fail "case6 own stale mirror still on disk"

echo "== 7. the mirror staged (added) a path origin only just introduced, never committed locally, THEN origin deletes it -> removed even though HEAD never had it"
new_origin_and_clone case7
CLONE7="$TEST_ROOT/case7-clone"; SEED7="$TEST_ROOT/case7-seed"
printf 'card v1\n' > "$SEED7/inbox/WP-2.md"
"$REAL_GIT" -C "$SEED7" add "inbox/WP-2.md"
"$REAL_GIT" -C "$SEED7" commit -qm "new card WP-2"
"$REAL_GIT" -C "$SEED7" push -q
bash "$SCRIPT" "$CLONE7" >/dev/null 2>&1   # stages WP-2.md into the index; never committed in the clone
"$REAL_GIT" -C "$CLONE7" ls-files --error-unmatch "inbox/WP-2.md" >/dev/null 2>&1 \
  || fail "case7 setup: mirror did not stage the new card"
! "$REAL_GIT" -C "$CLONE7" cat-file -e "HEAD:inbox/WP-2.md" 2>/dev/null \
  || fail "case7 setup: card ended up committed, not staged-only"
"$REAL_GIT" -C "$SEED7" rm -q "inbox/WP-2.md"
"$REAL_GIT" -C "$SEED7" commit -qm "drop card WP-2"
"$REAL_GIT" -C "$SEED7" push -q
out7=$(bash "$SCRIPT" "$CLONE7" 2>&1)
assert_contains "case7 diagnostic" "$out7" "removed=1"
[ ! -e "$CLONE7/inbox/WP-2.md" ] || fail "case7 staged-only mirror still on disk"
! "$REAL_GIT" -C "$CLONE7" ls-files --error-unmatch "inbox/WP-2.md" >/dev/null 2>&1 \
  || fail "case7 staged-only mirror still tracked"

echo "== 8. origin/main has zero paths matching the update scope right now -> the removal loop still runs"
new_origin_and_clone case8
CLONE8="$TEST_ROOT/case8-clone"; SEED8="$TEST_ROOT/case8-seed"
mkdir -p "$SEED8/archive/day-plans"
"$REAL_GIT" -C "$SEED8" mv "current/DayPlan 2026-10-03.md" "archive/day-plans/DayPlan 2026-10-03.md"
"$REAL_GIT" -C "$SEED8" rm -q "inbox/WP-1.md"
"$REAL_GIT" -C "$SEED8" commit -qm "day-close: archive the only plan, drop the only card"
"$REAL_GIT" -C "$SEED8" push -q
remaining=$(git -C "$SEED8" ls-tree -r --name-only main | grep -E '^(inbox/WP-.*\.md|current/[^/]+\.md|MEMORY\.md)$' || true)
[ -z "$remaining" ] || fail "case8 setup: origin/main still has a matching path: $remaining"
out8=$(bash "$SCRIPT" "$CLONE8" 2>&1)
assert_contains "case8 diagnostic" "$out8" "no files matched"
assert_contains "case8 diagnostic" "$out8" "removed=2"
[ ! -e "$CLONE8/current/DayPlan 2026-10-03.md" ] || fail "case8 stale DayPlan still on disk"
[ ! -e "$CLONE8/inbox/WP-1.md" ] || fail "case8 stale WP-1 still on disk"

echo "== 9. a long unpublished local history on the stale path (pipefail/SIGPIPE regression, Codex found 04.10.2026) -> still left alone"
new_origin_and_clone case9
CLONE9="$TEST_ROOT/case9-clone"; SEED9="$TEST_ROOT/case9-seed"
mkdir -p "$SEED9/archive/day-plans"
"$REAL_GIT" -C "$SEED9" mv "current/DayPlan 2026-10-03.md" "archive/day-plans/DayPlan 2026-10-03.md"
"$REAL_GIT" -C "$SEED9" commit -qm "day-close: archive DayPlan"
"$REAL_GIT" -C "$SEED9" push -q
# 1500 local-only commits on the exact stale path -- large enough that a naive
# `git rev-list ... | grep -q .` lets grep exit after the first match and SIGPIPEs git before it
# finishes writing the rest, which is exactly what exposed the bug (reproduced independently by
# Codex with the same count).
for i in $(seq 1 1500); do
  printf 'plan v1\nlocal edit %d\n' "$i" > "$CLONE9/current/DayPlan 2026-10-03.md"
  "$REAL_GIT" -C "$CLONE9" add "current/DayPlan 2026-10-03.md"
  "$REAL_GIT" -C "$CLONE9" commit -q -m "local edit $i" >/dev/null
done
printf 'local only\n' > "$CLONE9/other.txt"
"$REAL_GIT" -C "$CLONE9" add "other.txt"
"$REAL_GIT" -C "$CLONE9" commit -qm "unrelated local commit" >/dev/null
out9=$(bash "$SCRIPT" "$CLONE9" 2>&1)
assert_contains "case9 diagnostic" "$out9" "skipped_remove_ahead=1"
[ -f "$CLONE9/current/DayPlan 2026-10-03.md" ] || fail "case9 1500 unpublished local commits' path was removed"
assert_contains "case9 content preserved" "$(cat "$CLONE9/current/DayPlan 2026-10-03.md")" "local edit 1500"

echo "PASS: sync-strategy-files-removal-smoke.sh (9 scenarios)"
