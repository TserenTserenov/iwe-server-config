#!/bin/bash
# intent-gate-check.sh -- DP.SC.204 pre-action intent gate, WARN-ONLY rollout
# (pilot decision 13.10.2026, peer-session
# MC-sessions:2026-10/13/2026-10-13-07-wp561-f33-archgate-receiver, role
# DP.ROLE.102). Separate from wp-gate-check.sh (that one blocks a narrow
# set of Registry/context-file edits) and from DP.SC.201/DR-03's plan-hour
# admission machinery (contested-resource semantics, not this).
#
# Contract (Claude Code PreToolUse hook):
# - Stdin: JSON {"tool_name", "tool_input", "session_id", ...}
# - This hook NEVER blocks in warn-only mode: it always exits 0. It only
#   logs what WOULD have been blocked, so unseen automations (scheduled
#   jobs, background watchdogs -- scenario 4 of DP.SC.204) surface before
#   any hard block is turned on. Flip to blocking is a separate, explicit
#   pilot decision -- not a code change hidden in this file.
#
# Declaration source: scripts/declare-intent.sh writes
# .iwe-runtime/intent-declarations/<session_id>.json before a tool call.

set -uo pipefail
# M2 (Fable cold review, 13.10): /run/current-system/sw/bin first -- on
# NixOS (tsekh-1) that's where jq/date live, and a stripped-down environment
# (the unattended automations this gate exists to find) may not inherit a
# PATH that already has it.
export PATH="/run/current-system/sw/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ -n "$SESSION_ID" ] && [ -n "$TOOL_NAME" ] || exit 0

# C1 (Fable cold review, 13.10): declare-intent.sh itself runs as a Bash
# call and would otherwise be gated by the check it exists to satisfy --
# a dead end once this ever flips to blocking, and noise in warn-only.
if [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  case "$COMMAND" in
    *declare-intent.sh*) exit 0 ;;
  esac
fi

# M3 (Fable cold review): default without relying on HOME being set under
# `set -u` -- an unset HOME must not turn "always exit 0" into exit 1.
IWE_RUNTIME_DIR="${IWE_RUNTIME_DIR:-${HOME:-/nonexistent}/IWE/.iwe-runtime}"
DECL_FILE="$IWE_RUNTIME_DIR/intent-declarations/$SESSION_ID.json"
FRESHNESS_SECONDS=14400  # 4h -- a typical working session; pilot's call to retune (DP.SC.204)

reason=""
if [ ! -f "$DECL_FILE" ]; then
  reason="no intent declaration file"
else
  declared_at=$(jq -r '.declared_at // empty' "$DECL_FILE" 2>/dev/null)
  # H2 (Fable cold review): validate the format BEFORE computing age. GNU
  # `date -d ""` silently returns today 00:00 UTC (not an error) and BSD
  # `date -j -f` on an empty/malformed string fails -- the two platforms
  # disagreed on what an unreadable declaration means (always-stale on
  # macOS, a bypass window on Linux). A failed format check gets its own
  # reason instead of a computed age built on a value neither date flavor
  # agreed on.
  if [[ "$declared_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    declared_at_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$declared_at" +%s 2>/dev/null \
      || date -u -d "$declared_at" +%s 2>/dev/null)
    if [ -n "${declared_at_epoch:-}" ]; then
      age=$(( $(date -u +%s) - declared_at_epoch ))
      [ "$age" -gt "$FRESHNESS_SECONDS" ] && reason="declaration is ${age}s old (> ${FRESHNESS_SECONDS}s)"
    else
      reason="declaration unreadable (declared_at did not parse on this host)"
    fi
  else
    reason="declaration unreadable (declared_at missing or malformed)"
  fi
fi

[ -z "$reason" ] && exit 0  # fresh declaration found -- silent allow, no log noise

WARN_LOG="$IWE_RUNTIME_DIR/intent-gate-warnings.log"
mkdir -p "$(dirname "$WARN_LOG")" 2>/dev/null || true
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOG_ENTRY=$(jq -nc --arg ts "$TIMESTAMP" --arg sid "$SESSION_ID" --arg tool "$TOOL_NAME" --arg reason "$reason" \
  '{ts: $ts, gate: "intent-gate-check", session_id: $sid, tool_name: $tool, reason: $reason, mode: "warn-only", would_block: true}' 2>/dev/null)
[ -n "$LOG_ENTRY" ] && echo "$LOG_ENTRY" >> "$WARN_LOG" 2>/dev/null

exit 0
