#!/usr/bin/env bash
# WP-530 F160 step 3: `close --housekeeping <reason> --prove-owner-dead` closes the
# barrier only when the guard itself, under the session transition lock, proves the
# recorded owner dead from pid + pid_start_id (scripts/lib/process-identity.sh).
# match / unknown / a record without pid_start_id are refused with code 3 and the
# record stays open; the verdict does not depend on the caller's locale or time zone.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-hk-prove-dead.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
LIVE_PID=""
trap '[ -z "$LIVE_PID" ] || kill "$LIVE_PID" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT

GOV="$TEST_ROOT/DS-strategy"
SESSION_DIR="$TEST_ROOT/.iwe-runtime/sessions"
mkdir -p "$GOV/sessions" "$SESSION_DIR" "$TEST_ROOT/bin" "$TEST_ROOT/scripts"
git -C "$GOV" init -q
export IWE_SESSIONS_ROOT="$GOV/sessions" IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=DS-strategy
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/bin/iwe-tg"
chmod +x "$TEST_ROOT/bin/iwe-tg"

SEM="$SESSION_DIR/claude-code-housekeeping-hk-dead.open"
fail() { echo "FAIL: $*" >&2; exit 1; }
guard() { ( cd "$GOV" && PATH="$TEST_ROOT/bin:$PATH" bash "$GUARD" "$@" ) 2>&1; }
open_hk() { # <owner pid>
  rm -f "$SEM" "$SEM.closed"
  guard open --housekeeping hk-dead --agent claude-code --canonical-owner hk-dead --owner-pid "$1" >/dev/null \
    || fail "open must succeed for owner pid $1"
}
sid() { sed -n 's/^session_id: //p' "$SEM" | head -1; }
close_proving() { guard close --housekeeping hk-dead --agent claude-code --expect-session-id "$(sid)" --prove-owner-dead; }
expect_refused() { # <label>
  local out rc
  cp "$SEM" "$TEST_ROOT/record.before"
  set +e; out=$(close_proving); rc=$?; set -e
  [ "$rc" = 3 ] || fail "$1: must exit 3, got $rc: $out"
  [ -f "$SEM" ] && [ ! -e "$SEM.closed" ] || fail "$1: the record must stay open"
  cmp -s "$SEM" "$TEST_ROOT/record.before" || fail "$1: the record bytes changed on refusal"
  printf '%s' "$out" | grep -q -- "--prove-owner-dead отказ" || fail "$1: reason missing: $out"
}

sleep 300 &
LIVE_PID=$!

# 1. A live owner: the identity matches -> refused, even under a foreign locale and zone.
open_hk "$LIVE_PID"
grep -q '^pid_start_id: ' "$SEM" || fail "open must record pid_start_id"
expect_refused "live owner"
set +e; OUT=$( cd "$GOV" && LC_ALL=ru_RU.UTF-8 LC_TIME=ru_RU.UTF-8 TZ=Pacific/Auckland PATH="$TEST_ROOT/bin:$PATH" \
  bash "$GUARD" close --housekeeping hk-dead --agent claude-code --expect-session-id "$(sid)" --prove-owner-dead 2>&1 ); RC=$?; set -e
[ "$RC" = 3 ] && [ -f "$SEM" ] || fail "live owner under a foreign locale/zone must still be refused, got $RC: $OUT"

# 2. A record that predates pid_start_id: refused (no fallback to lstart), the pid is not even consulted.
grep -v '^pid_start_id: ' "$SEM" > "$SEM.tmp" && mv "$SEM.tmp" "$SEM"
expect_refused "record without pid_start_id"
OUT=$(close_proving 2>&1 || true)
printf '%s' "$OUT" | grep -q "нет pid_start_id" || fail "the refusal must name the missing pid_start_id: $OUT"

# 3. Same pid, different start (pid reuse): proven dead -> closed.
open_hk "$LIVE_PID"
RECORDED=$(sed -n 's/^pid_start_id: //p' "$SEM")
BUMPED="${RECORDED%:*}:$(( ${RECORDED##*:} + 1 ))"
sed "s|^pid_start_id: .*|pid_start_id: $BUMPED|" "$SEM" > "$SEM.tmp" && mv "$SEM.tmp" "$SEM"
OUT=$(close_proving) || fail "reused pid must be proven dead and closed, got: $OUT"
[ ! -e "$SEM" ] && [ -f "$SEM.closed" ] || fail "reused pid: only the terminal receipt may remain"

# 4. A malformed identity -> unknown -> refused.
open_hk "$LIVE_PID"
sed "s|^pid_start_id: .*|pid_start_id: garbage|" "$SEM" > "$SEM.tmp" && mv "$SEM.tmp" "$SEM"
expect_refused "malformed pid_start_id"
OUT=$(close_proving 2>&1 || true)
printf '%s' "$OUT" | grep -q 'вердикт «unknown» для pid' || fail "an unknown verdict must be named in the refusal: $OUT"
OUT=$( cd "$GOV" && LC_ALL=en_US.UTF-8 PATH="$TEST_ROOT/bin:$PATH" bash "$GUARD" close --housekeeping hk-dead --agent claude-code --expect-session-id "$(sid)" --prove-owner-dead 2>&1 || true )
printf '%s' "$OUT" | grep -q 'вердикт «unknown» для pid' || fail "the reason must be intact under a UTF-8 locale: $OUT"

# 4b. Duplicated fields are ambiguous: refused, never read as "the first one".
open_hk "$LIVE_PID"
printf 'pid: 1\n' >> "$SEM"
expect_refused "duplicated pid"
open_hk "$LIVE_PID"
# The second copy names a DEAD identity (same pid, other start): a reader that takes the last
# (or first) occurrence would close a live owner; the ambiguous record must be refused instead.
DUP_ID=$(sed -n 's/^pid_start_id: //p' "$SEM" | head -1)
printf 'pid_start_id: %s:%s\n' "${DUP_ID%:*}" "$(( ${DUP_ID##*:} + 1 ))" >> "$SEM"
expect_refused "duplicated pid_start_id"

# 5. The owner is gone: pid absent -> dead -> closed.
sleep 300 & DEAD_PID=$!
open_hk "$DEAD_PID"
kill "$DEAD_PID"
wait "$DEAD_PID" 2>/dev/null || true
OUT=$(close_proving) || fail "an exited owner must be proven dead and closed, got: $OUT"
[ ! -e "$SEM" ] && [ -f "$SEM.closed" ] || fail "dead owner: only the terminal receipt may remain"

# 6. Without the flag the old behaviour is untouched: an expected-id close of a live owner's record still works.
open_hk "$LIVE_PID"
OUT=$(guard close --housekeeping hk-dead --agent claude-code --expect-session-id "$(sid)") \
  || fail "close without the flag must keep its old behaviour, got: $OUT"
[ -f "$SEM.closed" ] || fail "close without the flag must close"

# 6b. Without the flag a dead owner's record closes as before (the flag adds a proof, removes nothing).
sleep 300 & DEAD2=$!
open_hk "$DEAD2"; kill "$DEAD2"; wait "$DEAD2" 2>/dev/null || true
OUT=$(guard close --housekeeping hk-dead --agent claude-code --expect-session-id "$(sid)") \
  || fail "close without the flag must keep working for a dead owner, got: $OUT"
[ -f "$SEM.closed" ] || fail "close without the flag must close a dead owner's record"

# 7. The flag outside close --housekeeping is refused, not ignored.
set +e; OUT=$(guard renew --wp WP-1 --prove-owner-dead); RC=$?; set -e
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q -- "--prove-owner-dead применяется только" \
  || fail "flag outside close --housekeeping must be refused, got $RC: $OUT"

echo "PASS: session-guard close --housekeeping --prove-owner-dead"
