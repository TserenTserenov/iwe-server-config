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
