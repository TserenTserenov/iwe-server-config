#!/usr/bin/env bash
#
# kimi-standalone-preflight.sh
# Hard gate для Kimi standalone-сессий.
# Проверяет, что сессия открыта через session-guard.sh и не устарела.
#
# Usage: bash scripts/kimi-standalone-preflight.sh [--wp WP-N] [--slug S] [--session-id ID]
#
# With at least one filter the semaphore must match ALL given filters and be
# the only match; zero or several matches fail closed. Without filters the
# legacy "newest kimi-*.open" pick is kept for old callers, but it can adopt
# another conversation's semaphore (WP-561 incident 26.10: a peer pipeline for
# WP-568/538 wrote into the WP-561 isolate this way), so it warns on stderr.

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
STALE_THRESHOLD="${IWE_SESSION_STALE_THRESHOLD:-1800}"  # 30 min

WANT_WP=""; WANT_SLUG=""; WANT_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --wp|--slug|--session-id)
      # An empty value (e.g. an unset PEER_WP) must not fall back to the unscoped newest-semaphore pick.
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "ERROR: $1 needs a non-empty value" >&2; exit 1; }
      case "$1" in --wp) WANT_WP="$2" ;; --slug) WANT_SLUG="$2" ;; *) WANT_ID="$2" ;; esac
      shift 2 ;;
    *) echo "ERROR: unknown argument: $1 (known: --wp, --slug, --session-id)" >&2; exit 1 ;;
  esac
done

SEM_FILE=""
if [ -z "$WANT_WP$WANT_SLUG$WANT_ID" ]; then
  SEM_FILE=$(ls -t "$SESSION_DIR/kimi"-*.open 2>/dev/null | head -1 || true)
  if [ -n "$SEM_FILE" ]; then
    echo "WARNING: preflight called without --wp/--slug/--session-id: took the newest Kimi semaphore ($(basename "$SEM_FILE")), which may belong to another conversation." >&2
  fi
else
  MATCHES=()
  for cand in "$SESSION_DIR"/kimi-*.open; do
    [ -f "$cand" ] || continue
    [ -z "$WANT_WP" ]   || grep -qxF "wp: $WANT_WP" "$cand"           || continue
    [ -z "$WANT_SLUG" ] || grep -qxF "slug: $WANT_SLUG" "$cand"       || continue
    [ -z "$WANT_ID" ]   || grep -qxF "session_id: $WANT_ID" "$cand"   || continue
    MATCHES+=("$cand")
  done
  if [ "${#MATCHES[@]}" -gt 1 ]; then
    echo "ERROR: ${#MATCHES[@]} Kimi semaphores match (wp='$WANT_WP' slug='$WANT_SLUG' id='$WANT_ID'); refusing to guess:" >&2
    printf '  %s\n' "${MATCHES[@]##*/}" >&2
    exit 1
  fi
  if [ "${#MATCHES[@]}" -eq 1 ]; then
    SEM_FILE="${MATCHES[0]}"
  fi
fi

if [ -z "$SEM_FILE" ]; then
  echo "ERROR: Kimi standalone session is NOT OPEN${WANT_WP:+ for $WANT_WP}${WANT_SLUG:+ (slug $WANT_SLUG)}${WANT_ID:+ (id $WANT_ID)}." >&2
  echo "Another conversation's semaphore does not count: open your own first:" >&2
  echo "  bash ~/IWE/scripts/session-guard.sh open --wp ${WANT_WP:-WP-N} --task \"...\" --agent kimi --isolate" >&2
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
