#!/usr/bin/env bash
# Regression (peer-session 2026-10-23-10-wp485-session-guard-host-field,
# bug-2026-10-23-session-guard-native-identity-refuses-when-host-field-absent):
# unique("host") used to run unconditionally before the wp/slug relevance
# check in _open_native_identity_available, so a closed semaphore missing a
# host: line entirely (written by the ORZ scaffold / peer-session close path,
# not `open --wp`) permanently refused ANY later `open` of the same
# conversation, even for unrelated wp/slug. Fixed by checking wp/slug
# relevance first; host absence now only matters once a record is already
# known to be about the SAME work (same wp+slug), where it correctly refuses
# instead of silently allowing a duplicate open.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-host-absent.XXXXXX")
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

NATIVE_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
export CLAUDE_CODE_SESSION_ID="$NATIVE_ID"
THIS_HOST=$(uname -n)

run() { ( cd "$GOV" && PATH="$TEST_ROOT/bin:$PATH" bash "$GUARD" "$@" ) 2>&1; }

write_record() {
    # write_record <name> <agent value> <extra wp/slug/host lines...>
    local name="$1" agent_value="$2"; shift 2
    local path="$SESSION_DIR/claude-code-$name"
    {
        echo "---"
        echo "agent: $agent_value"
        echo "harness_session_id: $NATIVE_ID"
        for line in "$@"; do echo "$line"; done
        echo "session_id: $name"
    } > "$path"
}

# session_id (and therefore the .open filename) is auto-generated unless
# --session-id is passed, so success is checked by content grep across the
# newly created .open file(s), the same way
# session-guard-housekeeping-then-wp-open-smoke.sh does it.
assert_new_open_created() {
    grep -rlq "^slug: $1\$" "$SESSION_DIR"/claude-code-*.open 2>/dev/null \
        || fail "no .open semaphore with slug: $1 was created"
}
count_open() { find "$SESSION_DIR" -maxdepth 1 -name 'claude-code-*.open' 2>/dev/null | wc -l | tr -d ' '; }
assert_no_new_open() {
    # Compares against a baseline taken right after the fixture was written
    # (a pre-seeded *.open fixture, e.g. the legacy-no-slug one, already
    # counts toward this pattern) -- a refusal must add zero new entries.
    local before="$1" after
    after=$(count_open)
    [ "$after" = "$before" ] || fail "refusal must not create a new semaphore, had $before, now $after"
}

# 1. Live bug scenario: a closed record names a DIFFERENT wp/slug and has no
# host: line at all (the ORZ-scaffold/peer-session-close record shape). Must
# succeed — relevance (wp/slug) is checked before host is ever looked at.
write_record "wp9-other.open.closed" claude-code "wp: WP-9" "slug: wp9-other"
OUT=$(run open --wp WP-7 --agent claude-code --slug target 2>&1) \
  || fail "irrelevant record missing host: must not block an unrelated open, got: $OUT"
assert_new_open_created target
echo "OK: a closed record for different wp/slug with no host: line does not block an unrelated open"

# 2. Negative control: an irrelevant record with an AMBIGUOUS host (2 lines)
# must also not block an unrelated open -- ambiguity of someone else's work
# is still irrelevant to this request.
rm -f "$SESSION_DIR"/claude-code-*.open "$SESSION_DIR"/claude-code-*.open.closed
write_record "wp9-dup-host.open.closed" claude-code "wp: WP-9" "slug: wp9-dup-host" "host: host-a" "host: host-b"
OUT=$(run open --wp WP-7 --agent claude-code --slug target 2>&1) \
  || fail "irrelevant record with ambiguous host must not block an unrelated open, got: $OUT"
echo "OK: a closed record for different wp/slug with ambiguous host does not block an unrelated open"

# 3. Relevant record (same wp+slug), host differs from this machine's host:
# must succeed -- a different host legitimately keeps its own records under
# the same wp/slug (multi-host, e.g. laptop + server).
rm -f "$SESSION_DIR"/claude-code-*.open "$SESSION_DIR"/claude-code-*.open.closed
write_record "target.open.closed" claude-code "wp: WP-7" "slug: target" "host: some-other-host"
OUT=$(run open --wp WP-7 --agent claude-code --slug target 2>&1) \
  || fail "a matching wp/slug record from a DIFFERENT host must not block this host's open, got: $OUT"
assert_new_open_created target
echo "OK: a same wp/slug record from a different host does not block this host's open"

# 4. The bug's own fix target: a relevant record (same wp+slug) with NO
# host: line at all must now refuse -- ownership is undetermined, this must
# not silently allow re-opening the same declared work.
rm -f "$SESSION_DIR"/claude-code-*.open "$SESSION_DIR"/claude-code-*.open.closed
write_record "target.open.closed" claude-code "wp: WP-7" "slug: target"
BEFORE=$(count_open)
OUT=$(run open --wp WP-7 --agent claude-code --slug target 2>&1) && fail "a matching wp/slug record with no host: line at all must refuse, got success"
printf '%s' "$OUT" | grep -q "не содержит host" \
  || fail "refusal must name the missing host, got: $OUT"
assert_no_new_open "$BEFORE"
echo "OK: a matching wp/slug record with no host: line at all refuses instead of allowing a duplicate open"

# 5. Negative control: a relevant record with an empty host: value (line
# present, no content) must get the same treatment as fully absent.
rm -f "$SESSION_DIR"/claude-code-*.open "$SESSION_DIR"/claude-code-*.open.closed
write_record "target.open.closed" claude-code "wp: WP-7" "slug: target" "host:"
BEFORE=$(count_open)
OUT=$(run open --wp WP-7 --agent claude-code --slug target 2>&1) && fail "a matching wp/slug record with an empty host: value must refuse, got success"
printf '%s' "$OUT" | grep -q "не содержит host" \
  || fail "refusal must name the missing host for an empty value too, got: $OUT"
assert_no_new_open "$BEFORE"
echo "OK: a matching wp/slug record with an empty host: value refuses the same way as fully absent"

# 6. Negative control: a relevant record with a genuinely AMBIGUOUS host
# (2+ differing values) must still refuse as data corruption, not as
# "irrelevant" or "absent".
rm -f "$SESSION_DIR"/claude-code-*.open "$SESSION_DIR"/claude-code-*.open.closed
write_record "target.open.closed" claude-code "wp: WP-7" "slug: target" "host: host-a" "host: host-b"
BEFORE=$(count_open)
OUT=$(run open --wp WP-7 --agent claude-code --slug target 2>&1) && fail "a matching wp/slug record with a duplicated host: field must refuse, got success"
printf '%s' "$OUT" | grep -q "неоднозначное поле host" \
  || fail "refusal must name the ambiguous host field, got: $OUT"
assert_no_new_open "$BEFORE"
echo "OK: a matching wp/slug record with a duplicated host: field still refuses as ambiguous"

# 7. Negative control: agent mismatch on a relevant, same-host record must
# still refuse -- host being handled correctly must not weaken the agent
# check that comes right after it.
rm -f "$SESSION_DIR"/claude-code-*.open "$SESSION_DIR"/claude-code-*.open.closed
write_record "target.open.closed" kimi "wp: WP-7" "slug: target" "host: $THIS_HOST"
BEFORE=$(count_open)
OUT=$(run open --wp WP-7 --agent claude-code --slug target 2>&1) && fail "agent mismatch on a matching, same-host record must refuse, got success"
printf '%s' "$OUT" | grep -q "agent не совпадает" \
  || fail "refusal must name the agent mismatch, got: $OUT"
assert_no_new_open "$BEFORE"
echo "OK: agent mismatch on a matching, same-host record still refuses"

# 8. Negative control (unchanged pre-existing behaviour): a matching wp with
# no slug: line at all must still refuse -- the wp/slug block's existing
# strictness (session-guard-housekeeping-then-wp-open-smoke.sh scenario 5)
# is unaffected by moving the block earlier.
rm -f "$SESSION_DIR"/claude-code-*.open "$SESSION_DIR"/claude-code-*.open.closed
write_record "no-slug-legacy.open" claude-code "wp: WP-7" "host: $THIS_HOST"
BEFORE=$(count_open)
OUT=$(run open --wp WP-7 --agent claude-code --slug target 2>&1) && fail "a matching wp with no slug: line at all must still refuse, got success"
printf '%s' "$OUT" | grep -q "неоднозначное поле slug" \
  || fail "refusal must name the missing slug field, got: $OUT"
assert_no_new_open "$BEFORE"
echo "OK: a matching wp with no slug: line at all still refuses (unchanged by the reorder)"

echo "PASS: host absence on an irrelevant record no longer blocks open; host absence on a matching record still refuses"
