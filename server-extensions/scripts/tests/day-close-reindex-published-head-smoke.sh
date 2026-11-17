#!/usr/bin/env bash
# WP-484, bug-2026-11-17-multiline-note-file-claim-blocks-product-receipt.md, fix 4.
#
# day-close.sh decided what to reindex by "did this checkout commit something since
# midnight". That missed work published by other sessions or hosts, counted local commits
# that never reached origin, and never walked DS-IT-systems/* (bot docs were not indexed).
# The decision is now: did origin's main branch move past the last indexed commit?
#
# The real function bodies are extracted from day-close.sh and run against throwaway repos.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT_DIR/scripts/day-close.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/day-close-reindex.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

FAILURES=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    FAILURES=$((FAILURES + 1))
  fi
}

extract_fn() {  # <name>: prints the function body up to its closing brace in column 0
  awk -v fn="$1" '$0 ~ "^" fn "\\(\\) \\{" { active = 1 } active { print } active && $0 == "}" { exit }' "$SCRIPT"
}
FIXTURE="$TEST_ROOT/fn.sh"
: > "$FIXTURE"
for fn in repo_main_ref reindex_state_file repo_needs_reindex repo_mark_reindexed mark_reindexed_all iwe_repo_dirs; do
  extract_fn "$fn" >> "$FIXTURE"
  grep -q "^${fn}() {" "$FIXTURE" || { echo "FAIL: setup -- ${fn}() not found in day-close.sh"; exit 1; }
done
warn() { echo "WARN: $*" >&2; }
export REINDEX_STATE_DIR="$TEST_ROOT/state"
export WORKSPACE_DIR="$TEST_ROOT/work"
# shellcheck source=/dev/null
source "$FIXTURE"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
OLD_DATE="2020-01-01T10:00:00"

make_published_repo() {  # <name> <commit date> -> clone in $TEST_ROOT/work/<name>, bare origin beside it
  local name="$1" date="$2"
  git init -q --bare -b main "$TEST_ROOT/origin/$name.git"
  git clone -q "$TEST_ROOT/origin/$name.git" "$TEST_ROOT/work/$name" 2>/dev/null
  echo seed > "$TEST_ROOT/work/$name/f.md"
  git -C "$TEST_ROOT/work/$name" add f.md
  GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" git -C "$TEST_ROOT/work/$name" commit -q -m seed
  git -C "$TEST_ROOT/work/$name" push -q origin HEAD:main
  git -C "$TEST_ROOT/work/$name" fetch -q origin
}
needs() { repo_needs_reindex "$1" >/dev/null 2>&1 && echo yes || echo no; }

# --- 1. no record yet: only a commit published today counts ---------------------
make_published_repo old "$OLD_DATE"
check "no state, only old published commits: not needed" "no" "$(needs "$TEST_ROOT/work/old")"
make_published_repo fresh "$(date +%Y-%m-%dT%H:%M:%S)"
check "no state, commit made today: needed" "yes" "$(needs "$TEST_ROOT/work/fresh")"

# --- 2. a recorded commit: another session publishes, this checkout never commits ---
HEAD_OLD=$(git -C "$TEST_ROOT/work/old" rev-parse HEAD)
repo_mark_reindexed "$TEST_ROOT/work/old" "$HEAD_OLD"
check "mark writes the recorded commit" "$HEAD_OLD" "$(tr -d '[:space:]' < "$REINDEX_STATE_DIR/old.sha")"
check "recorded commit equals origin: not needed" "no" "$(needs "$TEST_ROOT/work/old")"

git clone -q "$TEST_ROOT/origin/old.git" "$TEST_ROOT/other-session" 2>/dev/null
echo more >> "$TEST_ROOT/other-session/f.md"
git -C "$TEST_ROOT/other-session" commit -q -am "other session"
git -C "$TEST_ROOT/other-session" push -q origin HEAD:main
git -C "$TEST_ROOT/work/old" fetch -q origin
# The reindex reads THIS checkout: while it has not received the other session's commit there is
# nothing new on disk to index, but the lag is reported and the repo is not silently marked current.
check "published by another session, checkout not updated yet: nothing new on disk" "no" "$(needs "$TEST_ROOT/work/old")"
LAG_NOTE=$(repo_needs_reindex "$TEST_ROOT/work/old" 2>&1 >/dev/null)
check "the lag behind origin is reported" "0" "$([ -z "$LAG_NOTE" ] && echo 1 || echo 0)"
git -C "$TEST_ROOT/work/old" merge -q --ff-only origin/main
check "checkout received the commit: needed" "yes" "$(needs "$TEST_ROOT/work/old")"
CAUGHT_UP=$(repo_needs_reindex "$TEST_ROOT/work/old" 2>/dev/null)
check "the recorded commit is the checkout's HEAD" "$(git -C "$TEST_ROOT/other-session" rev-parse HEAD)" "$CAUGHT_UP"
repo_mark_reindexed "$TEST_ROOT/work/old" "$CAUGHT_UP"
check "caught up and recorded: not needed" "no" "$(needs "$TEST_ROOT/work/old")"

# --- 3. an unpublished local commit is indexed ONCE, then recorded like any other --
echo local > "$TEST_ROOT/work/old/local.md"
git -C "$TEST_ROOT/work/old" add local.md
git -C "$TEST_ROOT/work/old" commit -q -m "local only"
check "local commit never pushed: its content is on disk, needed once" "yes" "$(needs "$TEST_ROOT/work/old")"
repo_mark_reindexed "$TEST_ROOT/work/old" "$(repo_needs_reindex "$TEST_ROOT/work/old" 2>/dev/null)"
check "after recording it, an unpublished commit no longer triggers the repo on every run" "no" "$(needs "$TEST_ROOT/work/old")"
check "the checkout is ahead of origin, so no lag note" "0" "$(repo_needs_reindex "$TEST_ROOT/work/old" 2>&1 >/dev/null | wc -c | tr -d ' ')"

# --- 4. no origin at all: nothing published to index ----------------------------
git init -q "$TEST_ROOT/work/noorigin"
git -C "$TEST_ROOT/work/noorigin" commit -q --allow-empty -m x
check "repo without origin: not needed" "no" "$(needs "$TEST_ROOT/work/noorigin")"

# --- 5. nested repositories are walked ------------------------------------------
mkdir -p "$TEST_ROOT/ws/DS-IT-systems" "$TEST_ROOT/ws/DS-top"
git init -q "$TEST_ROOT/ws/DS-top"
git init -q "$TEST_ROOT/ws/DS-IT-systems/bot-docs"
FOUND=$(iwe_repo_dirs "$TEST_ROOT"/ws/DS-* "$TEST_ROOT"/ws/DS-IT-systems/* | xargs -n1 basename | LC_ALL=C sort | tr '\n' ' ')
check "nested DS-IT-systems repo is listed with the top-level one" "DS-top bot-docs " "$FOUND"
# Same basename in two places must not share one state file.
check "state files of PACK-foo and DS-IT-systems/foo differ" "differ" \
  "$([ "$(reindex_state_file "$WORKSPACE_DIR/PACK-foo")" != "$(reindex_state_file "$WORKSPACE_DIR/DS-IT-systems/foo")" ] && echo differ || echo same)"
check "do_reindex passes DS-IT-systems/* to the walker" "1" \
  "$(grep -c 'iwe_repo_dirs "\$WORKSPACE_DIR"/PACK-\* "\$WORKSPACE_DIR"/DS-\* "\$WORKSPACE_DIR"/DS-IT-systems/\*' "$SCRIPT")"
check "state is written only after a successful branch" "2" "$(grep -c 'mark_reindexed_all "\$l[24]_marks"' "$SCRIPT")"

if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: reindex follows the published main branch and walks nested repositories"
  exit 0
fi
echo "FAILURES: $FAILURES"
exit 1
