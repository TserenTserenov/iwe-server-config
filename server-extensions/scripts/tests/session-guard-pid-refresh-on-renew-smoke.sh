#!/usr/bin/env bash
# Regression (WP-530 Ф61): a resumed conversation (`--resume=<id>`) runs under
# a brand-new OS process, but `pid:` in the semaphore is written once, at
# `open`, and never again -- a liveness sweep that trusts only that stale
# field would quarantine a session that is very much alive (live-confirmed on
# tsekh-1, 2026-09-25: 2 of 3 active sessions carried a dead launch-time pid).
# `renew`, `note-file` and `note-commit` each prove the CURRENT process is the
# live owner just by being invoked -- this checks they correct `pid:`/
# `pid_start:` to match, and that a semaphore quarantines by its REFRESHED
# pid, not its stale one.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-pid-refresh.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

GOV="$TEST_ROOT/DS-strategy"
SESSION_DIR="$TEST_ROOT/.iwe-runtime/sessions"
REGISTRY="$TEST_ROOT/.iwe-runtime/zombie-semaphores.jsonl"
mkdir -p "$GOV/scripts" "$SESSION_DIR" "$TEST_ROOT/bin"
git -C "$GOV" init -q

cat > "$TEST_ROOT/bin/iwe-tg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_ROOT/bin/iwe-tg"

fail() { echo "FAIL: $*" >&2; exit 1; }

sg() {  # <subcommand...>
  IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_ZOMBIE_ESCALATE_SEC=1 \
    IWE_HEARTBEAT_STALE_SEC=600 IWE_AGENT=claude-code \
    PATH="$TEST_ROOT/bin:$PATH" /bin/bash "$GUARD" "$@" 2>&1
}

write_semaphore() {  # <path> <session> <pid>
  local path="$1" session="$2" pid="$3"
  {
    echo "agent: claude-code"
    echo "wp: WP-530"
    echo "slug: $session"
    echo "opened_at: 2000-01-01T00:00:00Z"
    echo "created_at: 2000-01-01T00:00:00Z"
    echo "session_id: $session"
    echo "harness_session_id: $session"
    echo "governance_worktree: $TEST_ROOT/.iwe-runtime/isolated-worktrees/$session"
    echo "isolated_worktree: $TEST_ROOT/.iwe-runtime/isolated-worktrees/$session"
    echo "pid: $pid"
    echo "host: $(hostname)"
    echo "---"
    echo "file: inbox/WP-530/WP-530.md"
  } > "$path"
}

DEAD_PID=99999999
if kill -0 "$DEAD_PID" 2>/dev/null; then
  fail "fixture dead PID unexpectedly exists: $DEAD_PID"
fi
# A real `claude` process, not this test script's own bash pid: the sweep's
# separate PID-identity check (Ф43) escalates any live pid whose `comm`
# doesn't contain "claude" for an `agent: claude-code` semaphore -- using our
# own actual harness process here is both realistic and avoids that unrelated
# check firing as a false positive for this fixture.
LIVE_PID="${CLAUDE_PID:-$$}"

# 1. renew with OWNER_PID set to the current (live) process corrects a
#    semaphore that still carries the launch-time (now dead) pid.
SEM="$SESSION_DIR/claude-code-resume-renew.open"
write_semaphore "$SEM" resume-renew "$DEAD_PID"
OUT=$(CLAUDE_PID=$LIVE_PID sg renew --wp WP-530 --slug resume-renew) || fail "renew failed: $OUT"
grep -q "^pid: $LIVE_PID\$" "$SEM" || fail "renew did not refresh pid: to the live process ($OUT)"
grep -qE '^pid_start: [^ ].*[^ ]$' "$SEM" || fail "renew did not add a trimmed pid_start: for the refreshed pid"

# 2. A semaphore refreshed by renew is NOT quarantined by a later sweep, even
#    though its ORIGINAL pid (still on disk in the fixture below) is dead --
#    the sweep must see the refreshed field, not a cached/original value.
DEAD_SEM="$SESSION_DIR/claude-code-still-dead.open"
write_semaphore "$DEAD_SEM" still-dead "$DEAD_PID"
printf 'renewed_at: 2000-01-01T00:00:01Z\nsession_id: still-dead\n' > "$DEAD_SEM.lease"
# `audit` exits non-zero whenever it has anything to report (e.g. the
# live resume-renew session listed as "active, no close yet") -- that is
# normal, informational status, not a failure; the assertions below check
# the actual outcome instead of the exit code.
OUT=$(sg audit --cleanup-orphans --quarantine-dead-interactive || true)
[ -f "$DEAD_SEM.orphaned-dead-interactive" ] || fail "control case: a genuinely dead, unrefreshed semaphore should still quarantine"
[ -f "$SEM" ] || fail "resume-renew semaphore was quarantined despite its refreshed, live pid"
[ ! -f "$SEM.orphaned-dead-interactive" ] || fail "resume-renew semaphore was quarantined despite its refreshed, live pid"

# 3. note-file performs the same refresh (already held under the same
#    session-transition-lock as its existing lease auto-renewal, WP-484 Ф133).
SEM2="$SESSION_DIR/claude-code-resume-notefile.open"
write_semaphore "$SEM2" resume-notefile "$DEAD_PID"
OUT=$(cd "$GOV" && CLAUDE_PID=$LIVE_PID IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
  PATH="$TEST_ROOT/bin:$PATH" /bin/bash "$GUARD" note-file inbox/WP-530/WP-530.md \
  --wp WP-530 --slug resume-notefile --agent claude-code 2>&1) || fail "note-file failed: $OUT"
grep -q "^pid: $LIVE_PID\$" "$SEM2" || fail "note-file did not refresh pid: to the live process ($OUT)"

# 4. A semaphore with no pid: field at all (kimi/codex adapters) is left
#    untouched -- this fix targets claude-code's liveness model, not theirs.
SEM3="$SESSION_DIR/kimi-headless-no-pid.open"
{
  echo "agent: kimi-headless"
  echo "wp: WP-530"
  echo "slug: no-pid"
  echo "opened_at: 2000-01-01T00:00:00Z"
  echo "created_at: 2000-01-01T00:00:00Z"
  echo "session_id: no-pid"
  echo "---"
  echo "file: inbox/WP-530/WP-530.md"
} > "$SEM3"
BEFORE=$(cat "$SEM3")
OUT=$(CLAUDE_PID=$LIVE_PID IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_AGENT=kimi-headless \
  PATH="$TEST_ROOT/bin:$PATH" /bin/bash "$GUARD" renew --wp WP-530 --slug no-pid --agent kimi-headless 2>&1) \
  || fail "renew (kimi, no pid) failed: $OUT"
AFTER=$(cat "$SEM3")
[ "$BEFORE" = "$AFTER" ] || fail "renew added a pid: field to a semaphore that never had one (kimi/codex liveness model must stay untouched)"

# 5. Cold-review Critical (2026-09-25): `renew --foreign` (WP-545, 05.09) is a
#    documented, already-used-in-prod escape hatch for renewing SOMEONE
#    ELSE'S semaphore. Refreshing pid:/pid_start: there would stamp the
#    CALLING session's own pid onto the session it is merely extending --
#    the exact bug this phase fixes, reopened through this other door.
FOREIGN_OWNER_PID=99999998
if kill -0 "$FOREIGN_OWNER_PID" 2>/dev/null; then
  fail "fixture foreign-owner PID unexpectedly exists: $FOREIGN_OWNER_PID"
fi
SEM4="$SESSION_DIR/claude-code-foreign-owner.open"
write_semaphore "$SEM4" foreign-owner "$FOREIGN_OWNER_PID"
# --session-id is the actual foreign-renew path (WP-537/WP-545): it targets
# ANOTHER session's exact semaphore by id, not "whichever semaphore my own
# agent+wp+slug resolves to" -- --wp/--slug alone would just find the
# caller's own session and never exercise this code path at all.
OUT=$(CLAUDE_PID=$LIVE_PID IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_AGENT=claude-code \
  PATH="$TEST_ROOT/bin:$PATH" /bin/bash "$GUARD" renew --session-id foreign-owner \
  --agent claude-code --foreign --reason "test: unrelated caller renews a stuck lease" 2>&1) \
  || fail "renew --foreign failed: $OUT"
grep -q "^pid: $FOREIGN_OWNER_PID\$" "$SEM4" \
  || fail "renew --foreign overwrote the foreign session's pid: with the calling session's own pid -- this reintroduces the false-quarantine bug through --foreign"

# 6. note-commit performs the same refresh as renew/note-file on ITS OWN
#    session (not a --foreign path -- note-commit has no such flag).
git -C "$GOV" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m "fixture commit"
FIXTURE_SHA=$(git -C "$GOV" rev-parse HEAD)
SEM5="$SESSION_DIR/claude-code-resume-notecommit.open"
write_semaphore "$SEM5" resume-notecommit "$DEAD_PID"
OUT=$(cd "$GOV" && CLAUDE_PID=$LIVE_PID IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
  PATH="$TEST_ROOT/bin:$PATH" /bin/bash "$GUARD" note-commit "$FIXTURE_SHA" \
  --wp WP-530 --slug resume-notecommit --agent claude-code 2>&1) || fail "note-commit failed: $OUT"
grep -q "^pid: $LIVE_PID\$" "$SEM5" || fail "note-commit did not refresh pid: to the live process ($OUT)"

echo "PASS: renew/note-file/note-commit refresh a resumed session's pid:/pid_start: to the live process, a genuinely dead session still quarantines, pid-less (kimi/codex) semaphores are left untouched, and renew --foreign never overwrites the foreign session's own pid"
