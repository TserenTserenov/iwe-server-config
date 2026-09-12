#!/usr/bin/env bash
# canon-reconcile.sh <repo-path> [branch] — resolve a "purely behind, dirty"
# canonical checkout: HEAD is a strict ancestor of origin/<branch>, but the
# tree carries local modifications to tracked files that block a plain
# fast-forward. canon-refresh.sh deliberately no-ops on this shape (2026-09-01
# design, WP-484 AF): a dirty tree might hold a real, never-committed edit
# from an ordinary editor that never took the lock, and silently discarding
# that would be worse than leaving the tree stale. This script keeps that
# same refusal — it only removes a local diff when the result on disk after
# fast-forwarding is byte-identical to what was there before, i.e. the local
# content was already fully superseded by something already on origin. Any
# path where that isn't true is left in the stash for a human/agent to look
# at by hand.
#
# Wired into ds-publish.sh's post-publish step, right after canon-refresh.sh
# (WP-530 Ф33): that script already handles the clean-tree case; this one
# covers what it deliberately leaves alone. Also safe to run by hand any time
# `iwe-safe-pull.sh`/git-dirty-guard.sh has told you the tree is behind-and-
# dirty and you want it resolved now instead of waiting for the next publish.
#
# Usage: canon-reconcile.sh <repo-path> [branch]
# Exit codes: 0 = already in sync, or fully reconciled.
#             1 = real problem (diverged history, mid-rebase/merge, or a
#                 stashed path still differs after the fast-forward — left
#                 untouched in `git stash list` for manual resolution).
#             2 = usage/repo error.

set -uo pipefail

if [ -z "${1:-}" ]; then
  echo "usage: canon-reconcile.sh <repo-path> [branch]" >&2
  exit 2
fi
REPO="$1"
BRANCH="${2:-}"

cd "$REPO" 2>/dev/null || { echo "canon-reconcile: cannot cd to $REPO" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "canon-reconcile: $REPO is not a git repo" >&2; exit 2; }

GIT_DIR=$(git rev-parse --git-dir)
if [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ] || [ -f "$GIT_DIR/MERGE_HEAD" ]; then
  echo "canon-reconcile: $REPO is mid-rebase/merge — refusing to touch, needs manual recovery" >&2
  exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$CURRENT_BRANCH" ] || [ "$CURRENT_BRANCH" = "HEAD" ]; then
  echo "canon-reconcile: detached HEAD in $REPO, refusing" >&2
  exit 2
fi
[ -n "$BRANCH" ] || BRANCH="$CURRENT_BRANCH"
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
  echo "canon-reconcile: checked-out branch is $CURRENT_BRANCH, not requested $BRANCH — refusing" >&2
  exit 2
fi

# Same lock directory as canon-refresh.sh/git-dirty-guard.sh (not a separate
# namespace) so all three serialize against each other for free — whichever
# acquires it first runs to completion before the next's mkdir can succeed.
LOCK_DIR="$GIT_DIR/dirty-guard.lock"
LOCK_META="$LOCK_DIR/owner"
HOSTNAME_NOW="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -f "$LOCK_META" ]; then
    OTHER_HOST=$(awk -F= '$1=="host"{print $2}' "$LOCK_META" 2>/dev/null)
    OTHER_PID=$(awk -F= '$1=="pid"{print $2}' "$LOCK_META" 2>/dev/null)
    if [ "$OTHER_HOST" = "$HOSTNAME_NOW" ] && [ -n "$OTHER_PID" ] && ! kill -0 "$OTHER_PID" 2>/dev/null; then
      echo "canon-reconcile: reclaiming stale lock (pid=$OTHER_PID on $OTHER_HOST no longer running)" >&2
      rm -rf "$LOCK_DIR" 2>/dev/null
    fi
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "canon-reconcile: lock busy (another refresh in progress), skipping this cycle"
    exit 0
  fi
fi
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT
printf 'host=%s\npid=%s\n' "$HOSTNAME_NOW" "$$" > "$LOCK_META"

if ! git fetch origin "$BRANCH" --quiet 2>/dev/null; then
  echo "canon-reconcile: fetch failed (offline?) — nothing to check" >&2
  exit 1
fi

HEAD_OID=$(git rev-parse HEAD)
REMOTE_OID=$(git rev-parse "origin/$BRANCH" 2>/dev/null) || { echo "canon-reconcile: no origin/$BRANCH" >&2; exit 2; }

if [ "$HEAD_OID" = "$REMOTE_OID" ]; then
  echo "canon-reconcile: already at origin/$BRANCH"
  exit 0
fi

if ! git merge-base --is-ancestor HEAD "origin/$BRANCH" 2>/dev/null; then
  echo "canon-reconcile: HEAD has commit(s) origin/$BRANCH doesn't have — history diverged, not this tool's job (rebase --onto by hand)" >&2
  exit 1
fi

if git merge --ff-only -q "origin/$BRANCH" 2>/dev/null; then
  echo "canon-reconcile: fast-forwarded $REPO from ${HEAD_OID:0:12} to ${REMOTE_OID:0:12} (tree was already clean)"
  exit 0
fi

# ff-only refused because tracked files would be overwritten. Extract exactly
# those paths from git's own error text (one per line, tab-indented) rather
# than re-deriving them from `git status` — that's the authoritative list of
# what's actually blocking, nothing more, nothing less.
CONFLICT_OUT=$(git merge --ff-only "origin/$BRANCH" 2>&1)
CONFLICTS=$(printf '%s\n' "$CONFLICT_OUT" | sed -n 's/^\t//p')
if [ -z "$CONFLICTS" ]; then
  echo "canon-reconcile: fast-forward failed for a reason this tool doesn't recognize — leaving untouched:" >&2
  printf '%s\n' "$CONFLICT_OUT" >&2
  exit 1
fi

STASH_MARKER="canon-reconcile $(date -u +%FT%TZ)"
STASH_ARGS=(stash push -u -m "$STASH_MARKER" --)
while IFS= read -r path; do
  [ -n "$path" ] && STASH_ARGS+=("$path")
done <<EOF
$CONFLICTS
EOF

if ! git "${STASH_ARGS[@]}" >/dev/null 2>&1; then
  echo "canon-reconcile: could not stash the blocking paths — leaving tree untouched" >&2
  exit 1
fi
STASH_OID=$(git rev-parse stash@{0})

if ! git merge --ff-only -q "origin/$BRANCH" 2>/dev/null; then
  git stash pop -q 2>/dev/null || echo "canon-reconcile: fast-forward still failed AND stash pop failed — check 'git stash list' by hand" >&2
  echo "canon-reconcile: fast-forward still failed after stashing the blockers — restored stash, tree unchanged" >&2
  exit 1
fi

# The worktree now equals the new HEAD by construction (that's what a
# fast-forward checkout does) — diffing it against HEAD would always be
# empty and prove nothing. What actually needs checking is whether the
# content that was stashed away is still different from what origin already
# has: identical means it was superseded and safe to drop, different means
# it's real information the fast-forward didn't capture.
STILL_DIFFERS=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  git diff --quiet "$STASH_OID" HEAD -- "$path" 2>/dev/null || STILL_DIFFERS="${STILL_DIFFERS}${path}"$'\n'
done <<EOF
$CONFLICTS
EOF

if [ -z "$STILL_DIFFERS" ]; then
  git stash drop -q
  echo "canon-reconcile: $REPO synced to origin/$BRANCH (local content was already superseded, stash dropped)"
  exit 0
fi

echo "canon-reconcile: fast-forwarded, but these paths still differ from what's now on origin — real content, left in stash for manual review:" >&2
printf '%s' "$STILL_DIFFERS" >&2
echo "canon-reconcile: run 'git stash show -p' in $REPO to inspect before deciding pop/drop" >&2
exit 1
