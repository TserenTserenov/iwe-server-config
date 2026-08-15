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
    # This fixture's repo dir defaults to the same name as the real canonical
    # checkout the WP-520 freeze targets -- opt out explicitly, this test is
    # about the wp+slug selector, not freeze.
    IWE_ROOT="$TEST_ROOT" IWE_SESSION_ID="$id" IWE_FROZEN_CANONICAL_PATH="" bash "$GUARD" open \
        --wp "$wp" --task fixture --slug "$slug" --agent fixture >/dev/null
}

# cd "$TEST_ROOT" in both helpers (Д2а, 15.08): note-file now refuses paths with
# no git context, so the fixture must run from its own repo — from a non-repo
# cwd every expect_note died on the path refusal before reaching the selector
# under test (review-01 Medium; target.md also genuinely lives there).
expect_note() {
    (cd "$TEST_ROOT" && IWE_ROOT="$TEST_ROOT" bash "$GUARD" note-file target.md "$@" --agent fixture) \
        | grep -q 'Noted in scope'
}

expect_refusal() {
    if (cd "$TEST_ROOT" && IWE_ROOT="$TEST_ROOT" bash "$GUARD" note-file target.md "$@" --agent fixture \
        >/dev/null 2>&1); then
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

# --- Д2а (WP-484, 15.08): poison-path refusals — the registry accepts only
# repo-relative paths; the old fallback recorded absolute/../-escaping entries
# verbatim and later scoped pathspecs died on them wholesale (Ф60 live bug).
poison_refusal() {  # poison_refusal <path> <cwd> — refusal must be the PATH one,
    # not an accidental selector failure (review-01: rc alone can't tell them apart)
    local out rc=0
    out=$( (cd "$2" && IWE_ROOT="$TEST_ROOT" bash "$GUARD" note-file "$1" --wp WP-777 --slug solo --agent fixture) 2>&1 ) || rc=$?
    if [ "$rc" -eq 0 ] || ! grep -q "запись отклонена" <<<"$out"; then
        echo "FAIL: expected poison-path refusal for '$1' (cwd=$2), got: $out" >&2
        exit 1
    fi
}

NOREPO_DIR=$(mktemp -d /private/tmp/session-guard-norepo.XXXXXX)
OTHER_DIR=$(mktemp -d /private/tmp/session-guard-other.XXXXXX)
trap 'rm -rf "$TEST_ROOT" "$NOREPO_DIR" "$OTHER_DIR"' EXIT

# Nonexistent path, cwd outside any repo -> no git context at all: refuse
# (used to be recorded verbatim, absolute).
poison_refusal "$NOREPO_DIR/ghost.md" "$NOREPO_DIR"

# Nonexistent path outside the repo, cwd inside a repo -> relpath escapes the
# root as ../…: refuse.
poison_refusal "$OTHER_DIR/ghost.md" "$TEST_ROOT"

# Positive control: a future file INSIDE the repo from a repo cwd stays
# accepted (pre-noting archive destinations is a legitimate, live pattern).
(cd "$TEST_ROOT" && IWE_ROOT="$TEST_ROOT" bash "$GUARD" note-file future-dir/planned.md --wp WP-777 --slug solo --agent fixture \
    | grep -q 'Noted in scope') || { echo "FAIL: future in-repo path must stay accepted" >&2; exit 1; }

echo "PASS: session-guard selector"
