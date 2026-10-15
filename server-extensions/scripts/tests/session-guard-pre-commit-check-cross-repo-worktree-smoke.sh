#!/usr/bin/env bash
# Regression for WP-530 Ф94 (11.10, root cause of the hard-block revert
# `9f222efd7` of `825d75b2c`): check 6a's worktree-mismatch comparison used
# to look at EVERY active semaphore on the host, regardless of which repo it
# actually belongs to. An isolated worktree registered for an UNRELATED
# repository still landed in REGISTERED_WORKTREES and could never match
# CURRENT_TOPLEVEL, flipping the warning for a commit that has nothing to do
# with that other session -- routine under WP-520 freeze, where several
# isolated worktrees of different WPs are open on one host at once. This
# test pins the fix: an active semaphore for a different repo (different
# origin, different git-common-dir) must not appear in the warning at all,
# while the actual bug check 6a exists for (same repo, wrong place) must
# keep warning.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-cross-repo-wt.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
# macOS resolves /tmp (and $TMPDIR) through a /private symlink; `git
# rev-parse --show-toplevel` returns the resolved form, so string-comparing
# against the raw mktemp path would mismatch on this host. Normalize once.
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)

# Repo B is the one receiving the commit under test (CURRENT_TOPLEVEL).
REPO_B="$TEST_ROOT/repo-b"
mkdir -p "$REPO_B"
git init -q "$REPO_B"
git -C "$REPO_B" config user.email test@example.com
git -C "$REPO_B" config user.name "Test"
git -C "$REPO_B" remote add origin "https://github.com/example/repo-b.git"
echo seed > "$REPO_B/README.md"
git -C "$REPO_B" add README.md
git -C "$REPO_B" commit -qm init

# Repo A is an UNRELATED repository -- different origin, different
# git-common-dir -- with its own active session.
WT_A="$TEST_ROOT/.iwe-runtime/isolated-worktrees/checkout-a"
mkdir -p "$(dirname "$WT_A")" "$WT_A"
git init -q "$WT_A"
git -C "$WT_A" config user.email test@example.com
git -C "$WT_A" config user.name "Test"
git -C "$WT_A" remote add origin "https://github.com/example/repo-a.git"
echo seed > "$WT_A/README.md"
git -C "$WT_A" add README.md
git -C "$WT_A" commit -qm init

mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/.iwe-runtime/sessions"

# Semaphores are written by hand, not via `open`: `open`'s own
# gov_repo_dir() resolution only ever names the CURRENT cwd's toplevel or
# the hardcoded $IWE_ROOT/$GOV_REPO canonical -- it has no path that points
# `governance_worktree:` at a thirdrepository's worktree the way a second,
# independently-configured session legitimately would in production (each
# session may run under its own IWE_GOVERNANCE_REPO). Writing the field
# directly is what actually exercises check 6a's own worktree comparison,
# the thing under test here, and matches how `scripts/tests/session-guard-
# abandon-prepared-smoke.sh` already drives semaphore-consuming logic
# straight off hand-built fixtures.
write_semaphore() {  # <path> <slug> <agent> <governance_worktree>
    cat > "$1" <<EOF
---
agent: $3
personality: unassigned
wp: WP-900
task: fixture
slug: $2
opened_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
created_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
session_id: $2
guard_schema: 1
harness_session_id: fixture-harness-$2
close_path: unknown
governance_worktree: $4
orz_file: 2026-10/2026-10-15-$2.md
orz_sessions_dir: $TEST_ROOT/MC-sessions
pid: $$
host: fixture-host
pid_start: $(date)
---
EOF
}

SEM_A="$TEST_ROOT/.iwe-runtime/sessions/fixture-alpha-alpha.open"
write_semaphore "$SEM_A" alpha fixture-alpha "$WT_A"

# Scenario 1 (fixed behaviour): committing in repo B must not see repo A's
# worktree at all -- different origin, different git-common-dir.
if ! OUT_B=$(cd "$REPO_B" && HOME="$TEST_ROOT/home" \
    IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="repo-b" IWE_FROZEN_CANONICAL_PATH="" \
    bash "$GUARD" pre-commit-check 2>&1); then
    echo "FAIL: pre-commit-check in an unrelated repo must not be blocked (warn-only check): $OUT_B" >&2
    exit 1
fi
if grep -q 'зарегистрированная worktree не совпадает' <<<"$OUT_B"; then
    echo "FAIL: cross-repo false positive -- repo A's unrelated worktree triggered the warning for repo B's commit: $OUT_B" >&2
    exit 1
fi
if grep -Fq "$WT_A" <<<"$OUT_B"; then
    echo "FAIL: repo A's worktree path leaked into repo B's pre-commit output: $OUT_B" >&2
    exit 1
fi

# Scenario 2 (must stay caught, regression guard against over-correction):
# a session registers an isolated worktree OF REPO B ITSELF, but the actual
# git command runs from repo B's own canonical checkout -- the exact
# inertia bug check 6a exists for. This must still warn, and must still
# name only the same-repo worktree, not repo A's.
WT_B2="$TEST_ROOT/.iwe-runtime/isolated-worktrees/checkout-b2"
mkdir -p "$(dirname "$WT_B2")"
git clone -q "$REPO_B" "$WT_B2"
git -C "$WT_B2" config user.email test@example.com
git -C "$WT_B2" config user.name "Test"
# A real `open --isolate` worktree shares git-common-dir with its canonical
# via `git worktree add`; this fixture uses a plain clone instead (simpler
# to set up standalone), so its origin defaults to the local clone source
# path, not a reusable URL. Re-point it to REPO_B's own remote so the
# remote-URL fallback (the path real clones of the same upstream actually
# hit) recognizes them as the same repository, same as `session-guard-
# duplicate-checkout-warn-smoke.sh` does for its own checkout pair.
git -C "$WT_B2" remote set-url origin "$(git -C "$REPO_B" remote get-url origin)"
SEM_B2="$TEST_ROOT/.iwe-runtime/sessions/fixture-bravo-bravo.open"
write_semaphore "$SEM_B2" bravo fixture-bravo "$WT_B2"

if ! OUT_B2=$(cd "$REPO_B" && HOME="$TEST_ROOT/home" \
    IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="repo-b" IWE_FROZEN_CANONICAL_PATH="" \
    bash "$GUARD" pre-commit-check 2>&1); then
    echo "FAIL: pre-commit-check must stay warn-only even when a same-repo mismatch fires: $OUT_B2" >&2
    exit 1
fi
if ! grep -q 'зарегистрированная worktree не совпадает' <<<"$OUT_B2"; then
    echo "FAIL: regression -- same-repo worktree/toplevel mismatch (the actual bug check 6a guards against) no longer warns: $OUT_B2" >&2
    exit 1
fi
if ! grep -Fq "$WT_B2" <<<"$OUT_B2"; then
    echo "FAIL: same-repo mismatch warning must still name its own (matching-repo) worktree: $OUT_B2" >&2
    exit 1
fi
if grep -Fq "$WT_A" <<<"$OUT_B2"; then
    echo "FAIL: unrelated repo A's worktree must still be absent even once a same-repo warning fires: $OUT_B2" >&2
    exit 1
fi

echo "PASS: session-guard pre-commit-check cross-repo worktree filter (WP-530 Ф94)"
