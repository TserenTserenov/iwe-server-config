#!/bin/bash
# test-dry-run-gate.sh — regression corpus for dry-run-gate.sh (WP-7 Ф109).
#
# Bug: the executed copy of this hook (252 lines) had drifted from the
# template's fix (656 lines) on two points — a 600s (10 min) sentinel TTL
# instead of 2400s (40 min), and TTL expiry treated as "rehearsal is over,
# allow" instead of fail-closed. A real day-close rehearsal runs ~26 minutes
# (issue #460), so the old 10-minute TTL silently dropped protection for
# EVERY session on the shared checkout partway through a legitimate
# rehearsal — not just the one that started it.
#
# Uses IWE_DRY_RUN_SENTINEL to point the hook at a scratch file instead of
# the shared /tmp/iwe-dry-run.flag, so this never touches the real sentinel
# other agent sessions on this machine may be relying on.
#
# Run: bash .claude/hooks/tests/test-dry-run-gate.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dry-run-gate.sh"
WORKDIR=$(mktemp -d)
SENTINEL="$WORKDIR/sentinel.flag"
PASS=0
FAIL=0

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

run_hook() { # $1 = tool_name -> exit code
  printf '{"tool_name":"%s","tool_input":{"file_path":"/tmp/x.md"}}' "$1" \
    | IWE_DRY_RUN_SENTINEL="$SENTINEL" bash "$HOOK" >/dev/null 2>"$WORKDIR/stderr"
  echo $?
}

expect_exit() { # $1 = описание, $2 = ожидаемый код выхода
  local desc="$1" expected="$2" actual
  actual=$(run_hook Write)
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидался код $expected, получен $actual): $(cat "$WORKDIR/stderr")"
  fi
}

# 1. No sentinel at all — allow.
rm -f "$SENTINEL"
expect_exit "no sentinel: allow" 0

# 2. Fresh sentinel — block (dry-run genuinely active).
echo '{"initiator":"test","created_at":"now"}' > "$SENTINEL"
expect_exit "fresh sentinel: block" 2

# 3. Sentinel just under TTL (39 minutes) — still block, rehearsal in progress.
touch -t "$(date -v-39M '+%Y%m%d%H%M')" "$SENTINEL" 2>/dev/null \
  || touch -d '39 minutes ago' "$SENTINEL"
expect_exit "sentinel at 39 minutes: still block" 2

# 4. THE BUG THIS PHASE FIXES: sentinel past TTL (41 minutes) must stay
#    fail-closed (block), not silently switch to allow the way the old
#    10-minute-TTL-then-allow logic did.
touch -t "$(date -v-41M '+%Y%m%d%H%M')" "$SENTINEL" 2>/dev/null \
  || touch -d '41 minutes ago' "$SENTINEL"
expect_exit "sentinel past TTL (41 min): fail-closed, not allow" 2

# 5. Fail-closed must not delete the sentinel — the old code's `rm -f` on
#    expiry is exactly what silently re-armed "allow" for every other
#    session on the shared checkout. It must still be there after the block.
if [ -f "$SENTINEL" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "FAIL: fail-closed branch deleted the sentinel — this re-enables silent allow"
fi

# 6. A real day-close rehearsal (~26 minutes, issue #460) must still be
#    protected under the new 40-minute TTL — this is the whole point of the
#    bump from 10 minutes.
touch -t "$(date -v-26M '+%Y%m%d%H%M')" "$SENTINEL" 2>/dev/null \
  || touch -d '26 minutes ago' "$SENTINEL"
expect_exit "26-minute rehearsal (issue #460 duration): still block" 2

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
