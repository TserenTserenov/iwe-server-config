#!/usr/bin/env bash
# session-guard-open-wp-format-smoke.sh -- WP-561 Ф25, punkt 1: `open` used to check only that
# --wp was non-empty, so a value the commit-barrier classifier cannot classify (28.09:
# `week-review-w39`) opened fine and failed every intersecting commit 17 minutes later.
# `open` now accepts exactly WP-<n>, unknown, day-close (exact spelling) and refuses the rest
# with exit 2 before any state is written. Selectors (close/renew/note-*) stay unvalidated so
# an old semaphore with a now-invalid wp remains closable.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-open-wp-format.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

# Same disarmed-freeze fixture as session-guard-unknown-flag-fail-smoke.sh: a plain directory as
# governance repo, so this suite exercises only the --wp contract.
mkdir -p "$TEST_ROOT/DS-strategy/inbox/WP-999"
printf '%s\n' 'hypothesis_relation: "tests"' > "$TEST_ROOT/DS-strategy/inbox/WP-999/WP-999.md"

guard() {
    IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" IWE_FROZEN_CANONICAL_PATH="" \
        bash "$GUARD" "$@"
}

semaphores() { find "$TEST_ROOT/.iwe-runtime" -name '*.open' 2>/dev/null; }

slug_n=0
expect_open_refused() {  # expect_open_refused <wp>
    local wp="$1" out rc=0
    slug_n=$((slug_n + 1))
    out=$(guard open --wp "$wp" --agent fixture --slug "refused-$slug_n" 2>&1) || rc=$?
    if [ "$rc" -ne 2 ]; then
        echo "FAIL: --wp '$wp' must be refused with exit 2, got rc=$rc: $out" >&2
        exit 1
    fi
    if ! printf '%s' "$out" | grep -q 'недопустим'; then
        echo "FAIL: refusal for --wp '$wp' must say why, got: $out" >&2
        exit 1
    fi
    if [ -n "$(semaphores)" ]; then
        echo "FAIL: refused open for --wp '$wp' left a semaphore behind" >&2
        exit 1
    fi
}

expect_open_accepted() {  # expect_open_accepted <wp>
    local wp="$1" out rc=0
    slug_n=$((slug_n + 1))
    out=$(guard open --wp "$wp" --agent fixture --slug "accepted-$slug_n" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL: --wp '$wp' must open, got rc=$rc: $out" >&2
        exit 1
    fi
    if ! grep -qx "wp: $wp" "$(semaphores | head -1)"; then
        echo "FAIL: semaphore for --wp '$wp' must record it verbatim" >&2
        exit 1
    fi
    guard close --wp "$wp" --agent fixture --slug "accepted-$slug_n" >/dev/null 2>&1 || rm -f "$(semaphores | head -1)"
    rm -rf "$TEST_ROOT/.iwe-runtime"
}

for wp in WP-999 unknown day-close; do
    expect_open_accepted "$wp"
done
echo "OK: WP-<n>, unknown and day-close open and are recorded verbatim"

for wp in 561 wp-561 Wp-561 WP-0 WP-01 WP-561a WP-TEST Unknown UNKNOWN Day-Close DAYCLOSE week-close week-review-w39 'WP-561 x'; do
    expect_open_refused "$wp"
done
echo "OK: bare numbers, other spellings and free-form values are refused with exit 2 and leave no semaphore"

# An ambient variable of the same name must not widen the accepted set: the script owns the list.
rc=0
out=$(SG_WP_SENTINELS='unknown day-close week-review-w39' guard open --wp week-review-w39 --agent fixture --slug ambient 2>&1) || rc=$?
if [ "$rc" -ne 2 ]; then
    echo "FAIL: an ambient SG_WP_SENTINELS must not make week-review-w39 acceptable, got rc=$rc: $out" >&2
    exit 1
fi
echo "OK: an ambient SG_WP_SENTINELS cannot widen the accepted set"

# The selector path must not apply the format check: an old semaphore with a legacy wp has to stay
# closable. Nothing is open here, so the honest failure is "no semaphore found", not "недопустим".
rc=0
out=$(guard close --wp week-review-w39 --agent fixture 2>&1) || rc=$?
if printf '%s' "$out" | grep -q 'недопустим'; then
    echo "FAIL: close --wp must not validate the format (old semaphores stay closable), got: $out" >&2
    exit 1
fi
if [ "$rc" -eq 0 ]; then
    echo "FAIL: close with no open semaphore must fail, got rc=0" >&2
    exit 1
fi
echo "OK: close --wp does not apply the open-time format check"

echo "PASS: open accepts exactly WP-<n>/unknown/day-close; selectors stay lenient"

# Native owners must not create another guard generation for the same work.
# Exercise the real CLI and its admission lock; all state stays in the fixture.
export CLAUDE_CODE_SESSION_ID=""
NATIVE_SESSION_DIR="$TEST_ROOT/.iwe-runtime/sessions"
NATIVE_SID="native-first"
NATIVE_OWNER="native-owner"
NATIVE_SLUG="native-work"
native_open() {
    IWE_SESSION_ID="$NATIVE_SID" CODEX_THREAD_ID="$NATIVE_OWNER" guard open \
        --wp WP-999 --agent codex --slug "$NATIVE_SLUG" --close-path peer-session "$@"
}
expect_native_refused() {
    local output rc=0
    output=$(native_open "$@" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: duplicate/malformed native open succeeded: $output" >&2
        exit 1
    fi
    printf '%s' "$output" | grep -q 'native\|неоднозначное поле' || {
        echo "FAIL: refusal did not identify native collision: $output" >&2; exit 1;
    }
}

native_open > "$TEST_ROOT/native-first.out" 2>&1
NATIVE_SEM="$NATIVE_SESSION_DIR/codex-$NATIVE_SID.open"
printf '%s\n' 'file: preserved.txt' >> "$NATIVE_SEM"
cp "$NATIVE_SEM" "$TEST_ROOT/native-before"
native_open > "$TEST_ROOT/native-repeat.out" 2>&1
cmp "$NATIVE_SEM" "$TEST_ROOT/native-before"
echo "OK: exact native guard ID re-entry preserves scope and identity"

NATIVE_SID="native-second"
expect_native_refused
NATIVE_SID=""
expect_native_refused
cmp "$NATIVE_SEM" "$TEST_ROOT/native-before"
[ "$(find "$NATIVE_SESSION_DIR" -name 'codex-*.open' | wc -l | tr -d ' ')" = 1 ]
# The guard must reject before attempting isolation, even when no Git origin exists.
expect_native_refused --isolate
echo "OK: changed/generated IDs refuse before isolation without changing the owner"

NATIVE_SID="native-other-owner"
NATIVE_OWNER="other-native-owner"
native_open > "$TEST_ROOT/native-other-owner.out" 2>&1
NATIVE_SID="native-other-slug"
NATIVE_OWNER="native-owner"
NATIVE_SLUG="other-native-work"
native_open > "$TEST_ROOT/native-other-slug.out" 2>&1
[ -f "$NATIVE_SESSION_DIR/codex-native-other-owner.open" ]
[ -f "$NATIVE_SESSION_DIR/codex-native-other-slug.open" ]
echo "OK: different native owners and slugs remain independent"

# A duplicate identity field must not be interpreted as a nonmatching owner.
NATIVE_SID="native-malformed"
NATIVE_SLUG="native-work"
printf '%s\n' 'harness_session_id: unrelated-owner' >> "$NATIVE_SEM"
expect_native_refused
cp "$TEST_ROOT/native-before" "$NATIVE_SEM"
# The file name is only an address: changing immutable close_path must still fail.
NATIVE_SID="native-first"
rc=0
native_open --close-path unknown > "$TEST_ROOT/native-immutable.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ]
cmp "$NATIVE_SEM" "$TEST_ROOT/native-before"
echo "OK: malformed owner fields and immutable identity changes refuse"

# A matching native owner with missing host is ambiguous, not a different host.
NATIVE_SID="native-missing-host"
sed '/^host: /d' "$TEST_ROOT/native-before" > "$NATIVE_SEM"
expect_native_refused
# A positively different host is a different owner identity.
sed 's/^host: .*/host: fixture-other-host/' "$TEST_ROOT/native-before" > "$NATIVE_SEM"
NATIVE_SID="native-other-host"
native_open > "$TEST_ROOT/native-other-host.out" 2>&1
[ -f "$NATIVE_SESSION_DIR/codex-native-other-host.open" ]
rm "$NATIVE_SESSION_DIR/codex-native-other-host.open"
cp "$TEST_ROOT/native-before" "$NATIVE_SEM"
NATIVE_OWNER="invalid native owner"
expect_native_refused
NATIVE_OWNER="native-owner"
echo "OK: host identity is required for a match; malformed native input refuses"

# Closed receipts reserve this logical work too; no live owner is silently adopted.
mv "$NATIVE_SEM" "$NATIVE_SEM.closed"
NATIVE_SID="native-after-close"
expect_native_refused
NATIVE_SID="native-first"
expect_native_refused
cmp "$NATIVE_SEM.closed" "$TEST_ROOT/native-before"
echo "OK: a closed native logical session refuses both same and new guard IDs"

# Concurrent opens have distinct IDs; admission must publish only one of them.
NATIVE_OWNER="concurrent-native-owner"
NATIVE_SLUG="concurrent-native-work"
(
    NATIVE_SID="native-race-a"
    rc=0; native_open > "$TEST_ROOT/native-race-a.out" 2>&1 || rc=$?
    printf '%s\n' "$rc" > "$TEST_ROOT/native-race-a.rc"
) &
FIRST_PID=$!
(
    NATIVE_SID="native-race-b"
    rc=0; native_open > "$TEST_ROOT/native-race-b.out" 2>&1 || rc=$?
    printf '%s\n' "$rc" > "$TEST_ROOT/native-race-b.rc"
) &
SECOND_PID=$!
wait "$FIRST_PID"
wait "$SECOND_PID"
FIRST_RC=$(cat "$TEST_ROOT/native-race-a.rc")
SECOND_RC=$(cat "$TEST_ROOT/native-race-b.rc")
if ! { [ "$FIRST_RC" = 0 ] && [ "$SECOND_RC" != 0 ]; } \
    && ! { [ "$SECOND_RC" = 0 ] && [ "$FIRST_RC" != 0 ]; }; then
    cat "$TEST_ROOT/native-race-a.out" "$TEST_ROOT/native-race-b.out" >&2
    echo "FAIL: concurrent native opens must have one winner: $FIRST_RC/$SECOND_RC" >&2
    exit 1
fi
[ "$(find "$NATIVE_SESSION_DIR" -name 'codex-native-race-*.open' | wc -l | tr -d ' ')" = 1 ]
echo "OK: concurrent native opens publish exactly one guard generation"
echo "PASS: native logical identity is reserved through open and closed states"
