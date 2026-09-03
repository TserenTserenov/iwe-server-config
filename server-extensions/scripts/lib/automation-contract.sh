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
  local name="$1" contract_file line auto caller globs
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

# automation_contract_caller <automation-name>
# Prints the declared caller-basename for <automation-name>, or nothing +
# return 1 if unknown. Documentation/audit use — the runtime admission check
# in canon-refresh.sh trusts observed git state, not a self-reported caller
# identity (WP-538 Ф5а design session: a live "I am automation X" signal from
# the writer process is not verifiable by the time canon-refresh.sh runs,
# since that process has already exited).
automation_contract_caller() {
  local entry
  entry=$(automation_contract_lookup "$1") || return 1
  printf '%s\n' "${entry%%$'\t'*}"
}

# automation_contract_path_allowed <automation-name> <path>
# Returns 0 if <path> matches one of the automation's declared globs.
automation_contract_path_allowed() {
  local name="$1" path="$2" entry globs g ifs_saved
  entry=$(automation_contract_lookup "$name") || return 1
  globs="${entry#*$'\t'}"
  ifs_saved="$IFS"
  IFS=','
  set -- $globs
  IFS="$ifs_saved"
  for g in "$@"; do
    case "$path" in
      $g) return 0 ;;
    esac
  done
  return 1
}

# automation_contract_all_paths_allowed <automation-name> <path...>
# Returns 0 only if every given path matches the automation's declared globs.
# Empty path list is vacuously true (nothing to object to) — callers are
# responsible for not treating "no paths differ" as "recovery needed" in the
# first place.
automation_contract_all_paths_allowed() {
  local name="$1"
  shift
  local path
  for path in "$@"; do
    automation_contract_path_allowed "$name" "$path" || return 1
  done
  return 0
}
