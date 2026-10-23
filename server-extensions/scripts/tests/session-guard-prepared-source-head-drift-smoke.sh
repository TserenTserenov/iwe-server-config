#!/usr/bin/env bash
# session-guard-prepared-source-head-drift-smoke.sh -- WP-530 Ф61 G5 (23.10.2026).
#
# Live incident WP-600: a PREPARED semaphore recorded `close_delivery_source_head`
# for a commit whose content was already proven published on origin (ancestor or
# cherry/patch-id equivalent against a frozen `remote_head`), but the worktree's
# CURRENT HEAD had since moved past that commit with later, unrelated work. The
# secondary check inside _prepared_source_set_has_publish_proof()'s
# `if all(directly_published(commit) for commit in commits):` branch used to
# require `HEAD == source_head` unconditionally and hard-exited otherwise,
# permanently stuck in PREPARED, with no fallback: the per-path tree-based
# fallback a few lines below is itself gated by remote_absorbs_prepared_tree(),
# whose own first check is the same unconditional HEAD == source_head -- so
# simply falling through into that fallback (the fix both peer agents first
# proposed in the 23.10 peer session before this one) would not have helped
# either. This test covers one part of the fix: the worktree's current HEAD is
# dropped from the check inside this one branch -- every commit in `commits` is
# already independently proven published, so a worktree advancing past
# `source_head` afterwards does not make that earlier publication stale. The
# close path around it (snapshot split, no push from a drifted copy, removal
# proof) is driven end to end by session-guard-prepared-drift-close-smoke.py.
#
# Scenarios:
#   T1 accept_head_drift_after_published -- the live incident itself: single
#                                            commit's content delivered under a
#                                            rewritten OID (patch-id match), then
#                                            the worktree advances past
#                                            source_head; must now pass.
#   T2 reject_expected_mismatch           -- regression guard: the recorded
#                                            `commits` no longer matches the
#                                            actual source_base..source_head
#                                            range; must still refuse (this
#                                            check was not touched by the fix).
#   T3 reject_never_published             -- baseline: content genuinely absent
#                                            from origin; must still refuse.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT_DIR/session-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-guard-head-drift.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FAILURES=0
fail_test() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
ok() { echo "ok   $1"; }

# Same extraction technique as session-guard-prepared-source-ledger-proof-smoke.sh
# and session-guard-supersession-large-blob-smoke.sh: bare `}` lines inside the
# <<'PY' heredoc are not the function's end.
extract_fn() {  # <function-name>
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { active = 1 }
    active {
      print
      if (!inpy && $0 ~ /<<.PY./) { inpy = 1; next }
      if (inpy && $0 == "PY") { inpy = 0; next }
      if (!inpy && $0 == "}") { active = 0; exit }
    }
  ' "$GUARD"
}
FIXTURE="$TEST_ROOT/fixture.sh"
extract_fn _prepared_source_set_has_publish_proof > "$FIXTURE"
grep -q '^_prepared_source_set_has_publish_proof() {' "$FIXTURE" \
  || fail_test "fixture setup -- extraction anchor no longer matches session-guard.sh"
# shellcheck source=/dev/null
source "$FIXTURE"

new_repo() {  # <name> -> prints bare origin path; seeds file.txt with "base"
  local name="$1"
  local bare="$TEST_ROOT/$name-origin.git" seed="$TEST_ROOT/$name-seed"
  git init -q --bare -b main "$bare"
  git clone -q "$bare" "$seed"
  git -C "$seed" config user.email test@example.com
  git -C "$seed" config user.name test
  printf 'base\n' > "$seed/file.txt"
  git -C "$seed" add file.txt
  git -C "$seed" commit -q -m seed
  git -C "$seed" push -q origin main
  echo "$bare"
}

clone_at() {  # <origin> <dest>
  git clone -q "$1" "$2"
  git -C "$2" config user.email test@example.com
  git -C "$2" config user.name test
}

write_sem() {  # <path> <base> <head> <commit...>
  local path="$1" base="$2" head="$3"
  shift 3
  local commits_json
  commits_json=$(printf '"%s", ' "$@")
  commits_json="[${commits_json%, }]"
  printf 'close_delivery_source_base: %s\nclose_delivery_source_head: %s\nclose_delivery_source_commits: %s\n' \
    "$base" "$head" "$commits_json" > "$path"
}

build_worktree() {  # <name> <own-origin> <own-sha> <remote-origin> -> echoes worktree path
  local name="$1"
  local wt="$TEST_ROOT/$name-wt"
  clone_at "$2" "$wt"
  git -C "$wt" fetch -q "$2" main
  git -C "$wt" checkout -q "$3"
  git -C "$wt" fetch -q "$4" main
  git -C "$wt" update-ref refs/remotes/origin/main FETCH_HEAD
  echo "$wt"
}

run_proof() {  # <semaphore> <worktree>
  _prepared_source_set_has_publish_proof "$1" "$2" >/dev/null 2>&1
}

# --- T1: accept_head_drift_after_published ----------------------------------
ORIGIN1=$(new_repo t1)
OWN1="$TEST_ROOT/t1-own"
clone_at "$ORIGIN1" "$OWN1"
BASE1=$(git -C "$OWN1" rev-parse HEAD)
printf 'base\nown-change\n' > "$OWN1/file.txt"
git -C "$OWN1" commit -q -am "own change"
HEAD1=$(git -C "$OWN1" rev-parse HEAD)
# Republish under a rewritten OID: a clone from the same base commits the
# identical final content under a different message, same patch-id.
OTHER1="$TEST_ROOT/t1-other"
clone_at "$ORIGIN1" "$OTHER1"
printf 'base\nown-change\n' > "$OTHER1/file.txt"
git -C "$OTHER1" commit -q -am "republish own change under a rewritten OID"
git -C "$OTHER1" push -q origin main
WT1=$(build_worktree t1 "$OWN1" "$HEAD1" "$OTHER1")
# The worktree advances past source_head with later, unrelated work -- the
# live WP-600 symptom.
printf 'unrelated later work\n' > "$WT1/other.txt"
git -C "$WT1" add other.txt
git -C "$WT1" commit -q -m "later unrelated work, HEAD now past source_head"
write_sem "$TEST_ROOT/sem1" "$BASE1" "$HEAD1" "$HEAD1"
if run_proof "$TEST_ROOT/sem1" "$WT1"; then
  ok "accept_head_drift_after_published: a published commit is recognized even after HEAD moved past it"
else
  fail_test "accept_head_drift_after_published: HEAD drift past an already-published source_head still refused"
fi

# --- T2: reject_expected_mismatch --------------------------------------------
ORIGIN2=$(new_repo t2)
OWN2="$TEST_ROOT/t2-own"
clone_at "$ORIGIN2" "$OWN2"
BASE2=$(git -C "$OWN2" rev-parse HEAD)
printf 'base\nown-change\n' > "$OWN2/file.txt"
git -C "$OWN2" commit -q -am "own change"
HEAD2=$(git -C "$OWN2" rev-parse HEAD)
OTHER2="$TEST_ROOT/t2-other"
clone_at "$ORIGIN2" "$OTHER2"
printf 'base\nown-change\n' > "$OTHER2/file.txt"
git -C "$OTHER2" commit -q -am "republish own change under a rewritten OID"
git -C "$OTHER2" push -q origin main
WT2=$(build_worktree t2 "$OWN2" "$HEAD2" "$OTHER2")
# `commits` recorded as BASE2 (trivially published, since it's origin's own
# ancestor) instead of HEAD2 -- the actual source_base..source_head range no
# longer matches what was recorded. Untouched by this fix, must still refuse.
write_sem "$TEST_ROOT/sem2" "$BASE2" "$HEAD2" "$BASE2"
if run_proof "$TEST_ROOT/sem2" "$WT2"; then
  fail_test "reject_expected_mismatch: a recorded commit range mismatch was not refused"
else
  ok "reject_expected_mismatch: a recorded commit range mismatch is still refused"
fi

# --- T3: reject_never_published ----------------------------------------------
ORIGIN3=$(new_repo t3)
OWN3="$TEST_ROOT/t3-own"
clone_at "$ORIGIN3" "$OWN3"
BASE3=$(git -C "$OWN3" rev-parse HEAD)
printf 'base\nnever delivered\n' > "$OWN3/file.txt"
git -C "$OWN3" commit -q -am "content that never reaches origin"
HEAD3=$(git -C "$OWN3" rev-parse HEAD)
OTHER3="$TEST_ROOT/t3-other"
clone_at "$ORIGIN3" "$OTHER3"
git -C "$OTHER3" commit -q --allow-empty -m "unrelated upstream commit"
git -C "$OTHER3" push -q origin main
WT3=$(build_worktree t3 "$OWN3" "$HEAD3" "$OTHER3")
write_sem "$TEST_ROOT/sem3" "$BASE3" "$HEAD3" "$HEAD3"
if run_proof "$TEST_ROOT/sem3" "$WT3"; then
  fail_test "reject_never_published: content genuinely absent from origin was accepted"
else
  ok "reject_never_published: content genuinely absent from origin is refused"
fi

[ "$FAILURES" -eq 0 ] && { echo "PASS: all scenarios"; exit 0; }
exit 1
