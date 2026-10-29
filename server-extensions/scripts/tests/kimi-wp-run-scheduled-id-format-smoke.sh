#!/usr/bin/env bash
# kimi-wp-run-scheduled-id-format-smoke.sh -- WP-7 Ф274: the runner accepts only the id shape
# kimi-wp-queue.sh `add` produces (<wp-n|task-slug>-YYYYMMDD-HHMM) and refuses anything else
# before it reads or writes a file.
#
# Safety: IWE_ROOT and HOME point under a mktemp dir, checked before the runner is called. The
# sandbox has no .claude/lib/iwe-env-bootstrap.sh, so an id that passes the check stops at the
# bootstrap `source` -- that different error is the proof the id check let it through.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RUNNER="$ROOT_DIR/scripts/kimi-wp-run-scheduled.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kimi-wp-run-id.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

export IWE_ROOT="$TEST_ROOT/iwe" HOME="$TEST_ROOT/home"
case "$IWE_ROOT:$HOME" in
    "$TEST_ROOT"/*:"$TEST_ROOT"/*) ;;
    *) echo "FAIL: the sandbox variables are not under the temp dir, refusing to run" >&2; exit 2 ;;
esac
mkdir -p "$IWE_ROOT" "$HOME"

PASS=0
FAIL=0
REFUSAL='is not a queue id'

ERR_FILE="$TEST_ROOT/runner.err"
run_runner() { # $1 = id -> runner stderr in $ERR_FILE, exit code in RC
    bash "$RUNNER" "$1" >/dev/null 2>"$ERR_FILE" && RC=0 || RC=$?
}

expect_refused() { # $1 = id
    run_runner "$1"
    if [ "$RC" = 1 ] && grep -q "$REFUSAL" "$ERR_FILE" && [ ! -e "$IWE_ROOT/.iwe-runtime" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1)); echo "FAIL: id '$1' was not refused before any write (rc=$RC): $(cat "$ERR_FILE")"
    fi
}

expect_accepted() { # $1 = id
    run_runner "$1"
    if grep -q "$REFUSAL" "$ERR_FILE"; then
        FAIL=$((FAIL+1)); echo "FAIL: queue id '$1' was refused: $(cat "$ERR_FILE")"
    else
        PASS=$((PASS+1))
    fi
}

for id in 'research' 'sched-1' 'wp-7' 'wp-07-20261029-0600' 'WP-7-20261029-0600' 'wp-7-2026102-0600' \
          'wp-7-20261029-0600x' 'task-Foo-20261029-0600' 'task--20261029-0600x' '../wp-7-20261029-0600' \
          'wp-7-20261029-0600 extra' "$(printf 'wp-7-20261029-0600\nx')" 'wp-.*-20261029-0600'; do
    expect_refused "$id"
done
for id in 'wp-7-20261029-0600' 'wp-561-20261130-2359' 'task-night-digest-20261029-0315'; do
    expect_accepted "$id"
done

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
