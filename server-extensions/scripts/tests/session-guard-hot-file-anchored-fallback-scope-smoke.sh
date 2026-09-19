#!/usr/bin/env bash
# session-guard-hot-file-anchored-fallback-scope-smoke.sh -- WP-484,
# peer-session 2026-09-19-05-wp484-ancestry-patchid-audit (Claude+Kimi+Codex),
# continuation by direct pilot request the same session.
#
# Twin of session-guard-hot-file-anchored-fallback-smoke.sh, for the second
# call site with the same byte-exact-tree problem:
# _repo_scope_has_publish_proof(). Unlike the first call site, this one has
# no single (source_base, source_head) pair -- it works off a set of
# independent `commit:` claims declared in the semaphore, in append order
# (not proven git-ancestry order). This test drives the real extracted
# heredoc directly, same technique as the sibling test.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT_DIR/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-hotfile-anchored-scope.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

PROOF_SCRIPT="$TEST_ROOT/proof.py"
awk '
  /^_repo_scope_has_publish_proof\(\) \{/ { infunc=1; next }
  infunc && /<<.PY./ { inpy=1; next }
  infunc && inpy && /^PY$/ { exit }
  infunc && inpy { print }
' "$GUARD" > "$PROOF_SCRIPT"
[ -s "$PROOF_SCRIPT" ] || { echo "FAIL: fixture setup -- extracted proof script is empty, awk anchors no longer match session-guard.sh" >&2; exit 1; }
python3 -c "import ast; ast.parse(open('$PROOF_SCRIPT').read())" \
  || { echo "FAIL: fixture setup -- extracted proof script is not valid Python" >&2; exit 1; }

REPO="$TEST_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
IWE_ROOT_FIXTURE="$TEST_ROOT/iwe-root-empty"
mkdir -p "$IWE_ROOT_FIXTURE"

commit_content() {  # <ref-to-checkout-from | --orphan> <content> -> prints new commit sha
  if [ "$1" = "--orphan" ]; then
    git -C "$REPO" checkout -q --orphan "tmp-$$-$RANDOM"
    git -C "$REPO" rm -rqf . >/dev/null 2>&1 || true
  else
    git -C "$REPO" checkout -q --detach "$1"
  fi
  printf '%s' "$2" > "$REPO/f.txt"
  git -C "$REPO" add f.txt
  git -C "$REPO" commit -qm content
  git -C "$REPO" rev-parse HEAD
}

REPO_NAME=$(basename "$REPO")

semaphore_for() {  # <extra-file-lines...> writes remaining args as "commit: <name> <sha>" lines
  local sem="$TEST_ROOT/sem-$RANDOM.open"
  {
    echo "governance_worktree: $REPO"
    echo "file: f.txt"
    for c in "$@"; do
      echo "commit: $REPO_NAME $c"
    done
  } > "$sem"
  printf '%s' "$sem"
}

run_proof() {  # <flag: 0|1> <semaphore> <remote-oid>
  if [ "$1" = "1" ]; then
    IWE_SESSION_GUARD_ANCHORED_FALLBACK=1 python3 "$PROOF_SCRIPT" \
      "$REPO" "test repo" "$2" "$3" governance_worktree orz_sessions_dir "" "" "$IWE_ROOT_FIXTURE"
  else
    python3 "$PROOF_SCRIPT" \
      "$REPO" "test repo" "$2" "$3" governance_worktree orz_sessions_dir "" "" "$IWE_ROOT_FIXTURE"
  fi
}

FAILED=0
check() {  # <description> <expected-exit> <actual-exit>
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (expected exit $2, got $3)" >&2
    FAILED=1
  fi
}

# --- Scenario 1: pure insertion into a hot file, single claim, flag off ->
# still refuses (default OFF must reproduce the exact pre-fix behaviour).
BASE_SHA=$(commit_content --orphan $'A\nB\nC\n')
OWN_SHA=$(commit_content "$BASE_SHA" $'A\nB\nNEW\nC\n')
PUBLISHED_SHA=$(commit_content "$BASE_SHA" $'A\nB\nNEW\nC\nD\n')
if git -C "$REPO" merge-base --is-ancestor "$OWN_SHA" "$PUBLISHED_SHA" 2>/dev/null; then
  echo "FAIL: fixture setup -- own is an ancestor of published" >&2
  exit 1
fi
git -C "$REPO" checkout -q --detach "$OWN_SHA"   # head = own's content, as a live checkout
SEM=$(semaphore_for "$OWN_SHA")
set +e
run_proof 0 "$SEM" "$PUBLISHED_SHA" >/dev/null 2>&1
RC=$?
set -e
check "single claim, insertion into hot file, fallback OFF still refuses" 1 "$RC"

# --- Scenario 1b: same fixture, flag on -> accepted via the claimed-path
# fallback (session base resolved from the single claim's parent).
set +e
run_proof 1 "$SEM" "$PUBLISHED_SHA" >/dev/null 2>&1
RC=$?
set -e
check "single claim, insertion into hot file, fallback ON is accepted" 0 "$RC"

# --- Scenario 2: same content mismatch, but the path is NOT in claimed_paths
# (no commit: line covers it -- scope-inferred only) -- the fallback must
# never engage for a path without an explicit commit claim, flag on or off.
SEM_NOCLAIM="$TEST_ROOT/sem-noclaim.open"
{
  echo "governance_worktree: $REPO"
  echo "file: f.txt"
} > "$SEM_NOCLAIM"
set +e
run_proof 1 "$SEM_NOCLAIM" "$PUBLISHED_SHA" >/dev/null 2>&1
RC=$?
set -e
# With zero commit: claims, claimed_paths is empty -> "нет полного
# repo-qualified commit scope" refuses upstream of the fallback entirely.
# That is the correct fail-closed outcome for an unclaimed path, so exit 1
# either way -- what this scenario actually pins down is that the fallback
# introduced here cannot be reached without a claim (verified structurally:
# `raw_path not in claimed_paths` in path_has_anchored_fallback_proof, code
# review confirmed this in the peer session, not independently re-derivable
# from exit code alone with this fixture shape).
check "path with no commit: claim at all refuses upstream of the fallback" 1 "$RC"

# --- Scenario 3: TWO claims declared out of git-ancestry order in the
# semaphore (second commit's line written first) -- resolve_session_base()
# must still find the true root claim by ancestry, not by semaphore order
# (Kimi, round 5: note-commit append order is not proven git history order).
BASE_SHA3=$(commit_content --orphan $'A\nB\nC\n')
MID_SHA3=$(commit_content "$BASE_SHA3" $'A\nB\nMID\nC\n')
OWN_SHA3=$(commit_content "$MID_SHA3" $'A\nB\nMID\nNEW\nC\n')
PUBLISHED_SHA3=$(commit_content "$BASE_SHA3" $'A\nB\nMID\nNEW\nC\nD\n')
if git -C "$REPO" merge-base --is-ancestor "$OWN_SHA3" "$PUBLISHED_SHA3" 2>/dev/null; then
  echo "FAIL: fixture setup -- own is an ancestor of published (scenario 3)" >&2
  exit 1
fi
git -C "$REPO" checkout -q --detach "$OWN_SHA3"
# semaphore_for appends in argument order -- pass the LATER commit (OWN_SHA3)
# before the EARLIER one (MID_SHA3) to force out-of-order declaration.
SEM3=$(semaphore_for "$OWN_SHA3" "$MID_SHA3")
set +e
run_proof 1 "$SEM3" "$PUBLISHED_SHA3" >/dev/null 2>&1
RC=$?
set -e
check "two claims declared out of ancestry order still resolve the correct session base" 0 "$RC"

exit "$FAILED"
