#!/usr/bin/env bash
# session-guard-open-foreign-isolate-smoke.sh -- WP-561 (26.10): `open` without --isolate from
# inside another live session's isolated worktree used to record that worktree as the new
# session's governance checkout, so two sessions wrote into one copy. It must refuse, while the
# owner itself re-entering (same agent + WP + slug) and a dead owner's leftover directory stay allowed.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-foreign-isolate.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

SESS="$TEST_ROOT/.iwe-runtime/sessions"
FOREIGN="$TEST_ROOT/.iwe-runtime/isolated-worktrees/kimi-foreign"
mkdir -p "$TEST_ROOT/DS-strategy/inbox/WP-999" "$SESS" "$FOREIGN" "$TEST_ROOT/MC-sessions"
printf '%s\n' 'hypothesis_relation: "tests"' > "$TEST_ROOT/DS-strategy/inbox/WP-999/WP-999.md"
git -C "$FOREIGN" init -q
git -C "$TEST_ROOT/MC-sessions" init -q
# Keep ORZ scaffolds inside the sandbox even when the caller exports IWE_SESSIONS_ROOT.
export IWE_SESSIONS_ROOT="$TEST_ROOT/MC-sessions"

fail() { echo "FAIL: $*" >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
write_owner() { # <opened_at>
    printf -- '---\nagent: kimi\nwp: WP-999\nslug: owner-slug\nsession_id: foreign\nopened_at: %s\ncreated_at: %s\n---\n' \
        "$1" "$1" > "$SESS/kimi-foreign.open"
}
drop_new_semaphores() { find "$SESS" -name '*.open' ! -name 'kimi-foreign.open' -type f -delete; }
open_from_foreign() { # <out file> <open args...>; sets RC without tripping set -e
    local out="$1"; shift
    RC=0
    (cd "$FOREIGN" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" IWE_FROZEN_CANONICAL_PATH="" \
        CODEX_THREAD_ID="aaaaaaaa-1111-2222-3333-444444444444" IWE_SESSION_ID="${OPEN_SESSION_ID:-}" \
        bash "$GUARD" open "$@") >"$out" 2>&1 || RC=$?
}
REFUSAL='изолят чужой живой сессии'

# 1. Live owner, a different agent/session opens from inside its isolate: refused.
write_owner "$(now)"
open_from_foreign "$TEST_ROOT/out1" --wp WP-999 --agent codex --slug intruder
[ "$RC" -ne 0 ] || fail "open from another live session's isolate must be refused: $(cat "$TEST_ROOT/out1")"
grep -q "$REFUSAL" "$TEST_ROOT/out1" || fail "refusal must name the foreign isolate: $(cat "$TEST_ROOT/out1")"
echo "OK: open from a live foreign isolate is refused"

# 2. Another agent reusing the owner's WP+slug is still foreign.
open_from_foreign "$TEST_ROOT/out2" --wp WP-999 --agent codex --slug owner-slug
[ "$RC" -ne 0 ] || fail "same WP+slug under a different agent must be refused: $(cat "$TEST_ROOT/out2")"
grep -q "$REFUSAL" "$TEST_ROOT/out2" || fail "refusal must name the foreign isolate: $(cat "$TEST_ROOT/out2")"
echo "OK: matching WP+slug does not excuse a different agent"

# 3. The owner itself (same agent + WP + slug) re-entering is allowed and really opens.
OPEN_SESSION_ID=kimi-reentry open_from_foreign "$TEST_ROOT/out3" --wp WP-999 --agent kimi --slug owner-slug
[ "$RC" -eq 0 ] || fail "owner re-entry must succeed: $(cat "$TEST_ROOT/out3")"
grep -q 'Session OPEN' "$TEST_ROOT/out3" || fail "owner re-entry must open a session: $(cat "$TEST_ROOT/out3")"
drop_new_semaphores
echo "OK: the owner re-enters with the same agent+WP+slug"

# 4. Owner semaphore expired (lease over): the directory is a leftover, not a live session.
write_owner "2020-01-01T00:00:00Z"
open_from_foreign "$TEST_ROOT/out4" --wp WP-999 --agent codex --slug heir
[ "$RC" -eq 0 ] || fail "an expired owner must not block a new session: $(cat "$TEST_ROOT/out4")"
grep -q 'Session OPEN' "$TEST_ROOT/out4" || fail "new session must open next to an expired owner: $(cat "$TEST_ROOT/out4")"
echo "OK: an expired owner's isolate is not treated as a live foreign session"

echo "PASS: open refuses to start from another live session's isolated worktree"
