#!/usr/bin/env bash
# The close route switch (WP-561 Ф61 stage 2) is read in three places that must agree:
#   - scripts/session-guard.sh            _close_route_enforced  (close itself)
#   - .claude/hooks/lib/close-route-switch.sh close_route_enforced (commit gate, close reminder)
#   - DS-my-strategy scripts/close_obligation.py _close_route_enforced (Stop check)
# If one of them disagreed, a peer session could pass the hooks and then be refused
# by close (or the reverse), leaving its mark hanging. Every combination of the
# variable and the host flag file is asked of all three.
# close_obligation.py is taken from $CLOSE_OBLIGATION_PY, else from the governance
# repository next to this checkout; without it the Python copy is reported unchecked.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO/scripts/session-guard.sh"
HOOK_LIB="$REPO/.claude/hooks/lib/close-route-switch.sh"
PY="${CLOSE_OBLIGATION_PY:-${IWE_ROOT:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/scripts/close_obligation.py}"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }

FN="$TEST_ROOT/guard-fn.sh"
awk '/^_close_route_enforced\(\) \{/{a=1} a{print} a && $0 == "}"{exit}' "$GUARD" > "$FN"
grep -q '^_close_route_enforced() {' "$FN" || fail "fixture: _close_route_enforced not found in session-guard.sh"
# shellcheck source=/dev/null
. "$FN"
# shellcheck source=/dev/null
. "$HOOK_LIB"

PY_CHECKED=0
if [ -f "$PY" ] && grep -q '^def _close_route_enforced' "$PY"; then
  PY_CHECKED=1
fi

answer_guard() { IWE_ROOT="$TEST_ROOT" _close_route_enforced 2>/dev/null && echo on || echo off; }
answer_hook() { close_route_enforced "$TEST_ROOT" && echo on || echo off; }
answer_py() {
  IWE_ROOT="$TEST_ROOT" PYTHONDONTWRITEBYTECODE=1 python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("close_obligation", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print("on" if module._close_route_enforced() else "off")
' "$PY"
}

mkdir -p "$TEST_ROOT/.iwe-runtime"
for file in absent present; do
  if [ "$file" = present ]; then : > "$TEST_ROOT/.iwe-runtime/close-route-enforce"; else rm -f "$TEST_ROOT/.iwe-runtime/close-route-enforce"; fi
  for value in unset "" 1 0 yes; do
    if [ "$value" = unset ]; then unset IWE_CLOSE_ROUTE_ENFORCE; else export IWE_CLOSE_ROUTE_ENFORCE="$value"; fi
    case "$value:$file" in
      1:* | *:present) expected=on ;;
      *) expected=off ;;
    esac
    [ "$(answer_guard)" = "$expected" ] || fail "session-guard: value=[$value] file=$file, expected $expected"
    [ "$(answer_hook)" = "$expected" ] || fail "hook lib: value=[$value] file=$file, expected $expected"
    if [ "$PY_CHECKED" = 1 ]; then
      [ "$(answer_py)" = "$expected" ] || fail "close_obligation.py: value=[$value] file=$file, expected $expected"
    fi
    PASS=$((PASS+1))
  done
done
unset IWE_CLOSE_ROUTE_ENFORCE

if [ "$PY_CHECKED" = 1 ]; then
  echo "PASS=$PASS: close route switch agrees in session-guard, hooks and close_obligation.py"
else
  echo "PASS=$PASS: close route switch agrees in session-guard and hooks; close_obligation.py not checked (no _close_route_enforced in $PY)"
fi
