#!/usr/bin/env bash
# sync-owned-canon.sh -- one predicate: is this checkout the MAIN checkout of the
# governance repository DS-my-strategy, whose branch only tsekh1-git-sync.sh may
# advance? SOURCED by canon-refresh.sh and canon-reconcile.sh, never executed.
#
# WP-530 Ф150 (И-8/И-9, peer session 2026-11-13-15-canon-reconcile-merge-claim,
# Claude+Kimi+Codex, reviewed by Fable). On 13.11 the main checkout on the server
# was fast-forwarded by canon-refresh.sh, called from ds-publish.sh after the
# auto Day Open publication, over 415 paths with no path claim while a Day Open
# session was live; the Mac saw 57 such merges the same day. Only
# tsekh1-git-sync.sh claims the whole diff in the session guard before it merges
# (declare_sync_scope), so the main checkout is advanced by it alone; the other
# tools defer.
#
# Fail-closed by construction (Fable С2): no environment variable decides. The
# checkout is protected when
#   - it is not a linked worktree (git-dir equals git-common-dir): isolated
#     session copies are linked worktrees and stay untouched by this rule, and
#   - the last component of its origin URL is DS-my-strategy (".git" stripped).
# A second full clone of DS-my-strategy is protected too: refusing there costs a
# deferred refresh, merging there unclaimed is the incident itself.
#
#   sync_owned_canon <dir>   0 = protected (do not advance it), 1 = not protected
sync_owned_canon() {  # <dir>
  local dir="$1" git_dir common_dir url name
  git_dir=$(git -C "$dir" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
  common_dir=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$git_dir" = "$common_dir" ] || return 1
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  url="${url%/}"
  name="${url##*/}"
  name="${name##*:}"
  name="${name%.git}"
  [ "$name" = "DS-my-strategy" ]
}

# shellcheck disable=SC2034  # read by the scripts that source this file
SYNC_OWNED_CANON_NOTE="main DS-my-strategy checkout is advanced only by tsekh1-git-sync.sh (it claims the paths first, WP-530 Ф150)"
