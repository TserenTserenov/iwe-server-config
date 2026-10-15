#!/usr/bin/env bash
# wp-session-journal-gaps.sh — best-effort, read-only scan for peer-session
# folders of a given WP whose journal (report.md) is missing or still a
# draft (WP-484, peer-session 2026-10-15-33-wp484-session-handoff-gap).
# Never fails the caller: any error here is a missed hint, not a blocker.
set -u

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SCRIPTS_DIR="${IWE_SCRIPTS:-$IWE_ROOT/scripts}"
SESSIONS_DIR="${IWE_SESSIONS_ROOT:-$IWE_ROOT/MC-sessions}"
SEM_DIR="$IWE_ROOT/.iwe-runtime/sessions"
# No silent default to a specific governance repo (matches session-guard.sh's
# own `GOV_REPO="${IWE_GOVERNANCE_REPO:?...no silent default}"` principle) --
# a wrong guess here (e.g. DS-strategy on a host that actually uses
# DS-my-strategy) would make the secondary ledger source silently and
# permanently report "no gaps" instead of failing loudly. Unset -> skip the
# ledger source, keep the semaphore-based primary scan working.
if [ -n "${IWE_GOVERNANCE_REPO:-}" ]; then
  LEDGER_DIR="$IWE_ROOT/$IWE_GOVERNANCE_REPO/machine/ledger/day"
else
  LEDGER_DIR=""
fi

WP=""
EXCLUDE_SESSION_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --exclude-session-id) EXCLUDE_SESSION_ID="${2:-}"; shift 2 ;;
    WP-*) WP="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$WP" ] || exit 0

PY="$("$SCRIPTS_DIR/lib/find-python3.sh" --stdlib-only 2>/dev/null)" || exit 0

# No array for the optional flag -- an empty array under `set -u` raises
# "unbound variable" on bash 3.2 (stock macOS /bin/bash) when expanded, which
# would only ever bite a caller that omits --exclude-session-id under a
# minimal PATH (cron/launchd). Not reachable from session-guard.sh today, but
# cheap to avoid outright.
if [ -n "$EXCLUDE_SESSION_ID" ]; then
  "$PY" "$SCRIPTS_DIR/wp-session-journal-gaps.py" \
    --wp "$WP" --sessions-dir "$SESSIONS_DIR" --sem-dir "$SEM_DIR" --ledger-dir "$LEDGER_DIR" \
    --exclude-session-id "$EXCLUDE_SESSION_ID" 2>/dev/null
else
  "$PY" "$SCRIPTS_DIR/wp-session-journal-gaps.py" \
    --wp "$WP" --sessions-dir "$SESSIONS_DIR" --sem-dir "$SEM_DIR" --ledger-dir "$LEDGER_DIR" 2>/dev/null
fi
exit 0
