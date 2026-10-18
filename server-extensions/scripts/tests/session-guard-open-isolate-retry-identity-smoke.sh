#!/usr/bin/env bash
# session-guard-open-isolate-retry-identity-smoke.sh -- WP-484 Ф204 (18.10): `open --isolate`
# without an explicit --session-id used to roll a fresh random id on every call, so a retry
# after a publish conflict (the peer-conversation skill's own documented recovery step is
# "reopen with --isolate") landed on a brand-new worktree/semaphore instead of re-entering the
# one from the previous attempt -- the live incident was one conversation piling up eight
# orphaned semaphores on 16.10. `open --isolate` now derives the isolate id from the native
# harness identity (CLAUDE_CODE_SESSION_ID/CODEX_THREAD_ID) plus WP and slug when available, and
# refuses outright when neither an explicit IWE_SESSION_ID nor a native identity is present.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-isolate-retry.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

ORIGIN="$TEST_ROOT/origin.git"
git init -q --bare -b main "$ORIGIN"
WORK="$TEST_ROOT/DS-strategy"
git init -q -b main "$WORK"
git -C "$WORK" remote add origin "$ORIGIN"
mkdir -p "$WORK/inbox/WP-999"
printf '%s\n' 'hypothesis_relation: "tests"' > "$WORK/inbox/WP-999/WP-999.md"
git -C "$WORK" add inbox/WP-999/WP-999.md
git -C "$WORK" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$WORK" push -q -u origin main

# The legacy (no-MC-sessions) ORZ fallback writes session/*.md straight into $WORK itself, so a
# second --isolate call in the same scenario (no reset in between, e.g. two different
# conversations opening back-to-back) sees $WORK as dirty and refuses -- a fixture artifact, not
# the thing under test. A real MC-sessions repo (same split as the close-isolated fixture) keeps
# the ORZ scaffold out of $WORK entirely.
SESSIONS_REPO="$TEST_ROOT/MC-sessions-fixture"
SESSIONS_ORIGIN="$TEST_ROOT/sessions-origin.git"
git init -q --bare -b main "$SESSIONS_ORIGIN"
git init -q -b main "$SESSIONS_REPO"
git -C "$SESSIONS_REPO" remote add origin "$SESSIONS_ORIGIN"
echo placeholder > "$SESSIONS_REPO/00-index.md"
git -C "$SESSIONS_REPO" add 00-index.md
git -C "$SESSIONS_REPO" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$SESSIONS_REPO" push -q -u origin main

guard() {
    (cd "$WORK" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" IWE_FROZEN_CANONICAL_PATH="" \
        IWE_SESSIONS_ROOT="$SESSIONS_REPO" bash "$GUARD" "$@")
}

worktrees() { find "$TEST_ROOT/.iwe-runtime/isolated-worktrees" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort; }
# --isolate creates a session-isolate/<id> branch directly in $WORK's own .git, which survives
# wiping .iwe-runtime -- a later scenario reusing the same derived id (e.g. the same conversation
# opening the same WP again) then collides on the stale branch name, not a real re-entry attempt.
reset_runtime() {
    rm -rf "$TEST_ROOT/.iwe-runtime"
    git -C "$WORK" worktree prune
    # xargs -r is GNU-only (CI also runs this suite on macOS); a plain read loop is portable and
    # already a no-op on an empty ref list.
    git -C "$WORK" for-each-ref --format='%(refname:short)' refs/heads/session-isolate/ \
        | while read -r ref; do git -C "$WORK" branch -D "$ref" >/dev/null; done
}

# A bare retry of the SAME conversation (same native id, no explicit identity) is refused by the
# pre-existing native-identity gate -- unchanged by this fix, still correct: it names the exact
# session_id the caller just created, which is now the DERIVED id, not a random one.
FIRST_OUT=$(CODEX_THREAD_ID="aaaaaaaa-1111-2222-3333-444444444444" guard open --wp WP-999 --agent codex --isolate)
DERIVED_ID=$(printf '%s' "$FIRST_OUT" | grep -o '"session_id": "[^"]*"' | head -1 | sed 's/.*: "//; s/"$//')
[ -n "$DERIVED_ID" ] || { echo "FAIL: first open did not report a session_id: $FIRST_OUT" >&2; exit 1; }

rc=0
BARE_RETRY_OUT=$(CODEX_THREAD_ID="aaaaaaaa-1111-2222-3333-444444444444" guard open --wp WP-999 --agent codex --isolate 2>&1) || rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: a bare retry with no explicit session marker must still be refused (unchanged pre-existing gate)" >&2; exit 1; }
printf '%s' "$BARE_RETRY_OUT" | grep -q "$DERIVED_ID" || {
    echo "FAIL: the refusal must name the DERIVED session_id ($DERIVED_ID), not a random one: $BARE_RETRY_OUT" >&2
    exit 1
}
echo "OK: a bare retry is still refused, and names the deterministic derived id, not a random one"

# A retry that explicitly reuses that SAME derived id (the one the caller can compute itself, or
# copy from the refusal message) re-enters the SAME isolated worktree -- not a second one.
SECOND_OUT=$(CODEX_THREAD_ID="aaaaaaaa-1111-2222-3333-444444444444" IWE_SESSION_ID="$DERIVED_ID" \
    guard open --wp WP-999 --agent codex --isolate)
[ "$(worktrees | wc -l | tr -d ' ')" = 1 ] || {
    echo "FAIL: retrying with the derived id must not create a second worktree" >&2
    worktrees >&2
    exit 1
}
FIRST_PATH=$(printf '%s' "$FIRST_OUT" | grep -o '"worktree_path": "[^"]*"' | head -1)
SECOND_PATH=$(printf '%s' "$SECOND_OUT" | grep -o '"worktree_path": "[^"]*"' | head -1)
[ "$FIRST_PATH" = "$SECOND_PATH" ] || {
    echo "FAIL: retry must resolve to the same worktree_path, got '$FIRST_PATH' vs '$SECOND_PATH'" >&2
    exit 1
}
echo "OK: retrying with the derived id re-enters the same worktree"
reset_runtime

# A different conversation (different native id) on the SAME WP must get its OWN worktree, not
# collide with the first one.
CODEX_THREAD_ID="bbbbbbbb-1111-2222-3333-444444444444" guard open --wp WP-999 --agent codex --isolate >/dev/null
CODEX_THREAD_ID="cccccccc-1111-2222-3333-444444444444" guard open --wp WP-999 --agent codex --isolate >/dev/null
[ "$(worktrees | wc -l | tr -d ' ')" = 2 ] || {
    echo "FAIL: two different conversations must get two separate isolated worktrees" >&2
    worktrees >&2
    exit 1
}
echo "OK: different conversations on the same WP get separate isolated worktrees"
reset_runtime

# The SAME conversation opening a DIFFERENT WP must also get its own worktree, not reuse the
# first one just because the native id matches.
mkdir -p "$WORK/inbox/WP-888"
printf '%s\n' 'hypothesis_relation: "tests"' > "$WORK/inbox/WP-888/WP-888.md"
git -C "$WORK" add inbox/WP-888/WP-888.md
git -C "$WORK" -c user.email=t@t -c user.name=t commit -q -m "add WP-888"
git -C "$WORK" push -q origin main
CODEX_THREAD_ID="aaaaaaaa-1111-2222-3333-444444444444" guard open --wp WP-999 --agent codex --isolate >/dev/null
CODEX_THREAD_ID="aaaaaaaa-1111-2222-3333-444444444444" guard open --wp WP-888 --agent codex --isolate >/dev/null
[ "$(worktrees | wc -l | tr -d ' ')" = 2 ] || {
    echo "FAIL: the same conversation opening a different WP must not reuse the first worktree" >&2
    worktrees >&2
    exit 1
}
echo "OK: the same conversation opening a different WP gets its own worktree"
reset_runtime

# An explicit --session-id/IWE_SESSION_ID still wins over the derived id, regardless of native
# identity being present.
CODEX_THREAD_ID="aaaaaaaa-1111-2222-3333-444444444444" IWE_SESSION_ID="explicit-one" \
    guard open --wp WP-999 --agent codex --isolate >/dev/null
[ -d "$TEST_ROOT/.iwe-runtime/isolated-worktrees/codex-explicit-one" ] || {
    echo "FAIL: an explicit IWE_SESSION_ID must be used verbatim for the worktree name" >&2
    worktrees >&2
    exit 1
}
echo "OK: explicit IWE_SESSION_ID overrides the derived id"
reset_runtime

# No native identity and no explicit IWE_SESSION_ID must refuse outright, not roll fresh entropy.
rc=0
OUT=$(CODEX_THREAD_ID="" CLAUDE_CODE_SESSION_ID="" guard open --wp WP-999 --agent kimi --isolate 2>&1) || rc=$?
[ "$rc" -ne 0 ] || {
    echo "FAIL: --isolate with no identity at all must refuse, got rc=0: $OUT" >&2
    exit 1
}
printf '%s' "$OUT" | grep -q 'IWE_SESSION_ID' || {
    echo "FAIL: the refusal must name IWE_SESSION_ID as the way out, got: $OUT" >&2
    exit 1
}
[ -z "$(worktrees)" ] || {
    echo "FAIL: a refused --isolate must not leave a worktree behind" >&2
    exit 1
}
echo "OK: --isolate with no identity at all refuses instead of rolling fresh entropy"

echo "PASS: isolate retry derives a stable id from native identity, separates unrelated opens, and refuses with no identity at all"
