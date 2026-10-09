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
# other agent sessions on this machine may be relying on. The hook's own
# anti-ambient guard (dry_dir_ensure(), ~line 38) only honors this override
# when IWE_DRY_RUN_DIR also points at a directory carrying a
# .iwe-dry-run-test-mode marker — without it, the override is silently
# discarded and the hook falls back to the real production paths. Found
# live 09.10.2026 (peer-session with Kimi+Codex): this test passed only
# IWE_DRY_RUN_SENTINEL, so every "block" expectation below was quietly
# checked against production state instead of the scratch sentinel.
#
# Run: bash .claude/hooks/tests/test-dry-run-gate.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dry-run-gate.sh"
WORKDIR=$(mktemp -d)
SENTINEL="$WORKDIR/sentinel.flag"
DRY_DIR="$WORKDIR/dry-dir"
PASS=0
FAIL=0

mkdir -p "$DRY_DIR"
chmod 0700 "$DRY_DIR" 2>/dev/null || true
touch "$DRY_DIR/.iwe-dry-run-test-mode"
chmod 0600 "$DRY_DIR/.iwe-dry-run-test-mode" 2>/dev/null || true

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

run_hook() { # $1 = tool_name -> exit code
  printf '{"tool_name":"%s","tool_input":{"file_path":"/tmp/x.md"}}' "$1" \
    | IWE_DRY_RUN_SENTINEL="$SENTINEL" IWE_DRY_RUN_DIR="$DRY_DIR" bash "$HOOK" >/dev/null 2>"$WORKDIR/stderr"
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

# 7. Isolation check (Kimi, cold review 09.10.2026): the whole point of
#    IWE_DRY_RUN_SENTINEL/IWE_DRY_RUN_DIR is to keep this test off the real
#    production paths. If the anti-ambient guard ever regresses again, this
#    is what would catch it — not the FAIL count above, which would still
#    read as "passing" if the hook happened to agree with production state
#    by coincidence.
if [ -e /tmp/iwe-dry-run.flag ] || [ -e "/tmp/iwe-dry-run-$(id -u)" ]; then
  FAIL=$((FAIL+1))
  echo "FAIL: production dry-run paths exist after this test run — isolation broke, verify by hand before trusting PASS above"
else
  PASS=$((PASS+1))
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
