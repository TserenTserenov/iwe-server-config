#!/bin/bash
# open-log-snapshot.sh — folds session-guard.sh's runtime-only open-sessions
# log (OPEN_LOG_RUNTIME, .iwe-runtime/) into the git-tracked canonical log
# (OPEN_LOG, inbox/open-sessions.log) that existing readers already consume.
#
# WHY separate from `session-guard.sh open`: append-then-commit inside the
# hot `open` path would make every session open depend on git state and
# violate the WP-520 freeze on direct canonical-checkout writes. This script
# is the control-plane counterpart — background, not agent-hot-path — and
# goes through the same --canonical-owner carve-out the launchd schedulers
# already use (WP-520 freeze-enforce, 14.08).
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
SESSION_GUARD="${IWE_SCRIPTS:-$IWE_ROOT/scripts}/session-guard.sh"

[ -f "$OPEN_LOG_RUNTIME" ] || { echo "open-log-snapshot: $OPEN_LOG_RUNTIME отсутствует, нечего снапшоттить"; exit 0; }

# Same mkdir-is-atomic + PID-liveness pattern as with_isolate_lock() in
# session-guard.sh (not reused directly — that one is scoped by session_id,
# this needs a single fixed key covering ALL snapshot runs against the one
# canonical OPEN_LOG). `trap ... EXIT` (not just INT/TERM) so a `set -e`
# abort from a failed `git commit`/`git push` releases the lock too —
# EXIT is the only trap bash fires on that path (cold-context review,
# same peer-session: INT/TERM alone left the lock held after a commit
# failure, with no TTL fallback to self-heal it).
TMP_RUNTIME_SNAPSHOT=""
cleanup() { rm -rf "$LOCK_DIR"; rm -f "$TMP_RUNTIME_SNAPSHOT"; }
trap cleanup EXIT INT TERM

mkdir -p "$(dirname "$LOCK_DIR")"
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

# Append-only: take only the lines OPEN_LOG_RUNTIME has beyond what OPEN_LOG
# already carries from the last snapshot. OPEN_LOG_RUNTIME grows monotonically
# via append (session-guard.sh open never truncates it), so its first N lines
# are always a prefix of OPEN_LOG's own history once a snapshot has run —
# tail by line-count difference, not a full overwrite (Kimi caught the
# overwrite/race bug in the first draft, peer-session 2026-08-15-17, turn 5).
#
# Snapshot to a temp copy BEFORE counting: a concurrent `open` can append a
# new line to OPEN_LOG_RUNTIME between `wc -l` and `tail -n N` if both read
# the live file directly, silently dropping one queued log line forever
# (cold-context review, same peer-session — not caught in the turn-loop
# consensus). `cp` is a single syscall-level read at one instant; counting
# and tailing the copy instead of the live file removes that window.
mkdir -p "$(dirname "$OPEN_LOG")"
touch "$OPEN_LOG"
TMP_RUNTIME_SNAPSHOT=$(mktemp)
cp "$OPEN_LOG_RUNTIME" "$TMP_RUNTIME_SNAPSHOT"
canonical_lines=$(wc -l < "$OPEN_LOG" | tr -d ' ')
runtime_lines=$(wc -l < "$TMP_RUNTIME_SNAPSHOT" | tr -d ' ')

if [ "$runtime_lines" -le "$canonical_lines" ]; then
  echo "open-log-snapshot: нечего переносить ($runtime_lines в runtime, $canonical_lines уже в canonical)"
  exit 0
fi

NEW_LINES=$((runtime_lines - canonical_lines))
tail -n "$NEW_LINES" "$TMP_RUNTIME_SNAPSHOT" >> "$OPEN_LOG"

cd "$IWE_ROOT/$GOV_REPO"

# SNAPSHOT_AGENT is fixed, NOT taken from an inherited $IWE_AGENT -- this
# process's own semaphore must be uniquely selectable by --agent alone even
# when several unrelated sessions from OTHER agents named "claude-code" (or
# whatever the caller's environment happens to export) are open at the same
# time. Reusing the caller's IWE_AGENT here made this script indistinguishable
# from those other sessions to select_semaphore() (live-caught: smoke test
# with 4 concurrent claude-code --isolate opens made `close` refuse with
# "несколько открытых семафоров", cold-context review didn't have live agents
# to catch this against).
# --housekeeping (not --wp): a one-off maintenance operation with no ORZ
# scaffold of its own to commit — --wp "housekeeping" (first draft) created
# a real ORZ file that `close` then refused to release because nothing
# git-added it (live-caught: same smoke test, close failed validation on
# the snapshotter's own scaffold file after the agent-scoping fix above).
SNAPSHOT_AGENT="open-log-snapshot"
IWE_AGENT="$SNAPSHOT_AGENT" bash "$SESSION_GUARD" open \
  --housekeeping "open-log-snapshot" --agent "$SNAPSHOT_AGENT" \
  --canonical-owner "open-log-snapshot" >&2 || {
    echo "open-log-snapshot: session-guard open --canonical-owner отказал — не коммичу без легитимного протокольного пропуска" >&2
    exit 1
  }

git add inbox/open-sessions.log
git commit -q -m "chore(open-log): снапшот $NEW_LINES строк из runtime-журнала"
git push -q

bash "$SESSION_GUARD" close --agent "$SNAPSHOT_AGENT" --housekeeping "open-log-snapshot" >&2 || \
  echo "open-log-snapshot: session-guard close не прошёл — семафор housekeeping останется до auto-orphan" >&2

echo "open-log-snapshot: $NEW_LINES строк перенесено и запушено"
