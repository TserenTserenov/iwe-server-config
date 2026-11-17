#!/usr/bin/env bash
# Regression (release 0.42, issue #1506, ported to the author's IWE in WP-529 F274
# step 8): `close --housekeeping <reason> --only-own-harness` closes the marker only
# when this conversation opened it (harness_session_id equals CLAUDE_CODE_SESSION_ID);
# another conversation's marker, or no conversation id, is refused with code 3 and
# the marker stays open. The flag is refused outside close --housekeeping.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-hk-own-harness.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
trap 'rm -rf "$TEST_ROOT"' EXIT

GOV="$TEST_ROOT/DS-strategy"
SESSION_DIR="$TEST_ROOT/.iwe-runtime/sessions"
mkdir -p "$GOV/sessions" "$SESSION_DIR" "$TEST_ROOT/bin"
git -C "$GOV" init -q
export IWE_SESSIONS_ROOT="$GOV/sessions" IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/bin/iwe-tg"
chmod +x "$TEST_ROOT/bin/iwe-tg"

SEM="$SESSION_DIR/claude-code-housekeeping-hk-own.open"
fail() { echo "FAIL: $*" >&2; exit 1; }
guard() { # <conversation id or empty> <args...>
  local conv="$1"; shift
  ( cd "$GOV" && CLAUDE_CODE_SESSION_ID="$conv" PATH="$TEST_ROOT/bin:$PATH" bash "$GUARD" "$@" ) 2>&1
}

OUT=$(guard conv-a open --housekeeping hk-own --agent claude-code --canonical-owner hk-own --owner-pid $$) \
  || fail "open must succeed, got: $OUT"
grep -qxF "harness_session_id: conv-a" "$SEM" || fail "open did not record the conversation id"

# 1. Another conversation: refused with code 3, marker untouched.
set +e; OUT=$(guard conv-b close --housekeeping hk-own --agent claude-code --only-own-harness); RC=$?; set -e
[ "$RC" = 3 ] || fail "foreign conversation must exit 3, got $RC: $OUT"
[ -f "$SEM" ] || fail "foreign conversation must leave the marker open"

# 2. No conversation id: not provably ours, refused with code 3.
set +e; OUT=$(guard "" close --housekeeping hk-own --agent claude-code --only-own-harness); RC=$?; set -e
[ "$RC" = 3 ] || fail "missing conversation id must exit 3, got $RC: $OUT"
[ -f "$SEM" ] || fail "missing conversation id must leave the marker open"

# 3. The flag outside close --housekeeping is refused, not ignored.
set +e; OUT=$(guard conv-a renew --wp WP-1 --only-own-harness); RC=$?; set -e
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q -- "--only-own-harness применяется только" \
  || fail "flag outside close --housekeeping must be refused, got $RC: $OUT"

# 4. The opening conversation closes it.
OUT=$(guard conv-a close --housekeeping hk-own --agent claude-code --only-own-harness) \
  || fail "own conversation must close, got: $OUT"
[ ! -e "$SEM" ] && [ -f "$SEM.closed" ] || fail "own close must leave only the terminal receipt"

echo "PASS: session-guard close --housekeeping --only-own-harness"
