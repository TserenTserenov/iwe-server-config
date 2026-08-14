#!/usr/bin/env bash
# Regression for peer-session 2026-08-14-02-git-worktree-chaos (consensus with
# Codex): `open` must warn — not block — when the same WP is already open in a
# DIFFERENT checkout that shares the same origin remote (the dashboard-clone
# incident: worktree added a warning class, but two independent `git clone`s
# of the same upstream stayed invisible until this fix).
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-dup-checkout.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

# gov_repo_dir() (the existing identity mechanism this fix reuses) only
# trusts a candidate checkout's remote when it can compare it against
# $IWE_ROOT/$GOV_REPO's own remote — an IWE_GOVERNANCE_REPO dir that doesn't
# exist falls through to that (nonexistent, in a fixture) canonical path
# silently, which is what made the first version of this fixture fail closed
# instead of testing the warning. The canonical dir itself is never opened
# from in this test — its only job is giving gov_repo_dir() something to
# compare against.
CANONICAL="$TEST_ROOT/canonical"
CHECKOUT_A="$TEST_ROOT/checkout-a"
CHECKOUT_B="$TEST_ROOT/checkout-b"
for dir in "$CANONICAL" "$CHECKOUT_A" "$CHECKOUT_B"; do
    mkdir -p "$dir/sessions"
    git init -q "$dir"
    git -C "$dir" remote add origin "https://github.com/example/shared-repo.git"
done

open_from() {
    local checkout="$1" id="$2" wp="$3" slug="$4"
    (cd "$checkout" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="canonical" \
        IWE_SESSION_ID="$id" bash "$GUARD" open \
        --wp "$wp" --task fixture --slug "$slug" --agent "fixture-$id")
}

# First session opens cleanly from checkout A — no prior session to warn about.
OUT_A=$(open_from "$CHECKOUT_A" alpha WP-900 first 2>&1)
if grep -q 'WARNING: WP WP-900 уже открыт' <<<"$OUT_A"; then
    echo "FAIL: first open in an empty session dir must not warn: $OUT_A" >&2
    exit 1
fi

# Second session, same WP, different checkout of the same remote — must warn.
OUT_B=$(open_from "$CHECKOUT_B" beta WP-900 second 2>&1)
if ! grep -q 'WARNING: WP WP-900 уже открыт' <<<"$OUT_B"; then
    echo "FAIL: expected duplicate-checkout warning, got: $OUT_B" >&2
    exit 1
fi
if ! grep -q "$CHECKOUT_A" <<<"$OUT_B"; then
    echo "FAIL: warning must name the other checkout's path: $OUT_B" >&2
    exit 1
fi

# The warning must never block: `open` still succeeds (exit 0) and writes a
# semaphore for checkout B — this is advisory, not a gate.
if [ ! -f "$TEST_ROOT/.iwe-runtime/sessions/fixture-beta-beta.open" ]; then
    echo "FAIL: open must still succeed (advisory warning, not a block)" >&2
    exit 1
fi

# A different WP in a duplicate checkout must NOT warn — the check is scoped
# per-WP, not per-remote (two agents legitimately working different РП from
# clones of the same repo is not the incident being guarded against).
OUT_C=$(open_from "$CHECKOUT_B" gamma WP-901 unrelated 2>&1)
if grep -q 'WARNING: WP WP-901 уже открыт\|WARNING: WP WP-900 уже открыт' <<<"$OUT_C"; then
    echo "FAIL: different WP must not trigger the duplicate-checkout warning: $OUT_C" >&2
    exit 1
fi

echo "PASS: session-guard duplicate-checkout warning"
