#!/usr/bin/env bash
# kimi-standalone-preflight-smoke.sh -- WP-561 (26.10): the preflight used to adopt the NEWEST
# kimi-*.open as "its own", so a peer pipeline for another WP wrote into the isolate of a
# conversation that happened to hold the newest semaphore. With --wp/--slug/--session-id the
# semaphore must match every filter and be the only match.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PREFLIGHT="$ROOT_DIR/scripts/kimi-standalone-preflight.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kimi-preflight.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
SESS="$TEST_ROOT/.iwe-runtime/sessions"
mkdir -p "$SESS"

make_sem() { # <session_id> <wp> <slug> <age-rank: older sem gets an older mtime>
    printf -- '---\nagent: kimi\nwp: %s\nslug: %s\nsession_id: %s\n---\n' "$2" "$3" "$1" > "$SESS/kimi-$1.open"
}
run() { IWE_ROOT="$TEST_ROOT" bash "$PREFLIGHT" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

make_sem aaa WP-1 slug-a
touch -t 202601010000 "$SESS/kimi-aaa.open"
make_sem bbb WP-2 slug-b

# Legacy call: newest semaphore, but now with a warning on stderr.
out=$(run 2>"$TEST_ROOT/legacy.err") || fail "legacy call must still succeed"
grep -q 'kimi-bbb.open' <<< "$out" || fail "legacy call must pick the newest semaphore, got: $out"
grep -q 'WARNING' "$TEST_ROOT/legacy.err" || fail "legacy call must warn that the pick may be foreign"
echo "OK: unscoped call keeps the newest-semaphore pick and warns"

# Scoped call picks the matching OLDER semaphore, not the newest one.
out=$(run --wp WP-1) || fail "--wp WP-1 must succeed"
grep -q 'kimi-aaa.open' <<< "$out" || fail "--wp WP-1 must select kimi-aaa, got: $out"
grep -q 'kimi-bbb.open' <<< "$out" && fail "--wp WP-1 must not select the newest semaphore"
echo "OK: --wp selects its own semaphore even when another one is newer"

# Another conversation's semaphore does not count (the incident case).
if run --wp WP-568 >/dev/null 2>"$TEST_ROOT/miss.err"; then
    fail "--wp WP-568 with no WP-568 semaphore must fail, not adopt WP-1/WP-2"
fi
grep -q 'NOT OPEN for WP-568' "$TEST_ROOT/miss.err" || fail "failure message must name the WP: $(cat "$TEST_ROOT/miss.err")"
echo "OK: --wp with no own semaphore fails closed instead of adopting a foreign one"

# Two matches: refuse to guess.
make_sem ccc WP-1 slug-c
if run --wp WP-1 >/dev/null 2>"$TEST_ROOT/ambig.err"; then
    fail "two semaphores for WP-1 must be refused"
fi
grep -q 'refusing to guess' "$TEST_ROOT/ambig.err" || fail "ambiguity message missing"
out=$(run --wp WP-1 --slug slug-c) || fail "--wp + --slug must disambiguate"
grep -q 'kimi-ccc.open' <<< "$out" || fail "--wp + --slug must select kimi-ccc, got: $out"
out=$(run --session-id aaa) || fail "--session-id must select exactly one"
grep -q 'kimi-aaa.open' <<< "$out" || fail "--session-id aaa must select kimi-aaa, got: $out"
echo "OK: ambiguity is refused; --slug and --session-id disambiguate"

# Bad arguments are errors, not silently ignored.
if run --bogus >/dev/null 2>&1; then fail "unknown argument must fail"; fi
if run --wp >/dev/null 2>&1; then fail "--wp without a value must fail"; fi
# An empty value (an unset shell variable) must never degrade into the unscoped newest-semaphore pick.
for flag in --wp --slug --session-id; do
    if run "$flag" "" >/dev/null 2>"$TEST_ROOT/empty.err"; then fail "$flag with an empty value must fail"; fi
    grep -q 'non-empty value' "$TEST_ROOT/empty.err" || fail "$flag empty-value message missing: $(cat "$TEST_ROOT/empty.err")"
done
echo "OK: unknown flags, missing and empty values fail"

echo "PASS: kimi-standalone-preflight resolves its own semaphore by filters, never by recency alone"
