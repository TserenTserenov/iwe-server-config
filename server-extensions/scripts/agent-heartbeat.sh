#!/usr/bin/env bash
#
# agent-heartbeat.sh
# Update a heartbeat timestamp in the active session semaphore.
# Agents must call this at least every 180 seconds during long operations
# to prove the session is not stuck.
#
# Usage: bash scripts/agent-heartbeat.sh [--agent kimi|claude-code|hermes]

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
SESSION_GUARD="$IWE_ROOT/scripts/session-guard.sh"
# Parse args
AGENT="${IWE_AGENT:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    -a)      AGENT="$2"; shift 2 ;;
    *)       shift ;;
  esac
done

if [ -z "$AGENT" ]; then
  # A pointer name is not caller identity.  Infer the agent only when exactly
  # one known pointer exists; precedence among several pointers would bind a
  # heartbeat to whichever `if` happened to come first.
  INFERRED_AGENT=""
  INFERRED_COUNT=0
  for candidate_agent in kimi claude-code hermes; do
    if [ -f "$SESSION_DIR/current-${candidate_agent}.ptr" ] \
      && [ ! -L "$SESSION_DIR/current-${candidate_agent}.ptr" ]; then
      INFERRED_AGENT="$candidate_agent"
      INFERRED_COUNT=$((INFERRED_COUNT + 1))
    fi
  done
  [ "$INFERRED_COUNT" -eq 1 ] || {
    echo "ERROR: --agent or IWE_AGENT required (active agent pointer is absent or ambiguous)" >&2
    exit 1
  }
  AGENT="$INFERRED_AGENT"
fi

PTR_FILE="$SESSION_DIR/current-${AGENT}.ptr"
if [ ! -f "$PTR_FILE" ] || [ -L "$PTR_FILE" ]; then
  echo "ERROR: no active $AGENT session pointer" >&2
  exit 1
fi

# The per-agent pointer is a projection, not a singleton authority.  Refuse
# to guess when more than one generation is still open, even if the pointer
# happens to name one of them.
ACTIVE_SEM=""
ACTIVE_COUNT=0
for candidate_sem in "$SESSION_DIR/${AGENT}-"*.open; do
  if [ ! -e "$candidate_sem" ] && [ ! -L "$candidate_sem" ]; then
    continue
  fi
  ACTIVE_SEM="$candidate_sem"
  ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
done
[ "$ACTIVE_COUNT" -eq 1 ] || {
  echo "ERROR: active $AGENT session is absent or ambiguous ($ACTIVE_COUNT matching .open files)" >&2
  exit 1
}

SEM_FILE="$(cat "$PTR_FILE")"
if [ "$SEM_FILE" != "$ACTIVE_SEM" ]; then
  echo "ERROR: active $AGENT pointer does not match the sole open session" >&2
  exit 1
fi
if [ ! -f "$SEM_FILE" ]; then
  echo "ERROR: session semaphore not found: $SEM_FILE" >&2
  exit 1
fi

case "$SEM_FILE" in
  "$SESSION_DIR/${AGENT}-"*.open) ;;
  *)
    echo "ERROR: active pointer is outside the exact $AGENT session namespace: $SEM_FILE" >&2
    exit 1
    ;;
esac
SESSION_ID="${SEM_FILE#"$SESSION_DIR/${AGENT}-"}"
SESSION_ID="${SESSION_ID%.open}"
if ! [[ "$SESSION_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]] \
  || [ "$SEM_FILE" != "$SESSION_DIR/${AGENT}-${SESSION_ID}.open" ]; then
  echo "ERROR: active pointer does not contain a safe exact session id" >&2
  exit 1
fi
[ -f "$SESSION_GUARD" ] || { echo "ERROR: session guard not found: $SESSION_GUARD" >&2; exit 1; }

# Never open the semaphore for writing here.  The guard resolves this exact
# session again, takes its persistent transition lock, refuses a closed/staged
# inode, and fsyncs the complete heartbeat record before reporting success.
bash "$SESSION_GUARD" heartbeat --agent "$AGENT" --session-id "$SESSION_ID" --owner-pid "$$" >/dev/null
