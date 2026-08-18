#!/bin/bash
# open-log-snapshot.sh — materializes session-guard.sh's runtime-only
# open-sessions log (OPEN_LOG_RUNTIME, .iwe-runtime/) as the local
# OPEN_LOG projection (inbox/open-sessions.log) consumed by existing readers.
#
# Runtime is the SSOT. OPEN_LOG is an ignored, replaceable cache: this script
# performs no git operation and never opens a session-guard semaphore.
#
# WP-484 (2026-08-18-02-wp484-witness-implementation, ArchGate + peer-session
# with Codex): OPEN_LOG was long assumed to be a git-tracked canonical log
# requiring append+commit -- it turned out `inbox/open-sessions.log` has been
# in .gitignore since 04.05.2026 (commit 01ff6fae3a), predating session-guard.sh
# itself by ~2.5 months. `git add` on it fails without `-f`; the commit/push
# steps this script used to run were already silently broken. This rewrite
# treats OPEN_LOG as what it actually is: a local materialized projection of
# the runtime SSOT, not an archive with its own history to preserve.
#
# Called from: close, cron, or manually. Not a blocker for `open`/`close` to
# succeed if this never runs — OPEN_LOG just lags OPEN_LOG_RUNTIME until the
# next snapshot (peer-session 2026-08-15-17-open-log-runtime-registry,
# Claude+Kimi consensus).
set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
OPEN_LOG="$IWE_ROOT/$GOV_REPO/inbox/open-sessions.log"
OPEN_LOG_RUNTIME="$IWE_ROOT/.iwe-runtime/open-sessions.log"
LOCK_DIR="$IWE_ROOT/.iwe-runtime/isolate-locks/_snapshotter-open-log-snapshot.lockdir"

[ -f "$OPEN_LOG_RUNTIME" ] || { echo "open-log-snapshot: $OPEN_LOG_RUNTIME отсутствует, нечего снапшоттить"; exit 0; }

# Same mkdir-is-atomic + PID-liveness pattern as with_isolate_lock() in
# session-guard.sh (not reused directly — that one is scoped by session_id,
# this needs a single fixed key covering ALL snapshot runs against the one
# projection).
#
# WP-484 code review (2026-08-18, Codex): the lock-release trap used to be
# installed before this process actually held the lock. A process still
# spinning in the wait loop below that got interrupted (signal, or the 30s
# timeout path) would run cleanup and `rm -rf "$LOCK_DIR"` -- deleting
# ANOTHER process's live lock, not its own. Only TMP_PROJECTION is safe to
# clean up unconditionally from the start (it is always this process's own
# temp file, never shared); the lock-release trap is installed only after
# `mkdir "$LOCK_DIR"` has actually succeeded for this process.
TMP_PROJECTION=""
cleanup_tmp() { rm -f "$TMP_PROJECTION"; }
trap cleanup_tmp EXIT INT TERM

mkdir -p "$(dirname "$LOCK_DIR")" "$(dirname "$OPEN_LOG")"
attempt=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  if [ -f "$LOCK_DIR/pid" ]; then
    held_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [[ "$held_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$held_pid" 2>/dev/null; then
      rm -rf "$LOCK_DIR"
      continue
    fi
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -gt 30 ] && { echo "open-log-snapshot: заблокирован другим параллельным снапшоттером >30с" >&2; exit 1; }
  sleep 1
done
echo $$ > "$LOCK_DIR/pid"
cleanup_lock_and_tmp() {
  rm -rf "$LOCK_DIR"
  rm -f "$TMP_PROJECTION"
}
trap cleanup_lock_and_tmp EXIT INT TERM

# OPEN_LOG is a complete materialized projection, not an archive. Build the
# replacement next to the target, so mv is one atomic rename. An `open`
# concurrent with cp may appear only in the next run, but can never be
# permanently omitted because every run rebuilds from the whole runtime SSOT.
TMP_PROJECTION=$(mktemp "${OPEN_LOG}.tmp.XXXXXX")
cp "$OPEN_LOG_RUNTIME" "$TMP_PROJECTION"
RECORDS=$(wc -l < "$TMP_PROJECTION" | tr -d ' ')
mv -f "$TMP_PROJECTION" "$OPEN_LOG"
TMP_PROJECTION=""

echo "open-log-snapshot: атомарно материализовано $RECORDS строк из runtime-журнала"
