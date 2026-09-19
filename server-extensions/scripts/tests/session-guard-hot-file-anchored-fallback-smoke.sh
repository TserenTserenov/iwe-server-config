#!/usr/bin/env bash
# session-guard-hot-file-anchored-fallback-smoke.sh -- WP-484, peer-session
# 2026-09-19-05-wp484-ancestry-patchid-audit (Claude+Kimi+Codex).
#
# _prepared_source_set_has_publish_proof() used to require the delivered
# blob at every touched path to be byte-identical to the current
# origin/main blob at that path. On a hot file (docs/WP-REGISTRY.md,
# WeekPlan) edited by 15-20 concurrent sessions, that can never succeed:
# a sibling session commits a further change to the same path before this
# proof runs, and the blob keeps moving forever (WP-537, commit
# 7240ab633, 17.09). Fixed with an opt-in anchored-insertion fallback
# (IWE_SESSION_GUARD_ANCHORED_FALLBACK=1): a pure insertion is proven by
# showing it is still uniquely anchored inside the current published blob,
# reusing the same primitive already trusted for commit-claim supersession
# (_commit_claim_supersession_has_publish_proof/anchored_insertions).
#
# This test extracts the real heredoc from session-guard.sh (not a copy)
# and drives it directly against hand-built git fixtures -- the function
# only reads three revisions by SHA, so no isolate-push/close/RUN-card
# machinery is needed to reach it.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT_DIR/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-hotfile-anchored.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

PROOF_SCRIPT="$TEST_ROOT/proof.py"
awk '
  /^_prepared_source_set_has_publish_proof\(\) \{/ { infunc=1; next }
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

semaphore_for() {  # <base> <head> <commits-json> -> prints semaphore path
  local sem="$TEST_ROOT/sem-$RANDOM.open"
  {
    echo "close_delivery_source_commits: $3"
    echo "close_delivery_source_base: $1"
    echo "close_delivery_source_head: $2"
  } > "$sem"
  printf '%s' "$sem"
}

run_proof() {  # <flag: 0|1> <semaphore>
  if [ "$1" = "1" ]; then
    IWE_SESSION_GUARD_ANCHORED_FALLBACK=1 python3 "$PROOF_SCRIPT" "$2" "$REPO"
  else
    python3 "$PROOF_SCRIPT" "$2" "$REPO"
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

# --- Scenario 1: pure insertion into a hot file, flag off -> still refuses
# (default OFF must reproduce the exact pre-fix behaviour -- Kimi's
# canary-first condition from the peer session).
BASE_SHA=$(commit_content --orphan $'A\nB\nC\n')
OWN_SHA=$(commit_content "$BASE_SHA" $'A\nB\nNEW\nC\n')
PUBLISHED_SHA=$(commit_content "$BASE_SHA" $'A\nB\nNEW\nC\nD\n')
git -C "$REPO" update-ref refs/remotes/origin/main "$PUBLISHED_SHA"
SEM=$(semaphore_for "$BASE_SHA" "$OWN_SHA" "[\"$OWN_SHA\"]")
set +e
run_proof 0 "$SEM" >/dev/null 2>&1
RC=$?
set -e
check "insertion into hot file with fallback OFF still refuses (default preserves prior behaviour)" 1 "$RC"

# --- Scenario 1b: same fixture, flag on -> the insertion is uniquely
# anchored in the published blob (which also carries a foreign append) ->
# proof succeeds even though the whole-file bytes never matched.
set +e
run_proof 1 "$SEM" >/dev/null 2>&1
RC=$?
set -e
check "insertion into hot file with fallback ON is accepted (anchored in published blob)" 0 "$RC"

# --- Scenario 2: a replace (not a pure insertion) must never be rescued by
# the fallback, flag on or off -- anchored_insertions() only vouches for
# insert ops, replace/delete stay fail-closed exactly as before.
BASE_SHA2=$(commit_content --orphan $'A\nB\nC\n')
OWN_SHA2=$(commit_content "$BASE_SHA2" $'A\nX\nC\n')
PUBLISHED_SHA2=$(commit_content "$BASE_SHA2" $'A\nX\nC\nD\n')
git -C "$REPO" update-ref refs/remotes/origin/main "$PUBLISHED_SHA2"
SEM2=$(semaphore_for "$BASE_SHA2" "$OWN_SHA2" "[\"$OWN_SHA2\"]")
set +e
run_proof 1 "$SEM2" >/dev/null 2>&1
RC=$?
set -e
check "replace (not insert) is not rescued by the fallback even with it ON" 1 "$RC"

# --- Scenario 3: non-unique anchor (repeated identical lines) -- the
# insertion boundary has no distinguishing context in the base file, so no
# anchor width can be proven unique. Must stay fail-closed, not silently
# accept a coincidental match.
BASE_SHA3=$(commit_content --orphan $'X\nX\nX\n')
OWN_SHA3=$(commit_content "$BASE_SHA3" $'X\nX\nNEW\nX\n')
PUBLISHED_SHA3=$(commit_content "$BASE_SHA3" $'X\nX\nNEW\nX\nD\n')
git -C "$REPO" update-ref refs/remotes/origin/main "$PUBLISHED_SHA3"
SEM3=$(semaphore_for "$BASE_SHA3" "$OWN_SHA3" "[\"$OWN_SHA3\"]")
set +e
run_proof 1 "$SEM3" >/dev/null 2>&1
RC=$?
set -e
check "non-unique anchor (repeated identical lines) stays fail-closed" 1 "$RC"

# --- Scenario 4: budget edge -- a blob over the 4096-line anchored_insertions
# budget must fail closed instead of silently skipping the size guard.
# Unique numbered lines (not a repeated single line) so the length guard is
# the thing under test, not an incidental non-unique-anchor rejection like
# scenario 3.
BASE_SHA4=$(commit_content --orphan "$(python3 -c 'print("\n".join(f"line{i}" for i in range(4090)) + "\n", end="")')")
OWN_CONTENT4=$(python3 -c 'lines = [f"line{i}" for i in range(4090)]; lines.insert(2000, "NEW"); print("\n".join(lines) + "\n", end="")')
OWN_SHA4=$(commit_content "$BASE_SHA4" "$OWN_CONTENT4")
PUBLISHED_CONTENT4=$(python3 -c 'lines = [f"line{i}" for i in range(4090)]; lines.insert(2000, "NEW"); lines += [f"extra{i}" for i in range(20)]; print("\n".join(lines) + "\n", end="")')
PUBLISHED_SHA4=$(commit_content "$BASE_SHA4" "$PUBLISHED_CONTENT4")
git -C "$REPO" update-ref refs/remotes/origin/main "$PUBLISHED_SHA4"
SEM4=$(semaphore_for "$BASE_SHA4" "$OWN_SHA4" "[\"$OWN_SHA4\"]")
set +e
run_proof 1 "$SEM4" >/dev/null 2>&1
RC=$?
set -e
check "oversized blob (>4096 lines) stays fail-closed under the anchored_insertions budget guard" 1 "$RC"

# --- Scenario 5 (regression for cold-review finding, peer-session same day):
# the fallback must check source_base's own mode too, not just own/published.
# A base->own mode flip (executable bit set) must stay fail-closed even
# though own and published agree with each other -- otherwise a path whose
# base was never a plain-mode blob (a directory, a symlink) could sneak a
# predictable "base content" past anchored_insertions by construction.
# published must be a SIBLING of own (both children of base), not a
# descendant of own -- own being an ancestor of published would satisfy the
# function's Level-1 ancestor fast-path before this fallback is ever reached
# (the exact mistake this comment now guards the fixture against, caught by
# a self-check of this very test during authoring).
BASE_SHA5=$(commit_content --orphan $'A\nB\nC\n')
git -C "$REPO" checkout -q --detach "$BASE_SHA5"
printf 'A\nB\nNEW\nC\n' > "$REPO/f.txt"
chmod +x "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -qm own
OWN_SHA5=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q --detach "$BASE_SHA5"
printf 'A\nB\nNEW\nC\nD\n' > "$REPO/f.txt"
chmod +x "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -qm published
PUBLISHED_SHA5=$(git -C "$REPO" rev-parse HEAD)
if git -C "$REPO" merge-base --is-ancestor "$OWN_SHA5" "$PUBLISHED_SHA5" 2>/dev/null; then
  echo "FAIL: fixture setup -- own is an ancestor of published, Level-1 ancestor fast-path would short-circuit this scenario before the fallback runs" >&2
  exit 1
fi
git -C "$REPO" update-ref refs/remotes/origin/main "$PUBLISHED_SHA5"
SEM5=$(semaphore_for "$BASE_SHA5" "$OWN_SHA5" "[\"$OWN_SHA5\"]")
set +e
run_proof 1 "$SEM5" >/dev/null 2>&1
RC=$?
set -e
check "base->own executable-bit flip stays fail-closed even when own/published agree" 1 "$RC"

exit "$FAILED"
