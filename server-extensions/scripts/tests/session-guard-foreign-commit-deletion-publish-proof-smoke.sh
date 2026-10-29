#!/usr/bin/env bash
# Regression for WP-484 Ф265 (peer-session 2026-10-28-13-wp529-release-notice-check,
# live session-guard-release log): a claimed third-repo commit that DELETES a
# path read as "путь не найден ни в одном из проверяемых checkout" instead of
# as a delivered deletion. Root cause: _repo_scope_has_publish_proof's
# claimed_other_owners()/declared_owner() checked "does the tree AT that
# commit still contain the path" (`git ls-tree <commit> -- <path>`) for any
# declared checkout outside the root/sessions/governance set -- which answers
# empty/False for a commit that deletes the path, exactly backwards from "did
# this commit touch the path". The root/sessions branch right above it already
# used the correct diff-based commit_touched_path(); this exercises that the
# SAME rule now also covers an ordinary third-party repository claim.
#
#   U: a claimed third-repo commit DELETING a claimed path -> owners resolve, no refusal
#   V: the same commit ADDING the path (regression guard, must keep working)
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-foreign-deletion.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

PROOF_HELPER="$TEST_ROOT/scoped-proof.sh"
python3 - "$GUARD" "$PROOF_HELPER" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()

def span(start_marker, end_marker):
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    return source[start:end]

body = (span("normalize_remote_url() {", "\ngit_identity_matches() {")
        + "\n" + span("_resolve_repo_checkout() {", "\n_peer_metadata_claim_has_publish_proof() {")
        + "\n" + span("_repo_scope_has_publish_proof() {", "\n_repo_head_has_publish_proof() {")
        + '\n_repo_scope_has_publish_proof "$@"\n')
Path(sys.argv[2]).write_text(body)
PY

export IWE_ROOT="$TEST_ROOT"
REPO="$TEST_ROOT/DS-strategy"
SESSIONS="$TEST_ROOT/MC-sessions"
BOT="$TEST_ROOT/aist_bot"
mkdir -p "$REPO/inbox/WP-484"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
echo "governance note" > "$REPO/inbox/WP-484/note.md"
git -C "$REPO" add inbox/WP-484/note.md
git -C "$REPO" commit -qm "own governance work"
OWN_SHA=$(git -C "$REPO" rev-parse HEAD)
ORIGIN="$TEST_ROOT/origin.git"
git init -q --bare -b main "$ORIGIN"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q origin HEAD:main
REMOTE=$(git -C "$REPO" rev-parse origin/main)

mkdir -p "$SESSIONS"
git init -q "$SESSIONS"
git -C "$SESSIONS" config user.email test@example.com
git -C "$SESSIONS" config user.name Test
echo seed > "$SESSIONS/README.md"
git -C "$SESSIONS" add README.md
git -C "$SESSIONS" commit -qm init

make_semaphore() {  # <path> -- own governance scope + the bot's deleted path
  cat > "$1" <<EOF
governance_worktree: $REPO
orz_sessions_dir: $SESSIONS
file: inbox/WP-484/note.md
file: tests/test_template_update_notify_dedup.py
commit: $(basename "$REPO") $OWN_SHA
commit: aist_bot $BOT_SHA
EOF
}

# --- U: the bot claim DELETES the path (live shape of the finding).
mkdir -p "$BOT/tests"
git init -q "$BOT"
git -C "$BOT" config user.email test@example.com
git -C "$BOT" config user.name Test
printf "%s\n" "x = 1" > "$BOT/tests/test_template_update_notify_dedup.py"
git -C "$BOT" add tests/test_template_update_notify_dedup.py
git -C "$BOT" commit -qm "add test"
git -C "$BOT" rm -q tests/test_template_update_notify_dedup.py
git -C "$BOT" commit -qm "delete test (deletion delivered to pilot/new-architecture)"
BOT_SHA=$(git -C "$BOT" rev-parse HEAD)

SEM_U="$TEST_ROOT/semaphore-u"
make_semaphore "$SEM_U"
OUT_U=$(bash "$PROOF_HELPER" "$REPO" "governance checkout" "$SEM_U" "$REMOTE" \
  governance_worktree orz_sessions_dir "" "" 2>&1) && RC_U=0 || RC_U=$?
grep -qF "путь не найден ни в одном из проверяемых checkout" <<<"$OUT_U" \
  && fail "U: deleted path in a claimed third-repo commit still reads as owned by no checkout: $OUT_U"
[ "$RC_U" -eq 0 ] || fail "U: scoped publish proof refused a deletion delivered by its claimed commit (rc $RC_U): $OUT_U"
echo "PASS: U -- a claimed third-repo commit deleting a claimed path resolves ownership instead of refusing 'путь не найден'"

# --- V: same shape, the bot claim ADDS the path (regression guard for the
# branch already correct before this fix -- must keep passing).
rm -rf "$BOT"
mkdir -p "$BOT/tests"
git init -q "$BOT"
git -C "$BOT" config user.email test@example.com
git -C "$BOT" config user.name Test
printf "%s\n" "x = 1" > "$BOT/tests/test_template_update_notify_dedup.py"
git -C "$BOT" add tests/test_template_update_notify_dedup.py
git -C "$BOT" commit -qm "add test (delivered)"
BOT_SHA=$(git -C "$BOT" rev-parse HEAD)

SEM_V="$TEST_ROOT/semaphore-v"
make_semaphore "$SEM_V"
OUT_V=$(bash "$PROOF_HELPER" "$REPO" "governance checkout" "$SEM_V" "$REMOTE" \
  governance_worktree orz_sessions_dir "" "" 2>&1) && RC_V=0 || RC_V=$?
[ "$RC_V" -eq 0 ] || fail "V: scoped publish proof refused an ADD delivered by its claimed commit (rc $RC_V): $OUT_V"
echo "PASS: V -- a claimed third-repo commit adding a claimed path still resolves ownership (regression guard)"

echo "OK: session-guard scoped publish proof resolves foreign-repo deletions by commit (U/V)"
