#!/usr/bin/env bash
# dirty-guard-lock-guards-smoke.sh -- the four guard scripts that share $GIT_DIR/dirty-guard.lock through scripts/lib/dirty-guard-lock.sh
# (canon-refresh.sh, canon-reconcile.sh, sync-strategy-files.sh, git-dirty-guard.sh; canon-reconcile-published.sh has its own suite)
# (WP-530 Ф81 remainder, peer session 2026-10-02-01 with Kimi and Codex). One table of busy profiles, the same scenarios for each guard.
# Two groups of assertions, so that the run on the guards as they were BEFORE the library can show what changed and what did not:
#   [old] behaviour that must NOT change: exit status, channel and first words of the busy message, a clean run, a lock kept or released
#   [new] what the library adds: the reason with the age of the lock, no takeover without proof (pid 1, a damaged or missing owner record),
#         the takeover message, the release of ONLY a lock with our token, the loud failure when the library is missing or cut short
# Usage: dirty-guard-lock-guards-smoke.sh [<scripts dir under test>]   (default: the scripts directory next to this file)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SDIR="${1:-$HERE/..}"
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/dglock-guards.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
REAL_GIT=$(command -v git)
HN="${HOSTNAME:-$(hostname)}"
DEAD_PID=$(( $(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 999998) + 1 ))   # a pid that cannot exist: above pid_max (4194304 on Tsekh) and above every pid of macOS
mkdir -p "$SANDBOX/home"
if [ -f "$SDIR/lib/dirty-guard-lock.sh" ]; then OWNKEY=node; else OWNKEY=host; fi   # the key that this version of the guards writes and understands for the name of the host: the guards of the library write node= (an old guard stands aside from it), the guards before it understand only host=
fails_old=0; fails_new=0
assert_old() { if [ "$1" = "$2" ]; then echo "  ok   [old] $3"; else echo "  FAIL [old] $3 (got '$1', want '$2')"; fails_old=$((fails_old+1)); fi; }
assert_new() { if [ "$1" = "$2" ]; then echo "  ok   [new] $3"; else echo "  FAIL [new] $3 (got '$1', want '$2')"; fails_new=$((fails_new+1)); fi; }

new_clone() {  # <name> -> $SANDBOX/<name>-clone, clean and level with its origin
  "$REAL_GIT" init --bare -q "$SANDBOX/$1-origin.git"; "$REAL_GIT" init -q "$SANDBOX/$1-seed"
  "$REAL_GIT" -C "$SANDBOX/$1-seed" config user.name fixture; "$REAL_GIT" -C "$SANDBOX/$1-seed" config user.email fixture@example.invalid
  mkdir -p "$SANDBOX/$1-seed/inbox" "$SANDBOX/$1-seed/current"; printf 'card v1\n' > "$SANDBOX/$1-seed/inbox/WP-1.md"
  "$REAL_GIT" -C "$SANDBOX/$1-seed" add inbox/WP-1.md; "$REAL_GIT" -C "$SANDBOX/$1-seed" commit -qm initial; "$REAL_GIT" -C "$SANDBOX/$1-seed" branch -M main
  "$REAL_GIT" -C "$SANDBOX/$1-seed" remote add origin "$SANDBOX/$1-origin.git"; "$REAL_GIT" -C "$SANDBOX/$1-seed" push -q -u origin main
  "$REAL_GIT" -C "$SANDBOX/$1-origin.git" symbolic-ref HEAD refs/heads/main; "$REAL_GIT" clone -q "$SANDBOX/$1-origin.git" "$SANDBOX/$1-clone"
  "$REAL_GIT" -C "$SANDBOX/$1-clone" config user.name fixture; "$REAL_GIT" -C "$SANDBOX/$1-clone" config user.email fixture@example.invalid
}
profile() {  # <guard> -> what the guard did at a busy lock BEFORE the library, and how it is called
  case "$1" in
    canon-refresh)       BUSY_RC=0; BUSY_CH=err; BUSY_PREFIX='canon-refresh: lock busy (another refresh in progress), skipping this cycle'; TAKE_PREFIX='canon-refresh:'; LIBMISS_RC=1; ARGS=(main) ;;
    canon-reconcile)     BUSY_RC=0; BUSY_CH=out; BUSY_PREFIX='canon-reconcile: lock busy (another refresh in progress), skipping this cycle'; TAKE_PREFIX='canon-reconcile:'; LIBMISS_RC=1; ARGS=(main) ;;
    sync-strategy-files) BUSY_RC=0; BUSY_CH=err; BUSY_PREFIX='[sync-strategy-files] lock busy (guard or canon-refresh running), skipping this cycle'; TAKE_PREFIX='[sync-strategy-files]'; LIBMISS_RC=1; ARGS=() ;;
    git-dirty-guard)     BUSY_RC=1; BUSY_CH=err; BUSY_PREFIX='git-dirty-guard: lock busy (live owner or unproven), refusing'; TAKE_PREFIX='git-dirty-guard:'; LIBMISS_RC=2; ARGS=(main) ;;
  esac
}
run_guard() {  # <guard> <clone> [<scripts dir>] -> G_RC, G_OUT (stdout), G_ERR (stderr); extra environment from the caller
  local dir="${3:-$SDIR}"
  G_OUT=$(HOME="$SANDBOX/home" GIT_DIRTY_GUARD_TG_ALERTS=false bash "$dir/$1.sh" "$2" ${ARGS[@]+"${ARGS[@]}"} 2>"$SANDBOX/err"); G_RC=$?
  G_ERR=$(cat "$SANDBOX/err")
}
busy_text() { if [ "$BUSY_CH" = out ]; then printf '%s' "$G_OUT"; else printf '%s' "$G_ERR"; fi; }
other_text() { if [ "$BUSY_CH" = out ]; then printf '%s' "$G_ERR"; else printf '%s' "$G_OUT"; fi; }
lock_of() { echo "$1/.git/dirty-guard.lock"; }
state_of() { if [ -d "$(lock_of "$1")" ]; then echo kept; else echo gone; fi; }
seed() {  # <clone> <printf-format> <args...>
  local c="$1"; shift; rm -rf "$(lock_of "$c")"; mkdir "$(lock_of "$c")" && printf "$@" > "$(lock_of "$c")/owner"
}

# a stand-in for git that, at the first fetch or ls-remote (a call the guard makes AFTER it took the lock), lets somebody else take the lock over
SHIM="$SANDBOX/shim"; mkdir -p "$SHIM"
cat > "$SHIM/git" <<'EOF'
#!/bin/bash
case "${1:-}" in
  fetch|ls-remote)
    if [ -n "${FOREIGN_LOCK:-}" ] && [ ! -e "$FOREIGN_LOCK.done" ] && [ -d "$FOREIGN_LOCK" ]; then
      : > "$FOREIGN_LOCK.done"; printf 'node=%s\npid=1\ntoken=foreign\n' "$HN" > "$FOREIGN_LOCK/owner"
    fi ;;
esac
exec "$REAL_GIT_BIN" "$@"
EOF
chmod +x "$SHIM/git"

# stand-ins for ln and mv that refuse to put a file into place as an owner record (any argument ending in /owner) and are the real command otherwise
FAILBIN="$SANDBOX/failbin"; mkdir -p "$FAILBIN"
for c in ln mv; do
  printf '#!/bin/bash\nfor a in "$@"; do case "$a" in */owner) exit 1 ;; esac; done\nexec %s "$@"\n' "$(command -v "$c")" > "$FAILBIN/$c"; chmod +x "$FAILBIN/$c"
done

# the scripts directory without the library, and with a library that was cut short in delivery
cp -R "$SDIR" "$SANDBOX/scripts-nolib"; rm -f "$SANDBOX/scripts-nolib/lib/dirty-guard-lock.sh"
cp -R "$SDIR" "$SANDBOX/scripts-cut"; if [ -f "$SDIR/lib/dirty-guard-lock.sh" ]; then sed '$d' "$SDIR/lib/dirty-guard-lock.sh" > "$SANDBOX/scripts-cut/lib/dirty-guard-lock.sh"; fi

for G in canon-refresh canon-reconcile sync-strategy-files git-dirty-guard; do
  profile "$G"
  echo "=== $G"
  echo "scenario $G-1: a clean run takes the lock and gives it back"
  new_clone "$G-1"; C="$SANDBOX/$G-1-clone"
  run_guard "$G" "$C"
  assert_old "$G_RC/$(state_of "$C")" "0/gone" "$G: exit 0 and no lock left behind after a clean run"

  echo "scenario $G-2: a live owner keeps the lock: the guard says so on the same channel and with the same status as before"
  new_clone "$G-2"; C="$SANDBOX/$G-2-clone"
  seed "$C" 'node=%s\npid=%s\nepoch=%s\ntoken=t\nscript=other\n' "$HN" "$$" "$(( $(date -u +%s) - 600 ))"
  run_guard "$G" "$C"
  assert_old "$G_RC/$(state_of "$C")" "$BUSY_RC/kept" "$G: exit status $BUSY_RC and the lock of the live owner is untouched"
  assert_old "$(busy_text | grep -c -F "$BUSY_PREFIX")/$(other_text | grep -c 'lock busy')" "1/0" "$G: the busy message (first words as before) is on the channel it always was on, and not on the other"
  assert_new "$(busy_text | grep -c -F -- "$BUSY_PREFIX -- owner pid $$ is alive, the lock was taken 10 min ago")" "1" "$G: the message now says who holds the lock and for how long"
  rm -rf "$(lock_of "$C")"

  echo "scenario $G-3: a dead owner: the lock is taken over and the guard goes on"
  new_clone "$G-3"; C="$SANDBOX/$G-3-clone"
  seed "$C" "$OWNKEY=%s\npid=%s\n" "$HN" "$DEAD_PID"
  run_guard "$G" "$C"
  assert_old "$G_RC/$(state_of "$C")" "0/gone" "$G: the stale lock of a dead owner does not stop the run, and it is released at the end"
  assert_new "$(printf '%s\n' "$G_ERR" | grep -c -F -x "$TAKE_PREFIX reclaiming the lock: owner pid $DEAD_PID is gone")/$(printf '%s\n' "$G_OUT" | grep -c 'reclaiming')" "1/0" "$G: one line, with the prefix of this guard, says on STDERR that the lock of a dead owner is taken over (nothing of it on stdout, which some callers read)"

  echo "scenario $G-4: a process that cannot be signalled (pid 1) exists: the lock stays (the old code took the refused signal for death)"
  new_clone "$G-4"; C="$SANDBOX/$G-4-clone"
  seed "$C" 'node=%s\npid=1\nepoch=%s\n' "$HN" "$(date -u +%s)"
  run_guard "$G" "$C"
  assert_new "$G_RC/$(state_of "$C")/$(busy_text | grep -c -F "$BUSY_PREFIX")" "$BUSY_RC/kept/1" "$G: pid 1 owns the lock: the guard stands aside, loudly, and the lock is not removed"
  rm -rf "$(lock_of "$C")"

  echo "scenario $G-5: an owner record that is not a record (pid=12x): not proof of death, the lock stays"
  new_clone "$G-5"; C="$SANDBOX/$G-5-clone"
  seed "$C" 'node=%s\npid=12x\n' "$HN"
  run_guard "$G" "$C"
  assert_new "$G_RC/$(state_of "$C")/$(busy_text | grep -c -F -- "-- the owner file is damaged (pid '12x')")" "$BUSY_RC/kept/1" "$G: a damaged owner record keeps the lock and the message says so (the old code took pid=12x for a dead process)"
  rm -rf "$(lock_of "$C")"

  echo "scenario $G-6: no owner file at all: the lock stays, and the message says why"
  new_clone "$G-6"; C="$SANDBOX/$G-6-clone"
  mkdir "$(lock_of "$C")"
  run_guard "$G" "$C"
  assert_old "$G_RC/$(state_of "$C")/$(busy_text | grep -c -F "$BUSY_PREFIX")" "$BUSY_RC/kept/1" "$G: a lock without an owner file stays held, as before"
  assert_new "$(busy_text | grep -c -F -- "-- the owner file is missing")" "1" "$G: the message says that the owner file is missing (before: silence)"
  rm -rf "$(lock_of "$C")"

  echo "scenario $G-7: the lock is taken over by somebody else while the guard is running: the exit of the guard removes only a lock that is its own"
  new_clone "$G-7"; C="$SANDBOX/$G-7-clone"
  rm -f "$(lock_of "$C").done"
  FOREIGN_LOCK="$(lock_of "$C")" HN="$HN" REAL_GIT_BIN="$REAL_GIT" PATH="$SHIM:$PATH" run_guard "$G" "$C"
  assert_old "$([ -e "$(lock_of "$C").done" ] && echo injected || echo not-injected)" "injected" "$G: precondition: the other owner appeared after the guard took the lock (the guard made a fetch or an ls-remote call)"
  if [ "$G" = git-dirty-guard ]; then ASSERT_G7=assert_old; else ASSERT_G7=assert_new; fi   # git-dirty-guard already left a foreign lock alone before the library; the other three removed it
  $ASSERT_G7 "$(state_of "$C")/$(awk -F= '$1=="token"{print $2}' "$(lock_of "$C")/owner" 2>/dev/null)" "kept/foreign" "$G: the lock of the other owner is still there when the guard has ended"
  rm -rf "$(lock_of "$C")" "$(lock_of "$C").done"

  echo "scenario $G-8: the library is missing, or was cut short in delivery: the guard says so and does NOTHING"
  new_clone "$G-8"; C="$SANDBOX/$G-8-clone"
  run_guard "$G" "$C" "$SANDBOX/scripts-nolib"
  assert_new "$G_RC/$(state_of "$C")/$(printf '%s%s' "$G_OUT" "$G_ERR" | grep -c -F "the lock library is missing or unusable")" "$LIBMISS_RC/gone/1" "$G: no library: exit $LIBMISS_RC (git-dirty-guard: 2, an installation error; the others: 1), said on stderr, no lock made"
  new_clone "$G-10"; C="$SANDBOX/$G-10-clone"
  echo "scenario $G-10: started through a RELATIVE path with a CDPATH that holds a decoy directory of the same name: the guard finds its own library and does its work"
  mkdir -p "$SANDBOX/rel" "$SANDBOX/decoy/scripts"; [ -e "$SANDBOX/rel/scripts" ] || cp -R "$SDIR" "$SANDBOX/rel/scripts"
  G_OUT=$(cd "$SANDBOX/rel" && CDPATH="$SANDBOX/decoy" HOME="$SANDBOX/home" GIT_DIRTY_GUARD_TG_ALERTS=false bash "scripts/$G.sh" "$C" ${ARGS[@]+"${ARGS[@]}"} 2>"$SANDBOX/err"); G_RC=$?; G_ERR=$(cat "$SANDBOX/err")
  assert_old "$G_RC/$(state_of "$C")/$(printf '%s%s' "$G_OUT" "$G_ERR" | grep -c -F "the lock library is missing or unusable")" "0/gone/0" "$G: with CDPATH set, a relative start works and finds nothing missing (it holds for the old guards too: they look for no library)"
  assert_new "$(printf '%s\n%s\n' "$G_OUT" "$G_ERR" | grep -c -E '^/')/$(printf '%s\n%s\n' "$G_OUT" "$G_ERR" | grep -c -E 'rror|rrno|annot|o such')" "0/0" "$G: ... and it says nothing of a directory that a CDPATH made cd print, and no error of any kind (it works as in a plain start)"
  new_clone "$G-9"; C="$SANDBOX/$G-9-clone"
  DGLOCK_LIB_READY=1 run_guard "$G" "$C" "$SANDBOX/scripts-cut"   # even with a ready marker left in the environment
  assert_new "$G_RC/$(state_of "$C")/$(printf '%s%s' "$G_OUT" "$G_ERR" | grep -c -F "the lock library is missing or unusable")" "$LIBMISS_RC/gone/1" "$G: a library without its last line is not taken for the library: the same loud failure"

  echo "scenario $G-11: the owner record cannot be written (no hard link, no rename into place): exit 1, the reason said, and no lock directory is left behind"
  new_clone "$G-11"; C="$SANDBOX/$G-11-clone"
  PATH="$FAILBIN:$PATH" run_guard "$G" "$C"
  assert_new "$G_RC/$(state_of "$C")/$(printf '%s\n' "$G_ERR" | grep -c -F "$TAKE_PREFIX cannot record the owner of the lock")" "1/gone/1" "$G: exit 1, no lock directory left, and the reason is said on stderr with the prefix of the guard"

  echo "scenario $G-12: a lock whose record is in the OLD format (host=, written by a guard from before the library) and whose owner is dead is NOT taken over (an old guard may be taking it over at this moment): the guard stands aside, loudly, with its usual busy status, and the lock is untouched"
  new_clone "$G-12"; C="$SANDBOX/$G-12-clone"
  seed "$C" 'host=%s\npid=%s\n' "$HN" "$DEAD_PID"
  run_guard "$G" "$C"
  assert_new "$G_RC/$(state_of "$C")/$(busy_text | grep -c -F -- "-- owner pid $DEAD_PID is gone, but its record is in the old format")" "$BUSY_RC/kept/1" "$G: an old-format lock of a dead owner is left to the old code or a human, said on the usual channel"
  rm -rf "$(lock_of "$C")"
done

echo "=== git-dirty-guard in the mode that prints the remote object id (iwe-safe-pull.sh reads its stdout)"
profile git-dirty-guard
new_clone oid-1; C="$SANDBOX/oid-1-clone"
seed "$C" "$OWNKEY=%s\npid=%s\n" "$HN" "$DEAD_PID"
GIT_DIRTY_GUARD_REMOTE_OID_OUTPUT=true run_guard git-dirty-guard "$C"
assert_old "$G_RC/$(printf '%s' "$G_OUT" | grep -c -E '^[0-9a-f]{40}$')/$(printf '%s\n' "$G_OUT" | wc -l | tr -d ' ')" "0/1/1" "git-dirty-guard: over the lock of a dead owner its stdout is exactly one object id (it was so before the library, and must stay so)"
assert_new "$(printf '%s\n' "$G_ERR" | grep -c -F -x "git-dirty-guard: reclaiming the lock: owner pid $DEAD_PID is gone")" "1" "git-dirty-guard: and the takeover line is on stderr"

echo "=== canon-reconcile-published (its own suite has the lock scenarios; here only the same loud failure)"
new_clone pub-1; C="$SANDBOX/pub-1-clone"
o=$(HOME="$SANDBOX/home" bash "$SANDBOX/scripts-nolib/canon-reconcile-published.sh" "$C" main 2>&1); rc=$?
assert_new "$rc/$(state_of "$C")/$(printf '%s' "$o" | grep -c -F "the lock library is missing or unusable")" "1/gone/1" "canon-reconcile-published: no library: exit 1, said, no lock made"

echo "=== summary: [old] failures $fails_old, [new] failures $fails_new"
if [ "$fails_old" -eq 0 ] && [ "$fails_new" -eq 0 ]; then echo "PASS: all scenarios"; else echo "FAIL: $((fails_old + fails_new)) assertion(s)"; exit 1; fi
