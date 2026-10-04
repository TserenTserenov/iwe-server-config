#!/usr/bin/env bash
# sync-strategy-files-no-unpublished-local-commit-smoke.sh -- function-level guard for
# no_unpublished_local_commit() of sync-strategy-files.sh (WP-530, Codex review 04.10.2026):
# a real git error (not "zero matching commits") must be read as "cannot prove it's safe",
# not as "safe to remove" -- the exact direction a fail-open mistake would take. The removal
# loop's own end-to-end scenario 9 covers the SIGPIPE/pipefail shape with a real 1500-commit
# history; this covers the "the check command itself fails" shape directly, with a stubbed git
# that fails on demand, since reproducing a real git object error end-to-end collides with other
# git operations (fetch's own "have" negotiation also walks local history and aborts first).
# Usage: sync-strategy-files-no-unpublished-local-commit-smoke.sh [path-to-sync-strategy-files.sh]
set -uo pipefail
SRC="${1:-$(cd "$(dirname "$0")" && pwd)/../sync-strategy-files.sh}"
[ -r "$SRC" ] || { echo "FAIL: cannot read $SRC"; exit 1; }

fails=0
assert() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }

REMOTE=origin
BRANCH=main
# shellcheck disable=SC1090
eval "$(sed -n '/^# BEGIN-NO-UNPUBLISHED-LOCAL-COMMIT/,/^# END-NO-UNPUBLISHED-LOCAL-COMMIT/p' "$SRC")"
command -v no_unpublished_local_commit >/dev/null || { echo "FAIL: extraction failed"; exit 1; }

echo "## 1. git reports no matching commit (clean output, exit 0) -> safe (true)"
git() { [ "$1" = rev-list ] && { :; return 0; }; command git "$@"; }
no_unpublished_local_commit "current/DayPlan.md"
assert "$?" "0" "no local-only commit -> proceed"

echo "## 2. git finds a matching commit (one SHA line, exit 0) -> not safe (false)"
git() { [ "$1" = rev-list ] && { echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"; return 0; }; command git "$@"; }
no_unpublished_local_commit "current/DayPlan.md"
assert "$?" "1" "a local-only commit exists -> block"

echo "## 3. the check command itself fails (a real git error, exit 128) -> fail CLOSED, not safe"
git() { [ "$1" = rev-list ] && return 128; command git "$@"; }
no_unpublished_local_commit "current/DayPlan.md"
assert "$?" "1" "a failed check must not be read as safe -- this is the exact Codex finding's direction"

echo "## 4. a long output (the real SIGPIPE/pipefail shape, simulated without an actual pipe here)"
git() { [ "$1" = rev-list ] && { for i in $(seq 1 2000); do echo "deadbeef$i"; done; return 0; }; command git "$@"; }
no_unpublished_local_commit "current/DayPlan.md"
assert "$?" "1" "many lines, still correctly read as 'a local-only commit exists'"

[ "$fails" -eq 0 ] && { echo "PASS: no_unpublished_local_commit"; exit 0; }
echo "FAIL: $fails check(s)"; exit 1
