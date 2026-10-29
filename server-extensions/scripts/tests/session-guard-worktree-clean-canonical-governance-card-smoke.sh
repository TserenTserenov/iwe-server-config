#!/usr/bin/env bash
# Regression for WP-484 (found 2026-10-29, session claude-code-6808465a82f48140,
# slug WP-484-f265-root): _worktree_clean_status_sha() refused to close a
# worktree isolated from a repo OTHER than the governance repo (e.g. the root
# iwe-local-config checkout) when its terminal RUN-quick-close card sits in the
# CANONICAL governance repo's own inbox/agent/tasks -- not in a registered
# worktree reachable via IWE_GOVERNANCE_REPO_PATH, and not under the closing
# worktree's own inbox/agent/tasks. The function only accepted (1) the closing
# worktree's own tasks dir or (2) an explicitly verified governance *worktree*
# dir; the canonical governance repo's plain tasks dir -- the one close()
# itself already searches first and trusts, via RUNNER_CARD_DIRS[0] -- was not
# an accepted shape, so the close refused "isolated worktree не полностью
# clean" on an actually-clean tree.
#
#   W: canonical-governance-repo card + the new 4th argument -> clean, no refusal
#   X: same card, 4th argument omitted (pre-fix call shape) -> still refused (documents the bug this closes)
#   Y: card parent matches none of the three known locations -> still refused (else-branch untouched)
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-canonical-card.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

FUNC_HELPER="$TEST_ROOT/clean-status.sh"
python3 - "$GUARD" "$FUNC_HELPER" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = source.index("_worktree_clean_status_sha() {")
end = source.index("\n_isolated_source_commits_json() {", start)
body = source[start:end] + '\n_worktree_clean_status_sha "$@"\n'
Path(sys.argv[2]).write_text(body)
PY

# Closing worktree: a plain, unrelated repo (stands in for an isolate of the
# root iwe-local-config checkout -- any repo other than the governance one).
CLOSING="$TEST_ROOT/closing-worktree"
mkdir -p "$CLOSING"
git init -q "$CLOSING"
git -C "$CLOSING" config user.email test@example.com
git -C "$CLOSING" config user.name Test
echo "root work" > "$CLOSING/file.txt"
git -C "$CLOSING" add file.txt
git -C "$CLOSING" commit -qm "root repo work"

# Canonical governance repo: a SEPARATE physical repo, carrying the terminal
# RUN card in its own inbox/agent/tasks -- never registered as a worktree of
# $CLOSING, and no IWE_GOVERNANCE_REPO_PATH override is exercised here.
GOVERNANCE="$TEST_ROOT/DS-my-strategy"
mkdir -p "$GOVERNANCE/inbox/agent/tasks"
git init -q "$GOVERNANCE"
git -C "$GOVERNANCE" config user.email test@example.com
git -C "$GOVERNANCE" config user.name Test
echo "governance work" > "$GOVERNANCE/note.md"
git -C "$GOVERNANCE" add note.md
git -C "$GOVERNANCE" commit -qm "governance repo work"

CARD="$GOVERNANCE/inbox/agent/tasks/RUN-quick-close-wp484-root-smoke.md"
echo "card" > "$CARD"

# --- W: canonical governance cards dir passed as the 4th argument -> clean ---
OUT_W=$(bash "$FUNC_HELPER" "$CLOSING" "$CARD" "" "$GOVERNANCE/inbox/agent/tasks") \
  || fail "W: expected a clean-status digest, got refusal"
[ -n "$OUT_W" ] || fail "W: clean-status digest is empty"
echo "PASS: W -- canonical-governance-repo card accepted via the 4th argument, worktree reports clean"

# --- X: same card, pre-fix call shape (no 4th argument) -> still refused ---
if OUT_X=$(bash "$FUNC_HELPER" "$CLOSING" "$CARD" ""); then
  fail "X: expected refusal without the canonical-governance-cards argument, got: $OUT_X"
fi
echo "PASS: X -- without the new argument the same card is still refused (documents the bug)"

# --- Y: card parent matches none of the three known locations -> still refused ---
mkdir -p "$TEST_ROOT/elsewhere"
STRAY_CARD="$TEST_ROOT/elsewhere/RUN-quick-close-wp484-stray-smoke.md"
echo "stray" > "$STRAY_CARD"
if OUT_Y=$(bash "$FUNC_HELPER" "$CLOSING" "$STRAY_CARD" "" "$GOVERNANCE/inbox/agent/tasks"); then
  fail "Y: expected refusal for a card outside all three known locations, got: $OUT_Y"
fi
echo "PASS: Y -- a card outside the closing worktree, governance_cards and canonical governance dir is still refused"

echo "OK: session-guard worktree-clean accepts a canonical-governance-repo terminal card (W/X/Y)"
