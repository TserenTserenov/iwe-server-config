#!/usr/bin/env bash
# Regression (bug-2026-10-22, WP-7 Ф247): a housekeeping semaphore carries no
# wp: line at all. _open_native_identity_available used to call unique("wp")
# unconditionally for any record sharing the same harness_session_id, and
# unique() refuses on an empty field -- so once a session opened
# --housekeeping, the SAME session could never again `open --wp <N>`, even
# after the housekeeping semaphore was closed. Fixed by checking raw wp
# relevance before enforcing single-value strictness.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-hk-then-wp.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
trap 'rm -rf "$TEST_ROOT"' EXIT

GOV="$TEST_ROOT/DS-strategy"
SESSION_DIR="$TEST_ROOT/.iwe-runtime/sessions"
mkdir -p "$GOV/scripts" "$GOV/sessions" "$SESSION_DIR" "$TEST_ROOT/bin"
git -C "$GOV" init -q
export IWE_SESSIONS_ROOT="$GOV/sessions" IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH=""

printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/bin/iwe-tg"
chmod +x "$TEST_ROOT/bin/iwe-tg"

fail() { echo "FAIL: $*" >&2; exit 1; }

NATIVE_ID="11111111-2222-3333-4444-555555555555"
export CLAUDE_CODE_SESSION_ID="$NATIVE_ID"

run() { ( cd "$GOV" && PATH="$TEST_ROOT/bin:$PATH" bash "$GUARD" "$@" ) 2>&1; }

# 1. Same conversation opens a housekeeping semaphore (no wp: line at all).
OUT=$(run open --housekeeping day-close --agent claude-code --canonical-owner day-close --owner-pid $$) \
  || fail "housekeeping open must succeed, got: $OUT"
[ -f "$SESSION_DIR/claude-code-housekeeping-day-close.open" ] \
  || fail "housekeeping semaphore was not created"
grep -q '^wp:' "$SESSION_DIR/claude-code-housekeeping-day-close.open" \
  && fail "fixture invalid: housekeeping semaphore unexpectedly carries a wp: line"

# 2. Close the housekeeping semaphore (matches the real incident: the stuck
# commit happened AFTER housekeeping closed, not while it was still open).
run close --agent claude-code --housekeeping day-close --canonical-owner day-close >/dev/null \
  || fail "housekeeping close must succeed"

# 3. The SAME conversation (same CLAUDE_CODE_SESSION_ID) now opens a real WP.
# Before the fix this refused with "неоднозначное поле wp" because
# _open_native_identity_available matched the closed housekeeping record by
# harness_session_id and called unique("wp") on a record with zero wp: lines.
OUT=$(run open --wp WP-7 --agent claude-code --slug wp7-after-housekeeping) \
  || fail "open --wp after a closed housekeeping semaphore of the same conversation must succeed, got: $OUT"
grep -rlq '^slug: wp7-after-housekeeping$' "$SESSION_DIR"/claude-code-*.open 2>/dev/null \
  || fail "the WP semaphore was not created"
echo "OK: open --wp succeeds right after this same conversation's housekeeping semaphore closes"

# 4. Negative control: a genuinely ambiguous wp: field on a record that DOES
# match the requested wp/slug must still refuse (corruption, not relevance).
# Fixture cleanup only (not exercising the full close/ORZ flow, which is
# unrelated to the native-identity check this test targets).
rm -f "$SESSION_DIR"/claude-code-*.open
CORRUPT="$SESSION_DIR/claude-code-wp7-corrupt.open"
cat > "$CORRUPT" <<EOF
---
agent: claude-code
harness_session_id: $NATIVE_ID
host: $(uname -n)
wp: WP-7
wp: WP-9
slug: wp7-corrupt
session_id: wp7-corrupt
EOF
OUT=$(run open --wp WP-7 --agent claude-code --slug wp7-corrupt 2>&1) && fail "a duplicate wp: field on a matching record must still refuse, got success"
printf '%s' "$OUT" | grep -q "неоднозначное поле wp" \
  || fail "refusal must name the ambiguous field, got: $OUT"
echo "OK: a genuinely ambiguous wp: field on a matching record still refuses"

# 5. Negative control (Kimi cold review, found a real regression in the first
# cut of this fix): a record whose wp: line is present and matches, but whose
# slug: line is entirely missing, must still refuse -- this is legacy/corrupt
# state, not "irrelevant", and the fix must not silently skip it.
rm -f "$SESSION_DIR"/claude-code-*.open
NO_SLUG="$SESSION_DIR/claude-code-no-slug-legacy.open"
cat > "$NO_SLUG" <<EOF
---
agent: claude-code
harness_session_id: $NATIVE_ID
host: $(uname -n)
wp: WP-7
session_id: no-slug-legacy
EOF
OUT=$(run open --wp WP-7 --agent claude-code --slug my-slug 2>&1) && fail "a matching wp: with no slug: line at all must still refuse, got success"
printf '%s' "$OUT" | grep -q "неоднозначное поле slug" \
  || fail "refusal must name the missing slug field, got: $OUT"
echo "OK: a matching wp: with no slug: field at all still refuses"

# 6. The scenario named in the bug report literally: the housekeeping
# record's own slug ("day-close") happens to equal the requested slug too.
# A bare relevance check keyed on slug alone would have let this one through
# to the strict unique("wp") refusal again; the fix must key relevance on the
# presence of a wp: line, not on slug equality.
rm -f "$SESSION_DIR"/claude-code-*.open
OUT=$(run open --housekeeping day-close --agent claude-code --canonical-owner day-close --owner-pid $$) \
  || fail "housekeeping open (reason=slug=day-close) must succeed, got: $OUT"
run close --agent claude-code --housekeeping day-close --canonical-owner day-close >/dev/null \
  || fail "housekeeping close must succeed"
OUT=$(run open --wp day-close --agent claude-code --slug day-close 2>&1) \
  || fail "open --wp day-close --slug day-close after this conversation's housekeeping (same slug) must succeed, got: $OUT"
echo "OK: open --wp succeeds even when its own slug coincides with the closed housekeeping record's slug"

echo "PASS: housekeeping semaphores no longer lock a conversation out of open --wp"
