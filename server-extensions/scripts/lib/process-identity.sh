#!/usr/bin/env bash
# process-identity.sh -- locale- and time-zone-independent identity of a live
# process, and a three-valued verdict against a recorded identity (WP-530 F160).
#
# Why: pid_start used to be the text of `ps -o lstart=`, which depends on
# LC_TIME and TZ of whoever ran ps. Writers and readers ran in different
# environments, so a live owner was not recognised (WP-530 F73) or, worse, a
# live owner's lock was released as "pid reused". Python twin:
# scripts/lib/process_identity.py; both must print identical output, enforced
# by scripts/tests/session-guard-process-identity-smoke.sh.
#
# Identity format (ASCII only, no whitespace):
#   linux:<boot_id>:<pid namespace of the WRITER>:<pid>:<start ticks>
#   darwin:<kern.bootsessionuuid>:<pid>:<start epoch seconds>
# Linux reads /proc only (no ps, works in systemd units without procps).
# The pid namespace is the writer's own (/proc/self/ns/pid): another
# process's ns link is often unreadable even for the same user.
#
# Verdict of a recorded identity against a pid:
#   match   -- the same process is alive
#   dead    -- PROVEN gone: pid absent (proven, not "a tool failed"), other
#              boot, a zombie without live threads, or the same boot and
#              namespace with a different start (pid reused)
#   unknown -- anything else (malformed record, other platform, other pid
#              namespace, record pid != asked pid, unreadable /proc or ps).
# Callers: unknown must never authorise a write nor release a lock.
#
# Usage (sourced; safe under `set -euo pipefail`, leaves IFS/noglob intact):
#   process_identity <pid>                 -> stdout identity; rc 0 ok,
#                                             rc 1 process proven absent,
#                                             rc 2 unknown
#   process_identity_verdict <rec> <pid>   -> stdout match|dead|unknown; rc 0

# Explicit character lists, not ranges: in a UTF-8 locale glibc ranges such as
# [0-9] also match characters like '²', which made a malformed record "dead".
_PI_LINUX_RE='^linux:[0123456789abcdef-]+:[0123456789]+:[123456789][0123456789]*:(0|[123456789][0123456789]*)$'
_PI_DARWIN_RE='^darwin:[0123456789ABCDEF-]+:[123456789][0123456789]*:(0|[123456789][0123456789]*)$'
_PI_PID_RE='^[123456789][0123456789]*$'

# /proc must belong to our own pid namespace: bash opens /proc/self/stat
# itself (no fork), so its first field must be $BASHPID.
_pi_linux_proc_is_ours() {
  local line=""
  read -r line </proc/self/stat 2>/dev/null || return 1
  [ "${line%% *}" = "$BASHPID" ]
}

# Fields of /proc/<pid>/stat after the LAST ') ': the command name may contain
# ')', spaces and newlines. [0] state, [1] ppid, [19] start time in ticks.
# Sets PI_STAT_FIELDS; rc 1 proven absent, rc 2 unreadable.
_pi_linux_stat_fields() {
  local pid=$1 stat rest had_noglob=0 IFS=$' \t\n'
  _pi_linux_proc_is_ours || return 2
  [ -e "/proc/$pid" ] || return 1
  stat=$(cat "/proc/$pid/stat" 2>/dev/null) || { [ -e "/proc/$pid" ] && return 2; return 1; }
  case "$stat" in *') '*) ;; *) return 2 ;; esac
  rest=${stat##*) }
  case $- in *f*) had_noglob=1 ;; esac
  set -f
  # shellcheck disable=SC2206 # word splitting of the numeric tail is intended
  PI_STAT_FIELDS=($rest)
  [ "$had_noglob" -eq 1 ] || set +f
  [ "${#PI_STAT_FIELDS[@]}" -ge 20 ] || return 2
  [[ ${PI_STAT_FIELDS[19]} =~ ^(0|[123456789][0123456789]*)$ ]] || return 2
  return 0
}

_pi_linux_boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null || true; }

_pi_linux_self_pidns() {
  local link
  link=$(readlink /proc/self/ns/pid 2>/dev/null) || return 0
  link=${link#pid:[}; link=${link%]}
  [[ $link =~ ^[0123456789]+$ ]] && printf '%s' "$link"
  return 0
}

_pi_darwin_boot_id() { sysctl -n kern.bootsessionuuid 2>/dev/null || true; }

# Existence without trusting ps: kill -0 succeeds for own processes; for a
# foreign one it fails with EPERM, which still proves existence.
# rc 0 exists, 1 proven absent, 2 unknown.
_pi_darwin_exists() {
  local err
  kill -0 "$1" 2>/dev/null && return 0
  err=$(LC_ALL=C kill -0 "$1" 2>&1) || true
  case "$err" in
    *"No such process"*) return 1 ;;
    *"Operation not permitted"*) return 0 ;;
    *) return 2 ;;
  esac
}

# Start of an existing pid as epoch seconds, independent of LC_*/TZ.
# Any ps or date failure is unknown (rc 2), never "absent".
_pi_darwin_start_epoch() {
  local lstart epoch
  lstart=$(LC_ALL=C TZ=UTC ps -p "$1" -o lstart= 2>/dev/null) || return 2
  lstart=$(printf '%s' "$lstart" | tr -s ' \t\n' ' ' | sed 's/^ //; s/ $//')
  [ -n "$lstart" ] || return 2
  epoch=$(LC_ALL=C TZ=UTC date -j -u -f "%a %b %d %T %Y" "$lstart" +%s 2>/dev/null) || return 2
  [[ $epoch =~ ^(0|[123456789][0123456789]*)$ ]] || return 2
  printf '%s' "$epoch"
}

# A pid is at most 10 ASCII digits and fits in int32.
_pi_valid_pid() { [[ ${1:-} =~ $_PI_PID_RE ]] && [ "${#1}" -le 10 ] && [ "$1" -le 2147483647 ]; }

process_identity() {
  local pid=${1:-} boot ns epoch rc=0
  _pi_valid_pid "$pid" || return 2
  case "$(uname -s 2>/dev/null || true)" in
    Linux)
      _pi_linux_stat_fields "$pid" || return $?
      boot=$(_pi_linux_boot_id)
      ns=$(_pi_linux_self_pidns)
      [[ $boot =~ ^[0123456789abcdef-]+$ ]] && [ -n "$ns" ] || return 2
      printf 'linux:%s:%s:%s:%s\n' "$boot" "$ns" "$pid" "${PI_STAT_FIELDS[19]}"
      ;;
    Darwin)
      _pi_darwin_exists "$pid" || return $?
      epoch=$(_pi_darwin_start_epoch "$pid") || rc=$?
      [ "$rc" -eq 0 ] || return 2
      boot=$(_pi_darwin_boot_id)
      [[ $boot =~ ^[0123456789ABCDEF-]+$ ]] || return 2
      printf 'darwin:%s:%s:%s\n' "$boot" "$pid" "$epoch"
      ;;
    *) return 2 ;;
  esac
}

# A zombie is dead only when no thread of it still runs: when the thread
# group leader exits first, it shows Z while the process keeps working.
# rc 0 dead zombie, 1 not a zombie, 2 unknown.
_pi_zombie_state() {
  local pid=$1 threads="" state
  case "$(uname -s 2>/dev/null || true)" in
    Linux)
      _pi_linux_stat_fields "$pid" || return 2
      [ "${PI_STAT_FIELDS[0]}" = Z ] || return 1
      threads=$(sed -n 's/^Threads:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null) || true
      [[ $threads =~ ^[0123456789]+$ ]] || return 2
      [ "$threads" -le 1 ] && return 0
      return 2
      ;;
    Darwin)
      state=$(LC_ALL=C ps -p "$pid" -o stat= 2>/dev/null) || return 2
      case "$state" in *Z*) return 0 ;; '') return 2 ;; esac
      return 1
      ;;
    *) return 2 ;;
  esac
}

process_identity_verdict() {
  local recorded=${1:-} pid=${2:-} platform boot ns rpid start rest
  local here_boot here_ns current rc=0 zrc=0
  case "$recorded" in *$'\n'*|*$'\r'*) echo unknown; return 0 ;; esac
  _pi_valid_pid "$pid" || { echo unknown; return 0; }
  if [[ $recorded =~ $_PI_LINUX_RE ]]; then
    platform=linux
    rest=${recorded#linux:}
    boot=${rest%%:*}; rest=${rest#*:}
    ns=${rest%%:*}; rest=${rest#*:}
    rpid=${rest%%:*}; start=${rest#*:}
  elif [[ $recorded =~ $_PI_DARWIN_RE ]]; then
    platform=darwin
    rest=${recorded#darwin:}
    boot=${rest%%:*}; rest=${rest#*:}
    ns=""
    rpid=${rest%%:*}; start=${rest#*:}
  else
    echo unknown; return 0
  fi
  [ "$rpid" = "$pid" ] || { echo unknown; return 0; }
  local boot_re='^[0123456789abcdef-]+$'
  [ "$platform" = linux ] || boot_re='^[0123456789ABCDEF-]+$'
  case "$platform:$(uname -s 2>/dev/null || true)" in
    linux:Linux) here_boot=$(_pi_linux_boot_id) ;;
    darwin:Darwin) here_boot=$(_pi_darwin_boot_id) ;;
    *) echo unknown; return 0 ;;
  esac
  [[ $here_boot =~ $boot_re ]] || { echo unknown; return 0; }
  [ "$boot" = "$here_boot" ] || { echo dead; return 0; }
  if [ "$platform" = linux ]; then
    here_ns=$(_pi_linux_self_pidns)
    [ -n "$here_ns" ] && [ "$ns" = "$here_ns" ] || { echo unknown; return 0; }
  fi
  current=$(process_identity "$pid") || rc=$?
  case "$rc" in
    0) ;;
    1) echo dead; return 0 ;;
    *) echo unknown; return 0 ;;
  esac
  _pi_zombie_state "$pid" || zrc=$?
  case "$zrc" in
    0) echo dead; return 0 ;;
    1) ;;
    *) echo unknown; return 0 ;;
  esac
  if [ "${current##*:}" = "$start" ]; then echo match; else echo dead; fi
}
