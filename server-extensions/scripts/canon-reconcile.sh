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

# Peer session 2026-09-21-17-wp7-f163-ancestry-hardening (Claude+Codex), WP-7
# Ф163: `merge-base --is-ancestor` below must be blind to local replacement
# refs and legacy grafts, or a forged origin/<branch> can make a genuinely
# diverged HEAD look like a pure fast-forward case and lose an unpublished
# local commit via `merge --ff-only` -- reproduced live (WP-7 Ф163 report).
export GIT_NO_REPLACE_OBJECTS=1
export GIT_GRAFT_FILE=/dev/null/iwe-no-grafts

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
# The exit of this run removes the lock only when no owner record of ANOTHER run stands in it (WP-530 Ф81, rounds 11 and 12 of the peer session with Kimi and Codex): a lock that
# another run took over while this one was going, or a lock of the shared library (its record has node=, no host=), is not ours to delete. No record, or a record of this
# very run, is ours as before. ONE read of the record decides (a second read would only move the gap): a shell has no compare-and-delete, so a lock that is taken over at the very
# moment between that read and the rm is still removed, a window of about a millisecond when the run goes freely and without an upper bound when it is suspended there, that can only open when a run has taken over the LIVE lock of another (the old
# takeover does that when its signal is refused); the shared library never does. Written first for the three guards whose exit removed the lock whatever stood in it; the library replaces this function.
release_own_lock() {
  local verdict
  verdict=$(awk -F= -v h="$HOSTNAME_NOW" -v p="$$" '$1=="host"{oh=$2} $1=="pid"{op=$2} END { if (oh == "" && op == "") print "none"; else if (oh == h && op == p) print "ours"; else print "foreign" }' "$LOCK_META" 2>/dev/null) || :
  if [ "$verdict" = foreign ]; then return 0; fi
  rm -rf "$LOCK_DIR" 2>/dev/null || :
  return 0
}
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
trap release_own_lock EXIT
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
LISTED=$(printf '%s\n' "$CONFLICT_OUT" | sed -n 's/^\t//p')
if [ -z "$LISTED" ]; then
  echo "canon-reconcile: fast-forward failed for a reason this tool doesn't recognize — leaving untouched:" >&2
  printf '%s\n' "$CONFLICT_OUT" >&2
  exit 1
fi

# git lists BOTH tracked paths with local edits and UNTRACKED paths that the
# fast-forward would overwrite, in separate sections, but every listed path is
# a tab-indented line. Classify each path by the index itself (language
# independent, unlike the section headings).
#
# Untracked paths must never be stashed: `git stash push -u` puts them in the
# stash's third parent (stash@{n}^3), and the "was it superseded?" check below
# only diffs the tracked tree, so it cannot see them. 02.10.2026 03:03: the
# day's unpublished ledger file (49 events, untracked because the canon was 187
# commits behind and had never tracked it) was carried off exactly this way and
# became invisible to every consumer (WP-530 F74). An untracked path blocking
# the fast-forward is real, unreconciled content: refuse and leave the tree
# untouched so a human (or the ledger publisher) deals with it.
CONFLICTS=""
UNTRACKED_BLOCKERS=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    CONFLICTS="${CONFLICTS}${path}"$'\n'
  else
    UNTRACKED_BLOCKERS="${UNTRACKED_BLOCKERS}${path}"$'\n'
  fi
done <<LISTED_EOF
$LISTED
LISTED_EOF

if [ -n "$UNTRACKED_BLOCKERS" ]; then
  echo "canon-reconcile: untracked file(s) would be overwritten by the fast-forward — refusing, tree untouched (never stashed: an untracked file hides inside the stash's third parent). Publish or move these by hand:" >&2
  printf '%s' "$UNTRACKED_BLOCKERS" >&2
  exit 1
fi

STASH_MARKER="canon-reconcile $(date -u +%FT%TZ)"
STASH_ARGS=(stash push -m "$STASH_MARKER" --)
while IFS= read -r path; do
  [ -n "$path" ] && STASH_ARGS+=("$path")
done <<CONFLICTS_EOF
$CONFLICTS
CONFLICTS_EOF

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
