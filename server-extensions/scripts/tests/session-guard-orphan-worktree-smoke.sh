#!/usr/bin/env bash
# Regression: an age-only no-PID quarantine may preserve the semaphore, but it
# must not publish or remove its isolated worktree without a terminal outcome.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-orphan-worktree.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

GOV="$TEST_ROOT/DS-strategy"
SESSION_DIR="$TEST_ROOT/.iwe-runtime/sessions"
WORKTREE="$TEST_ROOT/isolated-worktree"
PUSH_MARKER="$TEST_ROOT/isolate-push-called"
LEDGER_MARKER="$TEST_ROOT/ledger-called"
mkdir -p "$GOV/scripts" "$GOV/sessions" "$SESSION_DIR" \
  "$WORKTREE/inbox/agent/tasks"

cat > "$GOV/scripts/isolate-push.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$PUSH_MARKER"
exit 0
EOF
cat > "$GOV/scripts/ledger-append.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$LEDGER_MARKER"
exit 0
EOF
chmod +x "$GOV/scripts/isolate-push.sh" "$GOV/scripts/ledger-append.sh"

SEMAPHORE="$SESSION_DIR/kimi-no-pid-fixture.open"
cat > "$SEMAPHORE" <<EOF
---
agent: kimi
wp: WP-537
slug: no-pid-fixture
opened_at: 2000-01-01T00:00:00Z
created_at: 2000-01-01T00:00:00Z
session_id: no-pid-fixture
isolated_worktree: $WORKTREE
---
EOF

# A non-terminal card is deliberately present: the decision must inspect its
# outcome, not treat any matching card as proof of completion.
cat > "$WORKTREE/inbox/agent/tasks/RUN-quick-close-no-pid-fixture.md" <<'EOF'
---
process_id: quick-close
status: running
current_step: commit-push
---
EOF

OUT=$(IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
  IWE_ZOMBIE_ESCALATE_SEC=1 IWE_ZOMBIE_CLEANUP_SEC=1 \
  bash "$GUARD" audit --cleanup-orphans 2>&1)

QUARANTINED="${SEMAPHORE}.orphaned-zombie-no-pid"
[ ! -e "$SEMAPHORE" ] || {
  echo "FAIL: old no-PID semaphore stayed open" >&2
  exit 1
}
[ -f "$QUARANTINED" ] || {
  echo "FAIL: no-PID semaphore was not quarantined" >&2
  exit 1
}
[ -d "$WORKTREE" ] || {
  echo "FAIL: age-only quarantine removed the recovery worktree" >&2
  exit 1
}
[ ! -e "$PUSH_MARKER" ] || {
  echo "FAIL: age-only quarantine called isolate-push.sh without terminal proof" >&2
  exit 1
}
grep -q 'no proven terminal outcome' <<<"$OUT" || {
  echo "FAIL: audit did not explain why it preserved the worktree: $OUT" >&2
  exit 1
}
grep -q '"action":"quarantined"' "$TEST_ROOT/.iwe-runtime/zombie-semaphores.jsonl" || {
  echo "FAIL: quarantine event was not recorded" >&2
  exit 1
}

# Positive control: the same age-only route may hand a clean worktree to the
# existing reaper only after a matching terminal runner card supplies proof.
TERMINAL_WORKTREE="$TEST_ROOT/terminal-worktree"
mkdir -p "$TERMINAL_WORKTREE/inbox/agent/tasks"
cat > "$TERMINAL_WORKTREE/inbox/agent/tasks/RUN-quick-close-terminal-fixture.md" <<'EOF'
---
process_id: quick-close
status: completed
current_step: done
all_pushed: true
---
EOF
TERMINAL_SEMAPHORE="$SESSION_DIR/kimi-terminal-fixture.open"
cat > "$TERMINAL_SEMAPHORE" <<EOF
---
agent: kimi
wp: WP-537
slug: terminal-fixture
opened_at: 2000-01-01T00:00:00Z
created_at: 2000-01-01T00:00:00Z
session_id: terminal-fixture
isolated_worktree: $TERMINAL_WORKTREE
---
EOF
IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
  IWE_ZOMBIE_ESCALATE_SEC=1 IWE_ZOMBIE_CLEANUP_SEC=1 \
  bash "$GUARD" audit --cleanup-orphans >/dev/null 2>&1
grep -qF "$TERMINAL_WORKTREE main" "$PUSH_MARKER" || {
  echo "FAIL: proven terminal outcome did not reach the existing reaper" >&2
  exit 1
}

# The existing sanctioned recovery path stays available: it records a terminal
# recovery event and keeps the quarantine history instead of resurrecting .open.
IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy \
  bash "$GUARD" recover-orphaned "$(basename "$QUARANTINED")" >/dev/null
[ -f "${QUARANTINED}.recovered" ] || {
  echo "FAIL: recover-orphaned did not retain the quarantined record" >&2
  exit 1
}
grep -q 'session_recovered_closed' "$LEDGER_MARKER" || {
  echo "FAIL: recover-orphaned did not write its ledger event" >&2
  exit 1
}
[ -d "$WORKTREE" ] || {
  echo "FAIL: recover-orphaned unexpectedly removed the worktree" >&2
  exit 1
}

echo "PASS: no-PID age quarantine preserves worktree and recovery semantics"
