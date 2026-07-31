#!/usr/bin/env bash
# SessionEnd — fail-safe agent-status write (issue #266, РП-395 Ф3 promise)
# + session-marker cleanup (WP-484 Ф33/Нить1, peer-session
# 2026-07-31-14-wp484-session-close-discipline). Both steps are best-effort:
# this hook mirrors agent-status-report.sh's own "never fail the caller"
# contract and never blocks session end.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "${HOOK_DIR}/.." && pwd)"
# shellcheck source=../lib/iwe-env-bootstrap.sh
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" 2>/dev/null || { echo '{}'; exit 0; }

STATUS_SCRIPT="$IWE_ROOT/scripts/agent-status-report.sh"
[ -x "$STATUS_SCRIPT" ] && bash "$STATUS_SCRIPT" claude-code idle 2>/dev/null

# Remove this conversation's session-marker (written by session-start-guard.sh).
# Deliberately NOT closing any session-guard.sh semaphore here: semaphores
# aren't attributed to a Claude Code session_id (only to agent name), so a
# hook-driven auto-close risks closing a DIFFERENT concurrent window's
# session — rejected in the same peer-session as unsafe without that
# attribution first (see report.md §2 тема 1). Semaphore close stays the
# agent's own Quick Close responsibility, unchanged.
INPUT="$(cat 2>/dev/null || true)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$SESSION_ID" ] && rm -f "$IWE_ROOT/.iwe-runtime/session-markers/claude-code-${SESSION_ID}.yaml" 2>/dev/null

echo '{}'
exit 0
