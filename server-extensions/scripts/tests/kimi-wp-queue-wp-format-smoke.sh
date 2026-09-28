#!/usr/bin/env bash
# kimi-wp-queue-wp-format-smoke.sh -- WP-561 Ф25: the queue accepts exactly WP-<n> (n >= 1, no leading
# zero) or TASK-<slug>. The WP-<n> form is the one session-guard `open` accepts too (its other values,
# unknown and day-close, are not queue entries).
#
# Safety, because the script is not inert: at load time it creates its queue and log directories and
# sources a library from $IWE_ROOT, and a successful `add` writes a launchd job and loads it (even with
# --dry-run: the flag goes to the runner). So the whole run is in a throw-away tree:
#   * IWE_ROOT and HOME both point under a mktemp dir, checked BEFORE the script is called;
#   * launchctl is a recorder placed first on PATH; a single call is a failure;
#   * every case ends before the datetime is parsed: an invalid wp fails at the wp check, a valid one
#     is given a deliberately invalid agent and must fail at the agent check, which is the proof that
#     the wp check let it through. Nothing here ever reaches the code that writes a plist.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
QUEUE="$ROOT_DIR/scripts/kimi-wp-queue.sh"
TEST_ROOT=$(mktemp -d /private/tmp/kimi-wp-queue-format.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

export IWE_ROOT="$TEST_ROOT/iwe" HOME="$TEST_ROOT/home"
case "$IWE_ROOT:$HOME" in
    "$TEST_ROOT"/*:"$TEST_ROOT"/*) ;;
    *) echo "FAIL: the sandbox variables are not under the temp dir, refusing to run" >&2; exit 2 ;;
esac
mkdir -p "$IWE_ROOT/DS-my-strategy/scripts/lib" "$HOME/Library/LaunchAgents" "$TEST_ROOT/bin"
# The one function the script takes from the library it sources.
printf 'resolve_canonical_checkout() { echo "%s/DS-my-strategy"; }\n' "$IWE_ROOT" \
    > "$IWE_ROOT/DS-my-strategy/scripts/lib/governance-repo-path.sh"

LAUNCH_LOG="$TEST_ROOT/launchctl.log"
: > "$LAUNCH_LOG"
printf '#!/bin/bash\necho "$*" >> "%s"\nexit 0\n' "$LAUNCH_LOG" > "$TEST_ROOT/bin/launchctl"
chmod +x "$TEST_ROOT/bin/launchctl"
export PATH="$TEST_ROOT/bin:$PATH"
[ "$(command -v launchctl)" = "$TEST_ROOT/bin/launchctl" ] || fail "the launchctl recorder does not shadow the real one"

# A time in the future keeps the date check (which this test never reaches) out of the picture.
ADD_TIME="2099-01-01 10:00"

for wp in WP-007 WP-0 WP-00561 561 wp-561 WP-561x "WP-561 " WP- week-close TASK- TASK-Upper TASK-with_underscore; do
    RC=0; OUT=$(bash "$QUEUE" add "$ADD_TIME" "$wp" kimi 2>&1) || RC=$?
    [ "$RC" = "1" ] || fail "'$wp' must be refused with exit 1, got $RC: $OUT"
    printf '%s' "$OUT" | grep -q 'wp must look like' || fail "'$wp' must be refused at the wp check, got: $OUT"
done
echo "OK: 12 malformed wp values are refused at the wp check"

for wp in WP-561 WP-1 WP-100 TASK-transcribe-m4 TASK-a; do
    RC=0; OUT=$(bash "$QUEUE" add "$ADD_TIME" "$wp" nobody 2>&1) || RC=$?
    [ "$RC" = "1" ] || fail "'$wp' with an invalid agent must fail with exit 1, got $RC: $OUT"
    printf '%s' "$OUT" | grep -q 'agent must be' || fail "'$wp' must pass the wp check and stop at the agent check, got: $OUT"
    printf '%s' "$OUT" | grep -q 'wp must look like' && fail "'$wp' is valid but the wp check refused it: $OUT"
done
echo "OK: WP-<n> without a leading zero and TASK-<slug> pass the wp check"

[ ! -s "$LAUNCH_LOG" ] || fail "launchctl was called: $(cat "$LAUNCH_LOG")"
[ -z "$(find "$HOME/Library/LaunchAgents" -name '*.plist' 2>/dev/null)" ] || fail "a plist was written"
[ "$(wc -l < "$IWE_ROOT/.iwe-runtime/wp-queue/queue.tsv" | tr -d ' ')" = "1" ] || fail "the queue must hold only its header line"
echo "OK: no launchctl call, no plist, the queue holds only its header"

echo "PASS: kimi-wp-queue accepts exactly WP-<n> (no leading zero) or TASK-<slug>, and this test cannot schedule anything"
