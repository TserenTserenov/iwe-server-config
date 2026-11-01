#!/usr/bin/env bash
# Bash twin of claim_line.py (WP-484 Ф275). Sourced by session-guard.sh; no fork on the hot path.
# A claim line is `commit: <repo> <sha>` or `commit: <repo> <sha> <checkout> <branch>`:
# fields separated by exactly one space, no trailing space. Its identity is the pair (repo, sha),
# the last two fields are context. Both implementations run tests/fixtures/claim-line-cases.json.

_CLAIM_LINE_RE='^commit: ([^[:space:]]+) ([0-9a-fA-F]{40,64})( [^[:space:]]+ [^[:space:]]+)?$'

_claim_line_matches() {  # <line> <repo> <sha>; 0 = a well-formed claim on exactly this pair
  [[ "$1" =~ $_CLAIM_LINE_RE ]] || return 1
  [ "${BASH_REMATCH[1]}" = "$2" ] && [ "${BASH_REMATCH[2]}" = "$3" ]
}

_claim_present() {  # <semaphore file> <repo> <sha>; 0 = the file holds a claim on this pair, in either form
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    _claim_line_matches "$line" "$2" "$3" && return 0
  done <"$1"
  return 1
}
