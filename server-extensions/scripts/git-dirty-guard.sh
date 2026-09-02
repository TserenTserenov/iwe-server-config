#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# git-dirty-guard.sh — non-mutating dirty-tree gate for pull callers.
#
# A previous version tried to self-heal a stale mirror with `git reset --hard`.
# That is unsafe in a shared checkout: a staged layer or a tracked write arriving
# after classification can be erased, and no reset mode protects every case. The
# guard now diagnoses every tracked-dirty state and returns 1 without changing the
# branch, index, worktree or stash. Cleanup requires an exclusive worktree or manual
# owner action.
#
# Usage: git-dirty-guard.sh <repo-path> [branch]
# Environment:
#   GIT_DIRTY_GUARD_REQUIRE_FETCH=true  fail closed when the remote query fails.
#   GIT_DIRTY_GUARD_FETCH_TIMEOUT=N     portable query deadline in seconds (0=none).
#   GIT_DIRTY_GUARD_REMOTE_OID_OUTPUT=true  print only the remote OID on success.
#   GIT_DIRTY_GUARD_FETCH_DEST_REF      retired; any nonempty value is refused.
#   GIT_DIRTY_GUARD_TG_ALERTS=false     suppress direct Telegram delivery.
# Exit codes: 0 = tracked tree is clean (untracked-only is allowed).
#             1 = dirty, mid-operation, lock-busy, query-refused, or unstable.
#             2 = usage/repository error.
set -uo pipefail

REPO="${1:?usage: git-dirty-guard.sh <repo-path> [branch]}"
BRANCH="${2:-}"
GIT_DIRTY_GUARD_TG_ALERTS="${GIT_DIRTY_GUARD_TG_ALERTS:-true}"
GIT_DIRTY_GUARD_REQUIRE_FETCH="${GIT_DIRTY_GUARD_REQUIRE_FETCH:-false}"
GIT_DIRTY_GUARD_FETCH_TIMEOUT="${GIT_DIRTY_GUARD_FETCH_TIMEOUT:-0}"
GIT_DIRTY_GUARD_REMOTE_OID_OUTPUT="${GIT_DIRTY_GUARD_REMOTE_OID_OUTPUT:-false}"
GIT_DIRTY_GUARD_FETCH_DEST_REF="${GIT_DIRTY_GUARD_FETCH_DEST_REF:-}"
AIST_ENV="$HOME/.config/aist/env"

# Load only the two notification credentials as data. The AIST file is shell-shaped,
# but executing it would let unrelated readonly assignments, `exit`, PATH, functions,
# or Git environment variables change this guard's control plane.
load_aist_credentials() {
  local line key value loaded_token="" loaded_chat_id=""
  [ -f "$AIST_ENV" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      'export TELEGRAM_BOT_TOKEN='*)
        key="TELEGRAM_BOT_TOKEN"
        value="${line#export TELEGRAM_BOT_TOKEN=}"
        ;;
      'TELEGRAM_BOT_TOKEN='*)
        key="TELEGRAM_BOT_TOKEN"
        value="${line#TELEGRAM_BOT_TOKEN=}"
        ;;
      'export TELEGRAM_CHAT_ID='*)
        key="TELEGRAM_CHAT_ID"
        value="${line#export TELEGRAM_CHAT_ID=}"
        ;;
      'TELEGRAM_CHAT_ID='*)
        key="TELEGRAM_CHAT_ID"
        value="${line#TELEGRAM_CHAT_ID=}"
        ;;
      *) continue ;;
    esac
    case "$value" in
      ''|*[!A-Za-z0-9:_-]*) continue ;;
    esac
    if [ "$key" = "TELEGRAM_BOT_TOKEN" ]; then
      loaded_token="$value"
    else
      loaded_chat_id="$value"
    fi
  done < "$AIST_ENV"
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] || TELEGRAM_BOT_TOKEN="$loaded_token"
  [ -n "${TELEGRAM_CHAT_ID:-}" ] || TELEGRAM_CHAT_ID="$loaded_chat_id"
}
load_aist_credentials

# `git status` normally refreshes index stat data. This guard is observational.
export GIT_OPTIONAL_LOCKS=0
# Partial clones may fetch promised objects from ostensibly read-only commands such
# as rev-parse or diff. Keep every inspection inside the explicit query boundary.
export GIT_NO_LAZY_FETCH=1
# Classify the real commit graph, independent of local replacement refs or the
# deprecated info/grafts overlay in a shared repository.
export GIT_NO_REPLACE_OBJECTS=1
export GIT_GRAFT_FILE=/dev/null/iwe-no-grafts
COMPARE_REF=""
REMOTE_OID=""
REMOTE_STATE_AVAILABLE=true

is_true() {
  case "$1" in
    1|true|yes|on) return 0 ;;
  esac
  return 1
}

git_supports_no_lazy_fetch() {
  git --no-lazy-fetch --version >/dev/null 2>&1
}

run_with_timeout() {
  local seconds="$1"
  shift
  case "$seconds" in
    0|'') "$@" ;;
    *[!0-9]*)
      echo "git-dirty-guard: invalid remote-query timeout: $seconds" >&2
      return 1
      ;;
    *)
      command -v python3 >/dev/null 2>&1 || {
        echo "git-dirty-guard: remote-query timeout requested but python3 is unavailable" >&2
        return 1
      }
      # A process group plus TERM→KILL escalation makes this a hard deadline even
      # when git, ssh, or a credential helper ignores TERM.
      python3 -c '
import os
import signal
import subprocess
import sys

seconds = int(sys.argv[1])
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
handled_signals = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)

def stop_process_group():
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except OSError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
        process.wait()

def forward_signal(signum, _frame):
    for handled in handled_signals:
        signal.signal(handled, signal.SIG_IGN)
    stop_process_group()
    raise SystemExit(128 + signum)

for handled in handled_signals:
    signal.signal(handled, forward_signal)

try:
    returncode = process.wait(timeout=seconds)
except subprocess.TimeoutExpired:
    stop_process_group()
    raise SystemExit(124)

raise SystemExit(returncode if returncode >= 0 else 128 - returncode)
' "$seconds" "$@"
      ;;
  esac
}

query_origin() {
  local source_ref="refs/heads/$BRANCH"
  local remote_output parsed_oid query_status parse_status

  if [ -n "$GIT_DIRTY_GUARD_FETCH_DEST_REF" ]; then
    echo "git-dirty-guard: fetch destinations are unsupported; refusing ref mutation" >&2
    return 1
  fi

  remote_output=$(run_with_timeout "$GIT_DIRTY_GUARD_FETCH_TIMEOUT" \
    git ls-remote --exit-code --refs origin "$source_ref" 2>/dev/null)
  query_status=$?
  [ "$query_status" -eq 0 ] || return "$query_status"

  parsed_oid=$(printf '%s\n' "$remote_output" | awk -v expected="$source_ref" '
    NF != 2 || $2 != expected { exit 1 }
    { count += 1; oid = $1 }
    END {
      if (count != 1) exit 1
      print oid
    }
  ')
  parse_status=$?
  if [ "$parse_status" -ne 0 ]; then
    echo "git-dirty-guard: malformed remote response for $source_ref" >&2
    return 1
  fi

  case "$parsed_oid" in
    ''|*[!0-9a-fA-F]*)
      echo "git-dirty-guard: invalid remote object id for $source_ref" >&2
      return 1
      ;;
  esac
  case "${#parsed_oid}" in
    40|64) ;;
    *)
      echo "git-dirty-guard: invalid remote object-id length for $source_ref" >&2
      return 1
      ;;
  esac

  REMOTE_OID="$parsed_oid"
  COMPARE_REF="$REMOTE_OID"
}

tg_alert() {
  local msg="$1"
  case "$GIT_DIRTY_GUARD_TG_ALERTS" in
    0|false|no|off) return 0 ;;
  esac
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
  curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$msg" >/dev/null || true
}

# --- Alert dedup (WP-538 Ф4, 2026-09-02). Ported onto this file from the 18.08/01.09
# patch that lived only as an uncommitted copy of an older base and was wiped by its
# own self-heal on 02.09 13:55. One unresolved fact must not re-alert on every guard
# run: first sighting = full alert; same type+signature inside the TTL = silence
# (stderr still explains); after the TTL = one compact escalation. A clean exit
# clears the state. State lives next to the lock dir; it is not a ref, index or
# worktree write, so the non-mutating contract above holds.
GIT_DIRTY_GUARD_ALERT_TTL_MIN="${GIT_DIRTY_GUARD_ALERT_TTL_MIN:-60}"
case "$GIT_DIRTY_GUARD_ALERT_TTL_MIN" in
  ''|*[!0-9]*|0) GIT_DIRTY_GUARD_ALERT_TTL_MIN=60 ;;
esac
# Real uncommitted edits on a busy shared checkout are ordinary work, not an
# incident (pilot, 01.09): alert only once the repo has not been clean this long.
GIT_DIRTY_GUARD_CHRONIC_HOURS="${GIT_DIRTY_GUARD_CHRONIC_HOURS:-24}"
case "$GIT_DIRTY_GUARD_CHRONIC_HOURS" in
  ''|*[!0-9]*) GIT_DIRTY_GUARD_CHRONIC_HOURS=24 ;;
esac

alert_state_clear() {
  rm -f "$GIT_DIR/dirty-guard-alert-state" "$GIT_DIR/dirty-guard-chronic-since" 2>/dev/null || true
}

# alert_dedup_send <type> <signature> <full_msg> <cta> -- the only Telegram entry
# point for the alert paths below.
alert_dedup_send() {
  local type="$1" signature="$2" full_msg="$3" cta="$4"
  # A caller with alerts disabled (pull-on-touch) must not consume the TTL for a
  # caller that wants the pilot told (day-open-pipeline) — the state describes
  # alerts actually offered, not silent inspections (cold-context review, Ф4).
  case "$GIT_DIRTY_GUARD_TG_ALERTS" in
    0|false|no|off)
      echo "git-dirty-guard: alerts disabled ($type) -- dedup state untouched" >&2
      return 0
      ;;
  esac
  local state_file="$GIT_DIR/dirty-guard-alert-state"
  local now prev_type="" prev_sig="" prev_first="" prev_last=""
  now=$(date +%s)
  if [ -f "$state_file" ]; then
    prev_type=$(awk -F= '$1=="type"{print $2}' "$state_file" 2>/dev/null)
    prev_sig=$(awk -F= '$1=="signature"{print $2}' "$state_file" 2>/dev/null)
    prev_first=$(awk -F= '$1=="first_alerted_at"{print $2}' "$state_file" 2>/dev/null)
    prev_last=$(awk -F= '$1=="last_alerted_at"{print $2}' "$state_file" 2>/dev/null)
  fi
  case "$prev_first" in ''|*[!0-9]*) prev_first="" ;; esac
  case "$prev_last" in ''|*[!0-9]*) prev_last="" ;; esac

  if [ "$prev_type" != "$type" ] || [ "$prev_sig" != "$signature" ] \
    || [ -z "$prev_first" ] || [ -z "$prev_last" ]; then
    echo "git-dirty-guard: new problem ($type) -- full alert" >&2
    tg_alert "$full_msg"
    printf 'version=1\ntype=%s\nsignature=%s\nfirst_alerted_at=%s\nlast_alerted_at=%s\n' \
      "$type" "$signature" "$now" "$now" > "$state_file" 2>/dev/null || true
    return 0
  fi

  local age_min=$(( (now - prev_last) / 60 ))
  if [ "$age_min" -lt "$GIT_DIRTY_GUARD_ALERT_TTL_MIN" ]; then
    echo "git-dirty-guard: same problem ($type), last alert ${age_min} min ago (TTL ${GIT_DIRTY_GUARD_ALERT_TTL_MIN} min) -- Telegram skipped" >&2
    return 0
  fi

  local total_h=$(( (now - prev_first) / 3600 ))
  echo "git-dirty-guard: same problem ($type), escalating after ${GIT_DIRTY_GUARD_ALERT_TTL_MIN} min of silence" >&2
  tg_alert "🚨 $REPO: всё ещё не исправлено (${total_h}ч с первого предупреждения). $cta"
  printf 'version=1\ntype=%s\nsignature=%s\nfirst_alerted_at=%s\nlast_alerted_at=%s\n' \
    "$type" "$signature" "$prev_first" "$now" > "$state_file" 2>/dev/null || true
}

# differ_chronic_gate <full_msg> <cta> -- the set of differing files changes almost
# every run on a busy checkout, so an exact signature would look "new" each time.
# Decide by how long the repo has been continuously not-clean instead.
differ_chronic_gate() {
  local full_msg="$1" cta="$2"
  local chronic_file="$GIT_DIR/dirty-guard-chronic-since"
  local now dirty_since
  now=$(date +%s)
  dirty_since=$(cat "$chronic_file" 2>/dev/null)
  case "$dirty_since" in
    ''|*[!0-9]*)
      dirty_since="$now"
      printf '%s' "$now" > "$chronic_file" 2>/dev/null || true
      ;;
  esac
  local age_h=$(( (now - dirty_since) / 3600 ))
  if [ "$age_h" -lt "$GIT_DIRTY_GUARD_CHRONIC_HOURS" ]; then
    echo "git-dirty-guard: real uncommitted edits younger than ${GIT_DIRTY_GUARD_CHRONIC_HOURS}h (${age_h}h) -- log only, no alert" >&2
    return 0
  fi
  echo "git-dirty-guard: uncommitted edits older than ${GIT_DIRTY_GUARD_CHRONIC_HOURS}h -- treating as forgotten, alerting" >&2
  alert_dedup_send differ-chronic "chronic-${dirty_since}" \
    "${full_msg} (не решается уже ${age_h}ч)" "$cta"
}

repo_has_operation() {
  [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ] \
    || [ -f "$GIT_DIR/MERGE_HEAD" ] || [ -f "$GIT_DIR/CHERRY_PICK_HEAD" ] \
    || [ -f "$GIT_DIR/REVERT_HEAD" ]
}

cd "$REPO" 2>/dev/null || { echo "git-dirty-guard: cannot cd to $REPO" >&2; exit 2; }
REPO="$(pwd)"
if ! git_supports_no_lazy_fetch; then
  echo "git-dirty-guard: Git 2.45+ is required to prevent implicit object downloads; refusing" >&2
  exit 1
fi
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "git-dirty-guard: $REPO is not a git repo" >&2
  exit 2
}

[ -n "$BRANCH" ] || BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
if [ -z "$BRANCH" ] || ! git check-ref-format "refs/heads/$BRANCH" >/dev/null 2>&1; then
  echo "git-dirty-guard: invalid or detached branch in $REPO, refusing" >&2
  exit 2
fi

CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
  echo "git-dirty-guard: detached HEAD in $REPO, refusing" >&2
  exit 2
}
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
  echo "git-dirty-guard: checked-out branch is $CURRENT_BRANCH (expected $BRANCH), refusing" >&2
  exit 1
fi

GIT_DIR=$(git rev-parse --absolute-git-dir)
# A directory without its own repository (DS-MCP) resolves to the parent's Git
# dir: on 02.09 that is how an older guard reset the IWE root instead of DS-MCP.
# Refuse rather than inspect, alert or record state for the wrong repository.
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
# Compare physical paths: $REPO may be reached through a symlink (~/IWE/memory).
if [ "$TOPLEVEL" != "$(pwd -P)" ]; then
  echo "git-dirty-guard: $REPO is not a repository root (git dir belongs to $TOPLEVEL), refusing" >&2
  exit 2
fi
if repo_has_operation; then
  echo "git-dirty-guard: $REPO is mid-operation -- refusing to touch" >&2
  alert_dedup_send mid-operation "mid-operation" \
    "🚨 git-dirty-guard: $REPO застрял в git-операции — не тронул, нужно ручное восстановление." \
    "Незавершённая git-операция всё ещё висит, нужно ручное восстановление."
  exit 1
fi

# Serialize guard snapshots. This lock does not authorize mutation: ordinary editors
# do not honor it, which is why automatic reset/self-heal is deliberately absent.
LOCK_DIR="$GIT_DIR/dirty-guard.lock"
LOCK_META="$LOCK_DIR/owner"
HOSTNAME_NOW="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -f "$LOCK_META" ]; then
    OTHER_HOST=$(awk -F= '$1=="host"{print $2}' "$LOCK_META" 2>/dev/null)
    OTHER_PID=$(awk -F= '$1=="pid"{print $2}' "$LOCK_META" 2>/dev/null)
    if [ "$OTHER_HOST" = "$HOSTNAME_NOW" ] && [ -n "$OTHER_PID" ] \
      && ! kill -0 "$OTHER_PID" 2>/dev/null; then
      echo "git-dirty-guard: reclaiming stale lock (pid=$OTHER_PID on $OTHER_HOST)" >&2
      rm -rf "$LOCK_DIR" 2>/dev/null
    fi
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "git-dirty-guard: lock busy (live owner or unproven), refusing" >&2
    exit 1
  fi
fi
echo "host=$HOSTNAME_NOW" > "$LOCK_META"
echo "pid=$$" >> "$LOCK_META"
STATUS_FILE=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
release_guard_lock() {
  local owner_host owner_pid
  owner_host=$(awk -F= '$1=="host"{print $2}' "$LOCK_META" 2>/dev/null)
  owner_pid=$(awk -F= '$1=="pid"{print $2}' "$LOCK_META" 2>/dev/null)
  if [ "$owner_host" = "$HOSTNAME_NOW" ] && [ "$owner_pid" = "$$" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null
  fi
}
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup_guard() {
  [ -z "$STATUS_FILE" ] || rm -f "$STATUS_FILE" 2>/dev/null
  release_guard_lock
}
trap cleanup_guard EXIT

if ! query_origin; then
  echo "git-dirty-guard: remote query failed or timed out -- remote state unavailable" >&2
  if is_true "$GIT_DIRTY_GUARD_REQUIRE_FETCH" \
    || is_true "$GIT_DIRTY_GUARD_REMOTE_OID_OUTPUT" \
    || [ -n "$GIT_DIRTY_GUARD_FETCH_DEST_REF" ]; then
    exit 1
  fi
  REMOTE_STATE_AVAILABLE=false
fi

SNAPSHOT_HEAD=$(git rev-parse HEAD 2>/dev/null) || exit 1
if [ "$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" != "$BRANCH" ] \
  || repo_has_operation; then
  echo "git-dirty-guard: repo changed during remote query -- refusing" >&2
  exit 1
fi

# Collect tracked dirty paths (staged or unstaged). Untracked files are allowed:
# the guard never removes them, and they can be legitimate new work.
TRACKED_DIRTY=()
STATUS_FILE=$(mktemp "${TMPDIR:-/tmp}/git-dirty-guard-status.XXXXXX") || {
  echo "git-dirty-guard: cannot allocate status snapshot" >&2
  exit 1
}
if ! git status --porcelain=v2 --branch -z --untracked-files=no > "$STATUS_FILE"; then
  echo "git-dirty-guard: git status failed -- refusing" >&2
  exit 1
fi
STATUS_OID=""
STATUS_BRANCH=""
STATUS_PARSE_OK=true
while IFS= read -r -d '' entry; do
  case "$entry" in
    "# branch.oid "*)
      if [ -n "$STATUS_OID" ]; then
        STATUS_PARSE_OK=false
        break
      fi
      STATUS_OID="${entry#\# branch.oid }"
      ;;
    "# branch.head "*)
      if [ -n "$STATUS_BRANCH" ]; then
        STATUS_PARSE_OK=false
        break
      fi
      STATUS_BRANCH="${entry#\# branch.head }"
      ;;
    "# "*) ;;
    "1 "*|"2 "*|"u "*)
      rest="$entry"
      case "$entry" in
        "1 "*) field_count=8 ;;
        "2 "*) field_count=9 ;;
        *) field_count=10 ;;
      esac
      while [ "$field_count" -gt 0 ]; do
        case "$rest" in
          *' '*) rest="${rest#* }" ;;
          *) STATUS_PARSE_OK=false; break ;;
        esac
        field_count=$((field_count - 1))
      done
      [ "$STATUS_PARSE_OK" = true ] || break
      if [[ "$entry" == "2 "* ]]; then
        if ! IFS= read -r -d '' _origpath; then
          STATUS_PARSE_OK=false
          break
        fi
      fi
      TRACKED_DIRTY+=("$rest")
      ;;
    "? "*|"! "*) ;;
    *)
      STATUS_PARSE_OK=false
      break
      ;;
  esac
done < "$STATUS_FILE"
rm -f "$STATUS_FILE"
STATUS_FILE=""

if [ "$STATUS_PARSE_OK" != true ] \
  || [ "$STATUS_OID" != "$SNAPSHOT_HEAD" ] \
  || [ "$STATUS_BRANCH" != "$BRANCH" ] \
  || [ "$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" != "$BRANCH" ] \
  || [ "$(git rev-parse HEAD 2>/dev/null)" != "$SNAPSHOT_HEAD" ] \
  || repo_has_operation; then
  echo "git-dirty-guard: repo changed during inspection -- refusing" >&2
  exit 1
fi

clean_snapshot_is_stable() {
  local entry snapshot_oid="" snapshot_branch=""
  local seen_oid=0 seen_branch=0 snapshot_clean=true
  ! repo_has_operation || return 1
  STATUS_FILE=$(mktemp "${TMPDIR:-/tmp}/git-dirty-guard-clean-status.XXXXXX") || return 1
  if ! git status --porcelain=v2 --branch -z --untracked-files=no > "$STATUS_FILE"; then
    rm -f "$STATUS_FILE"
    STATUS_FILE=""
    return 1
  fi
  ! repo_has_operation || return 1
  while IFS= read -r -d '' entry || [ -n "$entry" ]; do
    case "$entry" in
      "# branch.oid "*)
        if [ "$seen_oid" -ne 0 ]; then
          snapshot_clean=false
          break
        fi
        snapshot_oid="${entry#\# branch.oid }"
        seen_oid=1
        ;;
      "# branch.head "*)
        if [ "$seen_branch" -ne 0 ]; then
          snapshot_clean=false
          break
        fi
        snapshot_branch="${entry#\# branch.head }"
        seen_branch=1
        ;;
      "# "*) ;;
      "? "*|"! "*) ;;
      *)
        snapshot_clean=false
        break
        ;;
    esac
  done < "$STATUS_FILE"
  rm -f "$STATUS_FILE"
  STATUS_FILE=""
  [ "$snapshot_clean" = true ] \
    && [ "$seen_oid" -eq 1 ] \
    && [ "$seen_branch" -eq 1 ] \
    && [ "$snapshot_oid" = "$SNAPSHOT_HEAD" ] \
    && [ "$snapshot_branch" = "$BRANCH" ] \
    && git diff --cached --quiet "$SNAPSHOT_HEAD" -- \
    && [ "$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" = "$BRANCH" ] \
    && [ "$(git rev-parse HEAD 2>/dev/null)" = "$SNAPSHOT_HEAD" ] \
    && ! repo_has_operation
}

if [ "${#TRACKED_DIRTY[@]}" -eq 0 ]; then
  # A second full status observation catches a worktree edit that lands after
  # the path-collecting snapshot. The explicit cached comparison independently
  # rejects a clean status assembled across a HEAD/index ABA transition.
  if ! clean_snapshot_is_stable; then
    echo "git-dirty-guard: tracked state changed during inspection -- refusing" >&2
    exit 1
  fi
  alert_state_clear
  if is_true "$GIT_DIRTY_GUARD_REMOTE_OID_OUTPUT"; then
    printf '%s\n' "$REMOTE_OID"
  else
    echo "git-dirty-guard: clean (or untracked-only) -- safe to inspect"
  fi
  exit 0
fi

DIFFERING=()
for f in "${TRACKED_DIRTY[@]}"; do
  if [ "$REMOTE_STATE_AVAILABLE" != "true" ]; then
    DIFFERING+=("$f")
    continue
  fi
  # Both layers must match the queried tree when that object exists locally.
  # Compare index→remote and worktree→index without an optional index refresh/write.
  if ! git diff --cached --quiet "$COMPARE_REF" -- "$f" 2>/dev/null \
    || ! git diff-files --quiet -- "$f" 2>/dev/null; then
    DIFFERING+=("$f")
  fi
done

if [ "${#DIFFERING[@]}" -eq 0 ]; then
  echo "git-dirty-guard: ${#TRACKED_DIRTY[@]} tracked file(s) match origin/$BRANCH, but automatic self-heal is disabled to protect concurrent work" >&2
  STALE_SIG=$(printf '%s\n' "${TRACKED_DIRTY[@]}" | LC_ALL=C sort | cksum | cut -d' ' -f1)
  alert_dedup_send stale-mirror "$STALE_SIG" \
    "🚨 git-dirty-guard: $REPO — найден устаревший зеркальный слой; автоматический reset отключён, нужна эксклюзивная ручная очистка." \
    "Устаревший зеркальный слой всё ещё на месте, нужна эксклюзивная ручная очистка."
  exit 1
fi

echo "git-dirty-guard: ${#DIFFERING[@]} tracked file(s) differ from origin/$BRANCH -- not touching:" >&2
printf '  %s\n' "${DIFFERING[@]}" >&2
LIST=$(printf '%s, ' "${DIFFERING[@]:0:5}")
LIST="${LIST%, }"
differ_chronic_gate \
  "🚨 git-dirty-guard: $REPO — ${#DIFFERING[@]} файл(ов) с несохранёнными правками (не тронул): $LIST." \
  "Незакоммиченные правки всё ещё не разобраны."
exit 1
