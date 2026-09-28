#!/usr/bin/env bash
# session-guard-runner-session-smoke.sh -- WP-561 Ф25: the contract the strategist wrapper relies on.
# A scheduled runner (the week-review wrapper) opens a HOUSEKEEPING session with --canonical-owner on
# a frozen checkout, declares a directory scope, and lets ANOTHER agent (the model) commit inside it.
# The guard's scope gate is agent-agnostic: any live semaphore covering a path authorises the commit.
# Regressing any line here breaks the wrapper's "session owned by the script" design.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-runner-session.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

GOV="$TEST_ROOT/DS-strategy"
git init -q -b main "$GOV"
git -C "$GOV" config user.email t@t
git -C "$GOV" config user.name t
mkdir -p "$GOV/current"
echo plan > "$GOV/current/WeekPlan W39 2026-09-21.md"
git -C "$GOV" add -A
git -C "$GOV" -c commit.gpgsign=false commit -q -m seed

# The checkout is frozen, the way the real canonical governance checkout is.
export IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="$GOV"
RUNNER=strategist-week-review
SEM="$TEST_ROOT/.iwe-runtime/sessions/${RUNNER}-housekeeping-week-review.open"

fail() { echo "FAIL: $*" >&2; exit 1; }
runner() { ( cd "$GOV" && bash "$GUARD" "$@" ) 2>&1; }
open_runner() { runner open --housekeeping week-review --agent "$RUNNER" --canonical-owner week-review --owner-pid $$; }
model_check() { ( cd "$GOV" && IWE_AGENT=claude-code bash "$GUARD" pre-commit-check ) >"$TEST_ROOT/check.out" 2>&1; }

# 1. Without --canonical-owner a housekeeping session is refused on the frozen checkout.
if OUT=$(runner open --housekeeping week-review --agent "$RUNNER" --owner-pid $$); then
    fail "housekeeping open on a frozen checkout must need --canonical-owner, got: $OUT"
fi
printf '%s' "$OUT" | grep -q 'freeze' || fail "the refusal must name the freeze, got: $OUT"
[ ! -e "$SEM" ] || fail "a refused open must leave no semaphore"
echo "OK: plain housekeeping open is refused under freeze and leaves nothing behind"

# 2. As a scheduled runner it opens, and the directory scope is recorded.
open_runner >/dev/null || fail "open --housekeeping --canonical-owner must succeed under freeze"
[ -f "$SEM" ] || fail "the semaphore file was not created"
runner note-file "current/" --agent "$RUNNER" >/dev/null || fail "note-file of a directory scope must succeed"
grep -qx 'file: current/' "$SEM" || fail "the directory scope must be recorded in the semaphore"
grep -q '^wp:' "$SEM" && fail "a housekeeping semaphore must carry no wp (the commit barrier would have to classify it)"
echo "OK: scheduled-runner open works under freeze; scope current/ recorded; no wp field"

# 3. The model (another agent) commits a NEW and a MODIFIED file inside the scope.
echo report > "$GOV/current/WeekReport W39 2026-09-21.md"
echo "plan v2" >> "$GOV/current/WeekPlan W39 2026-09-21.md"
git -C "$GOV" add -A
model_check || fail "another agent's commit inside the declared scope must pass: $(tail -3 "$TEST_ROOT/check.out")"
echo "OK: another agent may commit a new and a modified file inside the runner's scope"

# 4. A file outside the scope is still refused.
echo x > "$GOV/other.txt"
git -C "$GOV" add other.txt
RC=0; model_check || RC=$?
[ "$RC" = "6" ] || fail "a new file outside the scope must be refused with exit 6, got $RC"
grep -q 'other.txt' "$TEST_ROOT/check.out" || fail "the refusal must name the file"
git -C "$GOV" restore --staged other.txt
rm -f "$GOV/other.txt"
echo "OK: a file outside the declared scope is refused"

# 5. A leftover semaphore of a dead run refuses the fixed name until an exact close.
if OUT=$(open_runner); then fail "reopening without close must be refused, got: $OUT"; fi
printf '%s' "$OUT" | grep -q 'уже открыт' || fail "the refusal must say it is already open, got: $OUT"
runner close --housekeeping week-review --agent "$RUNNER" >/dev/null || fail "an exact close of the leftover must succeed"
[ ! -e "$SEM" ] || fail "close must remove the semaphore"
open_runner >/dev/null || fail "open after close must succeed"
echo "OK: a leftover refuses the fixed name; close, then open works"

# 6. After close the authority is gone.
runner close --housekeeping week-review --agent "$RUNNER" >/dev/null
RC=0; model_check || RC=$?
[ "$RC" != "0" ] || fail "after close the same commit must be refused"
echo "OK: after close the commit is refused again"

# 7. Two live sessions of the same runner (a run that overlapped midnight next to a leftover whose
# pid is alive): the agent-only selector is ambiguous and must refuse; the run's own reason, stored
# as the slug, selects exactly its session -- the scope lands there and nowhere else.
SEM2="$TEST_ROOT/.iwe-runtime/sessions/${RUNNER}-housekeeping-week-review-2.open"
open_runner >/dev/null || fail "first of two sessions must open"
runner open --housekeeping week-review-2 --agent "$RUNNER" --canonical-owner week-review --owner-pid $$ >/dev/null \
    || fail "a second session under another reason must open (unique name per run)"
if OUT=$(runner note-file "current/" --agent "$RUNNER"); then
    fail "note-file by agent alone must refuse with two live sessions, got: $OUT"
fi
printf '%s' "$OUT" | grep -q 'несколько открытых семафоров' || fail "the refusal must say several sessions are open, got: $OUT"
runner note-file "current/" --agent "$RUNNER" --slug week-review-2 >/dev/null || fail "note-file selected by slug must succeed"
grep -qx 'file: current/' "$SEM2" || fail "the scope must be recorded in the session selected by slug"
grep -qx 'file: current/' "$SEM" && fail "the other live session must stay untouched"
git -C "$GOV" add -A
model_check || fail "the commit inside the slug-selected session's scope must pass: $(tail -3 "$TEST_ROOT/check.out")"
runner close --housekeeping week-review-2 --agent "$RUNNER" >/dev/null || fail "close by reason must pick the right one of two"
[ ! -e "$SEM2" ] || fail "close must remove the slug-selected session"
[ -e "$SEM" ] || fail "close must leave the other live session alone"
runner close --housekeeping week-review --agent "$RUNNER" >/dev/null
echo "OK: with two live sessions the slug selects the run's own one; scope, commit and close land there only"

echo "PASS: a runner-owned housekeeping session authorises another agent's commit inside its scope only"
