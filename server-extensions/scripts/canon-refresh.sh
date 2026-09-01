#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, WP-484 AF (peer-session 2026-09-01-04-wp484-af-canon-staleness,
# consensus Claude+Kimi+Codex)
#
# canon-refresh.sh — fast-forwards a completely clean, purely-behind checkout
# to origin/<branch>.
#
# Correction (2026-09-01, found while updating this comment): an earlier
# draft of this note claimed git-dirty-guard.sh self-heals a byte-identical
# dirty mirror via `reset --hard`. That claim was based on reading a
# different agent's uncommitted local edit sitting in a shared checkout, not
# the actual committed script. The real committed git-dirty-guard.sh has no
# self-heal path at all — 2026-08-30 removed it entirely; the guard only
# diagnoses and refuses (exit 1), never mutates. So there is no dirty-mirror
# case for this script to avoid duplicating — git-dirty-guard.sh currently
# heals nothing, for any staleness shape.
#
# What this script closes: the one case neither git-dirty-guard.sh nor
# Pull-on-Touch's "first touch of a session" check covers — a tree that is
# already completely clean but whose HEAD simply never advanced, discovered
# only when someone happens to look. That is exactly what happened
# 2026-08-31: a canonical checkout sat untouched for ~5 hours while origin
# advanced ~90 commits, surfacing as a 69-path divergence discovered by
# accident.
#
# Safety condition: a fast-forward is safe if and only if the tree has zero
# uncommitted changes (tracked or untracked) and HEAD is a strict ancestor
# of origin/<branch>. If either fails, this script does nothing and exits 0
# — it is not this script's job to diagnose or alert on those cases
# (git-dirty-guard.sh and the pilot's own Pull-on-Touch flow already own
# diagnosing a genuinely dirty or diverged tree).
#
# Usage: canon-refresh.sh <repo-path> [branch]
# Exit codes: 0 = nothing to do, or fast-forwarded successfully.
#             1 = real problem (mid-rebase/merge, tree became dirty between
#                 the two clean checks, or the ff-only merge itself failed
#                 despite a proven-safe ancestry — should not happen, but
#                 must not be swallowed if it does).
#             2 = usage/repo error.

set -uo pipefail

if [ -z "${1:-}" ]; then
  echo "usage: canon-refresh.sh <repo-path> [branch]" >&2
  exit 2
fi
REPO="$1"
BRANCH="${2:-}"

cd "$REPO" 2>/dev/null || { echo "canon-refresh: cannot cd to $REPO" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "canon-refresh: $REPO is not a git repo" >&2; exit 2; }

GIT_DIR=$(git rev-parse --git-dir)

# Same class of hazard as git-dirty-guard.sh: resetting/merging through an
# in-progress rebase or merge would compound the mess, not clean it up.
if [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ] || [ -f "$GIT_DIR/MERGE_HEAD" ]; then
  echo "canon-refresh: $REPO is mid-rebase/merge — refusing to touch, needs manual recovery" >&2
  exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$CURRENT_BRANCH" ] || [ "$CURRENT_BRANCH" = "HEAD" ]; then
  echo "canon-refresh: detached HEAD in $REPO, refusing" >&2
  exit 2
fi
[ -n "$BRANCH" ] || BRANCH="$CURRENT_BRANCH"

# Cold-review finding (Codex, 2026-09-01): a caller passing a --branch
# argument that differs from what's actually checked out would fast-forward
# the WRONG branch (e.g. checked out on `feature`, called with `main` —
# ancestry could still hold and silently move `feature` onto origin/main).
# This tool only ever refreshes the branch that's actually checked out.
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
  echo "canon-refresh: checked-out branch is $CURRENT_BRANCH, not requested $BRANCH — refusing" >&2
  exit 2
fi

# mkdir-based lock. Reuses git-dirty-guard.sh's own lock directory name
# (same $GIT_DIR/dirty-guard.lock, not a separate canon-refresh.lock) so the
# two tools serialize against each other for free: whichever acquires it
# first runs to completion before the other's mkdir can succeed. git-dirty-
# guard.sh takes this lock for the full duration of every run regardless of
# whether that run ends up mutating anything, so a separate lock namespace
# here would still let both tools inspect/touch the same worktree at once
# with no coordination between them (cold-review, Codex, 2026-09-01 —
# Critical/High findings on an earlier draft that used a separate lock).
LOCK_DIR="$GIT_DIR/dirty-guard.lock"
LOCK_META="$LOCK_DIR/owner"
HOSTNAME_NOW="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -f "$LOCK_META" ]; then
    OTHER_HOST=$(awk -F= '$1=="host"{print $2}' "$LOCK_META" 2>/dev/null)
    OTHER_PID=$(awk -F= '$1=="pid"{print $2}' "$LOCK_META" 2>/dev/null)
    if [ "$OTHER_HOST" = "$HOSTNAME_NOW" ] && [ -n "$OTHER_PID" ] && ! kill -0 "$OTHER_PID" 2>/dev/null; then
      echo "canon-refresh: reclaiming stale lock (pid=$OTHER_PID on $OTHER_HOST no longer running)" >&2
      rm -rf "$LOCK_DIR" 2>/dev/null
    fi
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "canon-refresh: lock busy (another refresh in progress), skipping this cycle" >&2
    exit 0
  fi
fi
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT
printf 'host=%s\npid=%s\n' "$HOSTNAME_NOW" "$$" > "$LOCK_META"

if ! git fetch origin "$BRANCH" --quiet 2>/dev/null; then
  echo "canon-refresh: fetch failed (offline?) — nothing to check"
  exit 0
fi

if ! git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  echo "canon-refresh: no origin/$BRANCH — nothing to check"
  exit 0
fi

# Fail-closed on a broken `git status` (cold-review, Codex, 2026-09-01):
# command substitution swallows a non-zero exit and returns an empty string,
# which the old `[ -z "$(...)" ]` form would misread as "clean" instead of
# "unknown, could not verify" — the opposite of what this tool ever wants to
# assume for a mutation it initiates unattended.
is_clean() {
  local status_output
  status_output=$(git status --porcelain 2>/dev/null) || return 1
  [ -z "$status_output" ]
}

if ! is_clean; then
  echo "canon-refresh: tree not clean — nothing to do (git-dirty-guard.sh/pilot own that case)"
  exit 0
fi

HEAD_OID=$(git rev-parse HEAD)
REMOTE_OID=$(git rev-parse "origin/$BRANCH")

if [ "$HEAD_OID" = "$REMOTE_OID" ]; then
  echo "canon-refresh: already at origin/$BRANCH"
  exit 0
fi

if ! git merge-base --is-ancestor HEAD "origin/$BRANCH" 2>/dev/null; then
  echo "canon-refresh: HEAD has commit(s) origin/$BRANCH doesn't have — not a pure staleness case, leaving untouched"
  exit 0
fi

# Re-check clean immediately before mutating: narrows the window between the
# first check and the merge to the width of one more git-status call, same
# spirit as git-dirty-guard.sh's own late-race checks.
if ! is_clean; then
  echo "canon-refresh: tree became dirty during the check — aborting fast-forward" >&2
  exit 1
fi

if ! git merge --ff-only -q "origin/$BRANCH" 2>&1; then
  echo "canon-refresh: fast-forward failed despite proven ancestry — investigate manually" >&2
  exit 1
fi

echo "canon-refresh: fast-forwarded $REPO from ${HEAD_OID:0:12} to ${REMOTE_OID:0:12} (origin/$BRANCH)"
exit 0
