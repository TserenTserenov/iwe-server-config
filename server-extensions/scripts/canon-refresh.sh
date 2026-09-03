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
# diagnosing a genuinely dirty or diverged tree)...
#
# ...with one narrow, provable exception (WP-538 Ф5а, 2026-09-03, peer
# session with Kimi+Codex, root cause: sync-strategy-files.sh's `git
# checkout origin/$BRANCH -- $FILE` stages content that already matches
# origin for specific known paths, leaving the tree tracked-dirty relative
# to a stale HEAD even though nothing would actually be lost by catching up
# — this was blocking iwe-tsekh1-sync for 62 commits at a time, repeatedly).
# When the tracked-dirty set is provably a mirror of a captured remote OID —
# every touched path belongs to a declared automation in
# automation-contract.conf, the whole index tree equals that OID's tree, and
# the whole worktree equals the index — advancing HEAD with `git reset
# --soft` loses nothing (index/worktree are untouched, already correct) and
# is not a self-heal reset of unknown dirt. Any tree that fails even one of
# these checks (unknown path, real edit, partial mirror, mid-race change)
# falls straight through to the unchanged refusal below. git-dirty-guard.sh
# itself is not touched by this — its exit contract for its 20+ other
# callers stays exactly as it was.
#
# Usage: canon-refresh.sh <repo-path> [branch]
# Exit codes: 0 = nothing to do, or fast-forwarded successfully.
#             1 = real problem (mid-rebase/merge, tree became dirty between
#                 the two clean checks, or the ff-only merge itself failed
#                 despite a proven-safe ancestry — should not happen, but
#                 must not be swallowed if it does).
#             2 = usage/repo error.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/automation-contract.sh
. "$SCRIPT_DIR/lib/automation-contract.sh"

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

# automation_mirror_snapshot <automation-name> <remote-oid>
# Fails closed (return 1) on anything that isn't a provable, whole-tree
# mirror of <remote-oid> made entirely of paths <automation-name> owns:
#   - no untracked files (status must be tracked-changes-only)
#   - every changed path has a plain modify/add status (no delete, rename,
#     copy, type-change or unmerged entry — sync-strategy-files.sh never
#     produces those, so seeing one means this isn't that automation's work)
#   - every changed path is declared for <automation-name> in
#     automation-contract.conf
#   - the whole index tree equals <remote-oid>'s tree, and the whole
#     worktree equals the index (not just the paths git-status flagged —
#     Codex's cold-review finding: origin could have also changed a path
#     outside the automation's allowlist that still matches the old,
#     stale HEAD locally, so it never shows up as dirty on its own)
automation_mirror_snapshot() {
  local automation="$1" remote_oid="$2"
  local status_output line xy x y path touched_paths=""

  status_output=$(git status --porcelain=v1 --untracked-files=all 2>/dev/null) || return 1
  [ -n "$status_output" ] || return 1

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    xy="${line:0:2}"
    path="${line:3}"
    x="${xy:0:1}"
    y="${xy:1:1}"
    case "$x" in
      ' '|'M'|'A') ;;
      *) return 1 ;;  # delete/rename/copy/unmerged/untracked marker in X
    esac
    case "$y" in
      ' '|'M') ;;
      *) return 1 ;;  # anything but "matches index" or "modified since staged"
    esac
    touched_paths="${touched_paths}${path}"$'\n'
  done <<EOF
$status_output
EOF

  [ -n "$touched_paths" ] || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    automation_contract_path_allowed "$automation" "$path" || return 1
  done <<EOF
$touched_paths
EOF

  git diff --cached --quiet "$remote_oid" -- 2>/dev/null || return 1
  git diff-files --quiet -- 2>/dev/null || return 1
  return 0
}

# try_automation_mirror_recovery <remote-oid>
# Returns 0 and leaves HEAD reset onto <remote-oid> only when every check in
# automation_mirror_snapshot passes twice in a row — once to decide, once
# again immediately before the mutation (same narrowing-the-window spirit as
# the pre-existing re-check above the ff-only merge below). Returns 1 with
# nothing touched for every other case, including a snapshot that stops
# passing between the two checks.
try_automation_mirror_recovery() {
  local remote_oid="$1" automation="sync-strategy-files" old_head new_head

  old_head=$(git rev-parse HEAD 2>/dev/null) || return 1
  git merge-base --is-ancestor "$old_head" "$remote_oid" 2>/dev/null || return 1
  automation_mirror_snapshot "$automation" "$remote_oid" || return 1

  # Re-check immediately before mutating: narrows the race window to the
  # width of these two calls — same spirit as the ff-only path's own late
  # re-check below. A HEAD that moved between the two checks means some
  # other process touched this repo concurrently; bail rather than trust a
  # snapshot taken against a HEAD that's no longer current.
  #
  # This narrows, but — same as every other check in this file and in
  # git-dirty-guard.sh — does not close the window outright: "This lock does
  # not authorize mutation: ordinary editors do not honor it, which is why
  # automatic reset/self-heal is deliberately absent" (git-dirty-guard.sh's
  # own words for the identical caveat). What makes this safe regardless is
  # `git reset --soft` itself, not the lock: it only moves the branch ref,
  # never touches the index or worktree, so even a same-instant edit by
  # something outside this lock's three cooperating scripts can't be
  # overwritten or lost by this call — the postcondition check right below
  # would catch the resulting mismatch and hard-fail instead of masking it.
  [ "$(git rev-parse HEAD 2>/dev/null)" = "$old_head" ] || return 1
  automation_mirror_snapshot "$automation" "$remote_oid" || return 1

  if ! git reset --soft "$remote_oid" 2>&1; then
    echo "canon-refresh: automation-mirror reset failed unexpectedly" >&2
    return 1
  fi

  new_head=$(git rev-parse HEAD 2>/dev/null)
  if [ "$new_head" != "$remote_oid" ] || ! git diff --cached --quiet 2>/dev/null \
    || ! git diff-files --quiet -- 2>/dev/null; then
    echo "canon-refresh: automation-mirror reset postcondition violated (HEAD=$new_head, expected $remote_oid) — investigate manually" >&2
    exit 1
  fi

  echo "canon-refresh: resolved a $automation mirror in $REPO — HEAD ${old_head:0:12} -> ${new_head:0:12} (git reset --soft, no index/worktree change)"
  return 0
}

if ! is_clean; then
  REMOTE_OID_FOR_RECOVERY=$(git rev-parse "origin/$BRANCH" 2>/dev/null) || REMOTE_OID_FOR_RECOVERY=""
  if [ -n "$REMOTE_OID_FOR_RECOVERY" ] && try_automation_mirror_recovery "$REMOTE_OID_FOR_RECOVERY"; then
    exit 0
  fi
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
