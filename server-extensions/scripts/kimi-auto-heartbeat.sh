#!/usr/bin/env bash
#
# kimi-auto-heartbeat.sh
# Запускает фоновый heartbeat для активной Kimi standalone-сессии.
# Должен вызываться сразу после session-guard.sh open.
#
# Usage: bash scripts/kimi-auto-heartbeat.sh [--interval 120]

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
SESSION_GUARD="$IWE_ROOT/scripts/session-guard.sh"
INTERVAL="${IWE_HEARTBEAT_INTERVAL:-120}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    -i)         INTERVAL="$2"; shift 2 ;;
    *)          shift ;;
  esac
done

# A per-agent pointer is only a projection.  SessionStart does not know the
# guard UUID, so the only safe implicit binding is exactly one matching open
# semaphore.  Never pick the newest file when two generations overlap.
SEM_FILE=""
ACTIVE_COUNT=0
for candidate_sem in "$SESSION_DIR/kimi-"*.open; do
  if [ ! -e "$candidate_sem" ] && [ ! -L "$candidate_sem" ]; then
    continue
  fi
  SEM_FILE="$candidate_sem"
  ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
done
if [ "$ACTIVE_COUNT" -ne 1 ] || [ ! -f "$SEM_FILE" ]; then
  echo "ERROR: active kimi session is absent or ambiguous ($ACTIVE_COUNT matching .open files)" >&2
  echo "Run session-guard.sh open first." >&2
  exit 1
fi
if [ -e "$SESSION_DIR/current-kimi.ptr" ] || [ -L "$SESSION_DIR/current-kimi.ptr" ]; then
  if [ ! -f "$SESSION_DIR/current-kimi.ptr" ] || [ -L "$SESSION_DIR/current-kimi.ptr" ]; then
    echo "ERROR: current-kimi.ptr is not an owned regular projection" >&2
    exit 1
  fi
  CURRENT_SEM_FILE="$(cat "$SESSION_DIR/current-kimi.ptr")"
  if [ "$CURRENT_SEM_FILE" != "$SEM_FILE" ]; then
    echo "ERROR: current-kimi.ptr does not match the sole open session" >&2
    exit 1
  fi
fi
case "$SEM_FILE" in
  "$SESSION_DIR/kimi-"*.open) ;;
  *)
    echo "ERROR: active pointer is outside the exact kimi session namespace: $SEM_FILE" >&2
    exit 1
    ;;
esac
SESSION_ID="${SEM_FILE#"$SESSION_DIR/kimi-"}"
SESSION_ID="${SESSION_ID%.open}"
if ! [[ "$SESSION_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$ ]] \
  || [ "$SEM_FILE" != "$SESSION_DIR/kimi-${SESSION_ID}.open" ]; then
  echo "ERROR: active pointer does not contain a safe exact session id" >&2
  exit 1
fi
[ -f "$SESSION_GUARD" ] || { echo "ERROR: session guard not found: $SESSION_GUARD" >&2; exit 1; }

PID_FILE="$SESSION_DIR/kimi-heartbeat.pid"
HEARTBEAT_LOG="$IWE_ROOT/.iwe-runtime/logs/kimi-heartbeat.log"

echo "Starting auto-heartbeat for $(basename "$SEM_FILE") every ${INTERVAL}s"
echo "heartbeat_started_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$HEARTBEAT_LOG"
echo "heartbeat_sem_file: $SEM_FILE" >> "$HEARTBEAT_LOG"

# Store PID
echo $$ > "$PID_FILE"

heartbeat_loop() {
  while true; do
    if [ ! -f "$SEM_FILE" ]; then
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | semaphore gone, stopping heartbeat" >> "$HEARTBEAT_LOG"
      break
    fi
    # Guard: if current-kimi.ptr points to a different semaphore, a new session
    # has taken over. Stop this heartbeat to avoid leaving the old semaphore stale.
    if [ -f "$SESSION_DIR/current-kimi.ptr" ]; then
      local current_ptr
      current_ptr="$(cat "$SESSION_DIR/current-kimi.ptr")"
      if [ "$current_ptr" != "$SEM_FILE" ]; then
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | current-kimi.ptr switched to $current_ptr, stopping heartbeat for $SEM_FILE" >> "$HEARTBEAT_LOG"
        break
      fi
    fi
    # Bind every mutation to the original session id.  The guard serializes
    # against close and refuses to create a missing `.open`, so a close between
    # the pointer check above and this call stops the loop without resurrecting
    # a malformed semaphore.
    if ! bash "$SESSION_GUARD" heartbeat --agent kimi --session-id "$SESSION_ID" --owner-pid "$$" >/dev/null 2>&1; then
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | heartbeat rejected, session closing or identity changed" >> "$HEARTBEAT_LOG"
      break
    fi
    sleep "$INTERVAL"
  done
}

heartbeat_loop
rm -f "$PID_FILE"
echo "heartbeat_stopped_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$HEARTBEAT_LOG"
