#!/usr/bin/env bash
# session-guard-isolate-identity-smoke.sh -- WP-530 Ф91, peer-session with
# Codex (2026-10-19-19-wp530-f91-session-guard).
#
# `open --isolate`'s identity check used to be gated on ISOLATE_BASE_DIR
# "looking like" a governance repo (top-level inbox/): a repository without
# inbox/ skipped the check entirely and was isolated without requiring
# --force. git_identity_matches() replaces that heuristic with a strict
# physical-identity comparison (canonical git common-dir, symlinks
# resolved, no origin/basename fallback). Tests the helper directly
# (unit-level, acceptance A/B/C/D) and through the real `open --isolate`
# CLI path (acceptance E/F/G).

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT_DIR/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-isolate-identity.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail_test() { echo "FAIL: $1" >&2; exit 1; }

# --- Extract the real function body from session-guard.sh (not a copy) ---
FIXTURE="$TEST_ROOT/fixture.sh"
awk '
  $0 ~ "^git_identity_matches\\(\\) \\{" { active = 1 }
  active {
    print
    if ($0 == "}") { active = 0; exit }
  }
' "$GUARD" > "$FIXTURE"
grep -q "^git_identity_matches() {" "$FIXTURE" \
  || fail_test "fixture setup -- git_identity_matches() not found, extraction anchor no longer matches session-guard.sh"
# shellcheck source=/dev/null
source "$FIXTURE"

mk_repo() {  # mk_repo <dir> -> inits a git repo with one commit
  local dir="$1"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name Test
  printf 'x\n' > "$dir/f.txt"
  git -C "$dir" add f.txt
  git -C "$dir" commit -qm init >/dev/null
}

# --- Unit tests: git_identity_matches() directly ---

# D1: same directory on both sides -> trivially matches.
REPO_D1="$TEST_ROOT/d1"
mk_repo "$REPO_D1"
git_identity_matches "$REPO_D1" "$REPO_D1" \
  || fail_test "D1: a repo does not match itself"
echo "PASS: D1 -- a repo matches itself"

# D2: candidate path does not exist -> no match, no crash.
if git_identity_matches "$TEST_ROOT/does-not-exist" "$REPO_D1"; then
  fail_test "D2: a nonexistent candidate path reported a match"
fi
echo "PASS: D2 -- nonexistent candidate path is a mismatch, not a crash"

# D3: canonical path does not exist -> no match, no crash.
if git_identity_matches "$REPO_D1" "$TEST_ROOT/also-missing"; then
  fail_test "D3: a nonexistent canonical path reported a match"
fi
echo "PASS: D3 -- nonexistent canonical path is a mismatch, not a crash"

# A: two independent repos sharing the same origin URL must NOT match --
# proves there is no origin fallback (the exact gap an origin-based design
# would have reopened, per peer-review turn 1).
REPO_A1="$TEST_ROOT/a1"
REPO_A2="$TEST_ROOT/a2"
mk_repo "$REPO_A1"
mk_repo "$REPO_A2"
git -C "$REPO_A1" remote add origin "https://example.invalid/shared.git"
git -C "$REPO_A2" remote add origin "https://example.invalid/shared.git"
if git_identity_matches "$REPO_A1" "$REPO_A2"; then
  fail_test "A: two physically different repos with the same origin were reported as matching"
fi
echo "PASS: A -- shared origin does not make two different repos match"

# B: the same repo reached through a symlink, with no origin at all --
# must match (physical identity via git common-dir survives the symlink).
REPO_B="$TEST_ROOT/b-real"
mk_repo "$REPO_B"
LINK_B="$TEST_ROOT/b-link"
ln -s "$REPO_B" "$LINK_B"
git_identity_matches "$LINK_B" "$REPO_B" \
  || fail_test "B: the same repo through a symlink (no origin) did not match"
echo "PASS: B -- a symlink to the same repo matches without needing origin"

# C: a linked worktree of the same repo -- common-dir is shared with the
# main checkout, so identity must match.
REPO_C="$TEST_ROOT/c-main"
mk_repo "$REPO_C"
WT_C="$TEST_ROOT/c-worktree"
git -C "$REPO_C" worktree add -q -b "wt-$RANDOM" "$WT_C" >/dev/null
git_identity_matches "$WT_C" "$REPO_C" \
  || fail_test "C: a linked worktree of the canonical repo did not match"
echo "PASS: C -- a linked worktree matches its main checkout"

# --- CLI-level tests: the real `open --isolate` path ---

setup_sandbox() {  # setup_sandbox <name> -> prints IWE_ROOT for the caller
  local name="$1" e2e sess sess_origin
  e2e="$TEST_ROOT/$name"
  mkdir -p "$e2e/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$e2e/scripts/agent-status-report.sh"
  chmod +x "$e2e/scripts/agent-status-report.sh"
  sess="$e2e/sessions"
  sess_origin="$e2e/sessions-origin.git"
  git init -q --bare -b main "$sess_origin"
  git init -q -b main "$sess"
  git -C "$sess" config user.email test@example.com
  git -C "$sess" config user.name Test
  git -C "$sess" remote add origin "$sess_origin"
  echo placeholder > "$sess/00-index.md"
  git -C "$sess" add 00-index.md
  git -C "$sess" commit -qm init >/dev/null
  git -C "$sess" push -q origin main
  printf '%s\n' "$e2e"
}

run_open() {  # run_open <iwe-root> <gov-repo-name> <cwd> [extra args...]
  local iwe_root="$1" gov_repo="$2" cwd="$3"
  shift 3
  (cd "$cwd" && IWE_ROOT="$iwe_root" IWE_GOVERNANCE_REPO="$gov_repo" IWE_AGENT=fixture \
     IWE_SESSIONS_ROOT="$iwe_root/sessions" IWE_FROZEN_CANONICAL_PATH="" \
     CLAUDE_CODE_SESSION_ID="identity-smoke-$RANDOM" \
     bash "$GUARD" open --task fixture --agent fixture --isolate "$@")
}

# E: cwd is an unrelated repo (no inbox/, no relation to the governance
# repo configured for this call) -- must fail without --force, with a
# message about physical identity, not inbox/.
E_ROOT=$(setup_sandbox e)
GOV_E="$E_ROOT/gov"
mkdir -p "$GOV_E/inbox"
mk_repo "$GOV_E"
OTHER_E="$TEST_ROOT/other-e"
mk_repo "$OTHER_E"
OTHER_E_ORIGIN="$TEST_ROOT/other-e-origin.git"
git init -q --bare -b main "$OTHER_E_ORIGIN"
git -C "$OTHER_E" remote add origin "$OTHER_E_ORIGIN"
git -C "$OTHER_E" push -q origin main
if OUT_E=$(run_open "$E_ROOT" "gov" "$OTHER_E" --wp WP-999 --slug "e-$RANDOM" 2>"$TEST_ROOT/e.err"); then
  fail_test "E: isolating an unrelated repo without --force unexpectedly succeeded: $OUT_E"
fi
grep -q 'физическую идентичность' "$TEST_ROOT/e.err" \
  || { cat "$TEST_ROOT/e.err" >&2; fail_test "E: refusal did not mention physical identity"; }
echo "PASS: E -- isolating an unrelated repo (no inbox/) without --force is refused"

# F: same unrelated repo, but with --force -- must succeed, and the
# resulting worktree must be based on cwd (OTHER_E), not the canonical gov
# repo (checked by presence of a file unique to OTHER_E's working tree).
printf 'only-in-other\n' > "$OTHER_E/marker-other.txt"
git -C "$OTHER_E" add marker-other.txt
git -C "$OTHER_E" commit -qm "marker" >/dev/null
git -C "$OTHER_E" push -q origin main
OUT_F=$(run_open "$E_ROOT" "gov" "$OTHER_E" --wp WP-999 --slug "f-$RANDOM" --force) \
  || fail_test "F: isolating an unrelated repo WITH --force failed: see stderr above"
WT_F=$(printf '%s\n' "$OUT_F" | grep -o '"worktree_path": "[^"]*"' | cut -d'"' -f4)
[ -n "$WT_F" ] && [ -d "$WT_F" ] || fail_test "F: --force did not produce a worktree path"
[ -f "$WT_F/marker-other.txt" ] \
  || fail_test "F: the forced worktree is not based on cwd (OTHER_E) -- expected marker-other.txt"
echo "PASS: F -- --force isolates cwd itself, not the canonical governance repo"

# G: cwd IS the canonical governance repo (identity matches), has inbox/,
# but lacks the requested WP's folder -- the *existing*, unchanged inbox/WP
# check must still fire. Regression case from peer-review turn 1/3: a
# matching identity must not silently bypass this second, independent
# barrier.
G_ROOT=$(setup_sandbox g)
GOV_G="$G_ROOT/gov"
mkdir -p "$GOV_G/inbox"
mk_repo "$GOV_G"
if OUT_G=$(run_open "$G_ROOT" "gov" "$GOV_G" --wp WP-777 --slug "g-$RANDOM" 2>"$TEST_ROOT/g.err"); then
  fail_test "G: identity match with a missing WP folder unexpectedly succeeded: $OUT_G"
fi
grep -q 'похож на governance-репо' "$TEST_ROOT/g.err" \
  || { cat "$TEST_ROOT/g.err" >&2; fail_test "G: refusal did not come from the inbox/WP check"; }
echo "PASS: G -- a matching identity does not bypass the existing inbox/WP check"

echo "ALL PASS: session-guard-isolate-identity-smoke.sh"
