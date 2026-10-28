#!/usr/bin/env bash
# run-limited.sh -- run a command under a time limit, on a host without GNU timeout
# (WP-484 F257, review notes 1 and 4).
#
# Source it, then call:  run_limited <seconds> <command> [args...]
# Returns the command's exit code, or 124 when the limit expired (same as `timeout`).
# Callers that must never wait for input redirect stdin themselves (`run_limited 10 cmd
# </dev/null`): in the fallback the command runs as a background job, so a stdin bound to a
# terminal would stop it until the limit; with GNU timeout stdin is passed through.
#
# `timeout`/`gtimeout` are used when installed. Otherwise the command runs as its own
# job (own process group under job control) and, when the limit expires, the whole group
# is terminated so grandchildren do not outlive the limit. The negative-PID signal is sent
# only after checking that the child's group differs from the caller's group: signalling
# the caller's own group would end the caller (a hook) instead of the command.
# Written for bash 3.2 (stock macOS): no associative arrays, no empty-array expansion.

run_limited() {
  local secs="$1" tool
  shift
  for tool in timeout gtimeout; do
    if command -v "$tool" >/dev/null 2>&1; then
      "$tool" "$secs" "$@"
      return $?
    fi
  done

  local flag pid watcher rc
  flag="$(mktemp "${TMPDIR:-/tmp}/run-limited.XXXXXX")" || { "$@"; return $?; }
  rm -f "$flag"

  set -m 2>/dev/null
  "$@" &
  pid=$!
  set +m 2>/dev/null

  (
    sleeper=""
    trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM   # no orphaned sleep when the command ends first
    sleep "$secs" &
    sleeper=$!
    wait "$sleeper"
    own_group="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')"
    child_group="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$child_group" ] || exit 0   # already finished
    : >"$flag"
    if [ -n "$own_group" ] && [ "$child_group" != "$own_group" ]; then
      kill -TERM -- "-$child_group" 2>/dev/null
      sleep 2
      kill -KILL -- "-$child_group" 2>/dev/null
    else
      kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL "$pid" 2>/dev/null
    fi
  ) >/dev/null 2>&1 &
  watcher=$!

  # `|| rc=$?` / `|| true`: a non-zero code of the command or of the killed watcher must
  # not end a caller that runs under `set -e`.
  rc=0
  wait "$pid" 2>/dev/null || rc=$?
  pkill -P "$watcher" 2>/dev/null   # its sleep, even if the watcher has not set its trap yet
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null || true
  if [ -e "$flag" ]; then
    rm -f "$flag"
    return 124
  fi
  return "$rc"
}
