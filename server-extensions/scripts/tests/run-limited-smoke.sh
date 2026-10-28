#!/usr/bin/env bash
# Regression for scripts/lib/run-limited.sh (WP-484 F257, review notes 1 and 4):
# a time limit that works on a host without GNU timeout and never signals the
# caller's own process group.
set -uo pipefail
# shellcheck disable=SC1090  # the library path is built from ROOT_DIR at run time

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LIB="$ROOT_DIR/scripts/lib/run-limited.sh"

FAILURES=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    FAILURES=$((FAILURES + 1))
  fi
}

# A PATH without timeout/gtimeout forces the fallback branch (stock macOS has neither).
FALLBACK_PATH="/usr/bin:/bin"
if PATH="$FALLBACK_PATH" command -v timeout >/dev/null 2>&1 || PATH="$FALLBACK_PATH" command -v gtimeout >/dev/null 2>&1; then
  echo "SKIP fallback checks: timeout exists in $FALLBACK_PATH on this host"
  HAVE_FALLBACK=0
else
  HAVE_FALLBACK=1
fi

run_in() {  # run_in <PATH> <secs> <cmd...> ; prints "rc=<n>"
  local path="$1" secs="$2"
  shift 2
  ( PATH="$path"; . "$LIB"; run_limited "$secs" "$@" </dev/null >/dev/null 2>&1; echo "rc=$?" )
}

# Primary branch: a stub `timeout` is preferred over the fallback.
STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/run-limited-stub.XXXXXX")
trap 'rm -rf "$STUB_DIR"' EXIT
printf '#!/bin/sh\necho stub-used >&2\nshift\nexec "$@"\n' >"$STUB_DIR/timeout"
chmod +x "$STUB_DIR/timeout"
OUT=$( ( PATH="$STUB_DIR:$FALLBACK_PATH"; . "$LIB"; run_limited 5 true </dev/null 2>&1 ) )
check "primary: stub timeout is used when present" "stub-used" "$OUT"

if [ "$HAVE_FALLBACK" = 1 ]; then
  check "fallback: exit code of a quick command is passed through" "rc=7" "$(run_in "$FALLBACK_PATH" 5 bash -c 'exit 7')"
  check "fallback: success is 0" "rc=0" "$(run_in "$FALLBACK_PATH" 5 true)"

  START=$(date +%s)
  RC=$(run_in "$FALLBACK_PATH" 1 sleep 30)
  ELAPSED=$(( $(date +%s) - START ))
  check "fallback: expired limit returns 124" "rc=124" "$RC"
  check "fallback: a 30 s command is cut well before 30 s" "yes" "$([ "$ELAPSED" -lt 10 ] && echo yes || echo no)"

  # Grandchildren must not outlive the limit.
  MARK="run-limited-grandchild-$$"
  run_in "$FALLBACK_PATH" 1 bash -c "exec -a $MARK sleep 40 & wait" >/dev/null
  sleep 3
  LEFT=$(pgrep -f "$MARK" | wc -l | tr -d ' ')
  pkill -f "$MARK" 2>/dev/null
  check "fallback: no grandchild left after the limit" "0" "$LEFT"

  # A caller under `set -e` is not ended by a command that succeeded.
  EXIT_SAFE=$( ( set -e; PATH="$FALLBACK_PATH"; . "$LIB"; run_limited 3 true </dev/null; echo after ) 2>/dev/null )
  check "fallback: set -e caller continues after a successful command" "after" "$EXIT_SAFE"
  # No orphaned sleep waits for the limit after a fast command.
  BEFORE=$(pgrep -f 'sleep 41' | wc -l | tr -d ' ')
  ( PATH="$FALLBACK_PATH"; . "$LIB"; run_limited 41 true </dev/null )
  sleep 1
  AFTER=$(pgrep -f 'sleep 41' | wc -l | tr -d ' ')
  check "fallback: no orphaned sleep after a fast command" "$BEFORE" "$AFTER"

  # The caller must survive: the same shell keeps running after the limit expired.
  SURVIVED=$( ( PATH="$FALLBACK_PATH"; . "$LIB"; run_limited 1 sleep 30 </dev/null >/dev/null 2>&1; echo alive ) )
  check "fallback: the caller is not signalled" "alive" "$SURVIVED"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: run-limited"
  exit 0
fi
echo "FAIL: $FAILURES check(s) failed"
exit 1
