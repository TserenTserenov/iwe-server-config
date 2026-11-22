#!/usr/bin/env bash
# canon-reconcile-published.sh <repo-path> <branch> [<pinned-oid>] -- replace a
# canonical checkout's branch ref with the just-published origin tip when, and
# only when, the local history it would drop is provably already on origin.
#
# The gap this closes (WP-530 Phase 38, peer-session 2026-09-11-07, Claude+Kimi+Codex):
# sessions commit straight into the canonical checkout, isolate-push.sh carries
# those commits to origin as cherry-picks (new SHAs), and nothing afterwards
# moves the canonical ref -- so the canon is never an ancestor of origin again.
# canon-refresh.sh (clean + purely behind) and canon-reconcile.sh (dirty +
# purely behind) both refuse a diverged history by design; without this step the
# divergence grows until a human merges by hand (74/230 on 11.09).
#
# Contract (fail closed -- any doubt means "touch nothing, say why"):
#   preflight  no live session is writing into this host's checkouts (semaphores
#              under $IWE_RUNTIME_DIR/sessions without isolated_worktree and with a
#              live pid -- Codex, round 3: a re-check right before reset shrinks
#              the race with a concurrent writer but cannot close it, and this
#              script takes no snapshot of tracked dirt; until a barrier every
#              writer honours exists (Phase 5.1) the only safe answer is skip + retry
#              on the next publish; re-checked right before the swap) · branch
#              as expected · index clean · tracked-tree dirt only where the
#              on-disk entry already equals the target's (mode+blob) or the
#              path is deleted here and absent there (WP-561 Phase 24: point-
#              installed published bytes must not freeze the canon forever) ·
#              a live ledger journal (machine/ledger/**/*.yaml) is tolerated when,
#              under the journal lock ledger-append.sh uses (wait <= 30 s), every
#              event on disk is already on the target (whole-event comparison by
#              ledger-event-diff.py), else refused naming the events (ts, kind) ·
#              any other dirty regular file whose entry upstream left alone
#              (same blob entry in the old head and in the target; never a
#              symlink) is CARRIED: its local state (bytes, permissions, or its
#              local deletion) is saved as git objects held by a ref under
#              refs/canon-reconcile-carry/ plus a manifest in the runtime dir
#              before the swap and put back after the reset, as `git merge
#              --ff-only` would leave it (WP-484 I-34: one such edit froze the
#              canon for 1.5 days on 20.11); a complete manifest left by a failed
#              restore makes every later run refuse until `--restore-carry`
#              has put the paths back (an interrupted, partial one is removed) ·
#              every local-only commit patch-equivalent to the target (`git
#              cherry` has no `+`) OR content-superseded (every path it touched
#              has the same tree entry in HEAD and target; no local merge
#              commits either way) · every
#              path `git reset --hard` would CREATE (added in target vs current
#              HEAD) is either absent on disk or identical in type, mode and
#              content -- checked on disk, so ignored files, case-folded names
#              and file-vs-directory clashes count too (cold review 11.09).
#   action     `git update-ref` with compare-and-swap on the old head, then
#              `git reset --hard` so index and tracked tree follow the ref.
#   postcheck  HEAD == pinned · index clean and the tracked tree clean apart from
#              the carried paths, each back in its saved state · the set of untracked paths
#              (mode, hash, path) is unchanged apart from paths the target now
#              tracks -- a changed hash, a missing path or a NEW path means
#              someone wrote during the window: reported, never called success.
# This script never writes inside the repository except through git itself:
# its own log goes to $IWE_RUNTIME_DIR/canon-reconcile-published.log (a ledger
# event inside the canon would dirty the very tree it is reconciling -- cold
# review 11.09 found the resulting 15-minute publish loop).
#
# Loudness (WP-530 Phase 76): a refusal is silent by design, so a canon that cannot be reconciled used to look exactly like a
# healthy one. Every refusal prints how many times in a row this same class (the text before the first ':') has
# refused, over how many minutes, and how many tracked paths are dirty; when the class has lasted
# CANON_RECONCILE_ALERT_AFTER_SEC (default 3600) and at least CANON_RECONCILE_ALERT_MIN_COUNT times (default 3), one
# `ALERT` line is printed for the caller to forward, repeated no more often than CANON_RECONCILE_ALERT_REPEAT_SEC
# (default 14400). Any healthy exit clears the streak. The streak state lives next to the log, outside the repository.
# State handling (Codex review, peer-session 2026-10-01-20): the streak is an append-only JOURNAL (one O_APPEND write per
# refusal and per alert claim), so there is no read-change-write cycle to race, no lock to take or reclaim and no file to
# replace: parallel runs cannot lose a count, and the first alert claim of a window in file order is the only one that
# prints the ALERT. Every number is derived inside awk and reaches the shell as 1-12 digits (a damaged record is skipped, a
# damaged journal is a fresh streak, never an arithmetic error); an alert is printed only after its claim is on disk and
# only if the series is still valid when the claim is read back (within 120 s of writing it: a run that stalled longer
# prints nothing, since a later run may already have used the next window), and a journal that cannot be appended to (or a runtime
# directory that is not private to this user, or a path that is a symlink, a directory, a FIFO or somebody else's file)
# gives a warning and no alert at all -- an alert that cannot be rate-limited would repeat on every run. The journal is
# never cut, rotated or capped (any of those is a read-change-write again, or freezes a new series behind an old one): it
# grows by about 100 bytes per refusal until the first healthy exit removes it (through the same trusted chain as every
# other change of it; otherwise it stays and a warning says why).
# The contract of the repeat interval (accepted wording, peer-session 2026-10-01-20): with a continuous series and clocks that
# do not run backwards, the interval holds between the TIMES OF THE CONFIRMED ALERT CLAIMS. It is not promised between the
# ALERT lines or the deliveries: a run suspended for a long time between its last check and the print prints late (a duplicate
# line, never a lost one), and no shell script can close that without a serialized section. A claim that is never followed by a
# print can silence the alert until the end of the interval.
# Trust assumptions, stated once: processes of the same user are trusted; the runtime directory, the journal and every
# directory above them are not writable by anybody else (no write for group or others unless the sticky bit protects the
# entry), and are owned by this user or by root. If that cannot be shown, the streak is switched off LOUDLY. Times from the future are clamped (refusals) or ignored (claims stamped more than ten minutes
# ahead), so a clock set back mutes nothing for longer than the repeat interval.
#
# Exit: 0 = replaced, or nothing to do (already ancestor -> canon-refresh's job), or the cycle was SKIPPED because the repository
#           lock is held (named on stderr, logged, counted in its own journal; the ALERT of that series is the signal)
#       1 = refused (canon untouched) or post-check failed (ref already replaced
#           -- the message says which; both are logged)
#       2 = usage / repo error
set -uo pipefail

# The delivery proof (git cherry) must not trust local replacement refs or legacy
# grafts: a forged object can make an undelivered commit look published (WP-7 Phase 161).
export GIT_NO_REPLACE_OBJECTS=1
export GIT_GRAFT_FILE=/dev/null/iwe-no-grafts
# Every pathspec here is a literal path name, never a glob or ":(magic)" (WP-530 F72 review).
export GIT_LITERAL_PATHSPECS=1

usage() { echo "usage: canon-reconcile-published.sh <repo-path> <branch> [<pinned-oid>]" >&2; echo "       canon-reconcile-published.sh --restore-carry <repo-path> <carry-manifest>   (puts back what a failed run saved)" >&2; exit 2; }
[ $# -ge 2 ] || usage
MODE=reconcile; CARRY_RESTORE_MANIFEST=""
if [ "$1" = "--restore-carry" ]; then
  [ $# -eq 3 ] || usage
  MODE=restore; REPO="$2"; BRANCH="--restore-carry"; PINNED_ARG=""
  case "$3" in /*) CARRY_RESTORE_MANIFEST="$3" ;; *) CARRY_RESTORE_MANIFEST="$PWD/$3" ;; esac   # resolved before the cd below
else
  REPO="$1"; BRANCH="$2"; PINNED_ARG="${3:-}"
fi
SCRIPT_DIR="${BASH_SOURCE[0]}"; case "$SCRIPT_DIR" in */*) SCRIPT_DIR="${SCRIPT_DIR%/*}" ;; *) SCRIPT_DIR=. ;; esac; case "$SCRIPT_DIR" in /*) ;; *) SCRIPT_DIR="./$SCRIPT_DIR" ;; esac; SCRIPT_DIR=$(cd "$SCRIPT_DIR" >/dev/null 2>&1 && pwd && printf x); SCRIPT_DIR="${SCRIPT_DIR%x}"; SCRIPT_DIR="${SCRIPT_DIR%$'\n'}"; SELF="${SCRIPT_DIR%/}/${BASH_SOURCE[0]##*/}"   # computed before the cd below, without dirname (a minimal PATH has none) and without CDPATH; the marker x keeps a newline at the end of a directory name: the lock library is found next to this script
cd "$REPO" 2>/dev/null || { echo "canon-reconcile-published: cannot cd to $REPO" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "canon-reconcile-published: $REPO is not a git repo" >&2; exit 2; }
GIT_DIR=$(git rev-parse --git-dir && printf x); GIT_DIR="${GIT_DIR%x}"; GIT_DIR="${GIT_DIR%$'\n'}"   # the marker x keeps a newline at the end of the name (the lock is made where the guard says)
# Runtime directory (log, session semaphores). IWE_RUNTIME is the HOST NAME by contract
# (DP.IWE.011 §C: claude-code|headless|hermes|bot), never a path -- the old
# "${IWE_RUNTIME:-...}" fallback turned it into a directory RELATIVE to the checkout
# being reconciled (after the cd above): the log landed in <repo>/claude-code/ and the
# live-writer preflight looked for semaphores in <repo>/claude-code/sessions/, saw none
# and went on (reproduced on a throwaway repo 01.10: reset --hard ran past a live writer).
# Resolution order:
#   1. IWE_RUNTIME_DIR
#   2. a legacy ABSOLUTE IWE_RUNTIME naming an existing directory (launchd plists and old
#      tests export the path this way) -- accepted with a notice
#   3. ${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime
# The result must be an absolute path without '..' components. Inside this repository it must
# be ignored by git and hold no tracked files; nothing is created or removed to find out.
resolve_runtime_dir() {
  if [ -n "${IWE_RUNTIME_DIR:-}" ]; then
    printf '%s' "$IWE_RUNTIME_DIR"
  elif [ -n "${IWE_RUNTIME:-}" ] && [ "${IWE_RUNTIME#/}" != "$IWE_RUNTIME" ] && [ -d "$IWE_RUNTIME" ]; then
    echo "canon-reconcile-published: IWE_RUNTIME used as a directory (legacy caller); set IWE_RUNTIME_DIR instead" >&2
    printf '%s' "$IWE_RUNTIME"
  else
    printf '%s' "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime"
  fi
}
LOG_NAME="canon-reconcile-published.log"
runtime_dir_fatal() { echo "canon-reconcile-published: $1" >&2; exit 2; }
RUNTIME_DIR=$(resolve_runtime_dir)
while [ "${#RUNTIME_DIR}" -gt 1 ] && [ "${RUNTIME_DIR%/}" != "$RUNTIME_DIR" ]; do RUNTIME_DIR="${RUNTIME_DIR%/}"; done   # a trailing '/' would hide a symlink from the checks below
case "$RUNTIME_DIR" in
  /*) ;;
  *) runtime_dir_fatal "runtime dir must be absolute, got '$RUNTIME_DIR' (IWE_RUNTIME is a host name, not a path)" ;;
esac
case "$RUNTIME_DIR" in
  */../*|*/..) runtime_dir_fatal "runtime dir must not contain '..' components (the part that does not exist yet is not normalized), got '$RUNTIME_DIR'" ;;
esac
REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null)   # physical path (symlinks resolved)
STREAK_KEY=$(printf '%s\n%s\n' "$REPO_TOP" "$BRANCH" | cksum | cut -d' ' -f1)   # one streak per repository and branch: two canons must not share counts
STREAK_NAME="canon-reconcile-published.$STREAK_KEY.streak"
BUSY_NAME="canon-reconcile-published.$STREAK_KEY.lockbusy"   # the series of skips because the repository lock is held (its own journal, same law as the refusal journal)
physical_path() {  # <path> -> its longest existing prefix resolved through symlinks (macOS /var -> /private/var) plus the not-yet-existing rest; fails when the prefix cannot be entered or a symlink cannot be followed
  local p="$1" rest="" base
  while [ ! -d "$p" ] && [ "$p" != "/" ]; do
    [ -L "$p" ] && return 1   # a dangling symlink (or one that points at a file) cannot tell where the log would land: refuse, do not guess
    rest="/$(basename "$p")$rest"; p=$(dirname "$p")
  done
  base=$(cd "$p" 2>/dev/null && pwd -P) || return 1
  printf '%s%s' "$base" "$rest"
}
RUNTIME_PHYS=$(physical_path "$RUNTIME_DIR") || runtime_dir_fatal "cannot resolve runtime dir '$RUNTIME_DIR'"
case "$RUNTIME_PHYS/" in
  "$REPO_TOP"/*)
    RUNTIME_REL="${RUNTIME_PHYS#"$REPO_TOP"}"; RUNTIME_REL="${RUNTIME_REL#/}"   # repo-relative: literal pathspecs plus a symlinked /var make the absolute form unreliable
    [ -n "$RUNTIME_REL" ] || runtime_dir_fatal "runtime dir is the repository root itself -- refusing"
    # Ask about the very file this script writes there, so that no directory has to exist and an ignore
    # rule for some other name (or a negated log rule) cannot vouch for it: git treats the leading components
    # as directories and applies "dir/" patterns to them (a bare path of a missing directory is not matched).
    for state_name in "$LOG_NAME" "$STREAK_NAME" "$BUSY_NAME"; do
      GIT_LITERAL_PATHSPECS=0 git check-ignore -q -- "$RUNTIME_REL/$state_name" 2>/dev/null; ign=$?   # check-ignore rejects the 'literal' magic exported above
      [ "$ign" -eq 0 ] || runtime_dir_fatal "runtime dir $RUNTIME_DIR lies inside the repository and its file $state_name is not ignored (git check-ignore exit $ign) -- refusing (it would dirty the tree)"
    done
    [ -z "$(git ls-files -- "$RUNTIME_REL" 2>/dev/null)" ] || runtime_dir_fatal "runtime dir $RUNTIME_DIR lies inside the repository and holds tracked files -- refusing"
    ;;
esac
# Everything this script WRITES goes to the physical path resolved above (RUNTIME_PHYS), the one whose chain of directories is
# checked below: a link in the logical path could be pointed elsewhere between the check and the write (Codex round 5).
LOG_FILE="$RUNTIME_PHYS/$LOG_NAME"
STREAK_FILE="$RUNTIME_PHYS/$STREAK_NAME"   # append-only journal, one O_APPEND write per record: R<TAB>epoch<TAB>class<TAB>id (a refusal), A<TAB>epoch<TAB>class<TAB>id (an alert claim)
fresh_now() { local n; n=$(date -u +%s); epoch_field "$n" || return 1; printf '%s' "$((10#$n))"; }   # the clock, as 1-12 plain digits taken as decimal; fails when it cannot be read
epoch_field() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }   # 1-12 digits: no sign, point, exponent or overflow reaches shell arithmetic
num_or_default() {  # <value> <default>: a non-numeric or oversized override falls back to the default (base 10: "08" is not an octal error; more than 12 digits would wrap around)
  if epoch_field "$1"; then printf '%s' "$((10#$1))"; else printf '%s' "$2"; fi
}
ALERT_AFTER_SEC=$(num_or_default "${CANON_RECONCILE_ALERT_AFTER_SEC:-}" 3600)
ALERT_REPEAT_SEC=$(num_or_default "${CANON_RECONCILE_ALERT_REPEAT_SEC:-}" 14400)
ALERT_MIN_COUNT=$(num_or_default "${CANON_RECONCILE_ALERT_MIN_COUNT:-}" 3)
TMP_FILES=()
CARRY_DISCARD=""; CARRY_REF_DISCARD=""   # the carry manifest and its ref while they may still be dropped (a refusal before the swap); emptied at the swap, so a failure after it keeps both
cleanup() {
  rm -f "${TMP_FILES[@]+"${TMP_FILES[@]}"}"
  [ -z "$CARRY_DISCARD" ] || rm -f "$CARRY_DISCARD"
  [ -z "$CARRY_REF_DISCARD" ] || git update-ref -d "$CARRY_REF_DISCARD" 2>/dev/null || :
}
trap cleanup EXIT

# Live append-only ledger journals (machine/ledger/**/*.yaml), step 2 below. The journal lock is the one
# DS-my-strategy/scripts/ledger-append.sh takes before every write: `<file>.lock` through flock when flock
# exists, else the `<file>.lockdir` mkdir lock with an owner record. Taking it here keeps writers out between the
# comparison and the reset; it is NEVER taken while a publisher is run (the publisher does not take it, and this
# script does not start one: a journal event that is not on the target yet is a refusal, the publisher drains it).
LEDGER_LOCK_WAIT_S="${CANON_LEDGER_LOCK_WAIT_S:-30}"
printf '%s' "$LEDGER_LOCK_WAIT_S" | grep -Eq '^([1-9]|[12][0-9]|30)$' || { echo "canon-reconcile-published: CANON_LEDGER_LOCK_WAIT_S must be a whole number of seconds from 1 to 30, got '$LEDGER_LOCK_WAIT_S'" >&2; exit 2; }
LEDGER_HELD=(); LEDGER_FDS=(); LEDGER_LOCKDIRS=()
ledger_lock_take() {  # <journal path> -- 0 = lock held (kept until ledger_locks_release / exit), 1 = not taken within the wait
  local f="$1" h fd lockdir left="$LEDGER_LOCK_WAIT_S"
  for h in "${LEDGER_HELD[@]+"${LEDGER_HELD[@]}"}"; do [ "$h" = "$f" ] && return 0; done
  if command -v flock >/dev/null 2>&1; then
    fd=$((201 + ${#LEDGER_FDS[@]}))
    eval "exec $fd<>\"\${f}.lock\"" || return 1   # fd number is computed here, bash 3.2 has no {var} redirection
    if ! flock -x -w "$LEDGER_LOCK_WAIT_S" "$fd"; then eval "exec $fd>&-"; return 1; fi
    LEDGER_FDS+=("$fd")
  else
    lockdir="${f}.lockdir"
    while ! mkdir "$lockdir" 2>/dev/null; do
      left=$((left - 1)); [ "$left" -gt 0 ] || return 1
      sleep 1
    done
    LEDGER_LOCKDIRS+=("$lockdir")
    printf 'host=%s\npid=%s\n' "${HOSTNAME:-$(uname -n)}" "$$" > "$lockdir/owner"
  fi
  LEDGER_HELD+=("$f")
}
ledger_locks_release() {
  local fd d
  for fd in "${LEDGER_FDS[@]+"${LEDGER_FDS[@]}"}"; do eval "exec $fd>&-"; done
  for d in "${LEDGER_LOCKDIRS[@]+"${LEDGER_LOCKDIRS[@]}"}"; do rm -rf "$d"; done
  LEDGER_HELD=(); LEDGER_FDS=(); LEDGER_LOCKDIRS=()
}

log_line() {  # <status> <text> -- append-only log outside the repository; written only when the directory chain and the log file are trusted (the message is on stderr anyway)
  if [ -z "${LOG_TRUST:-}" ]; then if runtime_chain_ok && plain_file_ok "$LOG_FILE"; then LOG_TRUST=yes; else LOG_TRUST=no; fi; fi
  [ "$LOG_TRUST" = yes ] || return 0
  ( umask 077; printf '%s %s repo=%s branch=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(oneline "$REPO")" "$(oneline "$BRANCH")" "$(oneline "$2")" >> "$LOG_FILE" ) 2>/dev/null || true   # a new log is private like the journal: it names repositories and dirty paths
}
oneline() { printf '%s' "$1" | tr '\t\r\n' '   '; }   # a journal field, a log line and an alert line must stay one line: a path name with a newline must not forge a line

# The refusal streak is a JOURNAL, not a record that is read, changed and written back: appending one short line is
# atomic (O_APPEND), so parallel runs cannot lose a count, and nothing is ever replaced, locked or reclaimed. Every
# number in it is derived inside awk, which never aborts the shell; the shell only sees digits that awk printed.
# An alert is a CLAIM record appended before anything is printed; of the claims of one window the first one in FILE order
# wins, so exactly one of several parallel runs prints the ALERT, and a run whose claim could not be written prints none.
acl_entries() {  # <path> -- the ACL entries of <path>, one per line (macOS only: `ls -e`; there the "+" of the mode string is HIDDEN by "@" when the path also has extended attributes, so the mode string cannot be relied on). FAILS when the listing itself fails: an error is not "no ACL".
  local out
  [ "$(uname -s 2>/dev/null)" = Darwin ] || return 0
  out=$(ls -lde -- "$1" 2>/dev/null) || return 1
  printf '%s\n' "$out" | grep -E '^ *[0-9]+: ' || true
}
acl_none() { local acl; acl=$(acl_entries "$1") || return 1; [ -z "$acl" ]; }   # <path> -- no ACL entry at all (an unreadable ACL counts as an entry)
acl_deny_only() {  # <path> -- 0 when <path> has no ACL entries or only deny entries (macOS: the default "group:everyone deny delete" of home directories); an ACL on another platform, or one that cannot be read, is not trusted
  local acl
  acl=$(acl_entries "$1") || return 1
  [ -z "$acl" ] || ! printf '%s\n' "$acl" | grep -qv ' deny '
}
mode_ok() {  # <path> <strict:1|0> -- owned by this user or root and not writable by group or others. strict (the runtime directory and the journal): also no ACL entry at all and no sticky exception. Not strict (the directories above): a deny-only ACL is fine, and so is a sticky directory such as /tmp, where others cannot touch our entries.
  local perm owner
  perm=$(ls -ldL -- "$1" 2>/dev/null | cut -c1-11); owner=$(ls -ldnL -- "$1" 2>/dev/null | awk '{print $3}')
  [ "${#perm}" -ge 10 ] || return 1
  case "$owner" in "$(id -u)"|0) ;; *) return 1 ;; esac
  if [ "$2" = 1 ]; then
    [ "${perm:5:1}" = "-" ] && [ "${perm:8:1}" = "-" ] && [ "${perm:10:1}" != "+" ] && acl_none "$1" || return 1
  else
    [ "${perm:10:1}" != "+" ] || [ "$(uname -s 2>/dev/null)" = Darwin ] || return 1
    acl_deny_only "$1" || return 1
    case "${perm:9:1}" in t|T) return 0 ;; esac
    [ "${perm:5:1}" = "-" ] && [ "${perm:8:1}" = "-" ] || return 1
  fi
  return 0
}
make_tail() {  # <existing-dir> <target-dir>: makes the missing components below <existing-dir> ONE AT A TIME with a plain mkdir, which never follows an entry that appeared in the meantime (a link, a directory of somebody else): it fails, and the component must then be a real directory of this user
  local cur="${1%/}" rest="${2#"${1%/}"}" comp
  rest="${rest#/}"
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"; rest="${rest#"$comp"}"; rest="${rest#/}"
    cur="$cur/$comp"
    ( umask 077; mkdir "$cur" ) 2>/dev/null
    if [ -L "$cur" ] || [ ! -d "$cur" ] || [ ! -O "$cur" ]; then
      STREAK_WHY="runtime directory component $cur is not a real directory of this user (a link or somebody else's entry appeared while it was being made)"; return 1
    fi
  done
  return 0
}
dirs_above_ok() {  # <dir> -- 0 when <dir> and every directory above it are owned by this user or root and cannot be written by group or others (sticky directories and deny-only ACLs excepted); the reason in STREAK_WHY
  local up="$1"
  while [ "$up" != "/" ] && [ "$up" != "." ]; do
    [ ! -L "$up" ] || { STREAK_WHY="directory $up above the runtime directory is a link (the runtime path was resolved to a physical one, so a link appeared in it afterwards)"; return 1; }
    mode_ok "$up" 0 || { STREAK_WHY="directory $up above the runtime directory can be changed by somebody else (write for group or others, or another owner)"; return 1; }
    up=$(dirname "$up")
  done
  return 0
}
runtime_chain_ok() {  # 0 = the runtime directory and every directory above it are private (see the trust assumptions); the reason in STREAK_WHY
  local near="$RUNTIME_PHYS"
  # Nothing is created before the way to the runtime directory is judged: new directories below one that others can
  # write to are a change outside the law as well.
  while [ "$near" != "/" ] && [ "$near" != "." ]; do
    [ ! -L "$near" ] || { STREAK_WHY="$near is a link (the runtime path was resolved to a physical one, so a link appeared in it afterwards)"; return 1; }
    [ -d "$near" ] && break
    near=$(dirname "$near")
  done
  if [ "$near" != "$RUNTIME_PHYS" ]; then
    dirs_above_ok "$near" || return 1
    make_tail "$near" "$RUNTIME_PHYS" || return 1
  fi
  # The check of the path and the write that follows are two steps; what closes the gap is that nobody else can touch
  # the directory, the file or the way to them. A group is no proof of privacy (the primary group on a shared
  # multi-user host is often the common "users" group), a permission string or an ACL listing that cannot be read is no trust either.
  if [ ! -d "$RUNTIME_PHYS" ] || [ ! -O "$RUNTIME_PHYS" ] || ! mode_ok "$RUNTIME_PHYS" 1; then
    STREAK_WHY="runtime directory $RUNTIME_PHYS is not a private directory of this user (owner only: no write for group or others, no ACL)"; return 1
  fi
  dirs_above_ok "$(dirname "$RUNTIME_PHYS")"
}
plain_file_ok() {  # <path> -- 0 when it does not exist, or is a regular file (no symlink, no FIFO) of this user that nobody else can write
  { [ ! -e "$1" ] && [ ! -L "$1" ]; } && return 0
  [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && mode_ok "$1" 1
}
streak_usable() {  # 0 = the journal can be appended to and read; 1 = it cannot (reason in STREAK_WHY)
  STREAK_WHY=""
  runtime_chain_ok || return 1
  plain_file_ok "$STREAK_FILE" || { STREAK_WHY="$STREAK_FILE is not a plain file of this user without write for group or others, left untouched"; return 1; }
  return 0
}
append_streak() {  # <R|A> <epoch> <class> <id>: 0 only when the record is in the file
  ( umask 077; printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$STREAK_FILE" ) 2>/dev/null
}
streak_state() {  # <class> <now> [<stop-id>] -> "<found> <first> <count> <last-alert>" of the run of <class> that ends the journal (or ends just before the claim <stop-id>; found=1 when that claim was seen)
  LC_ALL=C CLS="$1" NOW="$2" STOP="${3:-}" awk -F'\t' '
    function epoch(s) { return (s ~ /^[0-9]+$/ && length(s) <= 12 && s + 0 >= 1000000000) }   # 1-12 digits and not before September 2001: a smaller number is damage, not a time
    BEGIN { cls = ENVIRON["CLS"]; now = ENVIRON["NOW"] + 0; stop = ENVIRON["STOP"]; cc = ""; first = 0; count = 0; la = 0; found = 0 }
    ($1 == "R" || $1 == "A") && epoch($2) && $3 != "" {
      e = $2 + 0
      if ($1 == "A") {
        if (stop != "" && ($4 "") == (stop "")) { found = 1; exit }   # string comparison: "123.45" and "123.450" are different ids
        if (e > now + 600) next              # a claim stamped far ahead (the clock was set back since) must not mute the alerts
        if (($3 "") != cc) next              # a claim of another class than the current run (a rejected one, say) changes nothing: only a REFUSAL starts a run
        if (e > now) e = now
        if (e > la) la = e   # the latest, not the last in file order: a claim of a delayed run carries an earlier time and must not shorten the interval
        next
      }
      if (e > now) e = now                   # a time from the future is no evidence of age
      if (($3 "") != cc) { cc = $3 ""; first = e; count = 0; la = 0 }   # a refusal of another class starts a new run (string comparison: a class that looks like a number is still a class)
      count++
    }
    END { if (cc == (cls "")) printf "%d %.0f %d %.0f\n", found, first, count, la; else printf "%d 0 0 0\n", found }   # %.0f: an epoch past 2^31 must not be clipped by the %d of an old awk
  ' "$STREAK_FILE" 2>/dev/null
}
end_series() {  # <journal> <what it is> <when>: a series has ended, its journal goes. Removed only when the chain of directories and the file are trusted, like every other change of it; when it stays (untrusted, or the removal itself failed) that is SAID, because a series that is never ended goes on counting.
  local why
  why=$( STREAK_FILE="$1"; if streak_usable; then rm -f "$1" 2>/dev/null || echo "the removal failed"; else echo "$STREAK_WHY"; fi )
  [ -z "$why" ] || echo "canon-reconcile-published: warning: $2 $1 is left in place $3 -- $why" >&2
  return 0
}
healthy() {  # a healthy exit ends the refusal streak; a refusal appended at the same instant belongs to the streak that just ended
  if [ -e "$STREAK_FILE" ] || [ -L "$STREAK_FILE" ]; then end_series "$STREAK_FILE" "the refusal journal" "on this healthy exit"; fi
  return 0
}

# A refusal must stop the script, and bash gives no guarantee for it: a FAILED ARITHMETIC EXPANSION discards the whole
# top-level command that is running -- the function that failed, its callers and their exit 1 included -- and the script
# goes on to the next line. Round 1 of Phase 76 had exactly that: a state field "12.3" broke `$((10#$first))` inside
# refuse(), the refusal was dropped and the run went on to reset the canon over a local-only commit. The hazard is
# structural (anything in a report that aborts has this effect; origin/main's refuse() has nothing abort-prone, so no
# trigger is known there). So: (1) the whole report runs in a SUBSHELL, where an abort ends only the subshell, and the
# exit 1 sits in the parent; (2) no shell arithmetic in the report on a value that was not just checked to be digits
# and taken as decimal ("only digits" is not enough: "0999" is an octal error); (3) defense in depth: a flag set before
# the report, checked at the point of no return (the ref swap), and the one refusal AFTER that check is followed by its
# own unconditional exit (see step 5).
REFUSAL_STARTED=""
refuse_report() {  # <reason> -- the whole report of one refusal: message, streak, alert; runs in a subshell (see refuse())
  local reason class now age=0 count=1 last=0 dirty note="" warn="" due=0 id first s_first s_count s_last c_found c_first c_count c_last c_now claim_at a_count=1 a_age=0
  reason=$(oneline "$1")
  class="${reason%%:*}"; class="${class:0:120}"
  now=$(date -u +%s); if epoch_field "$now"; then now=$((10#$now)); else now=""; fi
  dirty=$(GIT_OPTIONAL_LOCKS=0 git status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')
  if [ -z "$now" ]; then
    note="streak state skipped: the clock could not be read"   # a time of 0 in the journal would later read as an age of decades
  elif ! streak_usable; then
    note="streak state unusable: $STREAK_WHY"
  elif ! append_streak R "$now" "$class" "$$.$RANDOM"; then
    note="streak state could not be saved"
    warn="canon-reconcile-published: warning: cannot append to the refusal streak $STREAK_FILE -- a repeated alert could not be rate-limited, so none is raised"
  else
    read -r _ s_first s_count s_last <<< "$(streak_state "$class" "$now")"
    if epoch_field "${s_first:-}" && epoch_field "${s_count:-}" && epoch_field "${s_last:-}" && [ "$s_count" -ge 1 ]; then
      first=$((10#$s_first)); count=$((10#$s_count)); last=$((10#$s_last)); age=$((now - first))
      if [ "$count" -ge "$ALERT_MIN_COUNT" ] && [ "$age" -ge "$ALERT_AFTER_SEC" ] && [ $((now - last)) -ge "$ALERT_REPEAT_SEC" ]; then
        id="$$.$RANDOM"
        id="$id.$now"   # pid, random number and the second this run started: a reused pid with the same random number must not stop the read-back at an older claim
        c_now=$(fresh_now) || c_now=""   # the clock is read AGAIN: after a long stall the time taken at the start is stale, and a claim another run wrote meanwhile would look like one from the far future
        if [ -z "$c_now" ]; then
          warn="canon-reconcile-published: warning: the clock cannot be read for the alert claim -- no alert is raised"
        elif append_streak A "$c_now" "$class" "$id"; then
          claim_at=$c_now
          c_now=$(fresh_now) || c_now=""   # and once more for the read-back
          if [ -z "$c_now" ] || [ $((c_now - claim_at)) -gt 120 ]; then
            # A run that stalled between writing its claim and reading it back (more than 120 s) must not print: the window of
            # that claim may long be over and another run may have printed the alert of the next one. With a repeat interval
            # longer than this patience (the default is 4 hours) two alerts of one window can then not happen.
            warn="canon-reconcile-published: warning: the alert claim was read back more than 120 s after it was written, or the clock cannot be read (the run stalled) -- no alert is raised"
          else
            read -r c_found c_first c_count c_last <<< "$(streak_state "$class" "$c_now" "$id")"
            # The claim is the state that is on disk BEFORE the ALERT is printed; the first claim of the window wins. The
            # series is judged again at the claim: another class that began in between ends it (the state then reads 0 0 0),
            # and a series that is no longer past its thresholds raises nothing.
            if [ "${c_found:-0}" = 1 ] && epoch_field "${c_first:-}" && epoch_field "${c_count:-}" && epoch_field "${c_last:-}"; then
              a_count=$((10#$c_count)); a_age=$((c_now - 10#$c_first))   # the numbers of the ALERT; the refusal line keeps those of the first reading (they differ only after a run of another class came in)
              if [ "$a_count" -ge "$ALERT_MIN_COUNT" ] && [ "$a_age" -ge "$ALERT_AFTER_SEC" ] && [ $((claim_at - 10#$c_last)) -ge "$ALERT_REPEAT_SEC" ]; then due=1; fi   # the claim's own time, not the time of the re-read: a run that stalled before its clock reading must not look old enough
            fi
          fi
        else
          warn="canon-reconcile-published: warning: cannot append the alert claim to $STREAK_FILE -- no alert is raised"
        fi
      fi
    elif [ "${s_first:-}" = 0 ] && [ "${s_count:-}" = 0 ]; then   # the journal ends with a run of ANOTHER class: a parallel run recorded its refusal after ours; nothing is wrong with the journal
      note="a refusal of another class was recorded in between, counted from one"
    else   # the record was appended but nothing could be derived from the journal (unreadable, or no awk): say so, never count silently from one
      note="streak state could not be read"
      warn="canon-reconcile-published: warning: cannot read the refusal streak $STREAK_FILE -- no alert can be raised"
    fi
  fi
  if [ -z "$note" ]; then
    echo "canon-reconcile-published: ${REPORT_WORD:-refused} -- $reason (canon untouched, publish not rolled back; this reason $count time(s) over $((age / 60)) min; dirty tracked paths now: $dirty)" >&2
  else
    echo "canon-reconcile-published: ${REPORT_WORD:-refused} -- $reason (canon untouched, publish not rolled back; $note; dirty tracked paths now: $dirty)" >&2
  fi
  [ -z "$warn" ] || echo "$warn" >&2
  log_line "${REPORT_WORD:-refused}" "$reason"
  if [ "$due" -eq 1 ]; then
    # The class is cut at the first colon so the streak key stays stable; what
    # follows it (for "live canonical writer(s)" -- the semaphore names) is
    # what the pilot needs to act, so it rides along as an optional tail
    # (WP-568, peer-session 2026-10-24-07). Readers must accept its absence.
    local detail="" detail_tail=""
    if [ "$reason" != "$class" ]; then
      detail="${reason#*:}"; detail="${detail%% -- *}"; detail="${detail# }"
      [ "${#detail}" -le 1000 ] || { detail="${detail:0:1000}"; detail="${detail% *}"; }   # never a half name
      [ -z "$detail" ] || detail_tail=" -- detail: $detail"
    fi
    echo "canon-reconcile-published: ALERT canon $(oneline "$REPO") not reconciled for $((a_age / 60)) min: $a_count refusals '$class', $dirty dirty tracked path(s) -- an owner must clear the blocking state; next alert in $((ALERT_REPEAT_SEC / 60)) min$detail_tail" >&2
    log_line alert "class=$class count=$a_count age_s=$a_age dirty=$dirty"
  fi
  return 0
}
refuse() {  # <reason> -- nothing was changed; ALWAYS ends the script, with status 1, whatever happens in the report
  REFUSAL_STARTED=1
  ( refuse_report "$1" ) || echo "canon-reconcile-published: refused -- $(oneline "$1") (canon untouched, publish not rolled back; the report of this refusal failed)" >&2
  exit 1
}

fail_after_swap() {  # <reason> -- the ref is already replaced; say so honestly
  echo "canon-reconcile-published: post-check FAILED after the ref was replaced -- $1. HEAD=$(git rev-parse HEAD); inspect the tree before trusting it" >&2
  log_line post-check-failed "$1"
  exit 1
}

# --- carried dirty paths (WP-484 I-34): the part the recovery path needs, defined before any work starts ---------------------
# A carry is saved by carry_save (step 4 below): the raw bytes as git objects, a records blob (NUL-separated: kind, permissions,
# blob, highest directory that was gone too, path) and a parentless commit holding both under refs/canon-reconcile-carry/<key>/<stamp>,
# so gc cannot drop them; and a manifest in the runtime directory naming that ref, written under a temporary name (*.tmp) and
# renamed into place only when it is complete (its last line is CARRY_END_MARK). The rename happens BEFORE the swap, so a *.tmp
# left over always belongs to a run that died before its swap: its edit never left the working tree, and the leftover is removed.
# A complete manifest left over means a restore may be owed: every later run refuses (carry_leftover_check) until
# `canon-reconcile-published.sh --restore-carry <repo> <manifest>` has put the paths back, verified them, and only then removed
# the ref and the manifest (the ref first: a ref whose removal failed is still named by the manifest that stays).
CARRY_END_MARK="# end of carry manifest"
CARRY_PATHS=(); CARRY_SEEN=(); CARRY_KIND=(); CARRY_RAW=(); CARRY_PERM=(); CARRY_GONE=(); CARRY_SIG=""; CARRY_MANIFEST=""; CARRY_REF=""; CARRY_ERR=""
file_perm() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp -- "$1" 2>/dev/null; }   # GNU first: BSD stat rejects -c, while GNU stat -f would print file-system data
carry_warn() { echo "canon-reconcile-published: warning: $1" >&2; log_line warning "$1"; }
carry_check_one() {  # <index> -- 0 when the carried path is exactly in its saved state: still deleted, or a regular file with the saved bytes and permissions
  local p="${CARRY_PATHS[$1]}"
  if [ "${CARRY_KIND[$1]}" = deleted ]; then [ ! -e "$p" ] && [ ! -L "$p" ]; return; fi
  [ -f "$p" ] && [ ! -L "$p" ] && [ "$(file_perm "$p")" = "${CARRY_PERM[$1]}" ] && [ "$(git hash-object --no-filters -- "$p")" = "${CARRY_RAW[$1]}" ]
}
carry_unchanged() {  # 0 when every carried path is in its saved state; CARRY_ERR names those that are not
  local i
  CARRY_ERR=""
  for i in "${!CARRY_PATHS[@]}"; do carry_check_one "$i" || CARRY_ERR="$CARRY_ERR ${CARRY_PATHS[$i]}"; done
  [ -z "$CARRY_ERR" ]
}
carry_restore() {  # puts every carried path back; 0 = all back exactly, 1 = CARRY_ERR names those that are not
  local i p d t
  CARRY_ERR=""
  for i in "${!CARRY_PATHS[@]}"; do
    p="${CARRY_PATHS[$i]}"
    case "${CARRY_KIND[$i]}" in
      deleted)
        rm -f -- "$p" 2>/dev/null
        if [ -n "${CARRY_GONE[$i]}" ]; then   # only the directories that were gone before, and only while they are empty
          d=$(dirname "$p")
          while rmdir -- "$d" 2>/dev/null && [ "$d" != "${CARRY_GONE[$i]}" ]; do d=$(dirname "$d"); done
        fi ;;
      file)   # written beside the path and renamed over it: a failure leaves the path as it was (what the reset wrote), never half-written
        t="$(dirname "$p")/.canon-reconcile-carry.$$.$RANDOM"
        if ! { ( umask 077; set -C; git cat-file blob "${CARRY_RAW[$i]}" > "$t" ) 2>/dev/null && chmod "${CARRY_PERM[$i]}" "$t" 2>/dev/null && mv -f -- "$t" "$p" 2>/dev/null; }; then
          rm -f -- "$t" 2>/dev/null
        fi ;;
    esac
    carry_check_one "$i" || CARRY_ERR="$CARRY_ERR $p"
  done
  [ -z "$CARRY_ERR" ]
}
carry_drop() {  # <ref> <manifest> -- removes the ref FIRST, then the manifest; 1 with a warning when either stays
  if ! git update-ref -d "$1" 2>/dev/null; then carry_warn "the ref $1 cannot be removed; the manifest $2 stays and names it"; return 1; fi
  if ! rm -f -- "$2" 2>/dev/null || [ -e "$2" ]; then carry_warn "the ref $1 is removed, but the manifest $2 cannot be: remove it by hand"; return 1; fi
}
carry_load() {  # <manifest> -- fills the CARRY_* arrays and CARRY_REF from a COMPLETE manifest and the records its ref holds; 1 with CARRY_ERR when it cannot
  local m="$1" kind perm raw gone p
  CARRY_PATHS=(); CARRY_KIND=(); CARRY_PERM=(); CARRY_RAW=(); CARRY_GONE=(); CARRY_ERR=""; CARRY_REF=""
  [ "$(tail -n 1 "$m" 2>/dev/null)" = "$CARRY_END_MARK" ] || { CARRY_ERR="the manifest is incomplete (no end marker)"; return 1; }
  CARRY_REF=$(sed -n 's/^# ref: //p' "$m" 2>/dev/null | head -1)
  case "$CARRY_REF" in refs/canon-reconcile-carry/*) ;; *) CARRY_ERR="the manifest names no carry ref"; return 1 ;; esac
  git rev-parse -q --verify "$CARRY_REF^{commit}" >/dev/null 2>&1 || { CARRY_ERR="its ref $CARRY_REF is gone"; return 1; }
  while IFS= read -r -d '' kind && IFS= read -r -d '' perm && IFS= read -r -d '' raw && IFS= read -r -d '' gone && IFS= read -r -d '' p; do
    case "$p" in ""|/*|..|../*|*/..|*/../*) CARRY_ERR="a record of $CARRY_REF names an unsafe path"; return 1 ;; esac
    case "$kind" in
      deleted) ;;
      file)
        if ! { printf '%s' "$perm" | grep -Eq '^[0-7]{3,4}$' && printf '%s' "$raw" | grep -Eq '^[0-9a-f]{40,64}$'; }; then
          CARRY_ERR="a record of $CARRY_REF is damaged ($p)"; return 1
        fi ;;
      *) CARRY_ERR="a record of $CARRY_REF has an unknown kind"; return 1 ;;
    esac
    CARRY_PATHS+=("$p"); CARRY_KIND+=("$kind"); CARRY_PERM+=("$perm"); CARRY_RAW+=("$raw"); CARRY_GONE+=("$gone")
  done < <(git cat-file blob "$CARRY_REF:records" 2>/dev/null)
  [ "${#CARRY_PATHS[@]}" -gt 0 ] || { CARRY_ERR="its ref $CARRY_REF holds no readable records"; return 1; }
}
carry_restore_mode() {  # --restore-carry: puts the paths of one manifest back and verifies them; only then removes the ref and the manifest. Never returns.
  local m="$CARRY_RESTORE_MANIFEST" i blocked=""
  carry_load "$m" || { echo "canon-reconcile-published: --restore-carry: $m cannot be used: $CARRY_ERR -- nothing was changed" >&2; exit 1; }
  [ "$(sed -n 's/^# repo: //p' "$m" | head -1)" = "$(oneline "$REPO_TOP")" ] \
    || { echo "canon-reconcile-published: --restore-carry: $m belongs to another repository than $REPO_TOP -- nothing was changed" >&2; exit 1; }
  for i in "${!CARRY_PATHS[@]}"; do
    carry_check_one "$i" && continue   # already in its saved state
    # anything but the state the reset left (clean against HEAD) is a later edit, which a restore must not overwrite
    [ -z "$(git status --porcelain --untracked-files=no -- "${CARRY_PATHS[$i]}" 2>/dev/null)" ] || blocked="$blocked ${CARRY_PATHS[$i]}"
  done
  [ -z "$blocked" ] || { echo "canon-reconcile-published: --restore-carry: path(s) changed since the failed run, not overwritten:$blocked -- nothing was changed; the ref $CARRY_REF and the manifest stay" >&2; exit 1; }
  carry_restore || { echo "canon-reconcile-published: --restore-carry: not put back:$CARRY_ERR -- the ref $CARRY_REF and the manifest $m stay" >&2; log_line carry-restore-failed "$m:$CARRY_ERR"; exit 1; }
  carry_drop "$CARRY_REF" "$m" || exit 1
  echo "canon-reconcile-published: --restore-carry: ${#CARRY_PATHS[@]} path(s) put back and verified; ref $CARRY_REF and manifest removed"
  log_line carry-restored "$m"
  exit 0
}
carry_leftover_check() {  # before any work: a carry manifest left over by an earlier run of THIS canon and branch
  local m stamp ref
  for m in "$RUNTIME_PHYS/canon-reconcile-published.$STREAK_KEY.carry."*; do
    [ -e "$m" ] || [ -L "$m" ] || continue
    stamp="${m##*.carry.}"; stamp="${stamp%.tmp}"; ref="refs/canon-reconcile-carry/$STREAK_KEY/$stamp"
    case "$m" in
      *.tmp)   # written by a run that died before the rename, so before its swap: its edit never left the working tree
        git update-ref -d "$ref" 2>/dev/null || :
        rm -f -- "$m"
        carry_warn "removed an interrupted carry manifest $m and its ref $ref, if any: the run that wrote it died before its swap"
        continue ;;
    esac
    if carry_load "$m"; then
      if carry_unchanged; then   # every path is in its saved state already (the run died after the rename but before its swap, or the paths were put back by hand)
        carry_drop "$CARRY_REF" "$m" || refuse "carry manifest $m cannot be cleaned up although nothing is owed (see the warning above)"
        carry_warn "removed carry manifest $m and its ref: every path it names is already in its saved state"
        continue
      fi
      refuse "carried dirty paths of an earlier run were not put back: manifest $m, saved objects under $CARRY_REF -- put them back with: $(printf '%q --restore-carry %q %q' "$SELF" "$REPO_TOP" "$m")"
    fi
    if git rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
      refuse "carry manifest $m cannot be used ($CARRY_ERR) while the ref $ref still holds saved objects -- inspect by hand: git ls-tree $ref; git cat-file blob $ref:records"
    fi
    rm -f -- "$m"
    carry_warn "removed carry manifest $m: $CARRY_ERR, and no ref holds objects for it -- nothing could be restored from it"
  done
}

if [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ] || [ -f "$GIT_DIR/MERGE_HEAD" ] || [ -f "$GIT_DIR/CHERRY_PICK_HEAD" ]; then
  refuse "repo is mid-rebase/merge/cherry-pick"
fi
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
# A MAIN working copy left without a branch is re-attached below, after every other check (found 16.11, WP-539: one
# `git checkout origin/main` stopped this guard and the reader mover for a day). A linked worktree (git dir != common
# dir) is detached by design and keeps the old refusal.
DETACHED=0
if [ "$MODE" = restore ]; then
  :   # the restore subcommand touches only the paths its manifest names, on whatever branch is checked out
elif [ "$CURRENT_BRANCH" = "HEAD" ] && [ "$(git rev-parse --git-common-dir 2>/dev/null)" = "$GIT_DIR" ]; then
  DETACHED=1
else
  [ "$CURRENT_BRANCH" = "$BRANCH" ] || refuse "checked-out branch is not the expected one: '$CURRENT_BRANCH' instead of '$BRANCH'"
fi

# The repository lock is the one the other guard scripts take ($GIT_DIR/dirty-guard.lock) and it lives in ONE place, scripts/lib/
# dirty-guard-lock.sh (WP-530 Phase 81 and its remainder, peer session 2026-10-02-01 with Kimi and Codex): the takeover rule (only when
# the owner is PROVEN gone), the owner record, the release (only a lock with our token), the scope and the limits are described in
# the header of that file. What stays HERE is what happens when the lock is busy: the skip is printed, logged as "skipped" and
# recorded in its own journal (canon-reconcile-published.KEY.lockbusy: the series of skips because the lock is held, same law as the
# refusal journal); one lock instance that stays held becomes an ALERT of its own (three records of the same class AND an hour
# between the first and now, not a sliding window). The class of a skip names the lock INSTANCE (DGLOCK_ID: the owner pid or the
# state of the lock, and the inode number of the lock directory), so the skips of one instance form a series and a record about
# another instance does not join or age it (an inode number can be reused by a later lock directory: a limit of the library); a skip is written only while that instance is still the lock (a run that stalled in
# between writes nothing, and says so in the log). Taking the lock ends the series.
DGLOCK_LIB="$SCRIPT_DIR/lib/dirty-guard-lock.sh"
unset DGLOCK_LIB_READY   # a marker inherited from the environment must not vouch for a library that was cut short
# shellcheck source=lib/dirty-guard-lock.sh
if [ -r "$DGLOCK_LIB" ] && . "$DGLOCK_LIB" && [ "${DGLOCK_LIB_READY:-}" = 1 ]; then :; else
  echo "canon-reconcile-published: the lock library is missing or unusable: $DGLOCK_LIB (scripts/ and scripts/lib/ are updated together); nothing was done" >&2
  exit 1
fi
busy_report() {  # the lock is held: say so, and let a lock that stays held become an ALERT of its own series (the refusal journal is not touched: a skip is neither a refusal nor a healthy run). The class of a refusal is the text before the first colon of its reason, so the lock INSTANCE is named THERE; the skip is written only while that instance is still the lock
  echo "canon-reconcile-published: lock busy, skipping this cycle -- $1" >&2
  if [ -n "$DGLOCK_INSTANCE" ] && [ "$(dglock_instance)" != "$DGLOCK_INSTANCE" ]; then
    echo "canon-reconcile-published: the lock changed while this skip was being reported (or this file system does not keep directory numbers stable): not recorded" >&2
    log_line skipped "dirty-guard lock cannot be taken [$DGLOCK_ID]: $1 (the lock changed meanwhile, or the directory number is not stable on this file system: not counted)"
    return 0
  fi
  ( STREAK_FILE="$RUNTIME_PHYS/$BUSY_NAME"; REPORT_WORD=skipped; refuse_report "dirty-guard lock cannot be taken [$DGLOCK_ID]: $1" ) || true
}
trap 'cleanup || :; ledger_locks_release; dglock_release' EXIT  # set BEFORE the lock is asked for: a signal that arrives between the library's mkdir and its owner record must still remove the empty directory
rc=0; dglock_acquire "$GIT_DIR" canon-reconcile-published || rc=$?
case "$rc" in
  0) ;;
  1) [ "$MODE" != restore ] || { echo "canon-reconcile-published: --restore-carry: the repository lock is held ($DGLOCK_REASON) -- nothing was changed, retry" >&2; exit 1; }
     busy_report "$DGLOCK_REASON"; exit 0 ;;
  *) refuse "$DGLOCK_REASON" ;;   # 2: the lock directory was made but its owner record could not be written; 3: misuse of the library (the reason says which)
esac
if [ -e "$RUNTIME_PHYS/$BUSY_NAME" ] || [ -L "$RUNTIME_PHYS/$BUSY_NAME" ]; then   # the lock is ours: a series of skips because it was held has ended (looked for first: a run without such a series asks the runtime directory nothing)
  end_series "$RUNTIME_PHYS/$BUSY_NAME" "the lock journal" "although the lock was taken"
fi

# 0. a carry left over by an earlier run (see carry_leftover_check); the restore subcommand ends here.
[ "$MODE" != restore ] || carry_restore_mode
carry_leftover_check

# 1. no live canonical writer (strict, Codex round 3). Isolated sessions never
#    touch this tree; only semaphores without isolated_worktree count.
#
# pid-less semaphores (WP-538/568, peer-session 2026-10-17-01, Claude+Kimi+Codex):
# Kimi/Codex adapters never write a `pid:` field, so "no pid = no proof of death"
# used to mean "treat as live forever" -- a completed, published Kimi/Codex session
# that simply never called `session-guard.sh close` blocked reconcile indefinitely
# (live case found 17.10: codex-*.open from WP-484, work on origin/main 9h earlier,
# session never closed). session-guard.sh already has the right signal for this --
# the commit-lease that `close`/`renew` manage (LEASE_SEC, default 4h) -- so a
# pid-less semaphore is only still counted as live while that lease has not expired.
# Sourcing session-guard.sh itself is not an option: it ends in an unconditional
# command dispatch on $CMD, so sourcing it would also execute whatever command this
# script's own argv happens to contain. The handful of lines that compute lease
# expiry are duplicated here instead (semaphore_epoch/lease_deadline_epoch in
# session-guard.sh is the source of truth; keep both in sync by hand).
#
# Fail-safe default: a semaphore with neither opened_at: nor created_at: cannot be
# timed at all -- treated as live, same as before this fix (no regression for the
# pre-WP-484 semaphore shape the existing smoke test scenario 8 already covers).
pidless_semaphore_lease_expired() {  # <semaphore> -- 0 (expired, safe to not count as live) / 1 (valid or undecidable -> still live)
  local sem="$1" ts base_epoch renewed_at renewed_epoch="" lease_sec="${IWE_SESSION_LEASE_SEC:-14400}"
  ts=$(grep -E '^(opened_at|created_at): ' "$sem" | head -1 | cut -d' ' -f2-)
  [ -n "$ts" ] || return 1
  base_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || date -u -d "$ts" +%s 2>/dev/null) || return 1
  if [ -f "${sem}.lease" ]; then
    renewed_at=$(grep '^renewed_at: ' "${sem}.lease" | tail -1 | cut -d' ' -f2-)
    if [ -n "$renewed_at" ]; then
      renewed_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$renewed_at" +%s 2>/dev/null || date -u -d "$renewed_at" +%s 2>/dev/null)
    fi
  fi
  [ -n "$renewed_epoch" ] && [ "$renewed_epoch" -gt "$base_epoch" ] && base_epoch="$renewed_epoch"
  [ "$(date +%s)" -ge $(( base_epoch + lease_sec )) ]
}
# WP-484 Phase 250 (measure 2): a hand-made copy opened without --isolate records
# `governance_worktree:` but no `isolated_worktree:`, so the check below used to
# count it as a canonical writer and fence reconcile for as long as it lived.
# Its writes land in its own checkout when that checkout is a worktree
# registered in THIS repository (same criterion as _root_route_registered in
# process-runner.py: exact, unique entry in `git worktree list`) and is not the
# canon itself. Stricter than the unconditional trust in `isolated_worktree:`.
registered_noncanon_worktree() {  # <semaphore> -- 0 when its governance_worktree is a registered worktree other than the canon
  local gw gw_real
  gw=$(awk '$1=="governance_worktree:"{sub(/^governance_worktree:[ ]*/, ""); print; exit}' "$1")
  [ -n "$gw" ] && [ -d "$gw" ] || return 1
  gw_real=$(cd "$gw" 2>/dev/null && pwd -P) || return 1
  [ "$gw_real" != "$REPO_TOP" ] || return 1
  [ "$(git worktree list --porcelain 2>/dev/null | grep -cFx "worktree $gw_real")" = "1" ]
}
live_canonical_writers() {  # prints " name name ..." or nothing
  local sem sem_pid sem_host out=""
  local self_pid="${OWNER_PID:-${CLAUDE_PID:-}}" self_host="$(uname -n)"
  for sem in "$RUNTIME_DIR"/sessions/*.open; do
    [ -f "$sem" ] || continue
    grep -q '^isolated_worktree:' "$sem" && continue
    registered_noncanon_worktree "$sem" && continue
    sem_pid=$(awk '$1=="pid:"{print $2; exit}' "$sem")
    sem_host=$(awk '$1=="host:"{print $2; exit}' "$sem")
    # Same pid as ours (OWNER_PID/CLAUDE_PID, the env var session-guard wrote
    # it from) is our own still-open semaphore, not a foreign writer -- it
    # hasn't closed yet only because this reconcile call is part of its own
    # publish/close sequence (WP-7, found 2026-10-13). A pid is only unique
    # within one host's process namespace (same guard as session-guard.sh's
    # _quarantine_dead_interactive, WP-530 Phase 53): require the recorded host,
    # when present, to match ours too, or a restored/foreign semaphore whose
    # pid numerically collides with ours would be skipped as if it were us.
    if [ -n "$self_pid" ] && [ "$sem_pid" = "$self_pid" ] \
        && { [ -z "$sem_host" ] || [ "$sem_host" = "$self_host" ]; }; then
      continue
    fi
    if [ -z "$sem_pid" ]; then
      # pid-less (Kimi/Codex): live only while the commit-lease has not expired.
      pidless_semaphore_lease_expired "$sem" && continue
      out="$out $(basename "$sem" .open)"
    elif kill -0 "$sem_pid" 2>/dev/null; then
      out="$out $(basename "$sem" .open)"
    fi
  done
  printf '%s' "$out"
}
LIVE_WRITERS=$(live_canonical_writers)
[ -z "$LIVE_WRITERS" ] || refuse "live canonical writer(s):$LIVE_WRITERS -- skipped, will retry on the next publish"

# explicit refspec: `git fetch origin <branch>` alone is not guaranteed to move origin/<branch>
git fetch origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" --quiet 2>/dev/null || refuse "git fetch origin $BRANCH failed"
OLD_HEAD=$(git rev-parse HEAD)
REMOTE_TIP=$(git rev-parse "origin/$BRANCH")
if [ -n "$PINNED_ARG" ]; then
  PINNED=$(git rev-parse --verify "${PINNED_ARG}^{commit}" 2>/dev/null) || refuse "pinned oid is not a commit here: $PINNED_ARG"
  git merge-base --is-ancestor "$PINNED" "$REMOTE_TIP" || refuse "pinned oid is not on origin/$BRANCH"
  # origin moved past the caller's pin: re-evaluate against the live tip, never replace with a stale one
  [ "$PINNED" = "$REMOTE_TIP" ] || echo "canon-reconcile-published: origin/$BRANCH advanced past pinned ${PINNED:0:12}, targeting live tip ${REMOTE_TIP:0:12}"
fi
PINNED="$REMOTE_TIP"

if [ "$DETACHED" = 1 ]; then
  # Nothing may be lost: the branch ref must be missing-free and an ancestor of the target, so moving it forward drops no commit.
  OLD_BRANCH=$(git rev-parse --verify -q "refs/heads/$BRANCH") && git merge-base --is-ancestor "$OLD_BRANCH" "$PINNED" \
    || refuse "detached HEAD and refs/heads/$BRANCH is missing or holds commits the target lacks: not re-attaching"
  # git allows the branch to be checked out elsewhere only because this copy is detached; moving the ref under that worktree would leave it with a false staged revert
  ! git worktree list --porcelain 2>/dev/null | grep -qFx "branch refs/heads/$BRANCH" \
    || refuse "detached HEAD and refs/heads/$BRANCH is checked out in another worktree: not re-attaching"
  if [ "$OLD_HEAD" = "$PINNED" ] || git merge-base --is-ancestor "$OLD_HEAD" "$PINNED"; then
    # plain shape: `git switch -C` (not reset --hard) refuses when untracked files are in the way and keeps tracked edits
    [ -z "$(git diff --cached --name-only -z 2>/dev/null)" ] || refuse "detached HEAD: index is not clean, not re-attaching"
    SWITCH_ERR=$(git switch -q -C "$BRANCH" "$PINNED" 2>&1) || refuse "detached HEAD: git switch -C $BRANCH ${PINNED:0:12} refused, nothing changed: $(printf '%s' "$SWITCH_ERR" | head -1)"
    [ "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] && [ "$(git rev-parse HEAD)" = "$PINNED" ] || fail_after_swap "re-attached HEAD is not $BRANCH@${PINNED:0:12}"
    echo "canon-reconcile-published: $REPO re-attached to $BRANCH at ${PINNED:0:12} (was detached at ${OLD_HEAD:0:12})"
    log_line reattached "$OLD_HEAD -> $BRANCH@$PINNED"
    healthy
    exit 0
  fi
  # diverged shape: falls through to the full checks below; the swap re-attaches the branch (step 5)
fi

if [ "$OLD_HEAD" = "$PINNED" ]; then healthy; echo "canon-reconcile-published: already at $PINNED"; exit 0; fi
if git merge-base --is-ancestor "$OLD_HEAD" "$PINNED"; then
  healthy
  echo "canon-reconcile-published: HEAD is a plain ancestor of the target -- canon-refresh.sh owns that shape, nothing to do"
  exit 0
fi

tracked_and_deleted_by_target() {  # <path> -- a blob in OLD_HEAD that the target removes (reset deletes it itself)
  [ -n "$(git ls-tree "$OLD_HEAD" -- "$1" | awk '$1!="040000"')" ] && [ -z "$(git ls-tree "$PINNED" -- "$1" | awk '$1!="040000"')" ]
}
ANCESTRAL_HISTORY_LIMIT=400
# ANCESTRAL_PATH criterion (WP-530 Phase 72, next to "entry equals the target's"): the
# canon's version of <path> (`<mode> <oid>`) already occurred in the target's
# history of the SAME path, and the path is still alive on the target (a blob,
# not deleted, not renamed away, not a directory now). The canon then holds an
# older state of origin -- nothing of it is unique. A path missing on the target,
# a deletion on the canon side and any version origin never had all stay
# refusals. History-based evidence ("nothing is lost"), not a compatibility
# proof; no line-by-line subset mode (rejected in Phase 71). Literal pathspecs: a
# name with glob characters must not match its neighbours.
ancestral_path() {  # <path> <"mode oid"> -- return 0 when the criterion holds
  local p="$1" want="$2" alive sha
  # Only regular files and symlinks count: a tree ("dir"), a gitlink (160000) or an
  # unknown mode is never accepted as an ancestral version.
  case "${want%% *}" in 100644|100755|120000) ;; *) return 1 ;; esac
  # Literal pathspecs on every ls-tree too: ":(top)x" or "a*" must name that path only.
  alive=$(GIT_LITERAL_PATHSPECS=1 git ls-tree "$PINNED" -- "$p" | awk 'NR==1 && $2=="blob" && $1!="160000"{print $1" "$3}')
  [ -n "$alive" ] || return 1
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    [ "$(GIT_LITERAL_PATHSPECS=1 git ls-tree "$sha" -- "$p" | awk 'NR==1 && $2=="blob"{print $1" "$3}')" = "$want" ] && return 0
  done < <(GIT_LITERAL_PATHSPECS=1 git log --full-history --max-count="$ANCESTRAL_HISTORY_LIMIT" --format=%H "$PINNED" -- "$p")
  return 1
}
disk_entry() {  # <path> -> "<mode> <hash>" of what is on disk, or "" if absent
  if [ -L "$1" ]; then printf '120000 %s' "$(printf '%s' "$(readlink "$1")" | git hash-object --stdin)"
  elif [ -d "$1" ]; then printf 'dir'
  elif [ -x "$1" ]; then printf '100755 %s' "$(git hash-object "$1")"
  elif [ -e "$1" ]; then printf '100644 %s' "$(git hash-object "$1")"
  fi
}

# 2. index must be clean. Tracked-tree dirt is tolerated ONLY when what is on
#    disk already equals the target's entry (mode + blob, or "deleted here and
#    absent on the target"): `git reset --hard` would write the very same bytes,
#    so nothing is lost. WP-561 Phase 24 / WP-530 (peer-session 2026-09-27-09,
#    Claude+Kimi+Codex): published fixes were being point-installed into the
#    frozen canon, which then refused every reconcile as "tracked/staged changes
#    present" -- and stayed frozen precisely because it was dirty. Any other
#    dirt still refuses; staged changes always refuse (the index is intent, not
#    bytes on disk). Paths are NUL-delimited end to end (Codex: spaces, quotes,
#    newlines and rename records break line-based porcelain parsing).
STAGED=$(git diff --cached --name-only -z 2>/dev/null | tr '\0' ' ')
[ -z "$STAGED" ] || refuse "staged changes present in index:${STAGED:+ }$STAGED"
dirty_signature() {  # "<path>\t<disk entry>" per dirty tracked path, sorted -- compared again right before the swap
  git diff --name-only -z 2>/dev/null | while IFS= read -r -d '' p; do
    printf '%s\t%s\n' "$p" "$(disk_entry "$p")"
  done | LC_ALL=C sort
}

# LEDGER_JOURNAL criterion (live append-only journals machine/ledger/**/*.yaml; every session appends to them through
# ledger-append.sh and ledger-publish.sh carries them to origin by a union merge of whole events, so the bytes on disk
# equal neither the target nor any point of its history, and the checks above refuse the same file forever). What
# `git reset --hard` would destroy is the events, not the bytes: the path is tolerated when, UNDER THE JOURNAL LOCK,
# every event on disk (compared as a whole record with its multiplicity, by the same ledger-event-diff.py the publisher
# uses) is already in the target; the reset then rewrites the file with the target's version and nothing is lost. An
# event not on the target refuses with its ts and kind, and the file is not touched. The lock stays held until the
# swap is done, so no writer slips an event in between the comparison and the reset.
COMMIT_ANCESTRAL=0; LEDGER_DIFF_TOOL=""; LEDGER_PYTHON=""; LEDGER_REFUSAL=""
ledger_dirty_ok() {  # <path> -- 0 = every event on disk is in the target (journal lock held); 1 = LEDGER_REFUSAL says why
  local p="$1" ref tip snap tgt err out rc n lines line ts
  if ! ledger_lock_take "$p"; then
    LEDGER_REFUSAL="ledger lock busy or publish not responding: could not take the journal lock of $p within ${LEDGER_LOCK_WAIT_S}s -- a writer holds it (nothing was changed)"
    return 1
  fi
  git fetch origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" --quiet 2>/dev/null || { LEDGER_REFUSAL="git fetch origin $BRANCH failed under the journal lock of $p"; return 1; }
  ref="$PINNED"; tip=$(git rev-parse "origin/$BRANCH")
  # events published after the pin are on origin too, and reset never loses what origin has
  if [ "$tip" != "$PINNED" ] && git merge-base --is-ancestor "$PINNED" "$tip"; then ref="$tip"; fi
  if [ -z "$LEDGER_DIFF_TOOL" ]; then
    # the comparison tool imports yaml: the shared resolver picks a python3 that has it (a bare python3 may not)
    LEDGER_PYTHON=$("$SCRIPT_DIR/lib/find-python3.sh" 2>/dev/null) || { LEDGER_REFUSAL="no python3 with PyYAML found by $SCRIPT_DIR/lib/find-python3.sh: $p cannot be compared"; return 1; }
    LEDGER_DIFF_TOOL=$(mktemp); TMP_FILES+=("$LEDGER_DIFF_TOOL")
    git show "$PINNED:scripts/lib/ledger-event-diff.py" > "$LEDGER_DIFF_TOOL" 2>/dev/null || { LEDGER_REFUSAL="ledger comparison tool scripts/lib/ledger-event-diff.py is not in the target: $p cannot be compared"; return 1; }
  fi
  snap=$(mktemp); tgt=$(mktemp); err=$(mktemp); TMP_FILES+=("$snap" "$tgt" "$err")
  if ! cp "$p" "$snap" || ! git show "$ref:$p" > "$tgt" 2>/dev/null; then LEDGER_REFUSAL="cannot read $p from the disk or from the target"; return 1; fi
  rc=0; out=$("$LEDGER_PYTHON" "$LEDGER_DIFF_TOOL" --missing-by-field kind "$snap" "$tgt" 2>"$err") || rc=$?
  if [ "$rc" -ne 0 ]; then LEDGER_REFUSAL="ledger events cannot be compared: $p ($(tr '\n' ' ' < "$err" | cut -c1-200))"; return 1; fi
  [ -n "$out" ] || return 0
  n=$(printf '%s\n' "$out" | wc -l | tr -d ' '); lines=""
  while IFS= read -r line; do   # "<kind>\t<canonical json>"; keys are sorted, so the last "ts" is the event's own
    ts=$(printf '%s' "$line" | sed -n 's/.*"ts": "\([^"]*\)".*/\1/p')
    lines="$lines ${ts:-?} ${line%%$'\t'*};"
  done < <(printf '%s\n' "$out" | head -10)
  LEDGER_REFUSAL="ledger events not yet published: $p has $n event(s) that are not on the target (ts kind):$lines (the file is untouched; the publisher will carry them, retry after that)"
  return 1
}
# CARRIED criterion (WP-484 I-34, 21.11): a dirty path upstream never touched (the same blob entry in OLD_HEAD and in the
# target) is not a conflict -- `git merge --ff-only` would keep the local edit. The swap below is a reset, which would
# destroy it, so its local state is saved before the swap (carry_save) and put back after the reset (carry_restore).
# Checked after the rules above, which already make the reset lose nothing: a path identical to the target, an ancestral
# version, and the live ledger journals (they keep their own lock-based rule; a carried journal could lose an event a
# writer appends between the save and the restore). Only shapes that can be restored exactly are carried: a regular
# file, tracked as one and still one on disk (or its local deletion), under real directories, with its exact-case name on
# disk. Symlinks are never carried (Codex cold review of I-34: a link target read through the shell loses trailing
# newlines, so neither its save nor the check of its restore can be exact); a dirty symlink keeps blocking.
carry_shape_ok() {  # <path> <disk entry> -- 0 when upstream left <path> alone and its local state can be put back exactly
  local p="$1" on_disk="$2" o_entry d
  case "$p" in machine/ledger/*.yaml) return 1 ;; esac
  case "${on_disk%% *}" in ""|100644|100755) ;; *) return 1 ;; esac
  [ ! -L "$p" ] || return 1
  o_entry=$(git ls-tree "$OLD_HEAD" -- "$p" | awk 'NR==1{print $1" "$2" "$3}')
  case "$o_entry" in "100644 blob "*|"100755 blob "*) ;; *) return 1 ;; esac
  [ "$o_entry" = "$(git ls-tree "$PINNED" -- "$p" | awk 'NR==1{print $1" "$2" "$3}')" ] || return 1
  d=$(dirname "$p")
  while [ "$d" != "." ]; do   # every directory above: real, or (for a local deletion) absent -- never a link or a file the reset would replace
    if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then return 1; fi
    d=$(dirname "$d")
  done
  # shellcheck disable=SC2010  # literal, exact-case name match by design (APFS case folding), as in step 4
  [ -z "$on_disk" ] || ls -a "$(dirname "$p")" 2>/dev/null | grep -qFx "$(basename "$p")"
}
classify_dirty() {  # tolerated / ancestral / ledger / carried counts and DIRTY_BLOCKING / LEDGER_REFUSAL, computed afresh
  DIRTY_BLOCKING=""; DIRTY_TOLERATED=0; DIRTY_ANCESTRAL=0; DIRTY_LEDGER=0; LEDGER_REFUSAL=""
  DIRTY_CARRIED=0; CARRY_PATHS=(); CARRY_SEEN=()
  while IFS= read -r -d '' p; do
    [ -n "$p" ] || continue
    t_entry=$(git ls-tree "$PINNED" -- "$p" | awk 'NR==1{print $1" "$3}')
    on_disk=$(disk_entry "$p")
    if [ -z "$on_disk" ] && [ -z "$t_entry" ]; then DIRTY_TOLERATED=$((DIRTY_TOLERATED+1)); continue; fi   # deleted here, absent on target
    if [ -n "$on_disk" ] && [ "$on_disk" != "dir" ] && [ "$on_disk" = "$t_entry" ]; then DIRTY_TOLERATED=$((DIRTY_TOLERATED+1)); continue; fi
    if ancestral_path "$p" "$on_disk"; then DIRTY_ANCESTRAL=$((DIRTY_ANCESTRAL+1)); continue; fi
    case "$p" in
      machine/ledger/*.yaml)
        case "${on_disk%% *}/${t_entry%% *}" in
          100644/100644|100755/100644)   # a regular file here, a regular blob there; the first refusal ends the ledger checks of this pass
            if [ -z "$LEDGER_REFUSAL" ] && ledger_dirty_ok "$p"; then DIRTY_LEDGER=$((DIRTY_LEDGER+1)); fi
            continue ;;
        esac ;;
    esac
    if carry_shape_ok "$p" "$on_disk"; then
      DIRTY_CARRIED=$((DIRTY_CARRIED+1)); CARRY_PATHS+=("$p"); CARRY_SEEN+=("$on_disk"); continue
    fi
    DIRTY_BLOCKING="$DIRTY_BLOCKING $p"
  done < <(git diff --name-only -z 2>/dev/null)
}
classify_dirty
[ -z "$DIRTY_BLOCKING" ] || refuse "tracked changes differ from target:$DIRTY_BLOCKING"
[ -z "$LEDGER_REFUSAL" ] || refuse "$LEDGER_REFUSAL"
DIRTY_SIG_BEFORE=$(dirty_signature)

# 3. every local-only commit must already be on the target as an equivalent patch.
UNIQUE=$(git cherry "$PINNED" "$OLD_HEAD" 2>/dev/null | awk '$1=="+"{print $2}')
CONTENT_SUPERSEDED=0
if [ -n "$UNIQUE" ]; then
  # Content-superseded proof (Codex, peer-session 2026-09-27-09): a local-only
  # commit whose EVERY touched path has the same full tree entry (mode type oid,
  # or absent on both sides) in OLD_HEAD and in the target changes nothing at
  # those paths when OLD_HEAD is replaced -- its end state is already on the
  # target under some other history (a later fix that landed with a different
  # diff, so patch-id cannot see it). Proves safety of the END STATE, not
  # preservation of the commit; the log line says which. Renames are seen as
  # delete+add (--no-renames), a root commit needs --root, paths are NUL-safe.
  DIFFERING=""
  for c in $UNIQUE; do
    while IFS= read -r -d '' p; do
      [ -n "$p" ] || continue
      old_e=$(git ls-tree "$OLD_HEAD" -- "$p" | awk 'NR==1{print $1" "$2" "$3}')
      new_e=$(git ls-tree "$PINNED" -- "$p" | awk 'NR==1{print $1" "$2" "$3}')
      if [ "$old_e" != "$new_e" ]; then
        # ANCESTRAL_PATH: the version this commit left at <p> occurred earlier on origin's <p>, and <p> is alive there
        if ancestral_path "$p" "$(printf '%s' "$old_e" | awk '{print $1" "$3}')"; then COMMIT_ANCESTRAL=$((COMMIT_ANCESTRAL+1)); continue; fi
        DIFFERING="$p (commit ${c:0:12})"; break 2
      fi
    done < <(git diff-tree -r -z --root --no-renames --no-commit-id --name-only "$c" 2>/dev/null)
  done
  [ -z "$DIFFERING" ] || refuse "local-only commits not on target: $(printf '%s ' $UNIQUE)-- first path whose end state differs from the target: $DIFFERING"
  CONTENT_SUPERSEDED=$(printf '%s\n' $UNIQUE | wc -l | tr -d ' ')
fi
# `git cherry` skips merge commits entirely -- an unexpected local merge is not proven delivered.
LOCAL_MERGES=$(git rev-list --merges "$PINNED..$OLD_HEAD")
[ -z "$LOCAL_MERGES" ] || refuse "local merge commit(s) not provable by patch-id: $(printf '%s ' $LOCAL_MERGES)"

# 4. everything `git reset --hard` would CREATE on disk must be absent or identical.
#    Checked on disk (not via git's untracked listing), so ignored files, names
#    that differ only by case on APFS, and file-vs-directory clashes are covered.
COLLISION=""
while IFS= read -r -d '' status && IFS= read -r -d '' p; do
  [ "$status" = "A" ] || continue
  entry=$(git ls-tree "$PINNED" -- "$p" | head -1)
  t_mode=$(printf '%s' "$entry" | awk '{print $1}'); t_hash=$(printf '%s' "$entry" | awk '{print $3}')
  on_disk=$(disk_entry "$p")
  if [ "$on_disk" = "dir" ] && [ -n "$(git ls-tree "$OLD_HEAD" -- "$p/")" ] && [ -z "$(git ls-files --others -- "$p/")" ]; then
    on_disk=""   # tracked directory with nothing untracked inside: dir->file conversion, reset handles it
  fi
  if [ -n "$on_disk" ] && [ "$on_disk" != "$t_mode $t_hash" ]; then COLLISION="$p (on disk: ${on_disk%% *}, target wants $t_mode $t_hash)"; break; fi
  # case-insensitive filesystem: `-e` matched a differently-cased name; git would write into that inode
  # under the target's spelling and the post-check could only report it afterwards -- refuse up front
  # shellcheck disable=SC2010  # literal, exact-case name match by design (APFS case folding)
  if [ -n "$on_disk" ] && ! ls -a "$(dirname "$p")" 2>/dev/null | grep -qFx "$(basename "$p")"; then COLLISION="$p (a differently-cased name occupies this path on disk)"; break; fi
  # an ancestor of the new path exists on disk as a symlink (reset would destroy it and create a real
  # directory) or as a plain file that the target does not itself delete (file->dir conversion of a
  # tracked file is reset's normal job; an untracked/ignored file in the way is a collision)
  d=$(dirname "$p")
  while [ "$d" != "." ]; do
    if [ -L "$d" ]; then COLLISION="$d (on disk a symlink, target needs a directory for $p)"; break 2; fi
    if [ -e "$d" ] && [ ! -d "$d" ] && ! tracked_and_deleted_by_target "$d"; then COLLISION="$d (on disk a file, target needs a directory for $p)"; break 2; fi
    d=$(dirname "$d")
  done
done < <(git diff-tree -r -z --name-status --no-renames "$OLD_HEAD" "$PINNED")
[ -z "$COLLISION" ] || refuse "collision with what reset would write: $COLLISION"

untracked_inventory() {  # "<mode> <hash> <path>" per untracked (non-ignored) file, sorted
  git ls-files --others --exclude-standard -z | while IFS= read -r -d '' p; do
    case "$p" in machine/ledger/*.lockdir/*) continue ;; esac   # the journal's mkdir lock (ours, gone after the swap) is not content
    printf '%s %s\n' "$(disk_entry "$p")" "$p"
  done | LC_ALL=C sort -k3
}
UNTRACKED_BEFORE=$(mktemp); TMP_FILES+=("$UNTRACKED_BEFORE")
untracked_inventory > "$UNTRACKED_BEFORE"

# Re-check right before the irreversible step (still under lock): index still
# clean, the tolerated dirt is byte-for-byte what it was, and no canonical
# writer opened meanwhile (Codex, 2026-09-27-09: the semaphore scan in step 1
# is TOCTOU; this re-check narrows the window, a shared open/reconcile lock
# in session-guard.sh is the follow-up that closes it -- WP-530).
[ -z "$(git diff --cached --name-only -z 2>/dev/null)" ] || refuse "index changed during preflight"
if [ "$(dirty_signature)" != "$DIRTY_SIG_BEFORE" ]; then
  # a journal may have been appended to by a writer that does not take the journal lock: compare its events once more
  # (the locks are still held, so a second change cannot come from a writer that follows the rule); then refuse
  [ "$DIRTY_LEDGER" -gt 0 ] || refuse "tracked tree changed during preflight"
  classify_dirty
  [ -z "$DIRTY_BLOCKING" ] || refuse "tracked tree changed during preflight; now differs from target:$DIRTY_BLOCKING"
  [ -z "$LEDGER_REFUSAL" ] || refuse "$LEDGER_REFUSAL"
  DIRTY_SIG_BEFORE=$(dirty_signature)
  [ "$(dirty_signature)" = "$DIRTY_SIG_BEFORE" ] || refuse "tracked tree changed during preflight"
fi
# Carried paths (see carry_shape_ok and the carry block near the top): their local state is saved BEFORE the swap, so a
# failure after it can never lose the edit. A reset followed by a restore was chosen over a two-tree `read-tree -m -u` (which
# would carry the edits itself): read-tree refuses the dirt the rules above tolerate (identical, ancestral, ledger) and untracked
# files that equal what it would write, so it would change the behaviour this script already proves safe; the reset keeps it,
# and only the carried paths are put back after it.
fsync_best_effort() { command -v python3 >/dev/null 2>&1 && python3 -I -c 'import os,sys; fd=os.open(sys.argv[1], os.O_RDONLY); os.fsync(fd); os.close(fd)' "$1" 2>/dev/null; return 0; }
carry_save() {  # saves the local state of every carried path; refuses (nothing changed yet) when it cannot. Not to be called in a subshell: refuse must end the script
  local i p seen kind raw perm gone d rec="" sig="" entries="" recfile recblob stamp tree commit name tmp
  CARRY_KIND=(); CARRY_RAW=(); CARRY_PERM=(); CARRY_GONE=(); CARRY_SIG=""; CARRY_MANIFEST=""; CARRY_REF=""   # whatever a leftover check loaded is not this run's
  [ "${#CARRY_PATHS[@]}" -gt 0 ] || return 0
  recfile=$(mktemp); TMP_FILES+=("$recfile")
  for i in "${!CARRY_PATHS[@]}"; do
    p="${CARRY_PATHS[$i]}"; seen="${CARRY_SEEN[$i]}"; raw=""; perm=""; gone=""
    [ "$(disk_entry "$p")" = "$seen" ] || refuse "tracked tree changed during preflight: a carried path changed: $p"
    if [ -z "$seen" ]; then
      kind="deleted"
      d=$(dirname "$p")
      while [ "$d" != "." ] && [ ! -e "$d" ] && [ ! -L "$d" ]; do gone="$d"; d=$(dirname "$d"); done   # the highest directory that is gone too: removed again after the reset recreates it
      rec="$rec$(printf 'deleted - - %q' "$p")"$'\n'
    else
      [ -f "$p" ] && [ ! -L "$p" ] || refuse "tracked tree changed during preflight: carried path $p is no longer a regular file"
      kind="file"
      perm=$(file_perm "$p")   # read BEFORE the bytes: a change of either after this point is caught by carry_unchanged right before the swap
      printf '%s' "$perm" | grep -Eq '^[0-7]{3,4}$' || refuse "carried dirty path cannot be saved: the permissions of $p cannot be read"
      raw=$(git hash-object -w --no-filters -- "$p")
      printf '%s' "$raw" | grep -Eq '^[0-9a-f]{40,64}$' || refuse "carried dirty path cannot be saved: git hash-object -w failed for $p"
      entries="$entries$(printf '100644 blob %s\t%s' "$raw" "$i")"$'\n'
      rec="$rec$(printf 'file %s %s %q' "$raw" "$perm" "$p")"$'\n'
    fi
    printf '%s\0%s\0%s\0%s\0%s\0' "$kind" "${perm:--}" "${raw:--}" "$gone" "$p" >> "$recfile" || refuse "carried dirty paths cannot be saved: cannot write the records"
    CARRY_KIND+=("$kind"); CARRY_RAW+=("$raw"); CARRY_PERM+=("$perm"); CARRY_GONE+=("$gone")
    sig="$sig$(printf '%s\t%s' "$p" "$seen")"$'\n'
  done
  CARRY_SIG=$(printf '%s' "$sig" | LC_ALL=C sort)   # the shape of dirty_signature: what the tracked tree must show after the restore
  if [ -n "${RUNTIME_REL:-}" ]; then   # inside the repository the manifest must be ignored like the log, or it would change the untracked set
    GIT_LITERAL_PATHSPECS=0 git check-ignore -q -- "$RUNTIME_REL/canon-reconcile-published.$STREAK_KEY.carry.x" 2>/dev/null \
      || refuse "carried dirty paths cannot be saved: the runtime dir lies inside the repository and a carry manifest there would not be ignored"
  fi
  runtime_chain_ok || refuse "carried dirty paths cannot be saved: $STREAK_WHY"
  stamp="$(date -u +%Y%m%dT%H%M%SZ).$$.$RANDOM"
  CARRY_REF="refs/canon-reconcile-carry/$STREAK_KEY/$stamp"
  name="$RUNTIME_PHYS/canon-reconcile-published.$STREAK_KEY.carry.$stamp"; tmp="$name.tmp"
  # A commit, not a ref to a tree or a blob: `git log --all` and other readers of all refs expect commits.
  if ! { recblob=$(git hash-object -w -- "$recfile" 2>/dev/null) \
    && tree=$( { printf '%s' "$entries"; printf '100644 blob %s\trecords\n' "$recblob"; } | git mktree 2>/dev/null) \
    && commit=$(printf 'canon-reconcile-published: carried dirty paths saved before %s -> %s\n' "$OLD_HEAD" "$PINNED" \
         | GIT_AUTHOR_NAME=canon-reconcile-published GIT_AUTHOR_EMAIL=canon-reconcile-published@localhost \
           GIT_COMMITTER_NAME=canon-reconcile-published GIT_COMMITTER_EMAIL=canon-reconcile-published@localhost \
           git commit-tree --no-gpg-sign "$tree" 2>/dev/null); }; then
    refuse "carried dirty paths cannot be saved: the saved objects cannot be put into a commit"
  fi
  # 1. the whole manifest under a temporary name; a run that dies before the rename leaves a *.tmp, removed by the next run
  CARRY_DISCARD="$tmp"
  ( umask 077; set -C
    { printf '# canon-reconcile-published carry manifest\n'
      printf '# repo: %s\n' "$(oneline "$REPO_TOP")"
      printf '# branch: %s\n' "$(oneline "$BRANCH")"
      printf '# swap: %s -> %s\n' "$OLD_HEAD" "$PINNED"
      printf '# ref: %s\n' "$CARRY_REF"
      printf '# to put every path back (each is checked first; type, permissions and bytes are verified; only then are the ref and this file removed):\n'
      printf '#   %s\n' "$(printf '%q --restore-carry %q %q' "$SELF" "$REPO_TOP" "$name")"
      printf '# records, for reading only (the restore reads them from the ref): <file|deleted> <raw blob> <permissions> <path, shell-quoted>\n'
      printf '%s' "$rec"
      printf '%s\n' "$CARRY_END_MARK"; } > "$tmp" ) 2>/dev/null || refuse "carried dirty paths cannot be saved: cannot write the manifest $tmp"
  fsync_best_effort "$tmp"
  # 2. the ref that keeps the objects from gc
  git update-ref "$CARRY_REF" "$commit" "" 2>/dev/null || refuse "carried dirty paths cannot be saved: the saved objects cannot be kept under $CARRY_REF"
  CARRY_REF_DISCARD="$CARRY_REF"
  # 3. the complete manifest appears under its own name in one step (rename), still before the swap
  mv -f -- "$tmp" "$name" 2>/dev/null || refuse "carried dirty paths cannot be saved: cannot rename the manifest into place: $name"
  CARRY_MANIFEST="$name"; CARRY_DISCARD="$name"   # dropped by the exit trap while a refusal can still come; kept from the swap on
}
carry_forget() {  # every carried path is back and checked: the ref and the manifest have done their job (the objects are left to gc)
  carry_drop "$CARRY_REF" "$CARRY_MANIFEST" || :   # a failure is warned about; the next run then cleans up or refuses, see carry_leftover_check
  CARRY_NOTE=""
}
carry_save
[ "$(dirty_signature)" = "$DIRTY_SIG_BEFORE" ] || refuse "tracked tree changed during preflight"   # again: the save itself took time

LIVE_WRITERS=$(live_canonical_writers)
[ -z "$LIVE_WRITERS" ] || refuse "live canonical writer(s) appeared during preflight:$LIVE_WRITERS"

# 5. compare-and-swap on the ref, then bring index + tracked tree along.
[ -z "$REFUSAL_STARTED" ] || { echo "canon-reconcile-published: a refusal started earlier and its report was cut short -- stopping before the swap, canon untouched" >&2; exit 1; }   # tripwire, see refuse()
if [ "$DETACHED" = 1 ]; then   # detached: the branch is compared with its own old value, so HEAD itself must be re-checked here (a commit made on the detached HEAD meanwhile would be wiped by the reset below)
  [ "$(git rev-parse HEAD)" = "$OLD_HEAD" ] || refuse "HEAD moved during preflight (detached copy): not re-attaching"
  CAS_OLD="$OLD_BRANCH"
else
  CAS_OLD="$OLD_HEAD"
fi
# The last look before the irreversible step: bytes, permissions and type of every carried path are what carry_save saved
# (the dirty signature above sees only git's mode and hash, so a permission change would otherwise be reverted unseen).
carry_unchanged || refuse "tracked tree changed during preflight: carried path(s) changed after they were saved (bytes, permissions or type):$CARRY_ERR"
git update-ref -m "canon-reconcile-published: $OLD_HEAD -> $PINNED" "refs/heads/$BRANCH" "$PINNED" "$CAS_OLD"; CAS_RC=$?
[ "$CAS_RC" -eq 0 ] || refuse "compare-and-swap on refs/heads/$BRANCH lost (HEAD moved)"
[ "$CAS_RC" -eq 0 ] || exit 1   # a SEPARATE top-level command: reached only when the report above died halfway (see refuse()), so the reset below never runs after a lost swap
CARRY_DISCARD=""; CARRY_REF_DISCARD=""   # the branch ref is replaced: from here on the carry manifest and its ref are evidence and stay on any failure
CARRY_NOTE=""; [ -z "$CARRY_MANIFEST" ] || CARRY_NOTE="; carried dirty paths are saved in $CARRY_MANIFEST (objects kept under $CARRY_REF; every later run refuses until they are put back with: $(printf '%q --restore-carry %q %q' "$SELF" "$REPO_TOP" "$CARRY_MANIFEST"))"
if [ "$DETACHED" = 1 ]; then git symbolic-ref HEAD "refs/heads/$BRANCH" || fail_after_swap "could not attach HEAD to $BRANCH$CARRY_NOTE"; fi
RESET_RC=0; git reset --hard --quiet || RESET_RC=$?
# The carried paths go back even when the reset failed: whatever it managed to write over them must not stay there.
if [ "$DIRTY_CARRIED" -gt 0 ]; then
  carry_restore || fail_after_swap "carried dirty path(s) not put back:$CARRY_ERR$CARRY_NOTE$([ "$RESET_RC" -eq 0 ] || printf '; git reset --hard failed too')"
  carry_forget
fi
[ "$RESET_RC" -eq 0 ] || fail_after_swap "git reset --hard failed -- index/tree need manual sync to $PINNED$CARRY_NOTE"

# 6. post-check.
[ "$(git rev-parse HEAD)" = "$PINNED" ] || fail_after_swap "HEAD is not the pinned oid$CARRY_NOTE"
[ -z "$(git diff --cached --name-only -z 2>/dev/null)" ] || fail_after_swap "index not clean$CARRY_NOTE"
[ "$(dirty_signature)" = "$CARRY_SIG" ] || fail_after_swap "tracked tree not clean apart from the carried paths$CARRY_NOTE"
ledger_locks_release   # the journals were rewritten with the target's version; writers may append again
UNTRACKED_AFTER=$(mktemp); TMP_FILES+=("$UNTRACKED_AFTER"); untracked_inventory > "$UNTRACKED_AFTER"
# expected after-set = before-set minus paths the target now tracks (proven identical in 4)
EXPECTED=$(mktemp); TMP_FILES+=("$EXPECTED")
while IFS= read -r line; do
  p="${line#* * }"
  t=$(git ls-tree "$PINNED" -- "$p" 2>/dev/null | awk 'NR==1{print $1" "$3}')
  [ "$t" = "${line% "$p"}" ] || printf '%s\n' "$line"
done < "$UNTRACKED_BEFORE" > "$EXPECTED"
DIFF=$(diff "$EXPECTED" "$UNTRACKED_AFTER" | grep '^[<>]' | head -3)
[ -z "$DIFF" ] || fail_after_swap "untracked set changed during the operation (< expected / > actual): $(printf '%s' "$DIFF" | tr '\n' ';')$CARRY_NOTE"

echo "canon-reconcile-published: $REPO refs/heads/$BRANCH ${OLD_HEAD:0:12} -> ${PINNED:0:12} (dropped commits: patch-equivalent or content-superseded=$CONTENT_SUPERSEDED; tolerated identical dirty paths=$DIRTY_TOLERATED; ancestral-path dirty=$DIRTY_ANCESTRAL commit-paths=$COMMIT_ANCESTRAL; ledger journals with all events on target=$DIRTY_LEDGER; carried_dirty=$DIRTY_CARRIED (upstream left them alone, local state kept); untracked intact)"
log_line replaced "$OLD_HEAD -> $PINNED content_superseded=$CONTENT_SUPERSEDED dirty_tolerated=$DIRTY_TOLERATED ancestral_dirty=$DIRTY_ANCESTRAL ancestral_commit_paths=$COMMIT_ANCESTRAL ledger_dirty=$DIRTY_LEDGER carried_dirty=$DIRTY_CARRIED"
healthy
exit 0
