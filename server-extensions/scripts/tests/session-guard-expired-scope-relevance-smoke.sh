#!/usr/bin/env bash
# Regression for WP-530 Ф62/Ф68 (peer-session 2026-09-26-05-wp530-instant-
# sync-cleanup, Variant A, pilot-approved after Ф61/Ф62 analysis): the
# pre-commit-check EXPIRED-sessions block used to fire on the mere EXISTENCE
# of any expired semaphore anywhere in the system, unrelated to what's being
# committed now -- the live incident was extractor.sh's git-diff-feed: it
# opens its own valid housekeeping session and notes its own path, but the
# commit still fell into this same block (blocked, wrong error, wrong WPs
# listed) whenever an unrelated agent's session elsewhere had gone stale
# (bug-2026-09-{10,11,18,21,25}-git-diff-feed*.md). The fix makes the block
# relevance-aware: it only fires for an EXPIRED semaphore that itself claimed
# (via note-file) a path actually staged in THIS commit.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d /private/tmp/session-guard-expired-relevance.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

export IWE_ROOT="$TEST_ROOT/iwe"
REPO="$IWE_ROOT/gov-repo"
mkdir -p "$REPO/inbox/captures" "$REPO/some/unrelated"
git init -q "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/inbox/captures/2026-09.md"
printf 'seed\n' > "$REPO/some/unrelated/file.md"
git -C "$REPO" add inbox/captures/2026-09.md some/unrelated/file.md
git -C "$REPO" commit -q -m seed

SESS_DIR="$IWE_ROOT/.iwe-runtime/sessions"
mkdir -p "$SESS_DIR"

write_expired_semaphore() {  # <session-id> <wp> <claimed-path>
    # Filename must be exactly "<agent>-<session_id>.open" -- that's what
    # _locked_open_identity() (session-guard.sh) requires to accept a
    # semaphore as a real, non-housekeeping session at all; get this wrong
    # and the fixture silently falls into CLOSING/invalid instead of
    # EXPIRED, and the test would pass for the wrong reason.
    local session_id="$1" wp="$2" claimed="$3"
    local name="otheragent-${session_id}.open"
    cat > "$SESS_DIR/$name" <<EOF
---
agent: otheragent
personality: unassigned
wp: $wp
session_id: $session_id
created_at: 2020-01-01T00:00:00Z
pid: 999999
---
file: $claimed
EOF
    touch -t 202001010000 "$SESS_DIR/$name"
    printf '%s\n' "$name"
}

run_precommit() {
    (cd "$REPO" && IWE_ROOT="$IWE_ROOT" IWE_AGENT=testagent bash "$GUARD" pre-commit-check) 2>&1
}

# --- Scenario 1: no active session, one EXPIRED semaphore, but it claimed a
#     DIFFERENT path than what's being committed -- must NOT trigger the
#     "у открытых сессий истёк срок полномочий" block (the live bug).
SEM_1=$(write_expired_semaphore "irrelevant" "WP-999" "some/unrelated/file.md")
printf 'edit 1\n' >> "$REPO/inbox/captures/2026-09.md"
git -C "$REPO" add inbox/captures/2026-09.md
OUT_1=$(run_precommit) && RC_1=0 || RC_1=$?
if grep -q 'истёк срок полномочий' <<<"$OUT_1"; then
    echo "FAIL: irrelevant expired semaphore must not trigger the expired-sessions block: $OUT_1" >&2
    exit 1
fi
if [ "$RC_1" -ne 4 ] || ! grep -q 'Сессия не открыта по протоколу' <<<"$OUT_1"; then
    echo "FAIL: with no active session at all, expected the generic 'not opened' block (rc=4): rc=$RC_1 out=$OUT_1" >&2
    exit 1
fi
rm -f "$SESS_DIR/$SEM_1"
git -C "$REPO" reset -q --hard HEAD

# --- Scenario 2: no active session, one EXPIRED semaphore that DOES claim
#     the exact path being committed now -- must still block, with the
#     original informative message (this is a real, relevant expiry).
SEM_2=$(write_expired_semaphore "relevant" "WP-998" "inbox/captures/2026-09.md")
printf 'edit 2\n' >> "$REPO/inbox/captures/2026-09.md"
git -C "$REPO" add inbox/captures/2026-09.md
OUT_2=$(run_precommit) && RC_2=0 || RC_2=$?
if [ "$RC_2" -ne 4 ] || ! grep -q 'истёк срок полномочий' <<<"$OUT_2" || ! grep -q 'WP-998' <<<"$OUT_2"; then
    echo "FAIL: a genuinely relevant expired semaphore must still block, naming its WP: rc=$RC_2 out=$OUT_2" >&2
    exit 1
fi
rm -f "$SESS_DIR/$SEM_2"
git -C "$REPO" reset -q --hard HEAD

# --- Scenario 3 (no-regression control): an ACTIVE session for the current
#     agent still lets a matching commit through, regardless of how many
#     unrelated expired semaphores exist elsewhere.
write_expired_semaphore "irrelevant2" "WP-997" "some/unrelated/file.md" >/dev/null
(cd "$REPO" && IWE_ROOT="$IWE_ROOT" IWE_AGENT=testagent bash "$GUARD" \
    open --housekeeping ownreason --agent testagent --canonical-owner ownreason) >/dev/null 2>&1
(cd "$REPO" && IWE_ROOT="$IWE_ROOT" IWE_AGENT=testagent bash "$GUARD" \
    note-file inbox/captures/2026-09.md --housekeeping ownreason --agent testagent) >/dev/null 2>&1
printf 'edit 3\n' >> "$REPO/inbox/captures/2026-09.md"
git -C "$REPO" add inbox/captures/2026-09.md
OUT_3=$(run_precommit) && RC_3=0 || RC_3=$?
if [ "$RC_3" -ne 0 ]; then
    echo "FAIL: own active, correctly-scoped session must still pass regardless of unrelated expired sessions: rc=$RC_3 out=$OUT_3" >&2
    exit 1
fi

echo "PASS: session-guard pre-commit-check expired-scope relevance"
