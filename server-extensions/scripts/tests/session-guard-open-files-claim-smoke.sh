#!/usr/bin/env bash
# session-guard-open-files-claim-smoke.sh -- WP-484 F331, step 2: `open --files` wrote any value
# verbatim, so one absolute path in a mark made the commit barrier warn every agent (24.11).
# `open` now refuses a claimed path that is absolute or holds '..' (exit 2, no semaphore left);
# repository-relative paths, spaces around commas and directories open and are recorded.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-open-files.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/DS-strategy/inbox/WP-999"
printf '%s\n' 'hypothesis_relation: "tests"' > "$TEST_ROOT/DS-strategy/inbox/WP-999/WP-999.md"

guard() {
    IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" IWE_FROZEN_CANONICAL_PATH="" \
        bash "$GUARD" "$@"
}
semaphores() { find "$TEST_ROOT/.iwe-runtime" -name '*.open' 2>/dev/null; }

n=0
for bad in '/Users/someone/audio.txt' '../up.txt' 'a/../../b.txt' 'a/..' 'ok.txt, /abs.txt'; do
    n=$((n + 1))
    rc=0
    out=$(guard open --wp WP-999 --agent fixture --slug "bad-$n" --files "$bad" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || { echo "FAIL: --files '$bad' must be refused with exit 2, got rc=$rc: $out" >&2; exit 1; }
    printf '%s' "$out" | grep -q 'указывает вне хранилища' \
        || { echo "FAIL: refusal for '$bad' must say why, got: $out" >&2; exit 1; }
    [ -z "$(semaphores)" ] || { echo "FAIL: refused open for '$bad' left a semaphore" >&2; exit 1; }
done
echo "OK: absolute and '..' paths are refused with exit 2 and leave no semaphore"

rc=0
out=$(guard open --wp WP-999 --agent fixture --slug good --files 'inbox/WP-999/WP-999.md, docs/' 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: relative --files must open, got rc=$rc: $out" >&2; exit 1; }
sem=$(semaphores | head -1)
grep -qx 'file: inbox/WP-999/WP-999.md' "$sem" && grep -qx 'file: docs/' "$sem" \
    || { echo "FAIL: relative claims must be recorded verbatim" >&2; exit 1; }
echo "OK: repository-relative paths and a directory open and are recorded"
