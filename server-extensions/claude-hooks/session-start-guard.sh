#!/usr/bin/env bash
# SessionStart — write a lightweight session-marker (WP-484 Ф33/Нить1).
#
# NOT a session-guard.sh semaphore: the WP number isn't known yet at
# SessionStart (WP Gate runs later, inside the conversation), and writing a
# placeholder `wp:` into a real semaphore was rejected in peer-session
# 2026-07-31-14-wp484-session-close-discipline (pollutes the semaphore
# invariant, and would let the pre-commit scope gate pass before WP Gate
# actually ran). The marker is a separate, audit-only artifact: did this
# conversation ever start, regardless of whether WP Gate/session-guard open
# followed. session-end-status.sh removes it on SessionEnd.
#
# Fail-open: a broken hook must never block session start. Every failure
# path still emits '{}' and exits 0; only a note gets appended to the
# telemetry log below instead of failing silently.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "${HOOK_DIR}/.." && pwd)"
# shellcheck source=../lib/iwe-env-bootstrap.sh
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" 2>/dev/null || { echo '{}'; exit 0; }

MARKER_DIR="$IWE_ROOT/.iwe-runtime/session-markers"
FAIL_DIR="$IWE_ROOT/.iwe-runtime/session-start-failures"

note_failure() {
  mkdir -p "$FAIL_DIR" 2>/dev/null || return 0
  printf '%s | %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$FAIL_DIR/$(date +%s)-$$.log" 2>/dev/null || true
}

INPUT="$(cat 2>/dev/null || true)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
if [ -z "$SESSION_ID" ]; then
  note_failure "no session_id in SessionStart payload — marker not written"
  echo '{}'
  exit 0
fi

if ! mkdir -p "$MARKER_DIR" 2>/dev/null; then
  note_failure "mkdir $MARKER_DIR failed"
  echo '{}'
  exit 0
fi

MARKER_FILE="$MARKER_DIR/claude-code-${SESSION_ID}.yaml"
{
  echo "agent: claude-code"
  echo "session_id: $SESSION_ID"
  echo "opened_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hook_pid: $$"
} > "$MARKER_FILE" 2>/dev/null || note_failure "write $MARKER_FILE failed"

echo '{}'
exit 0
