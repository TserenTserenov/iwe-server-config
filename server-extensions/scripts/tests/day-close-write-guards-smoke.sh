#!/usr/bin/env bash
# Smoke for РП-561 Ф32: write-path-day-close-guard.sh hook and archive-done-wp.sh --day-close.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../../.claude/hooks/write-path-day-close-guard.sh"
ARCHIVE="$HERE/../archive-done-wp.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAIL=0
check() { # name expected_rc actual_rc
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: expected rc=$2 got rc=$3"; FAIL=1; fi
}

mkdir -p "$T/root/DS-my-strategy/current" "$T/root/.iwe-runtime" "$T/copy/current"
ln -s "$T/root/DS-my-strategy/current" "$T/copy/link-to-canon"
VARS="$T/root/.iwe-runtime/day-close-interactive.vars"
call() { # session_id path
  printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2" | IWE_WORKSPACE="$T/root" bash "$HOOK" >/dev/null 2>&1
}

call own "$T/root/DS-my-strategy/current/x.md"; check "no state file: canon write allowed" 0 $?
printf 'export DAY_CLOSE_WORKTREE=%q DAY_CLOSE_BRANCH=b DAY_CLOSE_LOCK_TOKEN=t\nexport DAY_CLOSE_NATIVE_RUNTIME=claude-code DAY_CLOSE_NATIVE_SESSION_ID=own\n' "$T/copy" > "$VARS"
call own "$T/root/DS-my-strategy/current/x.md"; check "owner writes canon: blocked" 2 $?
call own "$T/copy/current/x.md"; check "owner writes copy: allowed" 0 $?
call own "$T/copy/link-to-canon/x.md"; check "owner writes via symlink to canon: blocked" 2 $?
call other "$T/root/DS-my-strategy/current/x.md"; check "other session writes canon: allowed" 0 $?
call own "$T/elsewhere.md"; check "owner writes outside both: allowed" 0 $?

(unset IWE_GOVERNANCE_REPO_PATH; bash "$ARCHIVE" --day-close 1 "$T/root" >/dev/null 2>&1); check "archive --day-close without copy path: refused" 1 $?
(IWE_GOVERNANCE_REPO=DS-my-strategy IWE_GOVERNANCE_REPO_PATH="$T/root/DS-my-strategy" bash "$ARCHIVE" --day-close 1 "$T/root" >/dev/null 2>&1); check "archive --day-close with canon path: refused" 1 $?
OUT=$(IWE_GOVERNANCE_REPO=DS-my-strategy IWE_GOVERNANCE_REPO_PATH="$T/copy" bash "$ARCHIVE" --day-close 1 "$T/root" 2>&1)
case "$OUT" in *"STOP: --day-close"*) echo "FAIL archive --day-close with copy path: wrongly refused"; FAIL=1 ;; *) echo "PASS archive --day-close with copy path: not refused by the guard" ;; esac
exit $FAIL
