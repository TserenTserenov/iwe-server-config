#!/usr/bin/env bash
# session-guard-process-identity-smoke.sh -- contract test of the shared
# process identity (WP-530 F160): the bash and python twins print the same
# identity, it does not depend on LC_*/TZ, and the three-valued verdict
# follows the rules in scripts/lib/process-identity.sh. Above all: no input or
# environment may turn "could not read" into "dead" for a live process.
# Exit 77 = a prerequisite this host lacks or a case could not be set up
# (reported, not failed).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT_DIR/scripts/lib/process-identity.sh"
PY="$ROOT_DIR/scripts/lib/process_identity.py"
# shellcheck source=../lib/process-identity.sh
. "$LIB"

SYSTEM=$(uname -s)
case "$SYSTEM" in Linux|Darwin) ;; *) echo "NOT VERIFIED: unsupported platform $SYSTEM"; exit 77 ;; esac
for tool in python3 pgrep pkill ps; do
  command -v "$tool" >/dev/null || { echo "NOT VERIFIED: $tool missing"; exit 77; }
done
[ "$SYSTEM" = Darwin ] || command -v getconf >/dev/null || { echo "NOT VERIFIED: getconf missing"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }
NOT_VERIFIED=""
not_verified() { echo "NOT VERIFIED: $*"; NOT_VERIFIED="$NOT_VERIFIED; $*"; }

SCRATCH=$(mktemp -d)
# Absolute interpreters: section 5 runs them under a broken or empty PATH.
BASH_BIN=$BASH
PY_BIN=$(command -v python3)
PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]+"${PIDS[@]}"}"; do
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done
  rm -r "$SCRATCH" 2>/dev/null || true
}
trap cleanup EXIT
spawn_sleep() { sleep 300 & PIDS+=("$!"); }

py_identity() { python3 "$PY" identity "$1"; }
py_verdict() { python3 "$PY" verdict "$1" "$2"; }

# Both twins must agree on a verdict; prints it.
both_verdict() {
  local sh_v py_v
  sh_v=$(process_identity_verdict "$1" "$2")
  py_v=$(py_verdict "$1" "$2")
  [ "$sh_v" = "$py_v" ] || fail "verdict differs for [$1] pid $2: bash=$sh_v python=$py_v"
  printf '%s\n' "$sh_v"
}
expect_verdict() {  # <expected> <recorded> <pid> <why>
  [ "$(both_verdict "$2" "$3")" = "$1" ] || fail "$4: expected $1"
}

spawn_sleep; CHILD=$!

# 1. Same identity from both twins, for own, parent, child and pid 1.
for pid in $$ "$PPID" "$CHILD" 1; do
  sh_id=$(process_identity "$pid") || fail "bash identity failed for pid $pid"
  py_id=$(py_identity "$pid") || fail "python identity failed for pid $pid"
  [ "$sh_id" = "$py_id" ] || fail "identity differs for pid $pid: bash=$sh_id python=$py_id"
  [[ $sh_id =~ ^(linux:[0-9a-f-]+:[0-9]+|darwin:[0-9A-Fa-f-]+):$pid:[0-9]+$ ]] \
    || fail "unexpected identity shape for pid $pid: $sh_id"
done
echo "OK: bash and python print the same identity for 4 pids"

# 2. Locale and time zone of the caller do not change it.
BASE=$(process_identity "$CHILD")
for spec in "LC_ALL=C" "LC_TIME=ru_RU.UTF-8" "LC_ALL=ru_RU.UTF-8" "TZ=UTC" "TZ=Pacific/Kiritimati" "TZ="; do
  got=$(env "$spec" bash -c '. "$1"; process_identity "$2"' _ "$LIB" "$CHILD")
  [ "$got" = "$BASE" ] || fail "bash identity changed under $spec: $got != $BASE"
  got=$(env "$spec" python3 "$PY" identity "$CHILD")
  [ "$got" = "$BASE" ] || fail "python identity changed under $spec: $got != $BASE"
done
got=$(python3 -c 'import locale, sys
sys.path.insert(0, sys.argv[1])
try:
    locale.setlocale(locale.LC_ALL, "ru_RU.UTF-8")
except locale.Error:
    pass
import process_identity
print(process_identity.process_identity(int(sys.argv[2])))' "$ROOT_DIR/scripts/lib" "$CHILD")
[ "$got" = "$BASE" ] || fail "python identity changed after setlocale(ru_RU): $got"
echo "OK: identity is the same under 7 locale/zone settings"

# 3. Verdicts on a live process.
STEM=${BASE%:*}
BOOT_FIELD=$(printf '%s' "$BASE" | cut -d: -f2)
expect_verdict match "$BASE" "$CHILD" "live recorded identity"
expect_verdict dead "$STEM:1" "$CHILD" "other start on the same boot (pid reused)"
expect_verdict dead "${BASE/$BOOT_FIELD/00000000-0000-0000-0000-000000000000}" "$CHILD" "other boot"
expect_verdict unknown "${BASE/$BOOT_FIELD/}" "$CHILD" "empty boot id in the record"
NL=$'\n'
for bad in "" "garbage" "linux:x" "darwin:x:y" "darwin:a:$CHILD:1:2" "plan9:a:b:$CHILD:1" \
           "$STEM:12x" "$STEM:0${BASE##*:}" "$STEM:²" "$STEM:١٢٣" \
           "$BASE${NL}junk" "${NL}$BASE" " $BASE" "$BASE " "${BASE/:$CHILD:/:0$CHILD:}" "${BASE/:$CHILD:/:²:}"; do
  expect_verdict unknown "$bad" "$CHILD" "malformed record [$bad]"
done
for pid in "$$" x "0$CHILD" "²" -1 0 2147483648 99999999999999999999 "$(printf '9%.0s' $(seq 1 60))"; do
  expect_verdict unknown "$BASE" "$pid" "asked pid [$pid] differs from the record or is invalid"
done
if [ "$SYSTEM" = Linux ]; then FOREIGN=${BASE/linux:/darwin:}; else FOREIGN="linux:b:1:$CHILD:5"; fi
expect_verdict unknown "$FOREIGN" "$CHILD" "other platform"
for pid in "²" 2147483648 99999999999999999999; do
  rc=0; python3 "$PY" identity "$pid" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "python identity of pid [$pid] must be unknown (2), got $rc"
  rc=0; process_identity "$pid" >/dev/null || rc=$?
  [ "$rc" -eq 2 ] || fail "bash identity of pid [$pid] must be unknown (2), got $rc"
done
expect_verdict unknown "${BASE/:$CHILD:/:99999999999999999999:}" 99999999999999999999 "huge pid in the record"
if [ "$SYSTEM" = Darwin ]; then
  expect_verdict unknown "darwin:$(printf '%s' "$BOOT_FIELD" | tr 'A-F' 'a-f'):$CHILD:${BASE##*:}" "$CHILD" "lowercase boot id"
fi
echo "OK: verdicts match, dead and unknown as specified; strict format in both twins"

# 4. A gone process: identity says absent, verdict says dead.
spawn_sleep; GONE=$!
GONE_ID=$(process_identity "$GONE")
kill "$GONE"; wait "$GONE" 2>/dev/null || true
KEEP=(); for pid in "${PIDS[@]}"; do [ "$pid" = "$GONE" ] || KEEP+=("$pid"); done; PIDS=("${KEEP[@]}")
rc=0; process_identity "$GONE" >/dev/null || rc=$?
[ "$rc" -eq 1 ] || fail "bash identity of a gone pid must return 1, got $rc"
rc=0; py_identity "$GONE" >/dev/null || rc=$?
[ "$rc" -eq 1 ] || fail "python identity of a gone pid must return 1, got $rc"
expect_verdict dead "$GONE_ID" "$GONE" "gone process"
echo "OK: a gone process is absent and dead"

# 5. A broken toolchain is unknown, never dead: failing ps / sysctl / cat.
mkdir -p "$SCRATCH/broken"
for tool in ps sysctl cat readlink; do
  printf '#!/bin/sh\nexit 1\n' >"$SCRATCH/broken/$tool"; chmod +x "$SCRATCH/broken/$tool"
done
for path in "$SCRATCH/broken:$PATH" "/nonexistent"; do
  got=$(PATH="$path" "$BASH_BIN" -c '. "$1"; process_identity_verdict "$2" "$3"' _ "$LIB" "$BASE" "$CHILD")
  [ "$got" = unknown ] || fail "bash must say unknown without working tools (PATH=$path), got [$got]"
  # python reads /proc itself on Linux, so match is legitimate there.
  got=$(PATH="$path" "$PY_BIN" "$PY" verdict "$BASE" "$CHILD")
  case "$SYSTEM:$got" in Linux:match|*:unknown) ;; *) fail "python verdict under PATH=$path: [$got]" ;; esac
done
# A host boot id in a wrong format is unknown, not "other boot".
mkdir -p "$SCRATCH/garbage"
for tool in cat sysctl; do
  printf '#!/bin/sh\necho garbage\n' >"$SCRATCH/garbage/$tool"; chmod +x "$SCRATCH/garbage/$tool"
done
got=$(PATH="$SCRATCH/garbage:$PATH" "$BASH_BIN" -c '. "$1"; process_identity_verdict "$2" "$3"' _ "$LIB" "$BASE" "$CHILD")
[ "$got" = unknown ] || fail "garbage host boot id must be unknown in bash, got [$got]"
if [ "$SYSTEM" = Darwin ]; then
  got=$(PATH="$SCRATCH/garbage:$PATH" "$PY_BIN" "$PY" verdict "$BASE" "$CHILD")
  [ "$got" = unknown ] || fail "garbage host boot id must be unknown in python, got [$got]"
fi
# Called directly (not in $(...)) under set -e it must not abort the caller.
got=$(PATH="$SCRATCH/broken:$PATH" "$BASH_BIN" -c 'set -euo pipefail; . "$1"; process_identity_verdict "$2" "$3"; echo after' \
  _ "$LIB" "$BASE" "$CHILD" | tr '\n' ' ')
case "$got" in "unknown after "|"match after ") ;; *) fail "direct call under set -e broke the caller: [$got]" ;; esac
echo "OK: failing tools give unknown (never dead) and do not abort a set -e caller"

# 6. The caller's IFS and noglob survive, and a hostile IFS does not break parsing.
got=$(bash -c '. "$1"; set -f; IFS=:; v=$(process_identity_verdict "$2" "$3"); case $- in *f*) f=on ;; *) f=off ;; esac
  printf "%s %s %s" "$v" "$f" "$( [ "$IFS" = : ] && echo ifs-kept || echo ifs-lost)"' _ "$LIB" "$BASE" "$CHILD")
[ "$got" = "match on ifs-kept" ] || fail "caller state or parsing under IFS=: broken: [$got]"
echo "OK: the caller's IFS and noglob are kept"

# 7. Zombies: a reaped-never child is dead; on Linux a zombie leader with live
#    threads is not proven dead.
python3 -c 'import os, time
if os.fork() == 0:
    os._exit(0)
time.sleep(30)' &
PIDS+=("$!"); ZPARENT=$!
ZOMBIE=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  # pgrep skips zombies on macOS; the full process list shows them.
  ZOMBIE=$(LC_ALL=C ps -A -o pid=,ppid= | awk -v p="$ZPARENT" '$2 == p {print $1; exit}' || true)
  [ -n "$ZOMBIE" ] && [[ $(LC_ALL=C ps -p "$ZOMBIE" -o stat= 2>/dev/null) == *Z* ]] && break
  ZOMBIE=""; sleep 0.2
done
if [ -n "$ZOMBIE" ]; then
  ZID=$(process_identity "$ZOMBIE" || true)
  if [ -n "$ZID" ]; then
    expect_verdict dead "$ZID" "$ZOMBIE" "zombie"
    echo "OK: a zombie is dead"
  else
    not_verified "identity of a zombie is unreadable on this host"
  fi
else
  not_verified "could not create a zombie"
fi
if [ "$SYSTEM" = Linux ]; then
  python3 -c 'import ctypes, threading, time
threading.Thread(target=time.sleep, args=(30,), daemon=False).start()
ctypes.CDLL(None).pthread_exit(None)' &
  LEADER=$!; PIDS+=("$LEADER")
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(sed 's/.*) //' "/proc/$LEADER/stat" 2>/dev/null | cut -d' ' -f1)" = Z ] && break; sleep 0.2
  done
  if [ "$(sed 's/.*) //' "/proc/$LEADER/stat" 2>/dev/null | cut -d' ' -f1)" = Z ]; then
    LID="$STEM"; LID="${LID%:*}:$LEADER:$(sed 's/.*) //' "/proc/$LEADER/stat" | cut -d' ' -f20)"
    expect_verdict unknown "$LID" "$LEADER" "zombie leader with a live thread"
    echo "OK: a zombie leader with live threads is not proven dead"
  else
    not_verified "could not make a thread-group leader exit first"
  fi
fi

# 8. Linux only: other pid namespace, /proc of another namespace, odd names.
if [ "$SYSTEM" = Linux ]; then
  NS_OTHER=$(printf '%s' "$BASE" | awk -F: 'BEGIN{OFS=":"} {$3="1"; print}')
  expect_verdict unknown "$NS_OTHER" "$CHILD" "other pid namespace in the record"
  if unshare -Ur --pid --fork true 2>/dev/null; then
    for twin in bash python; do
      rc=0
      if [ "$twin" = bash ]; then
        unshare -Ur --pid --fork bash -c '. "$1"; sleep 30 & process_identity "$!"' _ "$LIB" >/dev/null 2>&1 || rc=$?
      else
        unshare -Ur --pid --fork bash -c 'sleep 30 & python3 "$1" identity "$!"' _ "$PY" >/dev/null 2>&1 || rc=$?
      fi
      [ "$rc" -eq 2 ] || fail "$twin identity with a foreign /proc must be unknown (2), got $rc"
    done
    echo "OK: a /proc of another pid namespace gives unknown"
  else
    not_verified "unshare of a pid namespace is not allowed here"
  fi

  mkdir -p "$SCRATCH/odd"
  for name in 'a) S 1 2 3 4 5' "$(printf 'n\nl) R 9')"; do
    # A copy of bash: coreutils on NixOS is a multicall binary that refuses
    # an unknown argv[0]. The trailing ':' keeps bash from exec-ing sleep.
    cp "$(readlink -f "$(command -v bash)")" "$SCRATCH/odd/$name"
    "$SCRATCH/odd/$name" -c 'sleep 300; :' &
    ODD=$!; PIDS+=("$ODD")
    sleep 0.2
    sh_id=$(process_identity "$ODD"); py_id=$(py_identity "$ODD")
    [ "$sh_id" = "$py_id" ] || fail "identity differs for odd name: bash=$sh_id python=$py_id"
    expect_verdict match "$sh_id" "$ODD" "odd-named process against itself"
    # Independent check of the parsed start: boot time + ticks / CLK_TCK must
    # equal what ps reports (C locale, UTC) to within a second.
    btime=$(awk '/^btime /{print $2}' /proc/stat)
    from_ticks=$(( btime + ${sh_id##*:} / $(getconf CLK_TCK) ))
    from_ps=$(python3 -c 'import calendar,sys,time; print(calendar.timegm(time.strptime(" ".join(sys.argv[1].split()), "%a %b %d %H:%M:%S %Y")))' \
      "$(LC_ALL=C TZ=UTC ps -o lstart= -p "$ODD")")
    diff=$(( from_ticks - from_ps )); diff=${diff#-}
    [ "$diff" -le 1 ] || fail "parsed start of an odd-named process is off by ${diff}s"
  done
  echo "OK: names with ')', spaces and a newline parse the same in both twins"
fi

if [ -n "$NOT_VERIFIED" ]; then
  echo "NOT VERIFIED (all other cases passed):${NOT_VERIFIED#;}"
  exit 77
fi
echo "PASS: process identity contract holds on $SYSTEM"
