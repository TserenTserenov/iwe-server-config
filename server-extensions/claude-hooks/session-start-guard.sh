#!/usr/bin/env bash
# SessionStart — write a lightweight session-marker (WP-484 Ф33/Нить1) and,
# best-effort, resolve this host's personality_id from the AI Personalities
# Registry (WP-510 Ф21 — closes the Ф20-diagnosed delivery gap; peer session
# 2026-08-05-35-wp510-f21-personality-delivery, consensus with Kimi+Codex).
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
# telemetry log below instead of failing silently. The personality lookup
# added here (Ф21) is additive and independently fail-open — its failure
# never blocks the marker write, and vice versa.
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

# --- Ф21: personality_id resolution (best-effort, additive, fail-open) ----
RESOLVER="$IWE_DS_MY_STRATEGY/scripts/resolve-personality-by-host.py"
REGISTRY="$IWE_DS_MY_STRATEGY/current/AI Personalities Registry.md"
PERSONALITY_RESOLUTION="skipped"
ADDITIONAL_CONTEXT=""

if command -v python3 >/dev/null 2>&1 && [ -f "$RESOLVER" ] && [ -f "$REGISTRY" ]; then
  RESOLVE_JSON="$(python3 "$RESOLVER" --registry "$REGISTRY" --hostname "$(hostname)" 2>/dev/null)"
  RESOLVE_EXIT=$?
  if [ "$RESOLVE_EXIT" -eq 0 ] && [ -n "$RESOLVE_JSON" ]; then
    RESOLVE_STATUS="$(printf '%s' "$RESOLVE_JSON" | jq -r '.status // empty' 2>/dev/null || true)"
    PERSONALITY_RESOLUTION="${RESOLVE_STATUS:-error}"
    if [ "$RESOLVE_STATUS" = "matched" ]; then
      PID="$(printf '%s' "$RESOLVE_JSON" | jq -r '.personality_id // empty' 2>/dev/null || true)"
      REL="$(printf '%s' "$RESOLVE_JSON" | jq -r '.relation // empty' 2>/dev/null || true)"
      if [ -n "$PID" ] && [ -n "$REL" ]; then
        ADDITIONAL_CONTEXT="Runtime personality binding for this host: personality_id=${PID}, relation=${REL}. This is a routing label only: not a passport, not an authority grant, not permission to attribute commits (no Co-Authored-By or similar) on behalf of this personality, and not a re-activation decision. Full passport only via explicit request through the standard collector."
      fi
    fi
  else
    PERSONALITY_RESOLUTION="error"
  fi
fi
# ---------------------------------------------------------------------------

MARKER_FILE="$MARKER_DIR/claude-code-${SESSION_ID}.yaml"
MARKER_TMP="$(mktemp "${MARKER_DIR}/.claude-code-${SESSION_ID}.XXXXXX" 2>/dev/null || true)"
if [ -n "$MARKER_TMP" ]; then
  MARKER_WRITE_OK=1
  {
    echo "agent: claude-code"
    echo "session_id: $SESSION_ID"
    echo "opened_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "hook_pid: $$"
    echo "personality_resolution: $PERSONALITY_RESOLUTION"
  } > "$MARKER_TMP" 2>/dev/null || MARKER_WRITE_OK=0
  if [ "$MARKER_WRITE_OK" -eq 1 ]; then
    mv "$MARKER_TMP" "$MARKER_FILE" 2>/dev/null || MARKER_WRITE_OK=0
  fi
  [ "$MARKER_WRITE_OK" -eq 1 ] || note_failure "write $MARKER_FILE failed"
else
  note_failure "mktemp for marker file failed"
fi

if [ -n "$ADDITIONAL_CONTEXT" ]; then
  python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": sys.argv[1]}}))' "$ADDITIONAL_CONTEXT" 2>/dev/null || echo '{}'
else
  echo '{}'
fi
exit 0
