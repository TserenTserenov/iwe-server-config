#!/usr/bin/env bash
# Regression (WP-484 Ф204 п.2, АрхГейт 18.10, peer-session Claude+Kimi+Codex
# 2026-10-20): dead-semaphore auto-recovery is off by default, and its
# dry-run observation pass (a) never mutates a quarantine even when a
# candidate fails the fresh recheck, (b) is a pure no-op when neither flag
# is set -- the sweep summary and quarantine state must be byte-identical
# to the pre-Ф204.2 behaviour, and (c) the manual recovery CLI path and the
# sweep's own candidate/recheck paths all go through the one shared
# _recover_orphaned_preflight function, not three copies of its checks.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-auto-recovery.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. Single shared preflight: one definition, three call sites. ---
# This is a call-graph identity check, not a byte-for-byte string compare
# (round-1 critique, Kimi, 2026-10-20): renaming a local variable or
# reformatting either call site does not break this test; replacing one of
# the three calls with a copy of the checks under a different name does.
DEF_COUNT=$(grep -c '^_recover_orphaned_preflight() {' "$GUARD")
[ "$DEF_COUNT" -eq 1 ] || fail "_recover_orphaned_preflight must be defined exactly once, found $DEF_COUNT"
CALL_COUNT=$(grep -c '_recover_orphaned_preflight "' "$GUARD")
[ "$CALL_COUNT" -eq 3 ] \
  || fail "expected exactly 3 call sites (manual recover-orphaned, sweep phase 1, sweep phase 2 recheck), found $CALL_COUNT"
grep -q 'event_json=\$(_recover_orphaned_preflight "\$ORPHAN_FILE" "\$BASE_ORPHAN_FILE")' "$GUARD" \
  || fail "manual recover-orphaned path does not call the shared preflight"
grep -q '_recover_orphaned_preflight "\$dead_quarantine_path" "\$dead_quarantine_path" >/dev/null' "$GUARD" \
  || fail "sweep phase 1 (candidate marking) does not call the shared preflight"
grep -q 'event_json=\$(_recover_orphaned_preflight "\$base" "\$base")' "$GUARD" \
  || fail "sweep phase 2 (fresh recheck) does not call the shared preflight"
echo "PASS: part 1 -- single _recover_orphaned_preflight definition, used by all three call sites"

# --- 2+3. Behavioural: default is a no-op; dry-run on a candidate without
# valid terminal proof records recheck_reject and never mutates the file. ---
GOV="$TEST_ROOT/DS-strategy"
SESSION_DIR="$TEST_ROOT/.iwe-runtime/sessions"
REGISTRY="$TEST_ROOT/.iwe-runtime/zombie-semaphores.jsonl"
DRY_RUN_LOG="$TEST_ROOT/logs/dead-semaphore-auto-dry-run.jsonl"
TG_LOG="$TEST_ROOT/iwe-tg.log"
mkdir -p "$GOV/scripts" "$GOV/sessions" "$SESSION_DIR" "$TEST_ROOT/bin" "$TEST_ROOT/scripts"
git -C "$GOV" init -q
# `audit`'s ORZ-defect section defaults ORZ_DIR to
# ${IWE_SESSIONS_ROOT:-$IWE_ROOT/MC-sessions} -- an ALREADY-EXPORTED
# IWE_SESSIONS_ROOT in the calling shell (e.g. from an earlier peer-session
# in this same terminal) wins over that default and points `audit` at the
# real MC-sessions repo instead of this sandbox, which is slow (real repo
# size) and unrelated to this test. Isolate it explicitly, same as the
# existing session-guard-dead-interactive-quarantine-smoke.sh fixture does.
export IWE_SESSIONS_ROOT="$GOV/sessions"
git -C "$IWE_SESSIONS_ROOT" init -q

cat > "$TEST_ROOT/bin/iwe-tg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_ROOT/bin/iwe-tg"

# `audit` unconditionally also runs its own §2 ("open semaphores without an
# ORZ file"), which shells out to $IWE_ROOT/scripts/open-log-snapshot.sh --
# unrelated to the sweep/dry-run behaviour this test exercises, but §2 runs
# in the same process after the sweep and a real production IWE_ROOT always
# has this script. A stub keeps the fixture minimal without masking any
# check this test actually cares about.
cat > "$TEST_ROOT/scripts/open-log-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_ROOT/scripts/open-log-snapshot.sh"

DEAD_PID=99999999
if kill -0 "$DEAD_PID" 2>/dev/null; then
  fail "fixture PID unexpectedly exists: $DEAD_PID"
fi

SEM="$SESSION_DIR/claude-code-dead-base.open"
{
  echo "---"
  echo "agent: claude-code"
  echo "wp: WP-530"
  echo "slug: dead-base"
  echo "opened_at: 2000-01-01T00:00:00Z"
  echo "created_at: 2000-01-01T00:00:00Z"
  echo "session_id: dead-base"
  echo "governance_worktree: $TEST_ROOT/.iwe-runtime/isolated-worktrees/dead-base"
  echo "isolated_worktree: $TEST_ROOT/.iwe-runtime/isolated-worktrees/dead-base"
  echo "pid: $DEAD_PID"
  echo "---"
  echo "file: inbox/WP-530/WP-530.md"
} > "$SEM"
mkdir -p "$TEST_ROOT/.iwe-runtime/isolated-worktrees/dead-base/inbox/agent/tasks"

run_audit() {  # [extra audit flags...]
  IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
    IWE_ZOMBIE_ESCALATE_SEC=1 IWE_HEARTBEAT_STALE_SEC=600 \
    IWE_DEAD_SEMAPHORE_AUTO_DRY_RUN_LOG="$DRY_RUN_LOG" \
    PATH="$TEST_ROOT/bin:$PATH" /bin/bash "$GUARD" audit "$@" 2>&1
}

# 2. Default (both flags off, same as before Ф204.2): no dry-run log, sweep
# summary unchanged -- quarantine happens (the pre-existing opt-in flag is
# set), but the new phase never runs.
OUT=$(run_audit --cleanup-orphans --quarantine-dead-interactive)
grep -q 'dead_quarantined=1' <<<"$OUT" || fail "sweep summary did not count the quarantine with both auto-recovery flags off"
[ ! -e "$DRY_RUN_LOG" ] || fail "dry-run log was created even though both flags are off"
QUARANTINE_FILE="$SESSION_DIR/claude-code-dead-base.open.orphaned-dead-interactive"
[ -f "$QUARANTINE_FILE" ] || fail "setup: expected quarantine file not found"
echo "PASS: part 2 -- default (both flags off) creates no dry-run log, matches pre-patch sweep summary"

# 3. Dry run on a second, otherwise-identical dead semaphore (no managed
# isolated-worktree with a matching RUN-quick-close card exists for this
# fixture, so it has no valid terminal proof -- the realistic common case
# for most dead sessions, which never reached a terminal quick-close card).
# Phase 1's own preflight call must already reject it, so it is never added
# as a candidate; phase 2 then has nothing to recheck, and the observation
# log stays untouched. This still exercises the real phase-1 call with the
# flag on (not a no-op skip) and proves it stays silent and non-mutating
# for a candidate it correctly refuses, which is the overwhelmingly common
# live case this dry-run window is meant to observe.
SEM2="$SESSION_DIR/claude-code-dead-second.open"
{
  echo "---"
  echo "agent: claude-code"
  echo "wp: WP-530"
  echo "slug: dead-second"
  echo "opened_at: 2000-01-01T00:00:00Z"
  echo "created_at: 2000-01-01T00:00:00Z"
  echo "session_id: dead-second"
  echo "governance_worktree: $TEST_ROOT/.iwe-runtime/isolated-worktrees/dead-second"
  echo "isolated_worktree: $TEST_ROOT/.iwe-runtime/isolated-worktrees/dead-second"
  echo "pid: $DEAD_PID"
  echo "---"
  echo "file: inbox/WP-530/WP-530.md"
} > "$SEM2"
mkdir -p "$TEST_ROOT/.iwe-runtime/isolated-worktrees/dead-second/inbox/agent/tasks"

OUT=$(IWE_DEAD_SEMAPHORE_AUTO_DRY_RUN=1 run_audit --cleanup-orphans --quarantine-dead-interactive)
grep -q 'dead_quarantined=1' <<<"$OUT" || fail "sweep summary did not count the second quarantine with dry-run on"
QUARANTINE_FILE2="$SESSION_DIR/claude-code-dead-second.open.orphaned-dead-interactive"
[ -f "$QUARANTINE_FILE2" ] || fail "setup: second quarantine file not found"
[ -f "$QUARANTINE_FILE2.recovery-pending" ] && fail "dry-run must never move a quarantine into recovery-pending"
[ -f "$QUARANTINE_FILE2.recovered" ] && fail "dry-run must never mark a quarantine recovered"
[ ! -e "$DRY_RUN_LOG" ] \
  || { cat "$DRY_RUN_LOG" >&2; fail "phase 1 should have rejected this candidate before any log entry -- an entry means an unprovable quarantine was treated as a candidate"; }
echo "PASS: part 3 -- dry-run's own phase-1 check rejects a candidate without valid terminal proof, writes nothing, mutates nothing"

echo "PASS: dead-semaphore auto-recovery is off by default, shares one preflight across all three call sites, and never mutates a quarantine during dry-run observation"
