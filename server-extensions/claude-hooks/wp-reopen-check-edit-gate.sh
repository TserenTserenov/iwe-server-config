#!/usr/bin/env bash
# wp-reopen-check-edit-gate.sh — PreToolUse hook (Edit|Write|MultiEdit): calls
# wp-reopen-gate.sh check-edit at the actual write boundary of a WP card file.
#
# Closes WP-530 Ф66's named gap ("Требование Б"): the mandatory-reopen-
# actualization gate (protocol-open.md §3.5) exists and is tested
# (wp-reopen-gate-smoke.sh), but nothing calls `check-edit` before a real
# edit lands -- the card is protected only by whoever remembers to run it by
# hand. Found live: this same gate's own peer-session edited WP-530.md
# earlier today without calling check-edit, because nothing required it.
#
# Complements write-path-lease-guard.sh (Local Gateway lock -- "who holds the
# pen right now", concurrency) with a different axis: "is this agent's
# knowledge of the card's content still the one it actualized against"
# (staleness/reopen). Both can block independently; neither replaces the
# other. Scoped to exactly WP-N.md (the file the lease digest is bound to),
# not every file under inbox/WP-N/ -- same scope wp-reopen-gate.sh itself uses.
#
# Mode (graduation pattern copied from write-path-manifest.yaml's
# enforce/telemetry split, same risk class): default telemetry -- warn on
# stderr, still allow -- because as of 2026-10-16 most existing leases on
# this host are already past their 8h TTL (checked: `.iwe-runtime/wp-reopen-leases/
# *.json`; only a handful, from active concurrent sessions, are fresh), so
# flipping straight to enforce would likely block the next edit of most
# currently open WP cards across concurrent sessions, not just new ones.
# Promote to enforce the same way the sibling class does: after a measured
# period with few telemetry warnings, or after the pilot reviews them --
# not by calendar. Mode source: $WP_REOPEN_CHECK_EDIT_MODE env var, else the
# marker file next to this hook (plain text "enforce" or "telemetry"), else
# telemetry.
#
# Debounce: `check-edit` does a network `git fetch` on every call (the
# underlying wp-reopen-gate.sh's own design, not this hook's) -- without a
# cache, a session that edits the same card 10-20 times (an ordinary work
# pattern) would do 10-20 redundant fetches. Same problem pull-on-touch.sh
# already solves for its own git pull, same fix: a short-TTL per-(session,
# WP) marker file records the last successful check; a repeat within
# CACHE_TTL_SECONDS skips the network round-trip. Only successes are
# cached -- a failure must always re-check next time (e.g. right after the
# pilot actualizes), never wait out a stale cached block.
#
# Contract: stdin JSON {tool_name, tool_input, session_id}. Exit 0 = allow,
# exit 2 = block (stderr = reason).

set -uo pipefail

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("tool_name",""))' 2>/dev/null)
case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
d = json.load(sys.stdin)
ti = d.get("tool_input", {})
print(ti.get("file_path") or "")
' 2>/dev/null)
[ -n "$FILE_PATH" ] || exit 0

# Same preference order as every other PreToolUse hook in this repo (e.g.
# close-gate-reminder.sh, protocol-stop-gate.sh): the harness's JSON payload
# first, $CLAUDE_CODE_SESSION_ID only as a fallback -- not the other way
# round, in case a future caller's payload session_id and its own env var
# ever diverge (e.g. a sandboxed subprocess without env propagation).
SESSION_ID=$(printf '%s' "$INPUT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("session_id","") or "")' 2>/dev/null)
[ -n "$SESSION_ID" ] || SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"

# A not-yet-existing file (first creation, e.g. create-wp.sh scaffolding a
# brand-new card) has nothing to actualize against -- only a REOPEN of an
# existing card is this gate's concern.
[ -f "$FILE_PATH" ] || exit 0

WP=$(python3 -c '
import re, sys
m = re.search(r"/(?:inbox|archive/wp-contexts)/WP-([0-9]+)/WP-\1\.md$", sys.argv[1])
print(m.group(1) if m else "")
' "$FILE_PATH" 2>/dev/null)
[ -n "$WP" ] || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${WP_REOPEN_CHECK_EDIT_MODE:-}"
if [ -z "$MODE" ] && [ -f "$HOOK_DIR/wp-reopen-check-edit-mode" ]; then
  MODE="$(tr -d ' \t\n\r' < "$HOOK_DIR/wp-reopen-check-edit-mode")"
fi
MODE="${MODE:-telemetry}"

# fail_or_warn MSG -- the one place that decides enforce-vs-telemetry once a
# problem is confirmed. Every exit path below the card-identification point
# (WP is already known) goes through this, so none can fall through to a
# silent allow by accident (the bug the cold review found: REPO_ROOT
# resolution failing used to `exit 0` with no message at all, in BOTH modes).
fail_or_warn() {
  local msg="$1"
  if [ "$MODE" = "enforce" ]; then
    echo "wp-reopen-check-edit-gate: $msg -- блокирую (fail-closed)." >&2
    exit 2
  fi
  echo "wp-reopen-check-edit-gate (telemetry, не блокирует): $msg." >&2
  exit 0
}

REPO_ROOT=$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null)
[ -n "$REPO_ROOT" ] || fail_or_warn "не удалось определить git-репозиторий для карточки РП-$WP"

# An explicit override is trusted as given -- no fallback to the production
# path underneath it, or a bad override (e.g. a test pointing at a
# nonexistent binary on purpose) would silently resolve to the real gate
# instead of surfacing "not found" (found while adding tests 8/9 below).
if [ -n "${WP_REOPEN_GATE_BIN:-}" ]; then
  GATE="$WP_REOPEN_GATE_BIN"
else
  GATE="$HOME/IWE/scripts/wp-reopen-gate.sh"
  [ -x "$GATE" ] || GATE="$HOME/IWE/iwe-local-config/scripts/wp-reopen-gate.sh"
fi
[ -x "$GATE" ] || fail_or_warn "wp-reopen-gate.sh не найден, правка карточки РП-$WP не проверена"

# Debounce (High finding, cold review): skip the network check-edit call if
# the SAME session already passed it for the SAME card within CACHE_TTL_SECONDS.
# Only a pass is ever cached -- see header comment for why a failure must not be.
CACHE_TTL_SECONDS=60
CACHE_DIR="${WP_REOPEN_CHECK_EDIT_CACHE_DIR:-$HOME/.claude/state/wp-reopen-check-edit-ok}"
CACHE_FILE="$CACHE_DIR/${SESSION_ID:-nosession}__WP-${WP}"
NOW=$(date +%s)
if [ -f "$CACHE_FILE" ]; then
  LAST_OK=$(cat "$CACHE_FILE" 2>/dev/null) || LAST_OK=0
  case "$LAST_OK" in ''|*[!0-9]*) LAST_OK=0 ;; esac
  [ $((NOW - LAST_OK)) -lt "$CACHE_TTL_SECONDS" ] && exit 0
fi

GATE_ARGS=(check-edit --wp "$WP" --governance-repo "$REPO_ROOT")
[ -n "$SESSION_ID" ] && GATE_ARGS+=(--session-id "$SESSION_ID")
OUT=$(bash "$GATE" "${GATE_ARGS[@]}" 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then
  mkdir -p "$CACHE_DIR" 2>/dev/null && echo "$NOW" > "$CACHE_FILE" 2>/dev/null
  exit 0
fi

if [ "$MODE" = "enforce" ]; then
  echo "wp-reopen-check-edit-gate: правка карточки РП-$WP заблокирована." >&2
  echo "$OUT" >&2
  exit 2
fi

echo "wp-reopen-check-edit-gate (telemetry, не блокирует): карточка РП-$WP не актуализирована по wp-reopen-gate.sh:" >&2
echo "$OUT" >&2
exit 0
