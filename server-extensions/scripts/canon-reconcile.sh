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
# The one exception is the event ledger (machine/ledger/*.yaml). Its dirty
# tail is not a stray edit: it is the day's events that were written but not
# yet published, and the stash route lost them (26.10.2026: 152 events, 15 of
# them session closures, sat in 28 forgotten stashes and every consumer saw
# the sessions as closed without a record, WP-484 Ф251/Ф255). So for ledger
# paths this script (1) holds the same flock the ledger writer takes for the
# whole dry run -> stash -> fast-forward -> merge-back window, so no event lands
# in between; (2) does a dry run of the merge BEFORE touching anything and
# refuses with "ledger tail NOT safe to reconcile" (tree untouched) if it cannot
# be proven lossless; and (3) after the fast-forward merges the stashed events
# back into the working file, three-way (base = the HEAD this run started from,
# so an event origin deliberately deleted does not come back), through
# ledger-event-diff.py --merge-driver. The tail then stays as an ordinary
# unpublished diff for the ledger publisher. If the merge-back still fails after
# the fast-forward, the stash stays and the exit code is 1.
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
SCRIPT_DIR="${BASH_SOURCE[0]}"; case "$SCRIPT_DIR" in */*) SCRIPT_DIR="${SCRIPT_DIR%/*}" ;; *) SCRIPT_DIR=. ;; esac; case "$SCRIPT_DIR" in /*) ;; *) SCRIPT_DIR="./$SCRIPT_DIR" ;; esac; SCRIPT_DIR=$(cd "$SCRIPT_DIR" >/dev/null 2>&1 && pwd && printf x); SCRIPT_DIR="${SCRIPT_DIR%x}"; SCRIPT_DIR="${SCRIPT_DIR%$'\n'}"   # computed before the cd below, without dirname (a minimal PATH has none) and without CDPATH; the marker x keeps a newline at the end of a directory name: the lock library is found next to this script

cd "$REPO" 2>/dev/null || { echo "canon-reconcile: cannot cd to $REPO" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "canon-reconcile: $REPO is not a git repo" >&2; exit 2; }

GIT_DIR=$(git rev-parse --git-dir && printf x); GIT_DIR="${GIT_DIR%x}"; GIT_DIR="${GIT_DIR%$'\n'}"   # the marker x keeps a newline at the end of the name (the lock is made where the guard says)
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
# The lock itself (the takeover rule: only when the owner is PROVEN gone; the owner record; the release: only a lock with our token) lives
# in scripts/lib/dirty-guard-lock.sh, shared by the five guard scripts (WP-530 Ф81 remainder, peer session 2026-10-02-01). What THIS script
# does when the lock is busy stays here.
DGLOCK_LIB="$SCRIPT_DIR/lib/dirty-guard-lock.sh"
unset DGLOCK_LIB_READY   # a marker inherited from the environment must not vouch for a library that was cut short
# shellcheck source=lib/dirty-guard-lock.sh
if [ -r "$DGLOCK_LIB" ] && . "$DGLOCK_LIB" && [ "${DGLOCK_LIB_READY:-}" = 1 ]; then :; else
  echo "canon-reconcile: the lock library is missing or unusable: $DGLOCK_LIB (scripts/ and scripts/lib/ are updated together); nothing was done" >&2
  exit 1
fi
trap 'dglock_release' EXIT   # set BEFORE the lock is asked for: a signal that arrives between the library's mkdir and its owner record must still remove the empty directory
rc=0; dglock_acquire "$GIT_DIR" canon-reconcile || rc=$?
case "$rc" in
  0) ;;
  1) echo "canon-reconcile: lock busy (another refresh in progress), skipping this cycle -- $DGLOCK_REASON"; exit 0 ;;
  *) echo "canon-reconcile: $DGLOCK_REASON" >&2; exit 1 ;;
esac

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

is_ledger_path() {
  case "$1" in
    machine/ledger/*.yaml) return 0 ;;
    *) return 1 ;;
  esac
}

# A dirty ledger tail is carried over, never set aside and forgotten (see the
# header). Three parts: the writer's lock, a dry run BEFORE anything moves, and
# the real merge-back after the fast-forward.
FLOCK_BIN="${CANON_RECONCILE_FLOCK:-flock}"
LEDGER_LOCK_WAIT="${CANON_RECONCILE_LEDGER_LOCK_WAIT:-30}"
LEDGER_TOOL="${CANON_RECONCILE_LEDGER_TOOL:-./scripts/lib/ledger-event-diff.py}"
LEDGER_UNSAFE="canon-reconcile: ledger tail NOT safe to reconcile"

# ledger_carry <path> <theirs file> <ours ref> <out file>: three-way merge of the
# event sets (base = the HEAD this run started from, ours = the file at <ours
# ref>, theirs = the dirty copy) by the ledger's own merge driver, so an event
# that origin deliberately deleted does not come back. The result counts only if
# it parses strictly and holds every event of the dirty copy: a deletion on
# origin of an event the dirty copy still has fails this check on purpose and
# leaves the decision to a human.
ledger_carry() {
  local path="$1" theirs="$2" ours_ref="$3" out="$4" work rc=1
  [ -r "$LEDGER_TOOL" ] || { echo "canon-reconcile: the ledger merge tool is missing: $LEDGER_TOOL" >&2; return 1; }
  work=$(mktemp -d "${TMPDIR:-/tmp}/canon-reconcile-ledger.XXXXXX") || return 1
  if git show "$HEAD_OID:$path" > "$work/base.yaml" 2>"$work/err" \
     && git show "$ours_ref:$path" > "$work/ours.yaml" 2>>"$work/err" \
     && python3 "$LEDGER_TOOL" --merge-driver "$work/base.yaml" "$work/ours.yaml" "$theirs" 2>>"$work/err" \
     && python3 "$LEDGER_TOOL" --validate "$work/ours.yaml" >/dev/null 2>>"$work/err" \
     && python3 "$LEDGER_TOOL" --source-subset "$theirs" "$work/ours.yaml" >/dev/null 2>>"$work/err" \
     && cp "$work/ours.yaml" "$out" 2>>"$work/err"; then
    rc=0
  else
    cat "$work/err" >&2
  fi
  rm -rf "$work"
  return $rc
}

LEDGER_CONFLICTS=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  is_ledger_path "$path" && LEDGER_CONFLICTS="${LEDGER_CONFLICTS}${path}"$'\n'
done <<CONFLICTS_EOF
$CONFLICTS
CONFLICTS_EOF

LOCK_T0=0
if [ -n "$LEDGER_CONFLICTS" ]; then
  if ! command -v "$FLOCK_BIN" >/dev/null 2>&1; then
    echo "$LEDGER_UNSAFE — '$FLOCK_BIN' is not available, so a concurrent writer cannot be kept out; refusing, tree untouched:" >&2
    printf '%s' "$LEDGER_CONFLICTS" >&2
    exit 1
  fi
  # Hold the ledger writer's lock (`<ledger file>.lock`, the file ledger-append.sh
  # flocks) from before the dry run until the merge-back is done. Descriptors are
  # numbered by hand: bash 3.2 on macOS has no `exec {fd}>`. Exit 75 is "timed
  # out" (the same convention as ledger-append.sh); any other failure is a broken
  # lock call and must not pass for a busy writer.
  lock_fd=200
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    eval "exec $lock_fd<>\"./\$path.lock\"" 2>/dev/null || { echo "$LEDGER_UNSAFE — cannot open the lock file of $path; refusing, tree untouched" >&2; exit 1; }
    lock_rc=0
    "$FLOCK_BIN" -x -w "$LEDGER_LOCK_WAIT" -E 75 "$lock_fd" || lock_rc=$?
    case "$lock_rc" in
      0) ;;
      75) echo "canon-reconcile: a ledger writer holds the lock of $path for more than ${LEDGER_LOCK_WAIT}s, skipping this cycle (tree untouched)"; exit 0 ;;
      *) echo "$LEDGER_UNSAFE — the lock call on $path failed with code $lock_rc; refusing, tree untouched" >&2; exit 1 ;;
    esac
    lock_fd=$((lock_fd + 1))
  done <<LEDGER_EOF
$LEDGER_CONFLICTS
LEDGER_EOF
  LOCK_T0=$(date +%s)

  # Dry run, before anything moves: the same merge the real step will do, on the
  # dirty file as it is now against origin's tip. Any refusal here leaves the
  # tree exactly as it was, instead of failing after the stash and the
  # fast-forward have already taken the tail off the disk.
  PRE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/canon-reconcile-pre.XXXXXX") || { echo "$LEDGER_UNSAFE — no scratch directory; refusing, tree untouched" >&2; exit 1; }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if ! ledger_carry "$path" "./$path" "origin/$BRANCH" "$PRE_DIR/dry-run.yaml"; then
      rm -rf "$PRE_DIR"
      echo "$LEDGER_UNSAFE — $path cannot be merged with origin without loss (details above); refusing, tree untouched" >&2
      exit 1
    fi
  done <<LEDGER_EOF
$LEDGER_CONFLICTS
LEDGER_EOF
  rm -rf "$PRE_DIR"
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
STASH_OID=$(git rev-parse "stash@{0}")

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

# Merge-back of the ledger tail. Every step must prove itself before a path
# counts as resolved; the file is replaced through a temporary neighbour, so an
# interrupted run never leaves a half-written ledger.
LEDGER_MERGED=""
merge_ledger_path() {
  local path="$1" work
  work=$(mktemp -d "${TMPDIR:-/tmp}/canon-reconcile-ledger.XXXXXX") || return 1
  if git show "$STASH_OID:$path" > "$work/stash.yaml" 2>"$work/err" \
     && ledger_carry "$path" "$work/stash.yaml" HEAD "$work/merged.yaml" \
     && cp "$work/merged.yaml" "$path.tmp.$$" 2>>"$work/err" \
     && mv -f "$path.tmp.$$" "$path" 2>>"$work/err"; then
    rm -rf "$work"
    return 0
  fi
  cat "$work/err" >&2
  rm -f "$path.tmp.$$"
  rm -rf "$work"
  return 1
}

if [ -n "$STILL_DIFFERS" ]; then
  REMAINING=""
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if is_ledger_path "$path" && merge_ledger_path "$path"; then
      LEDGER_MERGED="${LEDGER_MERGED}${path}"$'\n'
      echo "canon-reconcile: $path — unpublished ledger events merged back into the fast-forwarded file (three-way with origin, nothing lost)"
    else
      REMAINING="${REMAINING}${path}"$'\n'
    fi
  done <<EOF
$STILL_DIFFERS
EOF
  STILL_DIFFERS="$REMAINING"
fi

# The writer's budget for the lock is 60 s (ledger-append.sh): a longer window loses its event.
if [ "$LOCK_T0" -gt 0 ] && [ $(( $(date +%s) - LOCK_T0 )) -gt 30 ]; then
  echo "canon-reconcile: WARN the ledger lock was held for $(( $(date +%s) - LOCK_T0 )) s (a waiting writer gives up after 60 s)" >&2
fi

if [ -z "$STILL_DIFFERS" ]; then
  # Never drop an entry someone else pushed since ours.
  if [ "$(git rev-parse "stash@{0}" 2>/dev/null)" != "$STASH_OID" ]; then
    echo "canon-reconcile: stash@{0} is no longer the entry made by this run — not dropping anything, check 'git stash list' by hand" >&2
    exit 1
  fi
  git stash drop -q
  if [ -n "$LEDGER_MERGED" ]; then
    echo "canon-reconcile: $REPO synced to origin/$BRANCH (ledger tail carried over as an unpublished diff, stash dropped)"
  else
    echo "canon-reconcile: $REPO synced to origin/$BRANCH (local content was already superseded, stash dropped)"
  fi
  exit 0
fi

echo "canon-reconcile: fast-forwarded, but these paths still differ from what's now on origin — real content, left in stash for manual review:" >&2
printf '%s' "$STILL_DIFFERS" >&2
if [ -n "$LEDGER_MERGED" ]; then
  echo "canon-reconcile: the ledger file(s) below are ALREADY merged back on disk — take only the paths above from the stash (git checkout stash@{0} -- <path>), do not pop the ledger:" >&2
  printf '%s' "$LEDGER_MERGED" >&2
fi
echo "canon-reconcile: run 'git stash show -p' in $REPO to inspect before deciding pop/drop" >&2
exit 1
