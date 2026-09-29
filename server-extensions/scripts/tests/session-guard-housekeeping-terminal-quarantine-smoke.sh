#!/usr/bin/env bash
# Regression (bug-2026-09-22 day-close lockout): a dead-interactive quarantine
# file (.open.orphaned-dead-interactive) is terminal evidence, not a live fence.
# It must not block a fresh `open --housekeeping` of the same fixed name, an
# unknown sibling must still block it, and a SECOND death of the same fixed name
# must be quarantined next to the first without overwriting that evidence.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-hk-terminal.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)  # owner-status refuses a sessions dir behind a symlink (macOS /var)
trap 'rm -rf "$TEST_ROOT"' EXIT

GOV="$TEST_ROOT/DS-strategy"
SESSION_DIR="$TEST_ROOT/.iwe-runtime/sessions"
mkdir -p "$GOV/scripts" "$GOV/sessions" "$SESSION_DIR" "$TEST_ROOT/bin"
git -C "$GOV" init -q
export IWE_SESSIONS_ROOT="$GOV/sessions" IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy

printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/bin/iwe-tg"
chmod +x "$TEST_ROOT/bin/iwe-tg"

SEM="$SESSION_DIR/claude-code-housekeeping-day-close.open"
FIRST="$SEM.orphaned-dead-interactive"
DEAD_PID=99999999
kill -0 "$DEAD_PID" 2>/dev/null && { echo "FAIL: fixture PID unexpectedly exists" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
open_hk() { # <reason>
  ( cd "$GOV" && PATH="$TEST_ROOT/bin:$PATH" bash "$GUARD" open --housekeeping "$1" \
      --agent claude-code --canonical-owner "$1" --owner-pid $$ ) 2>&1
}
audit_quarantine() {
  ( cd "$GOV" && IWE_ZOMBIE_ESCALATE_SEC=1 PATH="$TEST_ROOT/bin:$PATH" \
      bash "$GUARD" audit --cleanup-orphans --quarantine-dead-interactive ) 2>&1
}
write_dead_semaphore() { # <path>
  cat > "$1" <<EOF
---
agent: claude-code
housekeeping: day-close
slug: day-close
session_id: housekeeping-day-close
opened_at: 2000-01-01T00:00:00Z
created_at: 2000-01-01T00:00:00Z
pid: $DEAD_PID
---
file: archive/day-plans/DayPlan 2000-01-01.md
EOF
}

# 1. A leftover quarantine file from a previous death must not block the open.
write_dead_semaphore "$FIRST"
FIRST_SUM=$(shasum -a 256 "$FIRST" | cut -d' ' -f1)
OUT=$(open_hk day-close) || fail "open must succeed beside a terminal quarantine file, got: $OUT"
[ -f "$SEM" ] || fail "the fresh semaphore was not created"
[ "$(shasum -a 256 "$FIRST" | cut -d' ' -f1)" = "$FIRST_SUM" ] || fail "the quarantine evidence must stay byte-identical"
echo "OK: terminal quarantine file does not block a fresh housekeeping open and stays intact"

# 2. An unknown sibling must still fail closed (the guard is not weakened).
: > "$SESSION_DIR/claude-code-housekeeping-probe.open.mystery"
if OUT=$(open_hk probe); then fail "an unknown sibling must still block the open, got: $OUT"; fi
printf '%s' "$OUT" | grep -q 'sibling' || fail "the refusal must name the sibling state, got: $OUT"
[ ! -e "$SESSION_DIR/claude-code-housekeeping-probe.open" ] || fail "a refused open must leave no semaphore"
echo "OK: unknown sibling state still blocks the open"

# 3. A symlink wearing the terminal suffix is not evidence: still blocks.
ln -s /nonexistent "$SESSION_DIR/claude-code-housekeeping-link.open.orphaned-dead-interactive"
if OUT=$(open_hk link); then fail "a symlink with the terminal suffix must still block, got: $OUT"; fi
ln -s /nonexistent "$SESSION_DIR/claude-code-housekeeping-link2.open.orphaned-dead-interactive-1790000000"
if OUT=$(open_hk link2); then fail "a symlink with the repeat-death name must still block, got: $OUT"; fi
echo "OK: a symlink with the terminal suffix still blocks"

# 4. The same fixed name dies again: quarantined beside the first, evidence kept.
write_dead_semaphore "$SEM"
OUT=$(audit_quarantine) || fail "audit failed: $OUT"
printf '%s' "$OUT" | grep -q 'QUARANTINED: claude-code-housekeeping-day-close.open' \
  || fail "the second dead semaphore must be quarantined, got: $OUT"
[ ! -e "$SEM" ] || fail "the second dead semaphore must leave .open"
[ "$(shasum -a 256 "$FIRST" | cut -d' ' -f1)" = "$FIRST_SUM" ] || fail "the first evidence must not be overwritten"
SECOND=$(find "$SESSION_DIR" -name 'claude-code-housekeeping-day-close.open.orphaned-dead-interactive-[0-9]*' | head -1)
[ -n "$SECOND" ] || fail "the second quarantine must land under a distinct name"
echo "OK: a second death is quarantined under a distinct name, first evidence untouched"

# 4b. The repeat-death name stays readable by owner-status: same answer as with
#     only the first quarantine (it keys on the .open.orphaned- prefix).
owner_status() { ( cd "$GOV" && bash "$GUARD" owner-status --owner-session-id housekeeping-day-close --owner-agent claude-code ) 2>&1 || true; }
STATUS_TWO=$(owner_status)
mv "$SECOND" "$TEST_ROOT/second.evidence"
STATUS_ONE=$(owner_status)
mv "$TEST_ROOT/second.evidence" "$SECOND"
printf '%s' "$STATUS_ONE" | grep -q 'unsafe sessions directory' && fail "owner-status ran in an unsafe sandbox, the check proves nothing: $STATUS_ONE"
[ "$STATUS_TWO" = "$STATUS_ONE" ] || fail "owner-status must answer the same for the repeat-death name: one='$STATUS_ONE' two='$STATUS_TWO'"
echo "OK: owner-status answers the same with the repeat-death name (got: $STATUS_TWO)"

# 5. With two terminal files present the fixed name opens again.
OUT=$(open_hk day-close) || fail "open must succeed beside two terminal quarantine files, got: $OUT"
[ -f "$SEM" ] || fail "the semaphore was not recreated"
echo "OK: the fixed name opens again after repeated deaths"
