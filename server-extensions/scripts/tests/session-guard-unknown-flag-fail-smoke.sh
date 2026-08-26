#!/usr/bin/env bash
# Regression for WP-7 Ф83: an unrecognized flag used to be silently `shift`ed
# away (the value after it fell into POSITIONAL instead) -- any protective
# flag typo'd or not yet wired into the parser vanished with no diagnostic.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-unknown-flag.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/DS-strategy/inbox/WP-001"
printf '%s\n' 'hypothesis_relation: "tests"' > "$TEST_ROOT/DS-strategy/inbox/WP-001/WP-001.md"

open_with() {
    IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" \
        bash "$GUARD" open --wp WP-001 --agent fixture "$@"
}

no_semaphore_left() {
    [ -z "$(find "$TEST_ROOT/.iwe-runtime" -name '*.open' 2>/dev/null)" ]
}

expect_loud_failure() {  # expect_loud_failure <slug> <extra open args...>
    local slug="$1"; shift
    local out rc=0
    out=$(open_with --slug "$slug" "$@" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: expected non-zero exit for: $*" >&2
        exit 1
    fi
    if ! grep -q "неизвестный флаг" <<<"$out"; then
        echo "FAIL: expected an explicit 'неизвестный флаг' diagnostic, got: $out" >&2
        exit 1
    fi
    if ! no_semaphore_left; then
        echo "FAIL: unknown flag left a semaphore behind: $*" >&2
        exit 1
    fi
}

# Unknown flag alone -- must fail loudly, no semaphore.
expect_loud_failure smoke1 --totally-unknown-flag value

# Unknown flag mixed with known ones, before and after -- the shared parser
# processes args left-to-right regardless of position; check both.
expect_loud_failure smoke2 --unknown-before value --task fixture
expect_loud_failure smoke3 --task fixture --unknown-after value

# A typo'd known flag (missing one letter) is indistinguishable from a truly
# unknown one to the parser -- this is the real-world case that motivated the
# fix (a protective flag silently doing nothing because of a typo upstream).
expect_loud_failure smoke4 --slgu smoke4

# Positive control: only known flags still opens cleanly.
open_with --slug smoke5 --task fixture >/dev/null
[ -n "$(find "$TEST_ROOT/.iwe-runtime" -name 'fixture-*.open' 2>/dev/null)" ] \
    || { echo "FAIL: normal open with known flags did not create a semaphore" >&2; exit 1; }

echo "PASS: session-guard rejects unrecognized flags instead of silently dropping them"
