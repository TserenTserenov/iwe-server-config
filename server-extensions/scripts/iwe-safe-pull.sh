#!/usr/bin/env bash
# iwe-safe-pull.sh -- Pull-on-Touch (AR.006) via git-dirty-guard.sh instead of raw --autostash.
#
# WP-484 recurrence 08.08: on tsekh-1, multiple concurrent agent sessions share one
# DS-my-strategy checkout. Raw `git pull --rebase --autostash` autostashes whatever
# ANOTHER session left uncommitted and rebases over it; when origin also touched the
# same file, the auto-pop at the end conflicts and wedges the working tree (confirmed
# live twice in ~36h: the resulting conflict has no MERGE_HEAD/rebase-merge marker, so
# it doesn't even surface as "mid-rebase" -- it just sits there until someone notices).
#
# git-dirty-guard.sh already solves the underlying problem for the periodic sync timer
# (tsekh1-git-sync.sh, WP-484 Ф69/Ф70): a stale-lock-aware mkdir lock, self-heal only
# for byte-identical drift, honest refusal (no touch, no stash) on real uncommitted
# work or a mid-rebase/merge tree. This script gives Pull-on-Touch the same protection
# instead of re-deriving it ad hoc per agent session.
#
# Usage: iwe-safe-pull.sh <repo-path> [branch]
# Exit codes: 0 = up to date (rebased cleanly if needed).
#             1 = pull skipped -- guard refused, or rebase itself failed. Working tree
#                 is left exactly as it was either way. Caller proceeds with session
#                 output marked potentially-stale (AR.006 exception path) instead of
#                 blocking.
set -uo pipefail

REPO="${1:?usage: iwe-safe-pull.sh <repo-path> [branch]}"
IWE="${IWE_ROOT:-$HOME/IWE}"
GUARD="${IWE_SAFE_PULL_GUARD:-$IWE/scripts/git-dirty-guard.sh}"

cd "$REPO" 2>/dev/null || { echo "iwe-safe-pull: cannot cd to $REPO" >&2; exit 1; }

BRANCH="${2:-}"
[ -n "$BRANCH" ] || BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  echo "iwe-safe-pull: detached HEAD in $REPO, refusing" >&2
  exit 1
fi

if ! bash "$GUARD" "$REPO" "$BRANCH"; then
  echo "iwe-safe-pull: guard refused -- real uncommitted work or mid-rebase/merge, pull skipped (tree untouched)" >&2
  exit 1
fi

if git rebase "origin/$BRANCH" >/dev/null 2>&1; then
  echo "iwe-safe-pull: rebased onto origin/$BRANCH ($(git rev-parse --short HEAD))"
  exit 0
fi

echo "iwe-safe-pull: guard passed but rebase failed (race with a concurrent writer?) -- aborting rebase, tree left as before" >&2
git rebase --abort 2>/dev/null || true
exit 1
