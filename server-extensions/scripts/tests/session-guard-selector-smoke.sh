#!/usr/bin/env bash
# Regression for WP-484: an exact wp+slug pair must not match another session
# that shares only one of those selectors.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-selector.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

open_session() {
    local id="$1" wp="$2" slug="$3"
    IWE_ROOT="$TEST_ROOT" IWE_SESSION_ID="$id" bash "$GUARD" open \
        --wp "$wp" --task fixture --slug "$slug" --agent fixture >/dev/null
}

expect_note() {
    IWE_ROOT="$TEST_ROOT" bash "$GUARD" note-file target.md "$@" --agent fixture \
        | grep -q 'Noted in scope'
}

expect_refusal() {
    if IWE_ROOT="$TEST_ROOT" bash "$GUARD" note-file target.md "$@" --agent fixture \
        >/dev/null 2>&1; then
        echo "FAIL: expected selector refusal: $*" >&2
        exit 1
    fi
}

git init -q "$TEST_ROOT"
mkdir -p "$TEST_ROOT/DS-strategy/sessions"
touch "$TEST_ROOT/target.md"

open_session exact WP-484 target
open_session same_wp WP-484 same-wp
open_session same_slug WP-999 target
open_session solo WP-777 solo

# Both selectors identify the exact session, even with partial matches present.
expect_note --wp WP-484 --slug target

# A single non-unique selector must still fail closed.
expect_refusal --wp WP-484
expect_refusal --slug target

# A unique single selector remains supported.
expect_note --slug same-wp
expect_note --wp WP-777

# A requested pair that does not exist never falls back to another open session.
expect_refusal --wp WP-404 --slug target

echo "PASS: session-guard selector"
