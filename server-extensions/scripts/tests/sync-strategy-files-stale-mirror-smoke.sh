#!/usr/bin/env bash
# Regression for WP-5 F42-B recurrence (peer-session 2026-09-12-17): a mirror
# staged by sync-strategy-files.sh from an older origin/main tip must be
# refreshed to the current origin content (its own dirty-skip previously locked
# it forever), while human staged/unstaged work on the same paths must never
# be touched.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# SCRIPT_UNDER_TEST override exists for mutation runs (point it at an old
# version and the test must fail).
SCRIPT="${SCRIPT_UNDER_TEST:-$ROOT_DIR/scripts/sync-strategy-files.sh}"
REAL_GIT=$(command -v git)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sync-strategy-stale-mirror.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] || fail "$label — expected '$expected', got '$actual'"
}

assert_contains() {
  local label="$1" text="$2" needle="$3"
  case "$text" in
    *"$needle"*) ;;
    *) fail "$label — missing '$needle' in: $text" ;;
  esac
}

ORIGIN="$TEST_ROOT/origin.git"
SEED="$TEST_ROOT/seed"
CANON="$TEST_ROOT/canon"

"$REAL_GIT" init --bare -q -b main "$ORIGIN"
"$REAL_GIT" init -q -b main "$SEED"
"$REAL_GIT" -C "$SEED" config user.name fixture
"$REAL_GIT" -C "$SEED" config user.email fixture@example.invalid
mkdir -p "$SEED/inbox/WP-7" "$SEED/inbox/WP-8" "$SEED/inbox/WP-9"
printf 'v1 stale-mirror card\n' > "$SEED/inbox/WP-9/WP-9.md"
printf 'v1 human-staged card\n' > "$SEED/inbox/WP-8/WP-8.md"
printf 'v1 unstaged-edit card\n' > "$SEED/inbox/WP-7/WP-7.md"
"$REAL_GIT" -C "$SEED" add inbox
"$REAL_GIT" -C "$SEED" commit -qm v1
"$REAL_GIT" -C "$SEED" remote add origin "$ORIGIN"
"$REAL_GIT" -C "$SEED" push -q origin main

"$REAL_GIT" clone -q "$ORIGIN" "$CANON"
"$REAL_GIT" -C "$CANON" config user.name fixture
"$REAL_GIT" -C "$CANON" config user.email fixture@example.invalid

# Origin advances to v2; canon stages the v2 mirror the same way the script
# does it (checkout from origin tree = staged content, HEAD stays at v1).
printf 'v2 stale-mirror card\n' > "$SEED/inbox/WP-9/WP-9.md"
"$REAL_GIT" -C "$SEED" commit -qam v2
"$REAL_GIT" -C "$SEED" push -q origin main
"$REAL_GIT" -C "$CANON" fetch -q origin main
"$REAL_GIT" -C "$CANON" checkout -q origin/main -- inbox/WP-9/WP-9.md

# Origin advances again to v3 -- the staged v2 mirror is now stale.
printf 'v3 stale-mirror card\n' > "$SEED/inbox/WP-9/WP-9.md"
"$REAL_GIT" -C "$SEED" commit -qam v3
"$REAL_GIT" -C "$SEED" push -q origin main

# Human work that must survive untouched: a staged edit whose blob never
# existed on origin, and a mirror with an extra unstaged edit on top.
printf 'human staged local edit\n' > "$CANON/inbox/WP-8/WP-8.md"
"$REAL_GIT" -C "$CANON" add inbox/WP-8/WP-8.md
"$REAL_GIT" -C "$CANON" checkout -q origin/main -- inbox/WP-7/WP-7.md
printf 'extra unstaged line\n' >> "$CANON/inbox/WP-7/WP-7.md"

OUTPUT=$(bash "$SCRIPT" "$CANON" 2>&1) || fail "script exited non-zero: $OUTPUT"

assert_contains "stale mirror refresh logged" "$OUTPUT" "refreshed own stale mirror: inbox/WP-9/WP-9.md"
assert_eq "stale mirror refreshed to current origin" "v3 stale-mirror card" "$(cat "$CANON/inbox/WP-9/WP-9.md")"
assert_eq "human staged edit untouched" "human staged local edit" "$(cat "$CANON/inbox/WP-8/WP-8.md")"
assert_eq "mirror with unstaged edit untouched" "v1 unstaged-edit card
extra unstaged line" "$(cat "$CANON/inbox/WP-7/WP-7.md")"
assert_contains "both protected paths counted as dirty" "$OUTPUT" "skipped_dirty=2"

# Idempotence: a second run must find nothing left to refresh.
OUTPUT2=$(bash "$SCRIPT" "$CANON" 2>&1) || fail "second run exited non-zero: $OUTPUT2"
case "$OUTPUT2" in
  *"refreshed own stale mirror"*) fail "second run refreshed again — not idempotent: $OUTPUT2" ;;
esac

# Third protection (cold review, 2026-09-12): a blob that once lived on
# origin (check 4 would match it) but was ALSO introduced by a local-only
# commit must not be treated as our own mirror -- the contract's 5th check
# exists exactly to catch this. Build it on a second file so it stays
# independent of WP-9's state above.
#
# 1. origin has WP-5.md v1; canon clones/ff's to it (HEAD == origin's v1).
# 2. origin advances to v2 (canon does not fetch/merge it yet, so it will
#    show up as "current origin tip" only when the script under test fetches).
# 3. Locally, canon makes three commits none of which are on origin: L0
#    moves HEAD away from v1 (otherwise "reintroducing v1" is a no-op diff),
#    L1 reintroduces v1's exact bytes (-> same git blob as origin's
#    historical v1), L2 moves on to unrelated local content.
# 4. Staging v1 content again (dirty against HEAD=L2) must NOT be refreshed:
#    its blob already exists in local-only history (L1), so it reads as
#    human intent, not a leftover checkout from this script.
mkdir -p "$SEED/inbox/WP-5"
printf 'v1 governed card\n' > "$SEED/inbox/WP-5/WP-5.md"
"$REAL_GIT" -C "$SEED" add inbox/WP-5/WP-5.md
"$REAL_GIT" -C "$SEED" commit -qm "WP-5 v1"
"$REAL_GIT" -C "$SEED" push -q origin main
"$REAL_GIT" -C "$CANON" fetch -q origin main
"$REAL_GIT" -C "$CANON" merge -q --ff-only origin/main

printf 'v2 governed card\n' > "$SEED/inbox/WP-5/WP-5.md"
"$REAL_GIT" -C "$SEED" commit -qam "WP-5 v2"
"$REAL_GIT" -C "$SEED" push -q origin main

printf 'local-only kickoff, unrelated to origin\n' > "$CANON/inbox/WP-5/WP-5.md"
"$REAL_GIT" -C "$CANON" commit -qam "local-only: L0 kickoff edit"
printf 'v1 governed card\n' > "$CANON/inbox/WP-5/WP-5.md"
"$REAL_GIT" -C "$CANON" commit -qam "local-only: L1 reintroduce v1 content"
printf 'local-only wip, unrelated to origin\n' > "$CANON/inbox/WP-5/WP-5.md"
"$REAL_GIT" -C "$CANON" commit -qam "local-only: L2 unrelated follow-up edit"

printf 'v1 governed card\n' > "$CANON/inbox/WP-5/WP-5.md"
"$REAL_GIT" -C "$CANON" add inbox/WP-5/WP-5.md

OUTPUT3=$(bash "$SCRIPT" "$CANON" 2>&1) || fail "third run exited non-zero: $OUTPUT3"
case "$OUTPUT3" in
  *"refreshed own stale mirror: inbox/WP-5/WP-5.md"*)
    fail "third run clobbered a blob that already exists in local-only history: $OUTPUT3" ;;
esac
assert_eq "blob-in-local-history survives a sync tick" "v1 governed card" "$(cat "$CANON/inbox/WP-5/WP-5.md")"

echo "PASS: stale-mirror refresh contract holds (refresh + 3 protections + idempotence)"
