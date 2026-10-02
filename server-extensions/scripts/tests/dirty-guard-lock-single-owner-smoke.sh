#!/usr/bin/env bash
# dirty-guard-lock-single-owner-smoke.sh -- the guard against the copies coming back (WP-530 Ф81 remainder, peer session 2026-10-02-01):
# the code of $GIT_DIR/dirty-guard.lock lives in scripts/lib/dirty-guard-lock.sh and nowhere else. Five copies of it had drifted apart: one
# script had been repaired, four had not. A static check, no repository needed: if somebody copies the mkdir-and-kill-0 code into a guard
# again, or writes a sixth script that takes the lock by itself, this fails.
# Usage: dirty-guard-lock-single-owner-smoke.sh [<scripts dir under test>]   (default: the scripts directory next to this file)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SDIR="${1:-$HERE/..}"
fails=0
assert() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }
code_of() { grep -v '^[[:space:]]*#' "$1"; }   # a script without its comment lines

GUARDS="git-dirty-guard canon-refresh canon-reconcile canon-reconcile-published sync-strategy-files"
echo "scenario 1: none of the five guards holds code of the lock of its own"
for g in $GUARDS; do
  f="$SDIR/$g.sh"
  assert "$(code_of "$f" | grep -c -E '(LOCK_DIR|LOCK_META|OTHER_PID|OTHER_HOST|HOSTNAME_NOW|release_guard_lock|reclaim_lock|acquire_lock|publish_owner)')" "0" "$g.sh: none of the names of the old lock code (LOCK_DIR, LOCK_META, OTHER_PID, OTHER_HOST, HOSTNAME_NOW, ...)"
  assert "$(code_of "$f" | grep -c -E 'mkdir[^|;&]*dirty-guard')" "0" "$g.sh: no mkdir of the lock directory"
done
echo "scenario 2: kill -0 stays only where it asks about something else (the session semaphores of the publisher), never about the lock"
for g in git-dirty-guard canon-refresh canon-reconcile sync-strategy-files; do
  assert "$(code_of "$SDIR/$g.sh" | grep -c 'kill -0')" "0" "$g.sh: no kill -0 at all"
done
assert "$(code_of "$SDIR/canon-reconcile-published.sh" | grep -c 'kill -0')" "1" "canon-reconcile-published.sh: exactly one kill -0, the one of its session semaphores"
assert "$(code_of "$SDIR/canon-reconcile-published.sh" | grep 'kill -0' | grep -c 'sem_pid')" "1" "canon-reconcile-published.sh: and that one asks about a semaphore pid"
echo "scenario 3: each guard loads the library the same way (next to itself, ready marker checked, loud failure) and uses its two functions"
for g in $GUARDS; do
  f="$SDIR/$g.sh"
  assert "$(code_of "$f" | grep -c 'DGLOCK_LIB="\$SCRIPT_DIR/lib/dirty-guard-lock.sh"')" "1" "$g.sh: the library is looked for next to the script"
  assert "$(code_of "$f" | grep -c 'DGLOCK_LIB_READY:-}" = 1')" "1" "$g.sh: the ready marker is checked after the library was sourced"
  assert "$(code_of "$f" | grep -c '^unset DGLOCK_LIB_READY')" "1" "$g.sh: the marker is unset BEFORE the source (an inherited one must not vouch for a cut library)"
  assert "$(code_of "$f" | grep -c 'the lock library is missing or unusable')" "1" "$g.sh: a missing or cut-short library is a loud failure"
  assert "$(code_of "$f" | grep -c 'dglock_acquire "\$GIT_DIR"')" "1" "$g.sh: one acquire, in the shell of the script"
  assert "$(code_of "$f" | grep -c 'dglock_release')" "1" "$g.sh: one release, from the exit handler of the script"
  assert "$(code_of "$f" | grep -n -E '^(SCRIPT_DIR=|cd )' | sed -n '1p' | grep -c 'SCRIPT_DIR=')" "1" "$g.sh: SCRIPT_DIR is taken BEFORE the first cd (a relative \$0 would not find the library after it)"
  assert "$(code_of "$f" | grep -c -F 'SCRIPT_DIR="./$SCRIPT_DIR"')/$(code_of "$f" | grep -c -F 'cd "$SCRIPT_DIR" >/dev/null 2>&1 && pwd && printf x')/$(code_of "$f" | grep '^SCRIPT_DIR=' | sed 's/   # .*//' | grep -c 'dirname')" "1/1/0" "$g.sh: SCRIPT_DIR is made with no dirname and no CDPATH (./ prefix, cd silenced) and with the newline marker"
  assert "$(code_of "$f" | grep -c 'GIT_DIR=\$(git rev-parse --[a-z-]*git-dir && printf x)')" "1" "$g.sh: the git directory is captured with the newline marker (the lock is made where the guard says)"
done
echo "scenario 3a: each guard loads the library, THEN sets its exit handler, THEN asks for the lock (a signal between the mkdir of the library and its owner record must still remove the empty directory: the handler has to exist before the acquire)"
for g in $GUARDS; do
  f="$SDIR/$g.sh"
  l=$(code_of "$f" | grep -n 'DGLOCK_LIB_READY:-}" = 1' | sed -n '1p' | cut -d: -f1)
  t=$(code_of "$f" | grep -n -E '^trap .*(dglock_release|cleanup_guard)' | sed -n '1p' | cut -d: -f1)
  a=$(code_of "$f" | grep -n 'dglock_acquire "\$GIT_DIR"' | sed -n '1p' | cut -d: -f1)
  assert "$([ -n "$l" ] && [ -n "$t" ] && [ -n "$a" ] && [ "$l" -lt "$t" ] && [ "$t" -lt "$a" ] && echo ordered || echo "loader=$l trap=$t acquire=$a")" "ordered" "$g.sh: library loaded, exit handler set, lock asked for: in this order"
  assert "$(code_of "$f" | grep -c -E '^trap .*(dglock_release|cleanup_guard)')" "1" "$g.sh: exactly one exit handler that releases the lock (a bash script has one EXIT trap)"
done
echo "scenario 3b: the exit handler of git-dirty-guard keeps going to the release when the removal of its temporary file fails"
assert "$(code_of "$SDIR/git-dirty-guard.sh" | grep -c 'rm -f "\$STATUS_FILE" 2>/dev/null || :')" "1" "git-dirty-guard.sh: rm of the temporary file is followed by || : (set -e in a later edit must not skip the release)"
echo "scenario 4: no sixth script takes the lock by itself"
is_guard() { case " $GUARDS " in *" $1 "*) return 0 ;; esac; return 1; }   # a function: bash 3.2 cannot parse a case inside $( ... )
others=""
for f in "$SDIR"/*.sh; do
  b=$(basename "$f" .sh)
  if is_guard "$b"; then continue; fi
  if code_of "$f" | grep -q -E 'dirty-guard\.lock'; then others="$others$b "; fi
done
assert "$others" "" "no other script of the scripts directory names the lock directory in its code (take the lock through the library)"
echo "scenario 5: the library is the only owner: its header carries the contract, the limits and the scope"
L="${DGLOCK_LIB_UNDER_TEST:-$SDIR/lib/dirty-guard-lock.sh}"   # the mutation run names a mutated copy here
assert "$([ -r "$L" ] && echo present || echo missing)" "present" "the library file exists"
for k in "Contract." "The takeover rule" "Old and new guards (the delivery window" "SCOPE of the library" "Limits of this protocol" "External commands"; do
  assert "$(grep -c -F -- "$k" "$L" 2>/dev/null)" "1" "the header of the library has: $k"
done
echo "scenario 6: a takeover never renames or deletes the lock DIRECTORY (that is what leaves no moment without a lock): only the release removes it, and nothing else in the library moves it"
assert "$(code_of "$L" | grep -c 'rm -rf "\$DGLOCK_DIR"[[:space:]]')" "0" "the library: the lock directory is never deleted in place (a delete that fails half way would leave a lock without its record)"
assert "$(code_of "$L" | grep -c 'mv "\$DGLOCK_DIR" ')" "1" "the library: the one rename of the lock directory is the release of a lock with our token (it goes away at once, then it is deleted)"
assert "$(code_of "$L" | grep -c 'mv "\$DGLOCK_DIR/owner"')" "1" "the library: the takeover moves the RECORD of the dead owner, never the directory"
assert "$(code_of "$L" | grep -c -E 'ln "\$1" "\$DGLOCK_DIR/owner"')" "1" "the library: a record is put into place by a link that refuses a taken name, atomically"
assert "$(code_of "$L" | grep -c -E 'mv -f [^|;&]*owner"')" "0" "the library: no rename onto the owner record at all (a rename replaces the record of another run, and look-first-then-rename is not one step)"

echo "scenario 6b: the release and the put-back run in the exit trap of a guard under set -e: no bare assignment from a command substitution may be able to fail them (awk fails on an absent record); every read there ends in || :"
handlers=$(awk '/^(dglock_release|_dglock_unclaim)\(\) \{/ { on = 1 } on { print } on && /^}/ { on = 0 }' "$L")
assert "$(printf '%s\n' "$handlers" | grep -v '^[[:space:]]*#' | grep -E '(^|[;&|{(][[:space:]]*)[A-Za-z_]+=\$\(' | grep -v -c -F '|| :')" "0" "the library: every assignment from a command substitution in dglock_release and _dglock_unclaim ends in || :"
assert "$(printf '%s\n' "$handlers" | grep -c -E '^(dglock_release|_dglock_unclaim)\(\)')" "2" "the library: both handlers were found (the check looks at something)"

echo "scenario 7: the record is written with node=, never host=: a guard from before the library reads host= and would take over, by its old judgment, the live lock of a guard that uses the library (it removes a lock after ONE failed kill -0); with no host= it stands aside"
writer=$(awk '/^_dglock_write_tmp\(\) \{/ { on = 1 } on { print } on && /^}/ { on = 0 }' "$L")
assert "$(printf '%s\n' "$writer" | grep -c -F 'node=%s')/$(printf '%s\n' "$writer" | grep -c 'host=')" "1/0" "the library: the record has node= and no host= line"
assert "$(code_of "$L" | grep -c -F 'does not take such a lock over')" "1" "the library: a record in the old format (host=, no node=) is never taken over (the reason says what to do)"

if [ "$fails" -eq 0 ]; then echo "PASS: all scenarios"; else echo "FAIL: $fails assertion(s)"; exit 1; fi
