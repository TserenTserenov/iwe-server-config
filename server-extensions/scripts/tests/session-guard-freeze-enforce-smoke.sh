#!/usr/bin/env bash
# Regression for peer-session 2026-08-14-07-wp520-freeze-enforce (consensus
# with Codex, two rounds): the found-28 freeze on the canonical checkout was
# text-only for three days — session-guard.sh had the check, but nothing ever
# exported IWE_FROZEN_CANONICAL_PATH, so the warning never fired live. This
# fixture verifies the default-on block and both carve-outs.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-freeze.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

FROZEN="$TEST_ROOT/frozen-checkout"
mkdir -p "$FROZEN/sessions"
git init -q "$FROZEN"

open_frozen() {
    (cd "$FROZEN" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="frozen-checkout" \
        IWE_FROZEN_CANONICAL_PATH="$FROZEN" \
        bash "$GUARD" open "$@")
}

# 1. Plain open on the frozen path, no carve-out flags -- must fail (exit != 0)
#    with the freeze message, and must NOT create a semaphore.
if OUT_1=$(open_frozen --wp WP-900 --task fixture --slug attempt-one --agent fixture 2>&1); then
    echo "FAIL: unconditioned open on a frozen checkout must fail, got exit 0: $OUT_1" >&2
    exit 1
fi
if ! grep -q 'под freeze (WP-520)' <<<"$OUT_1"; then
    echo "FAIL: expected freeze message, got: $OUT_1" >&2
    exit 1
fi
if [ -f "$TEST_ROOT/.iwe-runtime/sessions/fixture-"*.open ] 2>/dev/null; then
    echo "FAIL: a blocked open must not leave a semaphore behind" >&2
    exit 1
fi

# 2. --canonical-owner bypasses unconditionally, even with no prior session --
#    this is the launchd/cron carve-out (kimi-wp-run-scheduled.sh,
#    wp-run-scheduled-tsekh1.sh), which by construction never has a live
#    lease to re-enter on its first run of the day.
if ! OUT_2=$(open_frozen --wp WP-901 --task fixture --slug sched-1 --agent scheduler --canonical-owner "launchd-scheduled" 2>&1); then
    echo "FAIL: --canonical-owner must bypass freeze unconditionally, got: $OUT_2" >&2
    exit 1
fi
if ! find "$TEST_ROOT/.iwe-runtime/sessions" -name 'scheduler-*.open' -type f | grep -q .; then
    echo "FAIL: --canonical-owner open must still create a semaphore" >&2
    exit 1
fi

# 3. Exact-slug re-entry: same agent, same WP, same slug as an existing live
#    semaphore -- must be allowed through (crash-resume case).
#
# A fresh slug on the frozen path must itself fail first (no live semaphore
# yet to re-enter -- same rule as case 1), which is also why the fixture has
# to plant a semaphore by hand below rather than create one through
# open_frozen(): that helper can't produce a live semaphore on this path.
if OUT_3=$(open_frozen --wp WP-902 --task fixture --slug resume-me --agent resumer 2>&1); then
    echo "FAIL: a fresh slug with no existing semaphore must still be blocked, got exit 0: $OUT_3" >&2
    exit 1
fi
mkdir -p "$TEST_ROOT/.iwe-runtime/sessions"
PLANTED="$TEST_ROOT/.iwe-runtime/sessions/resumer-1786700000.open"
cat > "$PLANTED" <<EOF
---
agent: resumer
wp: WP-902
slug: resume-me
opened_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
orz_sessions_dir: $FROZEN/sessions
---
EOF

if ! OUT_4=$(open_frozen --wp WP-902 --task fixture --slug resume-me --agent resumer 2>&1); then
    echo "FAIL: matching-slug re-entry on a live semaphore must be allowed, got: $OUT_4" >&2
    exit 1
fi

# 4. Different slug, same agent+WP as the planted live semaphore -- must
#    still block. This is the exact gap cold-context review caught in the
#    first draft (exception keyed on WP+agent alone let an unrelated new
#    `open` ride someone else's live lease).
if OUT_5=$(open_frozen --wp WP-902 --task fixture --slug different-slug --agent resumer 2>&1); then
    echo "FAIL: a different slug must NOT ride the planted semaphore's lease, got exit 0: $OUT_5" >&2
    exit 1
fi
if ! grep -q 'под freeze (WP-520)' <<<"$OUT_5"; then
    echo "FAIL: expected freeze message for mismatched slug, got: $OUT_5" >&2
    exit 1
fi

echo "PASS: session-guard freeze enforcement (block, --canonical-owner, exact-slug re-entry, mismatched-slug still blocks)"
