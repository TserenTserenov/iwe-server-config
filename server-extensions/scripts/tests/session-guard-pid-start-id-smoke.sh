#!/usr/bin/env bash
# session-guard-pid-start-id-smoke.sh -- WP-530 F160 step 2 for the ordinary
# (non-housekeeping) open: the guard writes the locale-independent owner
# identity `pid_start_id:` next to the legacy `pid_start:`, keeps the legacy
# field in its old format, keeps the semaphore private (0600) when renew
# rewrites it, and rewrites only the frontmatter `pid:` line.
# (Housekeeping open and renew of a legacy record: session-guard-runner-session-smoke.sh.)
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
# shellcheck source=../lib/process-identity.sh
. "$ROOT_DIR/scripts/lib/process-identity.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-pid-start-id.XXXXXX")
trap 'rm -r "$TEST_ROOT" 2>/dev/null || true' EXIT
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)

fail() { echo "FAIL: $*" >&2; exit 1; }

GOV="$TEST_ROOT/DS-strategy"
SES="$TEST_ROOT/MC-sessions"
mkdir -p "$GOV/inbox/WP-999" "$SES"
printf '%s\n' 'hypothesis_relation: "tests"' > "$GOV/inbox/WP-999/WP-999.md"
for repo in "$GOV" "$SES"; do
  git -C "$repo" init -q
  git -C "$repo" config user.email test@test.local
  git -C "$repo" config user.name test
  echo seed > "$repo/README"
  git -C "$repo" add README
  git -C "$repo" commit -q -m seed
done

guard() {
  (cd "$SES" && CLAUDE_CODE_SESSION_ID="pid-start-id-fixture" IWE_ROOT="$TEST_ROOT" \
    IWE_GOVERNANCE_REPO=DS-strategy IWE_FROZEN_CANONICAL_PATH="" \
    IWE_SESSIONS_ROOT="$SES" bash "$GUARD" "$@")
}

guard open --wp WP-999 --agent fixture --slug pid-id --task pid-id --owner-pid $$ >"$TEST_ROOT/open.out" 2>&1 \
  || fail "open failed: $(cat "$TEST_ROOT/open.out")"
SEM=$(find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' | head -1)
[ -n "$SEM" ] || fail "the session semaphore was not created"

OWN_ID=$(process_identity $$)
LEGACY_START=$(LC_ALL=C ps -p $$ -o lstart= | sed 's/^ *//; s/ *$//')
grep -qx "pid: $$" "$SEM" || fail "pid must be the owner pid"
grep -qx "pid_start: $LEGACY_START" "$SEM" || fail "legacy pid_start must keep its old format"
grep -qx "pid_start_id: $OWN_ID" "$SEM" || fail "pid_start_id must equal the owner identity [$OWN_ID]: $(grep '^pid_start' "$SEM")"
[ "$(process_identity_verdict "$OWN_ID" $$)" = match ] || fail "the recorded identity must match the live owner"
echo "OK: ordinary open writes pid_start_id next to an unchanged legacy pid_start"

# A pre-F160 record (no pid_start_id) with a body line that looks like `pid:`:
# renew adds the field once, touches only the frontmatter and stays 0600.
grep -v '^pid_start_id: ' "$SEM" >"$SEM.legacy"
printf 'pid: 77\n' >>"$SEM.legacy"
mv "$SEM.legacy" "$SEM"
chmod 600 "$SEM"
CLAUDE_PID=$$ guard note-file README --agent fixture --slug pid-id >"$TEST_ROOT/note.out" 2>&1 \
  || fail "note-file failed: $(cat "$TEST_ROOT/note.out")"
[ "$(grep -c '^pid_start_id: ' "$SEM")" -eq 1 ] || fail "renew must add exactly one pid_start_id"
grep -qx "pid_start_id: $OWN_ID" "$SEM" || fail "renew must add the owner identity"
grep -qx 'pid: 77' "$SEM" || fail "a body line must not be rewritten"
grep -qx "pid_start: $LEGACY_START" "$SEM" || fail "renew must not touch the legacy pid_start"
# GNU stat first: on Linux `stat -f` succeeds but describes the file system.
mode=$(stat -c '%a' "$SEM" 2>/dev/null || stat -f '%Lp' "$SEM")
[ "$mode" = 600 ] || fail "renew must keep the semaphore private (0600), got $mode"
echo "OK: renew upgrades a legacy record once, frontmatter only, mode 0600 kept"

echo "PASS: session-guard writes pid_start_id on open and renew (WP-530 F160)"
