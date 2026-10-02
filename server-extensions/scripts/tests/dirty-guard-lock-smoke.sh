#!/usr/bin/env bash
# dirty-guard-lock-smoke.sh -- throwaway-repository scenarios for scripts/lib/dirty-guard-lock.sh itself, the lock library of the five guard
# scripts (WP-530 Ф81 remainder, peer session 2026-10-02-01 with Kimi and Codex). The takeover rule has its scenarios through the real
# consumer in canon-reconcile-published-smoke.sh (61-79); here are the CONTRACT of the library (return codes, variables, misuse, paths,
# environment) and the places where a consumer cannot reach it. Each scenario asserts an observable outcome, not just "did not crash".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="${1:-$HERE/../lib/dirty-guard-lock.sh}"
[ -r "$LIB" ] || { echo "FAIL: the library is not readable: $LIB"; exit 1; }
case "$LIB" in /*) ;; *) LIB="$PWD/$LIB" ;; esac   # several scenarios change the directory before they source the library
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/dglock-smoke.XXXXXX")
BGPIDS=""   # background helpers (sleepers that stand for live owners): killed when the suite ends, however it ends
trap '{ for p in $BGPIDS; do kill "$p"; wait "$p"; done; } 2>/dev/null; rm -rf "$SANDBOX"' EXIT
REAL_GIT=$(command -v git)
HN="${HOSTNAME:-$(hostname)}"
DEAD_PID=$(( $(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 999998) + 1 ))   # a pid that cannot exist: above pid_max (4194304 on Tsekh) and above every pid of macOS
fails=0
assert() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }

fresh() {  # <name> -> a throwaway repository $SANDBOX/<name>/r, its git directory in $GD
  rm -rf "${SANDBOX:?}/$1"; mkdir -p "$SANDBOX/$1"; "$REAL_GIT" init -q "$SANDBOX/$1/r" || { echo "FAIL: git init"; exit 1; }
  GD="$SANDBOX/$1/r/.git"
}
seed() {  # <printf-format> <args...> -- a lock directory with an owner file of the given text
  mkdir "$GD/dirty-guard.lock" && printf "$@" > "$GD/dirty-guard.lock/owner"
}
state_of_lock() { if [ -L "$GD/dirty-guard.lock" ]; then echo link; elif [ -d "$GD/dirty-guard.lock" ]; then echo dir; elif [ -e "$GD/dirty-guard.lock" ]; then echo file; else echo gone; fi; }
# a snippet runs in a fresh bash (set -u) that sources the library; $GD, $HN and $T (the sandbox) are in its environment
lib_run() { GD="$GD" HN="$HN" T="$SANDBOX" "$BASH" -c 'set -uo pipefail; . "$1" || exit 99; eval "$2"' _ "${LIB_UNDER_TEST:-$LIB}" "$1" 2>&1; }
lib_run_e() { GD="$GD" HN="$HN" T="$SANDBOX" "$BASH" -c 'set -euo pipefail; . "$1" || exit 99; eval "$2"' _ "${LIB_UNDER_TEST:-$LIB}" "$1" 2>&1; }
ACQ='rc=0; dglock_acquire "$GD" demo || rc=$?; echo "rc=$rc state=$DGLOCK_STATE"; echo "reason=$DGLOCK_REASON"; echo "id=$DGLOCK_ID"'
line() { printf '%s\n' "$1" | sed -n "${2}p"; }
rcline() { printf '%s\n' "$1" | grep -m1 '^rc='; }   # the result line, whatever was said before it on stderr

FAKEBIN="$SANDBOX/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/ps" <<'EOF'
#!/bin/bash
# a stand-in for ps -A -o pid=: FAKE_PS=fail (fails), hide:PID (the real list without PID), onlyone (the list is just pid 1)
real=""; for p in /bin/ps /usr/bin/ps /run/current-system/sw/bin/ps; do if [ -x "$p" ]; then real=$("$p" -A -o pid= 2>/dev/null); break; fi; done
[ -n "$real" ] || real=$(for d in /proc/[0-9]*; do echo "${d#/proc/}"; done)   # no ps anywhere (a bare Linux): the kernel's list
case "${FAKE_PS:-real}" in
  fail) exit 1 ;;
  hide:*) printf '%s\n' "$real" | awk -v h="${FAKE_PS#hide:}" '{ gsub(/[ \t]/, "") } $0 != h' ;;
  onlyone) echo 1 ;;
  *) printf '%s\n' "$real" ;;
esac
EOF
chmod +x "$FAKEBIN/ps"

echo "scenario 1: a taken lock is whole: absolute path, the five keys of the owner record, state taken; the release removes it"
fresh s1
o=$(lib_run 'rc=0; dglock_acquire "$GD" demo || rc=$?; echo "rc=$rc state=$DGLOCK_STATE abs=$([ "${DGLOCK_DIR#/}" != "$DGLOCK_DIR" ] && echo y || echo n)"; awk -F= "{ printf \"%s \", \$1 }" "$DGLOCK_DIR/owner"; echo; grep "^script=" "$DGLOCK_DIR/owner"; grep "^node=" "$DGLOCK_DIR/owner"; grep -c "^pid=[0-9]" "$DGLOCK_DIR/owner"; grep "^epoch=" "$DGLOCK_DIR/owner" | grep -c "^epoch=[1-9][0-9]\{9\}$"; dglock_release; [ -e "$DGLOCK_DIR" ] && echo present || echo gone')
assert "$(line "$o" 1)" "rc=0 state=taken abs=y" "taken: code 0, state taken, absolute lock path"
assert "$(line "$o" 2)" "node pid epoch token script " "the owner record has node, pid, epoch, token and script, in that order (the host name is node=, not host=: see the header)"
assert "$(line "$o" 3)/$(line "$o" 4)/$(line "$o" 5)/$(line "$o" 6)" "script=demo/node=$HN/1/1" "who, the node (host name), a numeric pid and a ten-digit epoch are recorded"
assert "$(line "$o" 7)" "gone" "the release removes the lock it took"

echo "scenario 2: the idiom of a guard under set -e (the call on the left of ||): a taken lock, a busy lock, and the release all leave the script running"
fresh s2
o=$(lib_run_e 'rc=0; dglock_acquire "$GD" a || rc=$?; echo "first=$rc"; rc=0; dglock_acquire "$GD" b || rc=$?; echo "second=$rc"; dglock_release; echo reached-end')
assert "$(printf '%s' "$o" | tr '\n' ' ')" "first=0 second=3 reached-end" "set -e: code 0, then code 3 (already ours), then the end of the script"
seed 'node=%s\npid=%s\n' "$HN" "$$"
o=$(lib_run_e 'rc=0; dglock_acquire "$GD" a || rc=$?; echo "rc=$rc"; echo reached-end')
assert "$(printf '%s' "$o" | tr '\n' ' ')" "rc=1 reached-end" "set -e: a busy lock gives code 1 and the script goes on"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 3: eight runs at the same instant on a free lock: exactly one takes it (mkdir is atomic), the others see it held"
fresh s3; rm -f "$SANDBOX"/s3.rc.*
for _ in 1 2 3 4 5 6 7 8; do ( lib_run 'trap dglock_release EXIT; rc=0; dglock_acquire "$GD" racer || rc=$?; echo "$rc" > "$T/s3.rc.$$"; sleep 1' >/dev/null ) & done
wait
assert "$(cat "$SANDBOX"/s3.rc.* | sort | uniq -c | awk '{ printf "%s:%s ", $2, $1 }')" "0:1 1:7 " "one winner (code 0) and seven that find the lock held (code 1)"
assert "$(state_of_lock)" "gone" "the winner released the lock from its EXIT trap (the idiom of a guard), the losers had nothing to release"

echo "scenario 4: a live owner keeps the lock and the reason names the age of the lock (the epoch of the owner record)"
fresh s4
seed 'node=%s\npid=%s\nepoch=%s\ntoken=t\nscript=other\n' "$HN" "$$" "$(( $(date -u +%s) - 600 ))"
o=$(lib_run "$ACQ")
assert "$(line "$o" 1)" "rc=1 state=held-alive" "a live owner: code 1, held-alive"
assert "$(line "$o" 2)" "reason=owner pid $$ is alive, the lock was taken 10 min ago" "the reason names the owner and the age"
assert "$(line "$o" 3 | sed 's/ dir [0-9][0-9]*$/ dir N/')" "id=pid $$ dir N" "the instance label names the owner and the directory number"
assert "$(state_of_lock)" "dir" "the lock of the live owner is untouched"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 5: a dead owner: the lock is taken over, said once on stderr, and the new owner record is ours"
fresh s5
seed 'node=%s\npid=%s\n' "$HN" "$DEAD_PID"
o=$(lib_run "$ACQ; grep -c \"^script=demo\" \"\$DGLOCK_DIR/owner\"; ls -A \"\$DGLOCK_DIR\" | tr '\\n' ' '; echo; dglock_release")
assert "$(line "$o" 1)" "demo: reclaiming the lock: owner pid $DEAD_PID is gone" "one line says that the lock of a dead owner is taken over (prefix: the name of the caller)"
assert "$(line "$o" 2)/$(line "$o" 5)" "rc=0 state=taken/1" "then the lock is ours, with our owner record"
assert "$(line "$o" 6)" "owner " "and nothing but that record is in the lock directory (the dead record and our draft are gone)"
assert "$(state_of_lock)" "gone" "released"

echo "scenario 6: what is NOT proof of death: each state of an owner record keeps the lock and says why"
check_state() {  # <label> <expected reason fragment> -- the lock in $GD is in the state under test
  o=$(lib_run "$ACQ")
  assert "$(line "$o" 1)/$(state_of_lock)/$(line "$o" 2 | grep -c "$2")" "rc=1 state=held-unproven/dir/1" "$1"
  rm -rf "$GD/dirty-guard.lock"
}
fresh s6; mkdir "$GD/dirty-guard.lock"; check_state "no owner file: held, the creator may have died before it wrote it" "owner file is missing"
fresh s6; mkdir "$GD/dirty-guard.lock"; : > "$GD/dirty-guard.lock/owner"; check_state "an empty owner file: damaged" "owner file is damaged"
fresh s6; seed 'node=%s\npid=12x\n' "$HN"; check_state "pid=12x is not a pid: damaged (the old guards took it for a dead process)" "owner file is damaged (pid '12x')"
fresh s6; seed 'node=%s\npid=%s\npid=%s\n' "$HN" "$DEAD_PID" "$DEAD_PID"; check_state "a doubled key: damaged (the old guards took the pid for dead)" "owner file is damaged (pid 'doubled-key')"
fresh s6; seed 'node=\npid=%s\n' "$DEAD_PID"; check_state "an empty host name: damaged" "owner file is damaged (host '')"
fresh s6; seed 'node=another-host-name\npid=%s\n' "$DEAD_PID"; check_state "another host name: not ours to judge" "is not this host"
fresh s6; seed 'node=%s\npid=0%s\n' "$HN" "$DEAD_PID"; check_state "a pid with a leading zero: damaged" "owner file is damaged (pid '0"
fresh s6; seed 'node=%s\r\npid=%s\r\n' "$HN" "$DEAD_PID"; check_state "an owner file with CRLF line ends (edited on another system): damaged, never taken for a dead owner" "owner file is damaged (pid '$DEAD_PID ')"
fresh s6; seed 'node=%s\r\npid=%s\r\n' "$HN" "$DEAD_PID"; o=$(lib_run "$ACQ")
assert "$(printf '%s' "$o" | LC_ALL=C grep -c "$(printf '\r')")" "0" "the reason keeps to one clean line: the carriage returns of the record are not repeated in the message"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 7: a pid that cannot be signalled (pid 1) exists: the lock stays (the old guards took a refused signal for death and removed the lock)"
fresh s7; seed 'node=%s\npid=1\nepoch=%s\n' "$HN" "$(date -u +%s)"
o=$(lib_run "$ACQ")
assert "$(line "$o" 1)/$(state_of_lock)" "rc=1 state=held-alive/dir" "the owner is pid 1: held-alive, the lock stays"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 8: the answer of the BUILTIN kill decides: a message nobody knows proves nothing, and a function kill of the environment stands in for nothing"
fresh s8; mkdir -p "$SANDBOX/s8lib"
sed 's@builtin kill -0 "\$1" 2>&1@{ echo "weird refusal"; false; }@' "$LIB" > "$SANDBOX/s8lib/dirty-guard-lock.sh"
assert "$(grep -c 'echo "weird refusal"' "$SANDBOX/s8lib/dirty-guard-lock.sh")" "1" "precondition: the unknown message is injected into the copy of the library"
seed 'node=%s\npid=%s\n' "$HN" "$DEAD_PID"
o=$(LIB_UNDER_TEST="$SANDBOX/s8lib/dirty-guard-lock.sh" lib_run "$ACQ")
assert "$(line "$o" 1)/$(line "$o" 2 | grep -c 'cannot be established whether owner pid')/$(state_of_lock)" "rc=1 state=held-unproven/1/dir" "a dead pid, but kill says something unknown: not proven, the lock stays"
rm -rf "$GD/dirty-guard.lock"
sleep 600 & LIVE=$!; BGPIDS="$BGPIDS $LIVE"
seed 'node=%s\npid=%s\n' "$HN" "$LIVE"
o=$( kill() { echo "x: No such process" >&2; return 1; }; export -f kill; FAKE_PS="hide:$LIVE" PATH="$FAKEBIN:$PATH" lib_run "$ACQ" )
assert "$(line "$o" 1)/$(state_of_lock)" "rc=1 state=held-alive/dir" "a function kill that says no such process and a list without the live owner: the builtin is called, the owner is alive"
rm -rf "$GD/dirty-guard.lock"; kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null

echo "scenario 9: the list of processes: absence needs ONE successful complete list; a failing or incomplete ps is not proof"
fresh s9
seed 'node=%s\npid=%s\n' "$HN" "$DEAD_PID"
o=$(FAKE_PS=fail PATH="$FAKEBIN:$PATH" lib_run "$ACQ")
assert "$(line "$o" 1)/$(state_of_lock)" "rc=1 state=held-unproven/dir" "kill says no such process but ps itself fails: not proven, the lock stays"
o=$(FAKE_PS=onlyone PATH="$FAKEBIN:$PATH" lib_run "$ACQ")
assert "$(line "$o" 1)/$(state_of_lock)" "rc=1 state=held-unproven/dir" "a list without this very run is not complete: not proven, the lock stays"
o=$(FAKE_PS="hide:$DEAD_PID" PATH="$FAKEBIN:$PATH" lib_run "$ACQ; dglock_release")
assert "$(rcline "$o")/$(state_of_lock)" "rc=0 state=taken/gone" "a complete list without the owner: proof, the lock is taken over (and released again)"

echo "scenario 10: a file or a link in the place of the lock is named and never taken over (not even a link to a directory whose owner is dead)"
fresh s10; mkdir "$SANDBOX/s10/target"; printf 'node=%s\npid=%s\n' "$HN" "$DEAD_PID" > "$SANDBOX/s10/target/owner"; ln -s "$SANDBOX/s10/target" "$GD/dirty-guard.lock"
o=$(lib_run "$ACQ")
assert "$(line "$o" 1)/$(state_of_lock)/$([ -f "$SANDBOX/s10/target/owner" ] && echo kept || echo lost)/$(line "$o" 2 | grep -c 'a file or a link stands in the place')" "rc=1 state=held-unproven/link/kept/1" "a link to a directory with a dead owner: named, untouched, its target untouched"
rm -f "$GD/dirty-guard.lock"; ln -s "$SANDBOX/s10/nowhere" "$GD/dirty-guard.lock"
o=$(lib_run "$ACQ")
assert "$(line "$o" 1)/$(state_of_lock)" "rc=1 state=held-unproven/link" "a dangling link: named, untouched"
rm -f "$GD/dirty-guard.lock"; : > "$GD/dirty-guard.lock"
o=$(lib_run "$ACQ")
assert "$(line "$o" 1)/$(state_of_lock)" "rc=1 state=held-unproven/file" "a plain file: named, untouched"
rm -f "$GD/dirty-guard.lock"

echo "scenario 11: the git directory spelled through a symlink and spelled as it is: ONE lock (the library resolves the physical path)"
fresh s11; ln -s "$GD" "$SANDBOX/s11/gitlink"
"$BASH" -c '. "$1"; dglock_acquire "$2" via-link || exit 9; echo held > "$3"; sleep 6' _ "$LIB" "$SANDBOX/s11/gitlink" "$SANDBOX/s11/held.flag" &
HP=$!; BGPIDS="$BGPIDS $HP"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$SANDBOX/s11/held.flag" ] && break; sleep 0.25; done
o=$(lib_run "$ACQ")
assert "$(line "$o" 1)" "rc=1 state=held-alive" "the second spelling finds the lock of the first held by a live owner"
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; rm -rf "$GD/dirty-guard.lock"

echo "scenario 12: a relative git directory and a later cd of the guard: the release still finds the lock (the library keeps an absolute path)"
fresh s12
o=$(GD=".git" "$BASH" -c 'set -uo pipefail; . "$1"; cd "$2" || exit 9; dglock_acquire .git relcd || exit 8; cd /; dglock_release; [ -e "$2/.git/dirty-guard.lock" ] && echo present || echo gone' _ "$LIB" "$SANDBOX/s12/r" 2>&1)
assert "$o" "gone" "acquired with .git, released after cd /: the lock is gone"

echo "scenario 13: misuse changes nothing: a second acquire is refused (code 3) and the lock stays releasable; a subshell can neither take nor release (bash 4 and newer)"
fresh s13
o=$(lib_run 'rc=0; dglock_acquire "$GD" demo || rc=$?; r1=$rc; rc=0; dglock_acquire "$GD" demo || rc=$?; echo "first=$r1 second=$rc state=$DGLOCK_STATE"; dglock_release; [ -e "$DGLOCK_DIR" ] && echo present || echo gone')
assert "$(line "$o" 1)/$(line "$o" 2)" "first=0 second=3 state=held-self/gone" "the second call: code 3 (held-self); the release still removes the lock of the first call"
case "${BASH_VERSION%%.*}" in
  3) echo "  ok   (skipped: bash 3.2 has no BASHPID, the limit is documented in the header)" ;;
  *) o=$(lib_run 'dglock_acquire "$GD" demo || exit 9; ( dglock_release ); [ -e "$DGLOCK_DIR" ] && echo present || echo gone; dglock_release; [ -e "$DGLOCK_DIR" ] && echo present || echo gone')
     assert "$(printf '%s' "$o" | tr '\n' ' ')" "present gone" "a release made in a subshell does nothing; the release of the shell removes the lock"
     fresh s13b
     o=$(lib_run 'out=$( rc=0; dglock_acquire "$GD" sub || rc=$?; echo "rc=$rc state=$DGLOCK_STATE" ); echo "$out"; [ -e "$GD/dirty-guard.lock" ] && echo present || echo gone')
     assert "$(printf '%s' "$o" | tr '\n' ' ')" "rc=3 state=held-error gone" "an acquire made in a command substitution is refused (code 3) and leaves no lock behind" ;;
esac

echo "scenario 14: the owner record that cannot be linked into place (ln refuses for any reason but a taken name, e.g. a file system without hard links): code 2, the directory is removed when that is possible, the reason says when it is not; there is no fallback by rename (it would replace the record of another run)"
fresh s14
o=$(lib_run 'ln() { return 1; }; rc=0; dglock_acquire "$GD" demo || rc=$?; echo "rc=$rc state=$DGLOCK_STATE"; echo "reason=$DGLOCK_REASON"')
assert "$(line "$o" 1)/$(state_of_lock)/$(line "$o" 2 | grep -c '^reason=cannot record the owner of the lock [^(]* (no write access, a full disk, or a file system without hard links?)$')" "rc=2 state=held-error/gone/1" "ln fails: code 2, no lock directory left, a reason that names the likely causes"
o=$(lib_run 'ln() { return 1; }; rmdir() { return 1; }; rc=0; dglock_acquire "$GD" demo || rc=$?; echo "rc=$rc"; echo "reason=$DGLOCK_REASON"')
assert "$(line "$o" 1)/$(state_of_lock)/$(line "$o" 2 | grep -c 'the lock directory was not removed')" "rc=2/dir/1" "ln and rmdir fail: code 2, the empty directory stays, and the reason SAYS so"
rm -rf "$GD/dirty-guard.lock"
fresh s14
o=$(lib_run 'mv() { return 1; }; rc=0; dglock_acquire "$GD" demo || rc=$?; echo "rc=$rc"; ls -A "$DGLOCK_DIR" | tr "\n" " "; echo; dglock_release')
assert "$(line "$o" 1)/$(line "$o" 2)" "rc=0/owner " "mv is not used for the record at all: with a refusing mv the lock is still taken, whole, and no temporary name is left"
fresh s14
o=$(lib_run 'rc=0; dglock_acquire "$GD" demo || rc=$?; echo "rc=$rc"; ls -A "$DGLOCK_DIR" | tr "\n" " "; echo; dglock_release')
assert "$(line "$o" 1)/$(line "$o" 2)" "rc=0/owner " "the usual way: one record, the temporary name is gone"

echo "scenario 15: a lock directory that cannot be created is named, not reported as a held lock"
if [ "$(id -u)" = 0 ]; then echo "  ok   (skipped: running as root, a directory mode does not stop root)"; else
fresh s15; chmod 555 "$GD"
o=$(lib_run "$ACQ")
chmod 755 "$GD"
assert "$(line "$o" 1)/$(line "$o" 2 | grep -c 'cannot be created')/$(line "$o" 3)" "rc=1 state=held-error/1/id=no lock directory" "no write access to the git directory: code 1, held-error, said"
fi

echo "scenario 16: the loader idiom: a file cut short in delivery, and a file with a syntax error, are not taken for the library; the whole file is"
LOADER='if [ -r "$1" ] && . "$1" && [ "${DGLOCK_LIB_READY:-}" = 1 ]; then echo ready; else echo unusable; fi'
assert "$("$BASH" -c "$LOADER" _ "$LIB" 2>&1)" "ready" "the whole library: ready"
sed '$d' "$LIB" > "$SANDBOX/cut.sh"
assert "$("$BASH" -c "$LOADER" _ "$SANDBOX/cut.sh" 2>&1)" "unusable" "the library without its last line (cut short): unusable"
{ cat "$LIB"; echo 'if then fi ('; } | sed '/^DGLOCK_LIB_READY=1$/d' > "$SANDBOX/broken.sh"
assert "$("$BASH" -c "$LOADER" _ "$SANDBOX/broken.sh" 2>&1 | tail -n 1)" "unusable" "a library with a syntax error: unusable"
assert "$("$BASH" -c "$LOADER" _ "$SANDBOX/does-not-exist.sh" 2>&1)" "unusable" "no library: unusable"
assert "$(DGLOCK_LIB_READY=1 "$BASH" -c "unset DGLOCK_LIB_READY; $LOADER" _ "$SANDBOX/cut.sh" 2>&1)" "unusable" "a ready marker left in the environment does not vouch for a cut library, because the idiom unsets it before the source"
assert "$(DGLOCK_LIB_READY=1 "$BASH" -c "$LOADER" _ "$SANDBOX/cut.sh" 2>&1)" "ready" "(the hazard that the unset closes: without it the inherited marker passes the cut library)"
assert "$(tail -n 1 "$LIB")" "DGLOCK_LIB_READY=1" "the ready marker is the last line of the library"

echo "scenario 17: a minimal PATH (the commands the header names, no ps, no tr, no sleep): the lock is taken and released, and a dead owner is still PROVEN gone (ps from a usual place, else /proc)"
fresh s17; MIN="$SANDBOX/minbin"; mkdir -p "$MIN"
for c in bash awk date hostname ln ls mkdir mv rm rmdir; do p=$(command -v "$c") && ln -sf "$p" "$MIN/$c"; done
seed 'node=%s\npid=%s\n' "$HN" "$DEAD_PID"
o=$(PATH="$MIN" lib_run "$ACQ; dglock_release")
assert "$(rcline "$o")/$(state_of_lock)" "rc=0 state=taken/gone" "PATH without ps: the proof comes from a usual place of ps, or from /proc, and the lock is taken over"
mkdir -p "$SANDBOX/s17lib"
sed 's@for p in /run/current-system/sw/bin/ps /usr/bin/ps /bin/ps; do@for p in /nonexistent/ps; do@' "$LIB" > "$SANDBOX/s17lib/dirty-guard-lock.sh"
assert "$(grep -c 'for p in /nonexistent/ps; do' "$SANDBOX/s17lib/dirty-guard-lock.sh")" "1" "precondition: the usual places of ps are removed from the copy of the library"
seed 'node=%s\npid=%s\n' "$HN" "$DEAD_PID"
o=$(PATH="$MIN" LIB_UNDER_TEST="$SANDBOX/s17lib/dirty-guard-lock.sh" lib_run "$ACQ; dglock_release")
if [ -d /proc/self ] && [ -d /proc/1 ]; then want="rc=0 state=taken/gone"; why="no ps at all, but /proc: the kernel's own list is read, the lock is taken over"; else want="rc=1 state=held-unproven/dir"; why="no ps and no /proc: nothing is ever taken over (the lock stays, loudly)"; fi
assert "$(rcline "$o")/$(state_of_lock)" "$want" "$why"
rm -rf "$GD/dirty-guard.lock"
fresh s17c; mkdir -p "$SANDBOX/s17c/r2"
o=$(PATH="$MIN" lib_run 'rc=0; dglock_acquire "$GD" demo || rc=$?; echo "rc=$rc"; dglock_release; [ -e "$DGLOCK_DIR" ] && echo present || echo gone' | tr '\n' ' ')
assert "$o" "rc=0 gone " "the plain take and release need only the commands of the header"

echo "scenario 18: the library is quiet and passive: no trap, no exit, nothing at the top level but functions and plain variables (a guard has ONE exit trap and its own exit statuses)"
assert "$(grep -v '^[[:space:]]*#' "$LIB" | grep -c -E '(^|[;&|{(][[:space:]]*)(trap|exit)[[:space:]]')" "0" "no trap and no exit statement in the library"
assert "$(awk '/^[^# \t}]/ && !/^_?dglock_[a-z_]*\(\) \{/ && !/^DGLOCK_LIB_READY=1$/ { n++ } END { print n + 0 }' "$LIB")" "0" "every line at the top level is a function or the ready marker"
assert "$("$BASH" -c 'before=$(typeset -F | awk "{ print \$3 }" | sort); . "$1"; after=$(typeset -F | awk "{ print \$3 }" | sort); comm -13 <(printf "%s\n" "$before") <(printf "%s\n" "$after") | grep -v -E "^_?dglock_" | wc -l | tr -d " "' _ "$LIB")" "0" "the library defines functions of its own namespace only (the functions of the environment are not counted)"
assert "$("$BASH" -c 'before=$(compgen -v | sort); . "$1"; after=$(compgen -v | sort); comm -13 <(printf "%s\n" "$before") <(printf "%s\n" "$after") | grep -v -E "^(_?DGLOCK_|PIPESTATUS$|before$|after$)" | wc -l | tr -d " "' _ "$LIB")" "0" "the library sets variables of its own namespace only"

echo "scenario 19: two git directories whose names differ only by a newline at the end are two locks (a command substitution would strip the newline)"
fresh s19; mkdir -p "$SANDBOX/s19/g" "$SANDBOX/s19/g
"
o=$(lib_run 'dglock_acquire "$T/s19/g"$'"'"'\n'"'"' nl || exit 9; [ -d "$T/s19/g"$'"'"'\n'"'"'/dirty-guard.lock ] && echo in-the-newline-one || echo not-there; [ -d "$T/s19/g/dirty-guard.lock" ] && echo in-the-plain-one || echo none-in-the-plain-one; dglock_release')
assert "$(printf '%s' "$o" | tr '\n' ' ')" "in-the-newline-one none-in-the-plain-one" "the lock of the directory whose name ends with a newline is made THERE and not in its plain neighbour"

echo "scenario 20: under set -e a release that fails (the rename of the lock away, or the delete of the renamed directory) still returns 0, says so, and forgets the token (the shell is not ended in the middle of the exit handler)"
fresh s20
o=$(lib_run_e 'dglock_acquire "$GD" demo || exit 9; mv() { return 1; }; dglock_release; echo reached; unset -f mv; dglock_release; [ -e "$DGLOCK_DIR" ] && echo still-there || echo gone')
assert "$(printf '%s\n' "$o" | grep -v 'warning' | tr '\n' ' ')/$(printf '%s\n' "$o" | grep -c 'could not be released')" "reached still-there /1" "the rename fails: the release returns 0 and the lock stays (as a stale lock for the next run), the script reaches its end, and the warning is said (the token is forgotten, so a later release does not retry)"
rm -rf "$GD/dirty-guard.lock"
fresh s20
o=$(lib_run_e 'dglock_acquire "$GD" demo || exit 9; rm() { return 1; }; dglock_release; echo reached; [ -e "$DGLOCK_DIR" ] && echo still-there || echo gone')
assert "$(printf '%s\n' "$o" | grep -v 'warning' | tr '\n' ' ')/$(printf '%s\n' "$o" | grep -c 'could not be deleted there')/$(ls -A "$GD" | grep -c 'dirty-guard.lock.released')" "reached gone /1/1" "the delete fails: the lock itself is gone at once (it was renamed), the leftover is named in a warning, and the script reaches its end"
rm -rf "$GD"/dirty-guard.lock.released.*

echo "scenario 21: the release from an EXIT trap never changes the exit status of the script (plain, and under set -e)"
for mode in plain errexit; do
  for code in 0 7; do
    fresh s21
    GD="$GD" "$BASH" -c 'case "$2" in errexit) set -e ;; esac; . "$1"; dglock_acquire "$GD" demo || exit 9; trap "dglock_release" EXIT; exit "$3"' _ "$LIB" "$mode" "$code" >/dev/null 2>&1
    assert "$?/$(state_of_lock)" "$code/gone" "exit $code ($mode): the status of the script is kept and the lock is gone"
  done
done

echo "scenario 22: a CDPATH in the environment must not lead the lock to another directory or soil the path (a relative name never consults CDPATH; cd prints nothing into the captured text)"
fresh s22; mkdir -p "$SANDBOX/s22/decoy/g" "$SANDBOX/s22/w/g"
o=$( cd "$SANDBOX/s22/w" && GD=g CDPATH="$SANDBOX/s22/decoy" lib_run 'rc=0; dglock_acquire "$GD" cd || rc=$?; echo "rc=$rc"; echo "dir=$DGLOCK_DIR"; dglock_release' )
SBP=$(cd "$SANDBOX" && pwd -P)   # the library reports the PHYSICAL path (on macOS /var is /private/var)
assert "$(line "$o" 1)/$(line "$o" 2 | sed "s#$SBP#SB#")" "rc=0/dir=SB/s22/w/g/dirty-guard.lock" "CDPATH holds a decoy directory of the same name: the lock is made in the directory that the guard named (the working directory), not in the decoy"
o=$( cd "$SANDBOX/s22/w" && GD=g CDPATH="$SANDBOX/s22/w" lib_run 'rc=0; dglock_acquire "$GD" cd || rc=$?; echo "rc=$rc"; echo "dir=$DGLOCK_DIR"; dglock_release' )
assert "$(line "$o" 1)/$(printf '%s\n' "$o" | wc -l | tr -d ' ')" "rc=0/2" "CDPATH holds the working directory itself (cd would print the directory): the result is still one clean path"

echo "scenario 23: an empty git directory is misuse (code 3): no lock is made in the working directory or anywhere"
fresh s23; mkdir -p "$SANDBOX/s23/w"
o=$( cd "$SANDBOX/s23/w" && lib_run 'rc=0; dglock_acquire "" demo || rc=$?; echo "rc=$rc state=$DGLOCK_STATE"; ls -A' )
assert "$(printf '%s' "$o" | tr '\n' ' ')" "rc=3 state=held-error" "no git directory given: code 3 and nothing was created"

# ---- the claim (v4): what happens when a lock changes hands while a run is taking it over -----------------------------------------------------
inject() {  # <library> <substring of a line> <hook line> <out>: a copy of the library with the hook line put BEFORE the first line that holds the substring
  awk -v pat="$2" -v hook="$3" 'index($0, pat) && !done { print hook; done = 1 } { print }' "$1" > "$4"
}
# A signal that was ignored when the suite started (a background job, nohup: SIGHUP) stays ignored in every bash below it; the checks that
# send a signal to the shell of a guard need the default back, so such a shell is started through perl, which resets it (as the timing suite of Ф82 does)
RESET_SIGS=(); if command -v perl >/dev/null 2>&1; then RESET_SIGS=(perl -e '$SIG{$_} = "DEFAULT" for qw(INT HUP TERM QUIT); exec @ARGV or exit 127'); fi
lib_status() {  # the exit status of a snippet that runs in a fresh bash with the library sourced (its output is dropped)
  GD="$GD" HN="$HN" T="$SANDBOX" ${RESET_SIGS[@]+"${RESET_SIGS[@]}"} "$BASH" -c 'set -uo pipefail; . "$1" || exit 99; eval "$2"' _ "${LIB_UNDER_TEST:-$LIB}" "$1" >/dev/null 2>&1; echo $?
}
HOOK='if [ -n "${DGLOCK_T_HOOK:-}" ]; then . "$DGLOCK_T_HOOK"; fi'   # the hook line: a file named in the environment is sourced at that point of the library (the copy only; the real library has no hooks)
MVLOG='mv() { printf "%s\n" "$*" >> "$T/mvlog"; command mv "$@"; }; '
mkdir -p "$SANDBOX/v4"
cat > "$SANDBOX/v4/hook-vanish.sh" <<'EOF'
# the lock goes away (its owner released it) at this point
if [ ! -e "$T/hookv.done" ]; then : > "$T/hookv.done"; rm -rf "$DGLOCK_DIR"; fi
EOF
sleep 600 & QLIVE=$!; BGPIDS="$BGPIDS $QLIVE"
sleep 600 & PLIVE=$!; BGPIDS="$BGPIDS $PLIVE"
stale_seed() { seed 'node=%s\npid=%s\nepoch=%s\ntoken=old\nscript=old\n' "$HN" "$DEAD_PID" "$(date -u +%s)"; }
leftovers() { ls -A "$GD" 2>/dev/null | grep -c 'dirty-guard.lock.stale'; }

echo "scenario 24: the record that is moved aside must be the record that was judged: the record of a live owner that took the lock after the judgment is put back untouched"
fresh s24; inject "$LIB" 'if ! { mv "$DGLOCK_DIR/owner" "$dead"' "$HOOK" "$SANDBOX/v4/lib24.sh"
assert "$(grep -c 'DGLOCK_T_HOOK' "$SANDBOX/v4/lib24.sh")" "1" "precondition: the hook line is in the copy of the library (before the rename of the record)"
cat > "$SANDBOX/v4/hook-q.sh" <<'EOF'
# the stale record is replaced by the record of a LIVE owner Q (its owner released the stale lock and Q took it) after the judgment
if [ ! -e "$T/hookq.done" ]; then : > "$T/hookq.done"; rm -f "$DGLOCK_DIR/owner"; printf 'node=%s\npid=%s\nepoch=%s\ntoken=qtoken\nscript=q\n' "$HN" "$QPID" "$(date -u +%s)" > "$DGLOCK_DIR/owner"; fi
EOF
LNLOG='ln() { printf "ln %s\n" "$*" >> "$T/lnlog"; command ln "$@"; }; '
stale_seed; : > "$SANDBOX/mvlog"; : > "$SANDBOX/lnlog"; rm -f "$SANDBOX"/hook*.done
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-q.sh" QPID="$QLIVE" LIB_UNDER_TEST="$SANDBOX/v4/lib24.sh" lib_run "$MVLOG$LNLOG$ACQ")
assert "$(rcline "$o")" "rc=1 state=held-alive" "the live record that stood in the place at the rename: busy (held-alive), NOT taken over"
assert "$(printf '%s\n' "$o" | grep -c "owner pid $QLIVE is alive")" "1" "the reason names the live owner of the record that was found"
assert "$(grep -c '^token=qtoken$' "$GD/dirty-guard.lock/owner" 2>/dev/null)/$(state_of_lock)/$(ls -A "$GD/dirty-guard.lock" | tr '\n' ' ')" "1/dir/owner " "the record of the live owner is back in its place, whole, and nothing is left in the lock directory"
assert "$(grep -c 'owner.dead' "$SANDBOX/mvlog")/$(grep -c 'owner.dead' "$SANDBOX/lnlog")" "1/1" "one rename moved the record aside, one link put it back (the claim really happened)"
assert "$(printf '%s\n' "$o" | grep -c 'reclaiming')" "0" "no takeover is announced"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 25: in the window of a takeover (the dead record is moved aside, ours is not in yet) the lock directory still stands: nobody can make a lock of their own, the dead record is NOT visible as an owner"
fresh s25; inject "$LIB" 'echo "$_DGLOCK_PREFIX reclaiming the lock:' "$HOOK" "$SANDBOX/v4/lib25.sh"
cat > "$SANDBOX/v4/hook-window.sh" <<'EOF'
# a run that wants to MAKE the lock at this very moment (the dead record is aside, ours is not in): mkdir must refuse, the directory is there without a record
if mkdir "$DGLOCK_DIR" 2>/dev/null; then echo made > "$T/window.mkdir"; else echo refused > "$T/window.mkdir"; fi
if [ -e "$DGLOCK_DIR/owner" ]; then echo record > "$T/window.owner"; else echo none > "$T/window.owner"; fi
EOF
stale_seed; rm -f "$SANDBOX"/hook*.done "$SANDBOX"/window.*
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-window.sh" LIB_UNDER_TEST="$SANDBOX/v4/lib25.sh" lib_run "$ACQ; dglock_release")
assert "$(cat "$SANDBOX/window.mkdir")/$(cat "$SANDBOX/window.owner")" "refused/none" "in the window: a mkdir is refused (the directory is there), and the directory holds no record"
assert "$(rcline "$o")/$(state_of_lock)" "rc=0 state=taken/gone" "the takeover still ends with our record, and the release removes the lock"

echo "scenario 26: a record moved aside by mistake whose place was taken meanwhile is NOT deleted: it is left, named, and the caller is told"
fresh s26; inject "$LIB" 'if ! { mv "$DGLOCK_DIR/owner" "$dead"' "$HOOK" "$SANDBOX/v4/lib26.sh"
inject "$SANDBOX/v4/lib26.sh" 'if [ "$snap1" != "$_DGLOCK_SNAP" ]' 'if [ -n "${DGLOCK_T_HOOK2:-}" ]; then . "$DGLOCK_T_HOOK2"; fi' "$SANDBOX/v4/lib26b.sh"
cat > "$SANDBOX/v4/hook-p.sh" <<'EOF'
# a third run publishes its record into the free place (not possible while the protocol is followed: the defence is tested directly)
if [ ! -e "$T/hookp.done" ]; then : > "$T/hookp.done"; printf 'node=%s\npid=%s\nepoch=%s\ntoken=ptoken\nscript=p\n' "$HN" "$PPID_LIVE" "$(date -u +%s)" > "$DGLOCK_DIR/owner"; fi
EOF
stale_seed; rm -f "$SANDBOX"/hook*.done
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-q.sh" DGLOCK_T_HOOK2="$SANDBOX/v4/hook-p.sh" QPID="$QLIVE" PPID_LIVE="$PLIVE" LIB_UNDER_TEST="$SANDBOX/v4/lib26b.sh" lib_run "$ACQ")
assert "$(rcline "$o")" "rc=1 state=held-error" "not taken: held-error"
assert "$(printf '%s\n' "$o" | grep -c 'could not be put back')/$(printf '%s\n' "$o" | grep -c 'owner.dead')" "1/2" "the warning and the reason both name the file in which the displaced record was left"
assert "$(grep -h -c '^token=qtoken$' "$GD"/dirty-guard.lock/owner.dead.* 2>/dev/null | tr '\n' ' ')" "1 " "the displaced record of the live owner survives whole under its new name"
assert "$(grep -c '^token=ptoken$' "$GD/dirty-guard.lock/owner" 2>/dev/null)" "1" "the record of the third run, which is in the place, is untouched"
assert "$(printf '%s\n' "$o" | grep '^id=')" "id=displaced record" "the instance label says displaced record"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 27: a lock that goes away while it is judged is not 'not a directory': the take is retried and succeeds"
fresh s27; inject "$LIB" 'DGLOCK_INSTANCE=$(dglock_instance)' "$HOOK" "$SANDBOX/v4/lib27.sh"
stale_seed; rm -f "$SANDBOX"/hook*.done
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-vanish.sh" LIB_UNDER_TEST="$SANDBOX/v4/lib27.sh" lib_run "$ACQ; grep -c \"^script=demo\" \"\$DGLOCK_DIR/owner\"; dglock_release")
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c 'not a directory')/$(printf '%s\n' "$o" | tail -n 1)/$(state_of_lock)" "rc=0 state=taken/0/1/gone" "the lock vanished before the judgment: taken, no false reason, our record, released"
fresh s27; inject "$LIB" 'snap=$(_dglock_snap "$DGLOCK_DIR/owner")' "$HOOK" "$SANDBOX/v4/lib27b.sh"
stale_seed; rm -f "$SANDBOX"/hook*.done
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-vanish.sh" LIB_UNDER_TEST="$SANDBOX/v4/lib27b.sh" lib_run "$ACQ; dglock_release")
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c -E 'not a directory|file or a link')/$(state_of_lock)" "rc=0 state=taken/0/gone" "the lock vanished between the check and the read of its owner file: taken, no false reason"

echo "scenario 28: an owner file that cannot be read is no proof: the lock stays, and the reason says that the file cannot be read"
if [ "$(id -u)" = 0 ]; then echo "  ok   (skipped: running as root, a file mode does not stop root)"; else
fresh s28; stale_seed; chmod 000 "$GD/dirty-guard.lock/owner"
o=$(lib_run "$ACQ")
chmod 644 "$GD/dirty-guard.lock/owner"
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c 'owner file cannot be read')/$(state_of_lock)" "rc=1 state=held-unproven/1/dir" "unreadable record: held, said, untouched"
rm -rf "$GD/dirty-guard.lock"
fi

echo "scenario 29: misuse is a code, never the end of the shell: a call without arguments under set -u"
fresh s29
o=$(lib_run 'rc=0; dglock_acquire || rc=$?; echo "rc=$rc state=$DGLOCK_STATE"; echo reached-end')
assert "$(printf '%s' "$o" | tr '\n' ' ')" "rc=3 state=held-error reached-end" "no git directory at all: code 3, the script goes on"

echo "scenario 30: a newline in a path stays one line in the reason (a message must not forge a second line)"
fresh s30; mkdir -p "$SANDBOX/s30/g
h"; : > "$SANDBOX/s30/g
h/dirty-guard.lock"
o=$(lib_run 'rc=0; dglock_acquire "$T/s30/g"$'"'"'\n'"'"'h demo || rc=$?; echo "rc=$rc"; echo "reason=$DGLOCK_REASON"')
assert "$(printf '%s\n' "$o" | wc -l | tr -d ' ')/$(rcline "$o")" "2/rc=1" "a file in the place of the lock, the name of the directory has a newline: still two lines of output (the code and ONE reason)"

echo "scenario 31: a signal between the mkdir and the owner record: the exit handler removes the empty directory of this run (the guard sets its trap BEFORE it asks for the lock)"
fresh s31; inject "$LIB" 'if _dglock_publish; then' 'if [ -n "${DGLOCK_T_TERM:-}" ]; then kill -TERM $$; fi' "$SANDBOX/v4/lib31.sh"
o=$(DGLOCK_T_TERM=1 LIB_UNDER_TEST="$SANDBOX/v4/lib31.sh" lib_status 'trap dglock_release EXIT; rc=0; dglock_acquire "$GD" demo || rc=$?; echo not-reached')
assert "$o/$(state_of_lock)" "143/gone" "TERM at that point: the status is 143, and no empty lock directory is left behind"
fresh s31
o=$(DGLOCK_T_TERM=1 LIB_UNDER_TEST="$SANDBOX/v4/lib31.sh" lib_status 'rc=0; dglock_acquire "$GD" demo || rc=$?; echo not-reached')
assert "$o/$(state_of_lock)" "143/dir" "(the hazard that the early trap closes: without a trap the empty directory stays and blocks the next runs)"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 32: a BASHPID left in the environment must not make a plain acquire look like a subshell (bash 3.2 has none: its value is not believed; bash 4 and newer own the variable)"
fresh s32
o=$(BASHPID=1 "$BASH" -c '. "$1"; rc=0; dglock_acquire "$2" demo || rc=$?; echo "rc=$rc state=$DGLOCK_STATE"; dglock_release' _ "$LIB" "$GD" 2>&1)
assert "$o/$(state_of_lock)" "rc=0 state=taken/gone" "an inherited BASHPID=1: the lock is taken and released as usual"

echo "scenario 33: the library speaks on stderr only (a caller may read the output of its guard: iwe-safe-pull.sh reads an object id from stdout)"
fresh s33; stale_seed
GD="$GD" HN="$HN" T="$SANDBOX" "$BASH" -c 'set -uo pipefail; . "$1"; rc=0; dglock_acquire "$GD" demo || rc=$?; echo "rc=$rc"; dglock_release' _ "$LIB" > "$SANDBOX/s33.out" 2> "$SANDBOX/s33.err"
assert "$(cat "$SANDBOX/s33.out")" "rc=0" "a takeover prints NOTHING on stdout but what the caller printed"
assert "$(grep -c 'reclaiming the lock' "$SANDBOX/s33.err")" "1" "the takeover line is on stderr"
seed 'node=%s\npid=%s\nepoch=%s\ntoken=t\nscript=o\n' "$HN" "$QLIVE" "$(date -u +%s)"
GD="$GD" HN="$HN" T="$SANDBOX" "$BASH" -c 'set -uo pipefail; . "$1"; rc=0; dglock_acquire "$GD" demo || rc=$?; echo "rc=$rc"' _ "$LIB" > "$SANDBOX/s33.out" 2> "$SANDBOX/s33.err"
assert "$(cat "$SANDBOX/s33.out")/$(wc -c < "$SANDBOX/s33.err" | tr -d ' ')" "rc=1/0" "a busy lock: nothing on stdout but the caller's line, and the library itself says nothing (the caller reports the reason)"
rm -rf "$GD/dirty-guard.lock"

ROUNDS="${DGLOCK_SMOKE_ROUNDS:-10}"   # rounds of the race of scenario 34 (a mutation run uses fewer: the deterministic scenarios carry the weight there)
echo "scenario 34: two and eight runs at the same instant on a STALE lock (dead owner), $ROUNDS rounds each: exactly one of them takes the lock and the others find it held, whatever the order of their steps"
race_round() {  # <round> <runs> -- the runs wait for a signal, take the same stale lock and hold it until all have reported; prints the outcome codes, sorted
  local n=$1 runs=$2 i pids="" waited=0
  fresh "s34-$n"; stale_seed; rm -f "$SANDBOX/s34.go" "$SANDBOX/s34.release" "$SANDBOX"/s34.out.*
  for i in $(seq 1 "$runs"); do
    ( GD="$GD" HN="$HN" "$BASH" -c 'set -uo pipefail; . "$1"; until [ -e "$2" ]; do sleep 0.005; done; rc=0; dglock_acquire "$GD" racer || rc=$?; echo "R rc=$rc state=$DGLOCK_STATE reason=$DGLOCK_REASON"; until [ -e "$3" ]; do sleep 0.01; done; dglock_release' _ "${LIB_UNDER_TEST:-$LIB}" "$SANDBOX/s34.go" "$SANDBOX/s34.release" > "$SANDBOX/s34.out.$i" 2>&1 ) &
    pids="$pids $!"
  done
  sleep 0.3; : > "$SANDBOX/s34.go"
  while [ "$(cat "$SANDBOX"/s34.out.* 2>/dev/null | grep -c '^R ')" -lt "$runs" ] && [ "$waited" -lt 2000 ]; do sleep 0.01; waited=$((waited + 1)); done
  : > "$SANDBOX/s34.release"; wait $pids
  cat "$SANDBOX"/s34.out.* | grep '^R ' | sed 's/^R rc=\([0-9]*\) state=\([a-z-]*\).*/\1:\2/' | sort | uniq -c | awk '{ printf "%s:%s ", $2, $1 }'
}
bad_rounds=0; false_total=0
for runs in 2 8; do
  want="0:taken:1 1:held-alive:$((runs - 1)) "
  for r in $(seq 1 "$ROUNDS"); do
    got=$(race_round "$r" "$runs")
    [ "$got" = "$want" ] || { bad_rounds=$((bad_rounds + 1)); echo "  $runs runs, round $r: $got (wanted $want)"; }
    false_total=$((false_total + $(cat "$SANDBOX"/s34.out.* | grep -c -E 'not a directory|file or a link|could not be put back')))
  done
done
assert "$bad_rounds" "0" "in every round: one run took the lock (code 0, taken) and all the others found it held by a live owner (code 1, held-alive)"
assert "$false_total" "0" "no false reason, no displaced record"
assert "$(state_of_lock)" "gone" "everything released"
rm -rf "$SANDBOX"/s34-*

echo "scenario 35: a record is never published over the record of another run (the directory that this run made was replaced by the lock of another run before the record went in)"
fresh s35; inject "$LIB" 'if _dglock_publish; then' "$HOOK" "$SANDBOX/v4/lib35.sh"
cat > "$SANDBOX/v4/hook-z.sh" <<'EOF'
# the directory of this run is replaced by the COMPLETE lock of another run Z (live owner) just before the record is written
if [ ! -e "$T/hookz.done" ]; then : > "$T/hookz.done"; rm -rf "$DGLOCK_DIR"; mkdir "$DGLOCK_DIR"; printf 'node=%s\npid=%s\nepoch=%s\ntoken=ztoken\nscript=z\n' "$HN" "$QPID" "$(date -u +%s)" > "$DGLOCK_DIR/owner"; fi
EOF
rm -f "$SANDBOX"/hook*.done
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-z.sh" QPID="$QLIVE" LIB_UNDER_TEST="$SANDBOX/v4/lib35.sh" lib_run "$ACQ")
assert "$(rcline "$o")/$(grep -c '^token=ztoken$' "$GD/dirty-guard.lock/owner")/$(ls -A "$GD/dirty-guard.lock" | tr '\n' ' ')" "rc=1 state=held-alive/1/owner " "busy (the owner of that lock is alive), the record of the other run is intact, and our temporary file is not left in its directory"
assert "$(printf '%s\n' "$o" | grep -c -E "owner pid $QLIVE is alive")" "1" "the reason names the live owner of the lock that this run found in its place"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 36: a signal in the middle of a takeover (the dead record is aside, ours is not in): the exit handler puts the dead record back, so the lock can be judged and taken over again (no lock without a record)"
fresh s36; inject "$LIB" 'echo "$_DGLOCK_PREFIX reclaiming the lock:' 'if [ -n "${DGLOCK_T_TERM:-}" ]; then kill -TERM $$; fi' "$SANDBOX/v4/lib36.sh"
stale_seed
o=$(DGLOCK_T_TERM=1 LIB_UNDER_TEST="$SANDBOX/v4/lib36.sh" lib_status 'trap dglock_release EXIT; rc=0; dglock_acquire "$GD" demo || rc=$?; echo not-reached')
assert "$o/$(grep -c '^token=old$' "$GD/dirty-guard.lock/owner" 2>/dev/null)/$(ls -A "$GD/dirty-guard.lock" | tr '\n' ' ')" "143/1/owner " "TERM there: the status is 143, the record of the dead owner is back, nothing else is left in the lock directory"
o=$(lib_run "$ACQ; dglock_release")
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c reclaiming)/$(state_of_lock)" "rc=0 state=taken/1/gone" "the next run takes the lock over as usual"
fresh s36; stale_seed
o=$(DGLOCK_T_TERM=1 LIB_UNDER_TEST="$SANDBOX/v4/lib36.sh" lib_status 'rc=0; dglock_acquire "$GD" demo || rc=$?; echo not-reached')
assert "$o/$([ -e "$GD/dirty-guard.lock/owner" ] && echo record || echo none)" "143/none" "(the hazard that the early trap closes: without a handler the lock stays without a record)"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 37: a zombie (it has exited but its parent has not collected it) still exists for kill -0 and ps: its lock is NOT taken over"
fresh s37
( sleep 0.1 & exec sleep 30 ) &   # the sleeper of 0.1 s exits and nobody collects it: a zombie (the parent is the process that exec'd into sleep 30)
ZPARENT=$!; BGPIDS="$BGPIDS $ZPARENT"
sleep 0.5
ZOMBIE=$(ps -A -o pid=,ppid=,stat= 2>/dev/null | awk -v pp="$ZPARENT" '$2 == pp && $3 ~ /^Z/ { print $1; exit }')
if [ -n "$ZOMBIE" ]; then
  seed 'node=%s\npid=%s\nepoch=%s\n' "$HN" "$ZOMBIE" "$(date -u +%s)"
  o=$(lib_run "$ACQ")
  assert "$(rcline "$o")/$(state_of_lock)" "rc=1 state=held-alive/dir" "a zombie owner counts as alive: the lock stays"
  rm -rf "$GD/dirty-guard.lock"
else
  echo "  ok   (skipped: no zombie could be made on this system)"
fi

echo "scenario 35b: ... also when ln refuses for another reason than a taken name: the record of the other run is still not touched (there is no rename that could replace it)"
fresh s35; rm -f "$SANDBOX"/hook*.done
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-z.sh" QPID="$QLIVE" LIB_UNDER_TEST="$SANDBOX/v4/lib35.sh" lib_run "ln() { return 1; }; $ACQ")
assert "$(rcline "$o")/$(grep -c '^token=ztoken$' "$GD/dirty-guard.lock/owner")/$(ls -A "$GD/dirty-guard.lock" | tr '\n' ' ')" "rc=1 state=held-alive/1/owner " "ln fails, a record of another run is in the place: busy, that record is intact, and our temporary file is not left"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 38: a lock directory that has no record YET (its creator, or a run that is taking it over, is about to write it): the run waits a few milliseconds before it calls the lock ownerless"
fresh s38; mkdir "$GD/dirty-guard.lock"
cat > "$SANDBOX/v4/hook-late-record.sh" <<'EOF'
# the creator finishes while this run pauses: its record appears
if [ ! -e "$T/hooklate.done" ]; then : > "$T/hooklate.done"; printf 'node=%s\npid=%s\nepoch=%s\ntoken=late\nscript=late\n' "$HN" "$QPID" "$(date -u +%s)" > "$DGLOCK_DIR/owner"; fi
EOF
sed 's@sleep 0.02 2>/dev/null || :; fi; }@sleep 0.02 2>/dev/null || :; fi; if [ -n "${DGLOCK_T_HOOK:-}" ]; then . "$DGLOCK_T_HOOK"; fi; }@' "$LIB" > "$SANDBOX/v4/lib38.sh"
assert "$(grep -c 'DGLOCK_T_HOOK' "$SANDBOX/v4/lib38.sh")" "1" "precondition: the hook is in the pause of the copy of the library"
rm -f "$SANDBOX"/hook*.done
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-late-record.sh" QPID="$QLIVE" LIB_UNDER_TEST="$SANDBOX/v4/lib38.sh" lib_run "$ACQ")
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c "owner pid $QLIVE is alive")" "rc=1 state=held-alive/1" "the record appeared during the pause: the lock is judged by it (held-alive), not called ownerless"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 39: the rename of the dead record fails because another run was faster and has already written its own record: the lock is judged again (busy by a live owner), it is NOT reported as 'cannot be taken over'"
fresh s39; inject "$LIB" 'if ! { mv "$DGLOCK_DIR/owner" "$dead"' "$HOOK" "$SANDBOX/v4/lib39.sh"
stale_seed; rm -f "$SANDBOX"/hook*.done
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-q.sh" QPID="$QLIVE" LIB_UNDER_TEST="$SANDBOX/v4/lib39.sh" lib_run 'mv() { case "$*" in *owner.dead*) return 1 ;; esac; command mv "$@"; }; '"$ACQ")
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c "owner pid $QLIVE is alive")/$(printf '%s\n' "$o" | grep -c 'could not be taken over')" "rc=1 state=held-alive/1/0" "the record in the place is the record of the live run Q: busy by Q, and no false 'cannot be taken over'"
rm -rf "$GD/dirty-guard.lock"
fresh s39; stale_seed; chmod 555 "$GD/dirty-guard.lock"
if [ "$(id -u)" = 0 ]; then echo "  ok   (skipped: running as root, a directory mode does not stop root)"; else
o=$(lib_run "$ACQ")
chmod 755 "$GD/dirty-guard.lock"
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c 'could not be taken over (owner pid .* is gone)')/$([ -f "$GD/dirty-guard.lock/owner" ] && echo whole || echo damaged)" "rc=1 state=held-error/1/whole" "a dead owner's lock whose directory cannot be written: named (could not be taken over), and the record is still whole"
fi
rm -rf "$GD/dirty-guard.lock"
fresh s39; stale_seed
o=$(lib_run 'mv() { case "$*" in *owner.dead*) return 1 ;; esac; command mv "$@"; }; '"$ACQ")
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c 'could not be taken over (owner pid .* is gone)')/$(grep -c '^token=old$' "$GD/dirty-guard.lock/owner")" "rc=1 state=held-error/1/1" "the rename of the dead record is refused although the directory is writable (the record is still there, whole): named as that, not as a lock that keeps changing hands"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 40: a lock that changes hands before every one of our renames: the take stops after a few tries and says so (not with the last judgment, a dead owner, which would contradict the busy answer)"
fresh s40; inject "$LIB" 'if ! { mv "$DGLOCK_DIR/owner" "$dead"' "$HOOK" "$SANDBOX/v4/lib40.sh"
cat > "$SANDBOX/v4/hook-swap.sh" <<'EOF'
# the stale record is swapped for ANOTHER stale record (another token) before every rename
n=$(cat "$T/swap.count" 2>/dev/null || echo 0); echo $((n + 1)) > "$T/swap.count"
rm -f "$DGLOCK_DIR/owner"; printf 'node=%s\npid=%s\nepoch=%s\ntoken=swap%s\nscript=s\n' "$HN" "$DEADP" "$(date -u +%s)" "$n" > "$DGLOCK_DIR/owner"
EOF
stale_seed; rm -f "$SANDBOX/swap.count"
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-swap.sh" DEADP="$DEAD_PID" LIB_UNDER_TEST="$SANDBOX/v4/lib40.sh" lib_run "$ACQ")
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c 'kept changing hands while it was being taken over')/$(cat "$SANDBOX/swap.count")/$([ -f "$GD/dirty-guard.lock/owner" ] && echo record || echo none)" "rc=1 state=held-error/1/8/record" "eight lost claims: busy, said as that, the records that were moved aside are all put back (a record is in the place)"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 41: a TERM or HUP that arrives while mkdir ITSELF runs (the directory is made, the flag was not set yet in the earlier version): the exit handler still removes the empty directory, and the next run takes the lock"
fresh s41; mkdir -p "$SANDBOX/s41bin"; REAL_MKDIR=$(command -v mkdir)
for sig in TERM HUP; do
  fresh s41
  printf '#!%s\n%s "$@"; rc=$?\nkill -%s $PPID\nsleep 0.3\nexit $rc\n' "$BASH" "$REAL_MKDIR" "$sig" > "$SANDBOX/s41bin/mkdir"; chmod +x "$SANDBOX/s41bin/mkdir"
  o=$(PATH="$SANDBOX/s41bin:$PATH" lib_status 'trap dglock_release EXIT; rc=0; dglock_acquire "$GD" demo || rc=$?; echo not-reached')
  case "$sig" in TERM) want=143 ;; HUP) want=129 ;; esac
  assert "$o/$(state_of_lock)" "$want/gone" "$sig while mkdir runs: the status of the signal, and no empty lock directory is left behind"
  o=$(lib_run "$ACQ; dglock_release")
  assert "$(rcline "$o")/$(state_of_lock)" "rc=0 state=taken/gone" "the next run takes the lock (an empty directory left behind would have stopped it for good)"
done

echo "scenario 42: a lock that is released between two looks of the judge is neither 'not a directory' nor 'cannot be read': the lock is judged again"
cat > "$SANDBOX/v4/hook-release.sh" <<'EOF'
# the owner releases at this very moment: the directory is renamed away and deleted
if [ ! -e "$T/hookr.done" ]; then : > "$T/hookr.done"; mv "$DGLOCK_DIR" "$DGLOCK_DIR.released.x" && rm -rf "$DGLOCK_DIR.released.x"; fi
EOF
for spot in '  if [ -L "$DGLOCK_DIR" ] || [ ! -d "$DGLOCK_DIR" ]; then' '  _DGLOCK_LABEL="no owner file"'; do
  fresh s42; inject "$LIB" "$spot" "$HOOK" "$SANDBOX/v4/lib42a.sh"
  sed 's@sleep 0.02 2>/dev/null || :; fi; }@sleep 0.02 2>/dev/null || :; fi; printf x >> "$T/pauses"; }@' "$SANDBOX/v4/lib42a.sh" > "$SANDBOX/v4/lib42.sh"
  seed 'node=%s\npid=%s\nepoch=%s\ntoken=t\nscript=o\n' "$HN" "$QLIVE" "$(date -u +%s)"; rm -f "$SANDBOX"/hook*.done "$SANDBOX/pauses"
  o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-release.sh" LIB_UNDER_TEST="$SANDBOX/v4/lib42.sh" lib_run "$ACQ; dglock_release")
  assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c -E 'not a directory|file or a link|cannot be read')/$(wc -c < "$SANDBOX/pauses" 2>/dev/null | tr -d ' ' || echo 0)" "rc=0 state=taken/0/0" "released before the look '${spot#  }': the free lock is taken at once (no false reason, and no pause: a pause is what a lock without a record would get)"
done
fresh s42; inject "$LIB" '  awk -F= '"'"'$1 == "pid" || $1 == "node"' "$HOOK" "$SANDBOX/v4/lib42b.sh"
inject "$SANDBOX/v4/lib42b.sh" 'if [ -z "$snap" ]; then' 'if [ -n "${DGLOCK_T_HOOK2:-}" ]; then . "$DGLOCK_T_HOOK2"; fi' "$SANDBOX/v4/lib42c.sh"
cat > "$SANDBOX/v4/hook-z2.sh" <<'EOF'
# right after the failed read: a live run Z has made a new lock with its record
if [ ! -e "$T/hookz2.done" ]; then : > "$T/hookz2.done"; mkdir "$DGLOCK_DIR"; printf 'node=%s\npid=%s\nepoch=%s\ntoken=ztoken\nscript=z\n' "$HN" "$QPID" "$(date -u +%s)" > "$DGLOCK_DIR/owner"; fi
EOF
seed 'node=%s\npid=%s\nepoch=%s\ntoken=t\nscript=o\n' "$HN" "$QLIVE" "$(date -u +%s)"; rm -f "$SANDBOX"/hook*.done
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-release.sh" DGLOCK_T_HOOK2="$SANDBOX/v4/hook-z2.sh" QPID="$QLIVE" LIB_UNDER_TEST="$SANDBOX/v4/lib42c.sh" lib_run "$ACQ")
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c "owner pid $QLIVE is alive")/$(printf '%s\n' "$o" | grep -c 'cannot be read')" "rc=1 state=held-alive/1/0" "released at the read, a new lock of a live run stands there right after: busy by that run, not 'cannot be read'"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 43: a lock that a live run makes and releases around our mkdir, twice in a row, is contention: the take goes on (it is not 'the lock directory cannot be created')"
fresh s43; inject "$LIB" '  _DGLOCK_MADE=1   # set BEFORE the mkdir' "$HOOK" "$SANDBOX/v4/lib43.sh"
inject "$SANDBOX/v4/lib43.sh" '    [ "$rc" -eq 1 ] || return "$rc"' 'if [ -n "${DGLOCK_T_HOOK2:-}" ]; then . "$DGLOCK_T_HOOK2"; fi' "$SANDBOX/v4/lib43b.sh"
cat > "$SANDBOX/v4/hook-churn-before.sh" <<'EOF'
# another run makes the lock just before our mkdir (twice)
n=$(cat "$T/churn.n" 2>/dev/null || echo 0); if [ "$n" -lt 2 ]; then mkdir "$DGLOCK_DIR" 2>/dev/null || :; fi
EOF
cat > "$SANDBOX/v4/hook-churn-after.sh" <<'EOF'
# ... and releases it just after our mkdir said no (twice)
n=$(cat "$T/churn.n" 2>/dev/null || echo 0); if [ "$n" -lt 2 ]; then rm -rf "$DGLOCK_DIR"; echo $((n + 1)) > "$T/churn.n"; fi
EOF
rm -f "$SANDBOX/churn.n"
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-churn-before.sh" DGLOCK_T_HOOK2="$SANDBOX/v4/hook-churn-after.sh" LIB_UNDER_TEST="$SANDBOX/v4/lib43b.sh" lib_run "$ACQ; dglock_release")
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c 'cannot be created')/$(cat "$SANDBOX/churn.n")/$(ls -A "$GD" | grep -c 'probe')" "rc=0 state=taken/0/2/0" "two rounds of contention: the lock is taken at the third try, no false 'cannot be created', no probe directory left"

echo "scenario 44: the owner releases while a straddling run holds its record aside for one read: the release waits a few milliseconds; the record is back: the lock is released; it is not back: the lock stays, and the release SAYS so (under set -e too)"
fresh s44; inject "$LIB" '  t=$(_dglock_field token) || :' "$HOOK" "$SANDBOX/v4/lib44.sh"
sed 's@sleep 0.02 2>/dev/null || :; fi; }@sleep 0.02 2>/dev/null || :; fi; if [ -n "${DGLOCK_T_HOOK2:-}" ]; then . "$DGLOCK_T_HOOK2"; fi; }@' "$SANDBOX/v4/lib44.sh" > "$SANDBOX/v4/lib44b.sh"
cat > "$SANDBOX/v4/hook-aside.sh" <<'EOF'
# a straddling run has just moved the record of this owner aside (it will put it back in a moment)
if [ ! -e "$T/hookaside.done" ]; then : > "$T/hookaside.done"; mv "$DGLOCK_DIR/owner" "$DGLOCK_DIR/owner.dead.straddler.1"; fi
EOF
cat > "$SANDBOX/v4/hook-back.sh" <<'EOF'
# ... and puts it back while the owner waits
if [ -e "$DGLOCK_DIR/owner.dead.straddler.1" ]; then ln "$DGLOCK_DIR/owner.dead.straddler.1" "$DGLOCK_DIR/owner" && rm -f "$DGLOCK_DIR/owner.dead.straddler.1"; fi
EOF
rm -f "$SANDBOX"/hook*.done
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-aside.sh" DGLOCK_T_HOOK2="$SANDBOX/v4/hook-back.sh" LIB_UNDER_TEST="$SANDBOX/v4/lib44b.sh" lib_run 'dglock_acquire "$GD" A || exit 9; dglock_release; [ -e "$DGLOCK_DIR" ] && echo STILL-THERE || echo released')
assert "$(printf '%s\n' "$o" | tail -n 1)/$(printf '%s\n' "$o" | grep -c 'was not released')" "released/0" "the record came back during the wait: the lock is released, nothing is said"
fresh s44; rm -f "$SANDBOX"/hook*.done
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-aside.sh" LIB_UNDER_TEST="$SANDBOX/v4/lib44b.sh" lib_run_e 'trap "dglock_release; echo handler-reached-its-end" EXIT; dglock_acquire "$GD" A || exit 9; exit 7')
rm -rf "$GD/dirty-guard.lock"; rm -f "$SANDBOX"/hook*.done
st=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-aside.sh" LIB_UNDER_TEST="$SANDBOX/v4/lib44b.sh" lib_status 'set -e; trap "dglock_release" EXIT; dglock_acquire "$GD" A || exit 9; exit 7')
assert "$(printf '%s\n' "$o" | grep -c 'was not released')/$(printf '%s\n' "$o" | grep -c 'handler-reached-its-end')" "1/1" "the record never came back: the lock stays (the next run judges it) and the release says so; the handler of a guard under set -e reaches its end"
assert "$st" "7" "... and the exit status of the guard under set -e is kept"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 45: a straddling run puts back the record of a live owner, and that owner releases (the directory goes) before the put-back: nothing is displaced, the run judges again and takes the free lock (no 'could not be put back' for a record that is gone)"
fresh s45; inject "$LIB" 'if ! { mv "$DGLOCK_DIR/owner" "$dead"' "$HOOK" "$SANDBOX/v4/lib45a.sh"
inject "$SANDBOX/v4/lib45a.sh" 'if [ "$snap1" != "$_DGLOCK_SNAP" ]' 'if [ -n "${DGLOCK_T_HOOK2:-}" ]; then . "$DGLOCK_T_HOOK2"; fi' "$SANDBOX/v4/lib45.sh"
cat > "$SANDBOX/v4/hook-release2.sh" <<'EOF'
# B has moved the record of the live owner A aside; now A releases: the directory is renamed away and deleted
if [ ! -e "$T/hookr2.done" ]; then : > "$T/hookr2.done"; mv "$DGLOCK_DIR" "$DGLOCK_DIR.released.atoken" && rm -rf "$DGLOCK_DIR.released.atoken"; fi
EOF
stale_seed; rm -f "$SANDBOX"/hook*.done
o=$(DGLOCK_T_HOOK="$SANDBOX/v4/hook-q.sh" DGLOCK_T_HOOK2="$SANDBOX/v4/hook-release2.sh" QPID="$QLIVE" LIB_UNDER_TEST="$SANDBOX/v4/lib45.sh" lib_run "$ACQ; dglock_release")
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c 'could not be put back')/$(ls -A "$GD" | grep -c 'owner.dead')" "rc=0 state=taken/0/0" "the lock was free by then: it is taken, and no false warning or leftover is left"

echo "scenario 46: a takeover whose own record cannot be linked in (ln refuses) so that the put-back of the dead record fails too: the reason names the file in which the dead record is left (not 'was put back'), and the warning says it"
fresh s46; stale_seed
o=$(lib_run 'ln() { return 1; }; '"$ACQ")
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c 'was put back')/$(printf '%s\n' "$o" | grep -c 'could not be put back: it is left in')/$(printf '%s\n' "$o" | grep -c 'warning: the record of the dead owner was moved aside')" "rc=2 state=held-error/0/1/1" "the dead record could not be put back: the reason and the warning name the file, no 'was put back'"
assert "$(ls -A "$GD/dirty-guard.lock" | grep -c '^owner\.dead\.')/$([ -e "$GD/dirty-guard.lock/owner" ] && echo record || echo none)" "1/none" "the dead record is in its named file, and no record stands in the place (the lock stays held, loudly, for a human)"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 47: a TERM in a takeover BEFORE the dead record is moved (our draft is written): the exit handler removes the draft"
fresh s47; inject "$LIB" '  _DGLOCK_CLAIM="$dead"   # from here a release' 'if [ -n "${DGLOCK_T_TERM:-}" ]; then kill -TERM $$; fi' "$SANDBOX/v4/lib47.sh"
stale_seed
o=$(DGLOCK_T_TERM=1 LIB_UNDER_TEST="$SANDBOX/v4/lib47.sh" lib_status 'trap dglock_release EXIT; rc=0; dglock_acquire "$GD" demo || rc=$?; echo not-reached')
assert "$o/$(ls -A "$GD/dirty-guard.lock" | tr '\n' ' ')" "143/owner " "TERM there: the status is 143, the dead record is untouched, and no draft of ours is left in the lock directory"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 48: a command the library needs is not in PATH: code 3, said by name, nothing is done (a missing ln would silently turn the link into the check-then-rename that the link replaces)"
fresh s48; NOLN="$SANDBOX/noln"; mkdir -p "$NOLN"
for c in bash awk date hostname ls mkdir mv rm rmdir; do p=$(command -v "$c") && ln -sf "$p" "$NOLN/$c"; done
o=$(PATH="$NOLN" lib_run "$ACQ")
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c 'the command ln is not in PATH')/$(state_of_lock)" "rc=3 state=held-error/1/gone" "no ln: code 3, the reason names ln, and no lock directory was made"

echo "scenario 49: a record in the OLD format (host=, no node=) whose owner is dead is NOT taken over by this library: an old guard may be taking it over at this moment, and the two must never judge the same stale lock; the reason says what to do"
fresh s49; seed 'host=%s\npid=%s\n' "$HN" "$DEAD_PID"
o=$(lib_run "$ACQ")
assert "$(rcline "$o")/$(state_of_lock)/$(printf '%s\n' "$o" | grep -c 'in the old format')/$(printf '%s\n' "$o" | grep -c '^id=old-format pid ')/$(grep -c "^pid=$DEAD_PID$" "$GD/dirty-guard.lock/owner")" "rc=1 state=held-unproven/dir/1/1/1" "old-format record, dead owner: held, loudly, the lock and its record untouched"
rm -rf "$GD/dirty-guard.lock"
fresh s49; seed 'host=%s\npid=%s\nepoch=%s\ntoken=pub\nscript=canon-reconcile-published\n' "$HN" "$DEAD_PID" "$(date -u +%s)"
o=$(lib_run "$ACQ")
assert "$(rcline "$o")/$(state_of_lock)/$(printf '%s\n' "$o" | grep -c 'in the old format')" "rc=1 state=held-unproven/dir/1" "the record of the publisher of Ф81 (host=, pid=, epoch=, token=, script=) is in the old format too: left to the old code or a human"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 50: a record in the old format whose owner is ALIVE is held as always (an old guard that runs now keeps its lock), with the age when the record has one"
fresh s50; seed 'host=%s\npid=%s\nepoch=%s\n' "$HN" "$QLIVE" "$(( $(date -u +%s) - 120 ))"
o=$(lib_run "$ACQ")
assert "$(rcline "$o")/$(printf '%s\n' "$o" | grep -c "owner pid $QLIVE is alive, the lock was taken 2 min ago")" "rc=1 state=held-alive/1" "old-format record, live owner: held-alive with the age"
rm -rf "$GD/dirty-guard.lock"

echo "scenario 51: an OLD guard and a lock written by this library: the old guard stands aside, whatever the owner is (dead, or a process it cannot signal), and it still takes over a stale lock of its own format; the old lock code is copied here as it was (git-dirty-guard.sh at 8434c03c45; the other three guards have the same shape)"
cat > "$SANDBOX/old-guard-model.sh" <<'EOF'
#!/usr/bin/env bash
# the lock section of git-dirty-guard.sh as it was before the library: ONE failed kill -0 is a dead owner, the directory is removed
GIT_DIR="$1"; LOCK_DIR="$GIT_DIR/dirty-guard.lock"; LOCK_META="$LOCK_DIR/owner"
HOSTNAME_NOW="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -f "$LOCK_META" ]; then
    OTHER_HOST=$(awk -F= '$1=="host"{print $2}' "$LOCK_META" 2>/dev/null)
    OTHER_PID=$(awk -F= '$1=="pid"{print $2}' "$LOCK_META" 2>/dev/null)
    if [ "$OTHER_HOST" = "$HOSTNAME_NOW" ] && [ -n "$OTHER_PID" ] && ! kill -0 "$OTHER_PID" 2>/dev/null; then
      echo "old guard: reclaiming stale lock (pid=$OTHER_PID on $OTHER_HOST)" >&2
      rm -rf "$LOCK_DIR" 2>/dev/null
    fi
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then echo "old guard: lock busy"; exit 1; fi
fi
echo "old guard: took the lock"
EOF
fresh s51; stale_seed
o=$("$BASH" "$SANDBOX/old-guard-model.sh" "$GD" 2>&1)
assert "$(printf '%s' "$o" | tr '\n' ' ')/$(grep -c '^token=old$' "$GD/dirty-guard.lock/owner")" "old guard: lock busy/1" "a lock of this library with a DEAD owner: the old guard stands aside (its record has no host=), the lock is untouched"
rm -rf "$GD/dirty-guard.lock"; fresh s51
seed 'node=%s\npid=1\nepoch=%s\ntoken=pid1\nscript=o\n' "$HN" "$(date -u +%s)"
o=$("$BASH" "$SANDBOX/old-guard-model.sh" "$GD" 2>&1)
assert "$(printf '%s' "$o" | tr '\n' ' ')/$(grep -c '^token=pid1$' "$GD/dirty-guard.lock/owner")" "old guard: lock busy/1" "a lock of this library whose owner the old guard cannot signal (pid 1: kill -0 is refused for a user process): the old guard stands aside; before this it removed such a lock"
rm -rf "$GD/dirty-guard.lock"; fresh s51; seed 'host=%s\npid=%s\n' "$HN" "$DEAD_PID"
o=$("$BASH" "$SANDBOX/old-guard-model.sh" "$GD" 2>&1)
assert "$(printf '%s' "$o" | tr '\n' ' ')" "old guard: reclaiming stale lock (pid=$DEAD_PID on $HN) old guard: took the lock" "a stale lock in the OLD format: the old guard takes it over as it always did (and this library left it alone in scenario 49)"
rm -rf "$GD/dirty-guard.lock"

kill "$QLIVE" "$PLIVE" 2>/dev/null; wait "$QLIVE" "$PLIVE" 2>/dev/null

if [ "$fails" -eq 0 ]; then echo "PASS: all scenarios"; else echo "FAIL: $fails assertion(s)"; exit 1; fi
