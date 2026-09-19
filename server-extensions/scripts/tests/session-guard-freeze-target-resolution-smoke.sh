#!/usr/bin/env bash
# Regression (WP-530 Ф56, peer-session 2026-09-18-10, consensus Claude+Kimi+
# Codex rounds 3-5): frozen_checkout_match() used to compare only the literal
# git toplevel of cwd (falling back to `pwd` when cwd wasn't a git repo at
# all) against the frozen-path list. `open`'s actual write target,
# governance_worktree:, comes from a DIFFERENT resolver (gov_repo_dir()) with
# a DIFFERENT fallback for the exact same "cwd not a match" case -- it falls
# back to the canonical path, not pwd. A session opened from a cwd outside
# any git repo (or inside an unrelated one) sailed past freeze while still
# claiming the frozen canonical checkout as its governance_worktree (live
# incident: WP-484 semaphore opened 2026-09-18 09:09, governance_worktree =
# canon, cwd elsewhere). The fix checks BOTH candidates inside one function:
# the literal cwd toplevel (protects a frozen path whose own origin doesn't
# match DS-my-strategy's, e.g. $IWE_ROOT itself) and gov_repo_dir()'s result
# (protects against the cwd-outside-git / foreign-origin gap). Checking only
# gov_repo_dir() was already tried and reverted (WP-484 Ф104, see the comment
# above frozen_checkout_match()) because it makes a second frozen path
# structurally unreachable -- this suite's scenario 2 is exactly that case.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GUARD="$ROOT_DIR/scripts/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-freeze-target.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

no_semaphore_created() {  # <sessions dir> <agent glob>
  ! compgen -G "$1/$2-*.open" >/dev/null
}

# --- fixtures -----------------------------------------------------------

# Canonical governance checkout (what the default freeze list protects).
# A real local bare origin, not a fake URL -- scenario 4 exercises --isolate,
# which does a real `git fetch origin main` before creating the worktree.
CANON_ORIGIN="$TEST_ROOT/canon-origin.git"
git init -q --bare "$CANON_ORIGIN"
CANON="$TEST_ROOT/DS-strategy"
mkdir -p "$CANON/sessions"
git init -q "$CANON"
git -C "$CANON" remote add origin "$CANON_ORIGIN"
git -C "$CANON" commit -q --allow-empty -m "seed"
git -C "$CANON" push -q -u origin HEAD:main

# A directory that is not a git repository at all.
NOT_A_REPO="$TEST_ROOT/plain-dir"
mkdir -p "$NOT_A_REPO"

# An unrelated git repository with its own, different origin -- the
# "chужой git-репозиторий" case Codex raised in round 3.
FOREIGN="$TEST_ROOT/unrelated-project"
git init -q "$FOREIGN"
git -C "$FOREIGN" remote add origin "https://example.invalid/unrelated.git"

# A second frozen checkout whose own origin does NOT match the canonical
# one -- models $IWE_ROOT (real remote: iwe-local-config) being frozen
# alongside DS-my-strategy. gov_repo_dir() can never resolve TO this path
# from anywhere (origin mismatch, not basename-matched), so only the
# literal-cwd-toplevel candidate can protect it.
SECOND_FROZEN="$TEST_ROOT/iwe-root-stand-in"
mkdir -p "$SECOND_FROZEN/sessions"
git init -q "$SECOND_FROZEN"
git -C "$SECOND_FROZEN" remote add origin "https://example.invalid/second-frozen.git"

open_from() {  # <cwd> <frozen-path-csv-as-array-already-exported> <args...>
  local cwd="$1"; shift
  (cd "$cwd" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" \
    bash "$GUARD" open "$@")
}

# 1. REGRESSION (the actual incident): default frozen list (canon), cwd is
#    not a git repository at all. Must now block -- this was the live gap.
if OUT_1=$(open_from "$NOT_A_REPO" --wp WP-900 --task fixture --slug non-git-cwd --agent fixture 2>&1); then
  fail "open from a non-git cwd must be blocked by freeze (regression), got exit 0: $OUT_1"
fi
grep -q 'под freeze' <<<"$OUT_1" || fail "expected the freeze message for a non-git cwd, got: $OUT_1"
no_semaphore_created "$TEST_ROOT/.iwe-runtime/sessions" fixture || fail "a blocked open from a non-git cwd must not leave a semaphore"

# 2. Codex's override scenario: freeze protects ONLY a second checkout whose
#    origin does not match canonical (gov_repo_dir() can never return it),
#    cwd is that checkout itself. Must still block -- proves the
#    cwd-toplevel candidate, not just gov_repo_dir(), is load-bearing.
if OUT_2=$(cd "$SECOND_FROZEN" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" \
    IWE_FROZEN_CANONICAL_PATH="$SECOND_FROZEN" \
    bash "$GUARD" open --wp WP-901 --task fixture --slug second-frozen-cwd --agent fixture 2>&1); then
  fail "open from the frozen second checkout itself must be blocked, got exit 0: $OUT_2"
fi
grep -q 'под freeze' <<<"$OUT_2" || fail "expected the freeze message for the second-frozen cwd, got: $OUT_2"

# 3. Foreign git repo case: default frozen list (canon only), cwd is an
#    unrelated repo with its own origin. gov_repo_dir() falls back to canon
#    (origin mismatch) -- must block even though cwd's own toplevel is NOT
#    a frozen path.
if OUT_3=$(open_from "$FOREIGN" --wp WP-902 --task fixture --slug foreign-repo-cwd --agent fixture 2>&1); then
  fail "open from an unrelated foreign git repo must be blocked (governance target is canon), got exit 0: $OUT_3"
fi
grep -q 'под freeze' <<<"$OUT_3" || fail "expected the freeze message for a foreign repo cwd, got: $OUT_3"

# 4. Positive control: --isolate from the non-git cwd is unaffected --
#    carve-out #3 in `open` routes around the freeze block entirely before
#    frozen_checkout_match() is reached for this path.
if ! OUT_4=$(open_from "$NOT_A_REPO" --wp WP-903 --task fixture --slug isolate-from-non-git --agent fixture --isolate --force 2>&1); then
  fail "--isolate from a non-git cwd must still succeed, got: $OUT_4"
fi
grep -q '"worktree_path"' <<<"$OUT_4" || fail "--isolate from a non-git cwd did not report a worktree: $OUT_4"

# 5. Positive control: --canonical-owner bypasses unconditionally, same as
#    before this patch (scheduled-runner carve-out, untouched by this fix).
if ! OUT_5=$(open_from "$FOREIGN" --wp WP-904 --task fixture --slug sched-owner --agent scheduler --canonical-owner "launchd-scheduled" 2>&1); then
  fail "--canonical-owner must still bypass freeze unconditionally, got: $OUT_5"
fi
find "$TEST_ROOT/.iwe-runtime/sessions" -name 'scheduler-*.open' -type f | grep -q . \
  || fail "--canonical-owner open must still create a semaphore"

# 6. Positive control: freeze explicitly disarmed (IWE_FROZEN_CANONICAL_PATH=""
#    break-glass, existing contract) must still let a plain open through --
#    frozen_checkout_match() returns immediately on an empty frozen list,
#    before either candidate is even computed.
if ! OUT_6=$(cd "$FOREIGN" && IWE_ROOT="$TEST_ROOT" IWE_GOVERNANCE_REPO="DS-strategy" \
    IWE_FROZEN_CANONICAL_PATH="" \
    bash "$GUARD" open --wp WP-905 --task fixture --slug unfrozen-target --agent fixture 2>&1); then
  fail "open with freeze disarmed must succeed, got: $OUT_6"
fi
find "$TEST_ROOT/.iwe-runtime/sessions" -name 'fixture-*.open' -type f | grep -q . \
  || fail "a legitimate open must still create a semaphore"

echo "PASS: freeze checks both the literal cwd toplevel and the resolved governance target; non-git and foreign-repo cwds are blocked, isolate/canonical-owner/legitimate opens are unaffected"
