#!/usr/bin/env bash
# Regression for WP-539 Ф21 Б4 (DRR-f21-b4-session-lock, peer-session
# 2026-11-03-19-wp539-b4-session-lock): `open` in the modes that touch the
# shared checkout (--canonical-owner with and without --housekeeping,
# --isolate) takes the shared ds-commit.lock first, so the sync's under-lock
# session re-check cannot miss a record published in its check-to-use window.
#
# Cases (each asserts an observable outcome, not just an exit code):
#   1. lock held elsewhere -> housekeeping --canonical-owner open refuses with
#      the busy message and publishes no record;
#   2. same for a plain --canonical-owner open;
#   3. lock free -> open succeeds, and right after it returns an independent
#      `flock -n` gets the lock (no inherited hold by the guard or its
#      detached children);
#   4. open --isolate waits for a held lock and completes once it is released
#      (record published only after the release);
#   5. an open without --canonical-owner/--isolate does not take the lock.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
FLOCK=$(command -v flock || true)
[ -n "$FLOCK" ] || { echo "SKIP: flock not installed"; exit 0; }
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-ds-commit-lock.XXXXXX")
HOLDER_PID=""
cleanup() {
    [ -z "$HOLDER_PID" ] || kill "$HOLDER_PID" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

LOCK="$TEST_ROOT/.claude/state/ds-commit.lock"
mkdir -p "$(dirname "$LOCK")"
SESSIONS="$TEST_ROOT/.iwe-runtime/sessions"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# Governance fixture with a real origin, so --isolate can fetch and add a worktree.
ORIGIN="$TEST_ROOT/origin.git"
GOV="$TEST_ROOT/gov"
git init -q --bare "$ORIGIN"
git init -q -b main "$GOV"
git -C "$GOV" config user.email test@example.com
git -C "$GOV" config user.name test
mkdir -p "$GOV/inbox/WP-900"
echo "# WP-900" > "$GOV/inbox/WP-900/WP-900.md"
git -C "$GOV" add inbox
git -C "$GOV" commit -qm seed
git -C "$GOV" remote add origin "$ORIGIN"
git -C "$GOV" push -q -u origin main
# Session journal files go to MC-sessions, not into the governance checkout
# (otherwise later --isolate opens see a dirty base).
git init -q "$TEST_ROOT/MC-sessions"

guard() {
    (cd "$GOV" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO=gov IWE_FROZEN_CANONICAL_PATH="" \
        DS_COMMIT_LOCK_FILE="$LOCK" IWE_DS_COMMIT_LOCK_WAIT_SEC="${WAIT:-2}" \
        bash "$GUARD" "$@")
}

hold_lock() {  # <seconds>
    # `exec sleep` makes the holder ONE process: killing a `flock cmd` wrapper
    # would leave its `sleep` child holding the inherited descriptor.
    ( exec 9>"$LOCK"; "$FLOCK" 9; exec sleep "$1" ) &
    HOLDER_PID=$!
    for _ in $(seq 1 50); do
        "$FLOCK" -n "$LOCK" true 2>/dev/null || return 0
        sleep 0.1
    done
    echo "holder never took the lock" >&2
    exit 1
}
release_lock() {
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
    HOLDER_PID=""
}

echo "1. housekeeping --canonical-owner refuses while the lock is held"
hold_lock 30
if OUT=$(WAIT=1 guard open --housekeeping hk1 --agent fixture --owner-pid "$$" --canonical-owner fixture-hk 2>&1); then
    bad "open succeeded under a held lock: $OUT"
elif ! grep -q 'занята синхронизацией или публикацией' <<<"$OUT"; then
    bad "expected busy message, got: $OUT"
elif [ -e "$SESSIONS/fixture-housekeeping-hk1.open" ]; then
    bad "refused open left a record behind"
else
    ok "refused with busy message, no record"
fi

echo "2. plain --canonical-owner refuses while the lock is held"
if OUT=$(WAIT=1 guard open --wp WP-900 --task t --slug co-1 --agent sched --owner-pid "$$" --canonical-owner fixture-co 2>&1); then
    bad "open succeeded under a held lock: $OUT"
elif compgen -G "$SESSIONS/sched-*.open" >/dev/null; then
    bad "refused open left a record behind"
else
    ok "refused, no record"
fi
release_lock

echo "3. lock free: open succeeds and leaves no inherited hold"
if ! OUT=$(guard open --housekeeping hk2 --agent fixture --owner-pid "$$" --canonical-owner fixture-hk 2>&1); then
    bad "open failed with a free lock: $OUT"
elif [ ! -f "$SESSIONS/fixture-housekeeping-hk2.open" ]; then
    bad "record not published"
elif ! "$FLOCK" -n "$LOCK" true; then
    bad "lock still held after open returned (inherited by a child?)"
else
    ok "record published, lock free right after"
fi

echo "4. --isolate waits for the lock and publishes only after release"
hold_lock 30
( WAIT=20 IWE_SESSION_ID=0123456789abcdef0123456789abcdef \
    guard open --wp WP-900 --task t --slug iso-1 --agent iso --isolate >"$TEST_ROOT/iso.out" 2>&1
  echo $? >"$TEST_ROOT/iso.rc" ) &
ISO_PID=$!
sleep 2
if compgen -G "$SESSIONS/iso-*.open" >/dev/null; then
    bad "isolate record published while the lock was held"
else
    ok "no record while the lock is held"
fi
release_lock
wait "$ISO_PID" || true
if [ "$(cat "$TEST_ROOT/iso.rc" 2>/dev/null)" != 0 ]; then
    bad "isolate open did not complete after release: $(tail -3 "$TEST_ROOT/iso.out")"
elif ! compgen -G "$SESSIONS/iso-*.open" >/dev/null; then
    bad "isolate record missing after release"
elif ! "$FLOCK" -n "$LOCK" true; then
    bad "lock still held after isolate open returned"
else
    ok "completed after release, lock free"
fi

echo "5. open without --canonical-owner/--isolate ignores the lock"
hold_lock 30
if ! OUT=$(WAIT=1 IWE_SESSION_ID=fedcba9876543210fedcba9876543210 \
        guard open --housekeeping hk3 --agent other --owner-pid "$$" 2>&1); then
    bad "plain housekeeping open blocked by ds-commit.lock: $OUT"
elif [ ! -f "$SESSIONS/other-housekeeping-hk3.open" ]; then
    bad "plain housekeeping record missing"
else
    ok "plain open unaffected"
fi
release_lock

echo "6. no network fetch runs while open holds the lock (--isolate, --isolate --base-sha, --canonical-owner)"
# A git wrapper logs every fetch; a fetch made while the lock is taken by the
# guard shows up as `under-lock` (the wrapper's own `flock -n` fails then).
REAL_GIT=$(command -v git)
WRAP_BIN="$TEST_ROOT/wrap-bin"
FETCH_LOG="$TEST_ROOT/fetch.log"
mkdir -p "$WRAP_BIN"
cat > "$WRAP_BIN/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    if [ "\$arg" = fetch ]; then
        if "$FLOCK" -n "$LOCK" true 2>/dev/null; then echo free >> "$FETCH_LOG"; else echo under-lock >> "$FETCH_LOG"; fi
        break
    fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$WRAP_BIN/git"
BASE=$(git -C "$GOV" rev-parse HEAD)
# Case 3 left a canonical owner open; a second --canonical-owner is refused by design.
guard close --housekeeping hk2 --agent fixture >/dev/null 2>&1 \
    || { bad "cannot close the case-3 housekeeping record"; }
: > "$FETCH_LOG"
PATH="$WRAP_BIN:$PATH" IWE_SESSION_ID=11111111111111111111111111111111 \
    guard open --wp WP-900 --task t --slug iso-2 --agent iso2 --isolate >/dev/null 2>&1 || true
PATH="$WRAP_BIN:$PATH" IWE_SESSION_ID=22222222222222222222222222222222 \
    guard open --wp WP-900 --task t --slug iso-3 --agent iso3 --isolate --base-sha "$BASE" >"$TEST_ROOT/iso3.out" 2>&1 || true
PATH="$WRAP_BIN:$PATH" guard open --wp WP-900 --task t --slug co-2 --agent sched2 --owner-pid "$$" \
    --canonical-owner fixture-co2 >"$TEST_ROOT/sched2.out" 2>&1 || true
if grep -q under-lock "$FETCH_LOG"; then
    bad "a fetch ran under ds-commit.lock: $(tr '\n' ' ' < "$FETCH_LOG")"
elif ! grep -q free "$FETCH_LOG"; then
    bad "no fetch observed at all -- the wrapper was not used"
elif ! compgen -G "$SESSIONS/iso3-*.open" >/dev/null || ! compgen -G "$SESSIONS/sched2-*.open" >/dev/null; then
    bad "base-sha or canonical-owner open did not publish its record: $(grep -v SESSIONS_SPLIT "$TEST_ROOT/iso3.out" "$TEST_ROOT/sched2.out" | tail -4)"
else
    ok "all fetches ran outside the lock ($(grep -c free "$FETCH_LOG") observed)"
fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
