#!/usr/bin/env bash
#
# kimi-standalone-preflight.sh
# Hard gate для Kimi standalone-сессий.
# Проверяет, что сессия открыта через session-guard.sh и не устарела.
#
# Usage: bash scripts/kimi-standalone-preflight.sh

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
STALE_THRESHOLD="${IWE_SESSION_STALE_THRESHOLD:-1800}"  # 30 min

SEM_FILE=$(ls -t "$SESSION_DIR/kimi"-*.open 2>/dev/null | head -1 || true)

if [ -z "$SEM_FILE" ]; then
  echo "ERROR: Kimi standalone session is NOT OPEN." >&2
  echo "Run first:" >&2
  echo "  bash ~/IWE/scripts/session-guard.sh open --wp WP-N --task \"...\" --agent kimi" >&2
  exit 1
fi

SEM_AGE=0
if command -v stat >/dev/null 2>&1; then
  if stat -f %m "$SEM_FILE" >/dev/null 2>&1; then
    # macOS
    SEM_MTIME=$(stat -f %m "$SEM_FILE")
  else
    # Linux
    SEM_MTIME=$(stat -c %Y "$SEM_FILE")
  fi
  SEM_AGE=$(($(date +%s) - SEM_MTIME))
fi

if [ "$SEM_AGE" -gt "$STALE_THRESHOLD" ]; then
  echo "WARNING: active session $(basename "$SEM_FILE") is stale (${SEM_AGE}s)." >&2
  echo "Consider closing and reopening the session." >&2
fi

# WP-484 Ф72: standalone Kimi has no pilot-witness hook, so quick-close needs a
# trust anchor. Write a session-scoped marker now (launcher context, not agent
# context) so session-reflection-append.sh can fail-open safely.
SESSION_ID=$(grep '^session_id: ' "$SEM_FILE" | cut -d' ' -f2- || true)
if [ -n "$SESSION_ID" ]; then
  mkdir -p "$IWE_ROOT/.iwe-runtime"
  : > "$IWE_ROOT/.iwe-runtime/kimi-standalone-${SESSION_ID}.marker"
  echo "MARKER: $IWE_ROOT/.iwe-runtime/kimi-standalone-${SESSION_ID}.marker"
fi

echo "OK: $(basename "$SEM_FILE") (age: ${SEM_AGE}s)"
