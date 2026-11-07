#!/usr/bin/env bash
# Verifies drop_unpushed_auto_commits from sync-extensions-auto.sh: a copy that
# diverged from origin because of OUR OWN unpushed auto-commit heals itself,
# while a foreign local commit or an uncommitted edit is never destroyed.
# Regression for the 05-07.11.2026 stall (push rejected after a 27-min tick,
# then every `git pull --ff-only` failed for two days).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/sync-extensions-auto.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sync-self-heal.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

LOG_PREFIX="[test]"
eval "$(sed -n '/^drop_unpushed_auto_commits() {/,/^}/p' "$SCRIPT")"
declare -F drop_unpushed_auto_commits >/dev/null || { echo "FAIL: function not found in $SCRIPT"; exit 1; }

fail() { echo "FAIL: $*"; exit 1; }

# fresh_pair <name>: bare origin + clone with one shared commit, cwd = clone
fresh_pair() {
  git init -q --bare "$WORK/$1.git"
  git clone -q "$WORK/$1.git" "$WORK/$1" 2>/dev/null
  cd "$WORK/$1"
  git config user.email t@example.invalid; git config user.name t
  git checkout -q -b main
  echo base > f.txt; git add f.txt; git commit -q -m base
  git push -q origin main
}

# moves origin ahead from a second clone, then returns to the first one
advance_origin() {
  git clone -q "$WORK/$1.git" "$WORK/$1-other" 2>/dev/null
  git -C "$WORK/$1-other" config user.email t@example.invalid
  git -C "$WORK/$1-other" config user.name t
  echo upstream > "$WORK/$1-other/up.txt"
  git -C "$WORK/$1-other" add up.txt
  git -C "$WORK/$1-other" commit -q -m "upstream change"
  git -C "$WORK/$1-other" push -q origin HEAD:main
}

# Case 1: only our auto-commit ahead, origin moved -> healed to origin/main
fresh_pair c1
advance_origin c1
echo auto > auto.txt; git add auto.txt; git commit -q -m "sync: auto extensions (1 файлов) [sync-extensions-auto]"
git pull --ff-only --quiet 2>/dev/null && fail "case1: pull unexpectedly succeeded, fixture is not diverged"
drop_unpushed_auto_commits >/dev/null || fail "case1: function refused an auto-only divergence"
git pull --ff-only --quiet || fail "case1: pull still fails after heal"
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "case1: HEAD != origin/main"
[ ! -e auto.txt ] || fail "case1: auto file survived the drop"

# Case 2: a foreign commit is ahead too -> refused, commit kept
fresh_pair c2
advance_origin c2
echo mine > mine.txt; git add mine.txt; git commit -q -m "hand-written fix"
before=$(git rev-parse HEAD)
if drop_unpushed_auto_commits >/dev/null; then fail "case2: dropped a foreign commit"; fi
[ "$(git rev-parse HEAD)" = "$before" ] || fail "case2: HEAD moved"

# Case 3: nothing ahead (plain behind) -> refused (nothing to heal here)
fresh_pair c3
advance_origin c3
if drop_unpushed_auto_commits >/dev/null; then fail "case3: claimed a heal with nothing ahead"; fi

# Case 4: auto-commit ahead + uncommitted edit of a file the reset does NOT touch
fresh_pair c4
advance_origin c4
echo auto > auto.txt; git add auto.txt; git commit -q -m "sync: auto extensions (1 файлов) [sync-extensions-auto]"
echo precious > auto.txt.keep
echo "edited-by-other-session" >> f.txt
git fetch -q origin
git diff --quiet origin/main HEAD -- f.txt || fail "case4: fixture broken (f.txt should match)"
drop_unpushed_auto_commits >/dev/null || fail "case4: unrelated uncommitted edit blocked the heal"
grep -q edited-by-other-session f.txt || fail "case4: uncommitted edit was lost"
[ -e auto.txt.keep ] || fail "case4: untracked file was lost"

# Case 5: auto-commit ahead but origin did NOT move (push refused by a
# server-side hook, not by a race) -> refused, commit kept, so the alert stays loud
fresh_pair c5
echo auto > auto.txt; git add auto.txt; git commit -q -m "sync: auto extensions (1 файлов) [sync-extensions-auto]"
before=$(git rev-parse HEAD)
if drop_unpushed_auto_commits >/dev/null; then fail "case5: dropped a commit although origin never moved"; fi
[ "$(git rev-parse HEAD)" = "$before" ] || fail "case5: HEAD moved"

# Case 6: diverged auto-commit, but HEAD is on another branch -> refused
fresh_pair c6
advance_origin c6
git checkout -q -b side
echo auto > auto.txt; git add auto.txt; git commit -q -m "sync: auto extensions (1 файлов) [sync-extensions-auto]"
before=$(git rev-parse HEAD)
if drop_unpushed_auto_commits >/dev/null; then fail "case6: reset a non-main branch"; fi
[ "$(git rev-parse HEAD)" = "$before" ] || fail "case6: HEAD moved"

# Case 7: uncommitted edit overlaps a file the drop would rewrite -> reset
# --keep refuses, the edit survives, function reports failure
fresh_pair c7
git clone -q "$WORK/c7.git" "$WORK/c7-other" 2>/dev/null
git -C "$WORK/c7-other" config user.email t@example.invalid
git -C "$WORK/c7-other" config user.name t
echo upstream > "$WORK/c7-other/f.txt"
git -C "$WORK/c7-other" commit -q -am "upstream edits f.txt"
git -C "$WORK/c7-other" push -q origin HEAD:main
echo auto > f.txt; git commit -q -am "sync: auto extensions (1 файлов) [sync-extensions-auto]"
echo precious >> f.txt
if drop_unpushed_auto_commits >/dev/null 2>&1; then fail "case7: reset ran over an overlapping uncommitted edit"; fi
grep -q precious f.txt || fail "case7: uncommitted edit was lost"

# Case 8: a `git revert` of an auto-commit has the marker in its subject but is
# a human rollback -> refused, commit kept (the documented rollback path)
fresh_pair c8
advance_origin c8
echo auto > auto.txt; git add auto.txt; git commit -q -m "sync: auto extensions (1 файлов) [sync-extensions-auto]"
git revert --no-edit HEAD >/dev/null
before=$(git rev-parse HEAD)
if drop_unpushed_auto_commits >/dev/null; then fail "case8: dropped a human git revert"; fi
[ "$(git rev-parse HEAD)" = "$before" ] || fail "case8: HEAD moved"

# Case 9: two stacked auto-commits are both dropped
fresh_pair c9
advance_origin c9
for n in 1 2; do
  echo "auto$n" > "auto$n.txt"; git add "auto$n.txt"
  git commit -q -m "sync: auto extensions ($n файлов) [sync-extensions-auto]"
done
drop_unpushed_auto_commits >/dev/null || fail "case9: stacked auto-commits refused"
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "case9: HEAD != origin/main"

echo "PASS: self-heal smoke (9 cases)"
