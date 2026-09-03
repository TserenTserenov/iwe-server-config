#!/usr/bin/env bash
# automation-contract.sh — WP-538 Ф5а shared reader for automation-contract.conf.
#
# No associative arrays and no `exec {fd}>` — this repo's own history has two
# documented bash-3.2 (macOS system /bin/bash) crashes from those constructs
# (bug-2026-08-25-notification-dedup-crashes-on-bash-3.2.md); this file avoids
# the same class of bug rather than adding a third instance.
#
# Callers must `source` this file, not execute it.

# automation_contract_file: resolve the contract path relative to this
# library file, not $PWD — callers cd into arbitrary repos before sourcing.
automation_contract_file() {
  local lib_dir
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  printf '%s\n' "${AUTOMATION_CONTRACT_FILE:-$lib_dir/../automation-contract.conf}"
}

# automation_contract_lookup <automation-name>
# Prints "<caller-basename><TAB><comma-separated globs>" and returns 0, or
# prints nothing and returns 1 if the name has no entry (or the file is
# missing/unreadable — fail closed, same as every other lookup in this repo).
automation_contract_lookup() {
  local name="$1" contract_file auto caller globs
  contract_file=$(automation_contract_file)
  [ -r "$contract_file" ] || return 1
  while IFS=$'\t' read -r auto caller globs || [ -n "$auto" ]; do
    case "$auto" in
      ''|'#'*) continue ;;
    esac
    if [ "$auto" = "$name" ]; then
      printf '%s\t%s\n' "$caller" "$globs"
      return 0
    fi
  done < "$contract_file"
  return 1
}

# _automation_glob_match <path> <glob>
# A plain bash `case` glob's `*` matches '/' too — "inbox/WP-*.md" would
# then also match an arbitrary nested path like "inbox/WP-anything/x.md" as
# long as it ends in .md (found live while smoke-testing this file,
# 2026-09-03; the reverse also surfaced live: the actual inbox convention is
# `inbox/WP-{N}/WP-{N}.md`, a *nested* form the flat "inbox/WP-*.md" glob
# alone can't express either). This matches path and glob segment-by-segment
# ('/' as the separator): segment counts must be equal, and each glob
# segment matches its corresponding path segment as an ordinary `case` glob
# — since neither side of that per-segment comparison can contain '/', `*`
# can no longer cross a path boundary in either direction.
_automation_glob_match() {
  local path="$1" glob="$2" ifs_saved path_segs glob_segs i n seg noglob_was_set
  # Splitting an unquoted variable that contains glob metacharacters (the
  # whole point of $glob here) does not just word-split on IFS — bash also
  # runs pathname expansion on the result, against whatever the *caller's*
  # current directory happens to be. Found live: running this from ~/IWE
  # expanded "*/*.md" into real filenames from the repo root instead of
  # leaving it as literal segments. `set -f` suppresses only that expansion;
  # `case` pattern matching below is unaffected by it either way.
  case "$-" in
    *f*) noglob_was_set=1 ;;
    *) noglob_was_set=0 ;;
  esac
  set -f
  ifs_saved="$IFS"
  IFS='/'
  set -- $path
  path_segs=("$@")
  set -- $glob
  glob_segs=("$@")
  IFS="$ifs_saved"
  [ "$noglob_was_set" -eq 1 ] || set +f
  n="${#glob_segs[@]}"
  [ "${#path_segs[@]}" -eq "$n" ] || return 1
  i=0
  while [ "$i" -lt "$n" ]; do
    seg="${glob_segs[$i]}"
    # shellcheck disable=SC2254  # intentional glob match — $seg is a shell
    # glob segment from the contract file (e.g. "WP-*"), not a literal.
    case "${path_segs[$i]}" in
      $seg) ;;
      *) return 1 ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# automation_contract_path_allowed <automation-name> <path>
# Returns 0 if <path> matches one of the automation's declared globs.
automation_contract_path_allowed() {
  local name="$1" path="$2" entry globs g ifs_saved noglob_was_set
  entry=$(automation_contract_lookup "$name") || return 1
  globs="${entry#*$'\t'}"
  # Same pathname-expansion trap as _automation_glob_match: $globs is a
  # comma-separated list of glob patterns, so splitting it unquoted must not
  # also let bash expand each piece against the current directory.
  case "$-" in
    *f*) noglob_was_set=1 ;;
    *) noglob_was_set=0 ;;
  esac
  set -f
  ifs_saved="$IFS"
  IFS=','
  set -- $globs
  IFS="$ifs_saved"
  [ "$noglob_was_set" -eq 1 ] || set +f
  for g in "$@"; do
    _automation_glob_match "$path" "$g" && return 0
  done
  return 1
}
