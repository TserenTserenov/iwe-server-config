#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# iwe-verified-sync — fail-closed sync primitive for git clones consumed by
# headless processes on the server (WP-545 Ф12, peer-session with Codex
# 2026-09-08-15-wp545-pull-repos-audit, АрхГейт f12-archgate.md).
#
# Why this exists: the pull-repos sentinel became fetch-only on 2026-08-17 and
# 16 clones silently fell behind for three weeks while the nightly knowledge
# reindex kept rebuilding from stale packs. Ф11 fixed one clone with an inline
# nix script; this file generalises it and is pinned into /nix/store by
# `pkgs.writeShellApplication` so a bad commit in any auto-updated checkout can
# never break the verifier that checks it (FPF A.3:6.3 — no self-evidence).
#
# Subcommands
#   sync  --repo DIR --branch BR --state NAME [--remote origin]
#         [--lock FILE] [--lock-wait SEC] [--fetch-timeout SEC]
#         Advance DIR to <remote>/<branch> by fast-forward only. Refuses on a
#         dirty tree, a diverged history, fetch failure, or a post-merge
#         mismatch. Never writes back to git. Exit 0 = advanced or already
#         fresh (state written with status=ok); 1 = refused (state keeps the
#         last successful provenance, records the attempt); 2 = usage error.
#   fresh --repo DIR --branch BR --state NAME [--ttl-h H]
#         Gate for consumers: exit 0 only when state is readable, status is
#         ok or refused (a refusal keeps the last-known-good until TTL runs
#         out — Ф11 consensus, 6h = 3 sentinel intervals), repo/branch match,
#         sha == upstream_sha == HEAD, the working tree is clean (a consumer
#         must never run unreviewed local edits), and the last success is
#         within TTL and not in the future. Identity and freshness are
#         separate predicates (FPF A.2.6:8.5); an unreadable state is
#         "unknown", not "stale" (FPF EG-3). Exit 1 = not fresh; 2 = usage.
#   read  --state NAME
#         Print the validated key=value lines of a state file (no source/eval).
#         Exit 0 = printed; 1 = missing or malformed.
#
# State file v1 (~/.local/state/exocortex/verified-sync/<NAME>.state):
#   schema_version=1 repo= remote= branch= sha= upstream_sha=
#   status=ok|refused last_success_ts= last_attempt_ts= last_error=
#
# Alerts go to Telegram when TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID are set and
# are deduplicated per <NAME>:<failure class>: first immediately, a reminder
# every IWE_VERIFIED_SYNC_ALERT_TTL_MIN (default 240), one recovery message.
# Deduplication suppresses the message only — never the exit code or journal.
set -euo pipefail

STATE_DIR="${IWE_VERIFIED_SYNC_STATE_DIR:-$HOME/.local/state/exocortex/verified-sync}"
ALERT_TTL_MIN="${IWE_VERIFIED_SYNC_ALERT_TTL_MIN:-240}"
LOG_TAG="iwe-verified-sync"
FUTURE_SKEW_SEC=300

# `timeout` is coreutils on the server; macOS dev boxes may lack it.
if command -v timeout > /dev/null 2>&1; then with_timeout() { timeout "$@"; }; else with_timeout() { shift; "$@"; }; fi
HOST=$(uname -n)

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new}"

usage() {
  sed -n '/^# Subcommands/,/^# State file/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

log() {
  logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true
  echo "$LOG_TAG: $*" >&2
}

die_usage() {
  echo "$LOG_TAG: $*" >&2
  usage
}

# --- state file helpers -------------------------------------------------------

state_path() { printf '%s/%s.state' "$STATE_DIR" "$1"; }
alert_path() { printf '%s/%s.alert' "$STATE_DIR" "$1"; }

# state_check_file PATH → 0 when the file is a regular file owned by us.
# Reason on stdout when it is not (class name usable as a failure class).
state_check_file() {
  local path="$1"
  if [ ! -e "$path" ]; then echo "missing"; return 1; fi
  if [ -L "$path" ] || [ ! -f "$path" ]; then echo "not-regular-file"; return 1; fi
  local owner
  owner=$(stat -c %u "$path" 2>/dev/null || stat -f %u "$path" 2>/dev/null || echo "")
  if [ "$owner" != "$(id -u)" ]; then echo "foreign-owner"; return 1; fi
  return 0
}

# state_get PATH KEY → value (empty when absent). Only key=value lines with a
# safe charset are honoured; nothing is ever evaluated.
state_get() {
  local path="$1" key="$2"
  grep -E "^${key}=[A-Za-z0-9_./:@+ -]*$" "$path" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# state_safe VALUE → VALUE with every character outside state_get's charset
# replaced by "_", so what we write is exactly what a reader can get back.
state_safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9_./:@+ -' '_'; }

# state_write NAME k=v ... — atomic replace: temp file in the same directory,
# owner-only permissions, rename.
state_write() {
  local name="$1"; shift
  local path tmp
  path=$(state_path "$name")
  mkdir -p "$STATE_DIR"
  tmp=$(mktemp "$STATE_DIR/.${name}.XXXXXX")
  printf '%s\n' "$@" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$path"
}

# --- alerting with per-class deduplication ------------------------------------

send_telegram() {
  local text="$1"
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log "telegram not configured - alert only in journal: $text"
    return 0
  fi
  curl -s --max-time 10 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$text" > /dev/null || log "telegram send failed"
}

# alert_fail NAME CLASS MESSAGE — first alert immediately, then at most one
# reminder per ALERT_TTL_MIN for the same class; a different class alerts again.
alert_fail() {
  local name="$1" class="$2" message="$3"
  local apath now prev_class prev_ts
  apath=$(alert_path "$name")
  now=$(date -u +%s)
  prev_class=""; prev_ts=0
  if [ -f "$apath" ]; then
    prev_class=$(state_get "$apath" class)
    prev_ts=$(state_get "$apath" ts)
    [[ "$prev_ts" =~ ^[0-9]+$ ]] || prev_ts=0
  fi
  if [ "$prev_class" = "$class" ] && [ "$prev_ts" -le "$now" ] \
      && [ $(( (now - prev_ts) / 60 )) -lt "$ALERT_TTL_MIN" ]; then
    log "alert suppressed (dedup ${name}:${class}): $message"
    return 0
  fi
  mkdir -p "$STATE_DIR"
  printf 'class=%s\nts=%s\n' "$class" "$now" > "$apath"
  send_telegram "⚠️ verified-sync ${name} ($HOST, $(date '+%Y-%m-%d %H:%M')) [${class}]: ${message}"
}

# alert_recovered NAME MESSAGE — one message when a previously alerted state
# becomes healthy again; silent when nothing was alerted.
alert_recovered() {
  local name="$1" message="$2"
  local apath
  apath=$(alert_path "$name")
  [ -f "$apath" ] || return 0
  rm -f "$apath"
  send_telegram "✅ verified-sync ${name} ($HOST, $(date '+%Y-%m-%d %H:%M')): ${message}"
}

# --- argument parsing ---------------------------------------------------------

REPO=""; BRANCH=""; NAME=""; REMOTE="origin"
LOCK_FILE="${IWE_VERIFIED_SYNC_LOCK:-$HOME/IWE/.iwe-git-ops.lock}"
LOCK_WAIT=60; FETCH_TIMEOUT=45; TTL_H=6
DIRTY_GRACE_SEC="${IWE_VERIFIED_SYNC_DIRTY_GRACE_SEC:-15}"

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) REPO="${2:-}"; shift 2 ;;
      --branch) BRANCH="${2:-}"; shift 2 ;;
      --state) NAME="${2:-}"; shift 2 ;;
      --remote) REMOTE="${2:-}"; shift 2 ;;
      --lock) LOCK_FILE="${2:-}"; shift 2 ;;
      --lock-wait) LOCK_WAIT="${2:-}"; shift 2 ;;
      --fetch-timeout) FETCH_TIMEOUT="${2:-}"; shift 2 ;;
      --ttl-h) TTL_H="${2:-}"; shift 2 ;;
      *) die_usage "unknown argument: $1" ;;
    esac
  done
}

require_name() {
  [ -n "$NAME" ] || die_usage "--state NAME is required"
  [[ "$NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || die_usage "--state must match [A-Za-z0-9_.-]+"
}

require_repo_branch() {
  [ -n "$REPO" ] || die_usage "--repo DIR is required"
  [ -n "$BRANCH" ] || die_usage "--branch BR is required (no default on purpose)"
  [[ "$BRANCH" =~ ^[A-Za-z0-9_./-]+$ ]] || die_usage "--branch has an unsafe character"
  [[ "$REMOTE" =~ ^[A-Za-z0-9_.-]+$ ]] || die_usage "--remote has an unsafe character"
}

# --- sync -----------------------------------------------------------------------

# record_refusal CLASS MESSAGE — keep the last success, note the attempt.
record_refusal() {
  local class="$1" message="$2"
  local path prev_sha prev_up prev_ok now
  path=$(state_path "$NAME")
  prev_sha=""; prev_up=""; prev_ok=""
  if state_check_file "$path" > /dev/null; then
    prev_sha=$(state_get "$path" sha)
    prev_up=$(state_get "$path" upstream_sha)
    prev_ok=$(state_get "$path" last_success_ts)
  fi
  now=$(date -u +%s)
  state_write "$NAME" "schema_version=1" "repo=$REPO" "remote=$REMOTE" "branch=$BRANCH" \
    "sha=$prev_sha" "upstream_sha=$prev_up" "status=refused" \
    "last_success_ts=$prev_ok" "last_attempt_ts=$now" "last_error=$(state_safe "$class: $message")"
  log "$NAME refused [$class]: $message"
  alert_fail "$NAME" "$class" "$message"
}

record_success() {
  local sha="$1" now
  now=$(date -u +%s)
  state_write "$NAME" "schema_version=1" "repo=$REPO" "remote=$REMOTE" "branch=$BRANCH" \
    "sha=$sha" "upstream_sha=$sha" "status=ok" \
    "last_success_ts=$now" "last_attempt_ts=$now" "last_error="
}

cmd_sync() {
  parse_args "$@"
  require_name; require_repo_branch
  local ref="refs/remotes/$REMOTE/$BRANCH"

  if [ ! -d "$REPO/.git" ]; then
    record_refusal "missing" "no git clone at $REPO"; return 1
  fi
  local current_branch
  current_branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ "$current_branch" != "$BRANCH" ]; then
    record_refusal "wrong-branch" "checkout is on '$current_branch', expected '$BRANCH'"; return 1
  fi

  if ! touch "$LOCK_FILE" 2>/dev/null; then
    record_refusal "unknown" "cannot open lock file $LOCK_FILE"; return 1
  fi
  exec 200>"$LOCK_FILE"
  if ! flock -w "$LOCK_WAIT" 200; then
    # Not a failure of the clone: another git writer holds the shared lock.
    # State is left untouched so freshness ages naturally; the next tick retries.
    log "$NAME: lock $LOCK_FILE busy for ${LOCK_WAIT}s - skipping this tick"; return 1
  fi

  if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
    sleep "$DIRTY_GRACE_SEC"
    if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
      record_refusal "dirty" "working tree has local changes - refusing to advance"; return 1
    fi
  fi

  local before_sha upstream_sha after_sha
  before_sha=$(git -C "$REPO" rev-parse HEAD)
  if ! with_timeout "$FETCH_TIMEOUT" git -C "$REPO" fetch --quiet --prune "$REMOTE" "$BRANCH"; then
    record_refusal "fetch-failed" "git fetch $REMOTE $BRANCH failed or timed out (${FETCH_TIMEOUT}s)"; return 1
  fi
  upstream_sha=$(git -C "$REPO" rev-parse "$ref" 2>/dev/null || echo "")
  if [ -z "$upstream_sha" ]; then
    record_refusal "no-upstream" "cannot resolve $ref after fetch"; return 1
  fi

  if [ "$before_sha" = "$upstream_sha" ]; then
    record_success "$upstream_sha"
    alert_recovered "$NAME" "clone healthy again at ${upstream_sha:0:7}"
    return 0
  fi

  if ! git -C "$REPO" merge --ff-only "$ref" > /dev/null 2>&1; then
    record_refusal "diverged" "$ref is not a fast-forward of ${before_sha:0:7} - history diverged or rewritten, manual check required"; return 1
  fi
  after_sha=$(git -C "$REPO" rev-parse HEAD)
  if [ "$after_sha" != "$upstream_sha" ]; then
    record_refusal "post-merge-mismatch" "HEAD ${after_sha:0:7} != $ref ${upstream_sha:0:7} after merge"; return 1
  fi
  record_success "$after_sha"
  log "$NAME advanced ${before_sha:0:7} -> ${after_sha:0:7} ($(git -C "$REPO" rev-list --count "$before_sha".."$after_sha") commits)"
  alert_recovered "$NAME" "clone advanced to ${after_sha:0:7}"
  return 0
}

# --- fresh ------------------------------------------------------------------------

# fresh_fail CLASS MESSAGE → exit 1 (alert deduplicated per class).
fresh_fail() {
  local class="$1" message="$2"
  log "$NAME not fresh [$class]: $message"
  alert_fail "${NAME}.gate" "$class" "$message"
  return 1
}

cmd_fresh() {
  parse_args "$@"
  require_name; require_repo_branch
  [[ "$TTL_H" =~ ^[0-9]+$ ]] || die_usage "--ttl-h must be an integer number of hours"
  local path reason
  path=$(state_path "$NAME")
  if ! reason=$(state_check_file "$path"); then
    fresh_fail "unknown" "state file $path: $reason - checkout unverified"; return 1
  fi
  local schema status s_repo s_branch sha up ok_ts now head
  schema=$(state_get "$path" schema_version)
  status=$(state_get "$path" status)
  s_repo=$(state_get "$path" repo)
  s_branch=$(state_get "$path" branch)
  sha=$(state_get "$path" sha)
  up=$(state_get "$path" upstream_sha)
  ok_ts=$(state_get "$path" last_success_ts)
  if [ "$schema" != "1" ]; then
    fresh_fail "unknown" "unsupported schema_version '$schema'"; return 1
  fi
  if [ "$s_repo" != "$REPO" ] || [ "$s_branch" != "$BRANCH" ]; then
    fresh_fail "identity" "state is for $s_repo@$s_branch, gate asked for $REPO@$BRANCH"; return 1
  fi
  case "$status" in
    ok) ;;
    refused) log "$NAME: last sync attempt refused ($(state_get "$path" last_error)) - checking last-known-good" ;;
    *) fresh_fail "unknown" "unsupported status '$status'"; return 1 ;;
  esac
  if [ -z "$sha" ] || [ "$sha" != "$up" ]; then
    fresh_fail "identity" "recorded sha '$sha' != upstream_sha '$up'"; return 1
  fi
  head=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo "")
  if [ "$head" != "$sha" ]; then
    fresh_fail "identity" "checkout HEAD ${head:0:7} != verified sha ${sha:0:7}"; return 1
  fi
  if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
    fresh_fail "dirty" "working tree has local changes - a consumer would run unreviewed code"; return 1
  fi
  now=$(date -u +%s)
  if ! [[ "$ok_ts" =~ ^[0-9]+$ ]]; then
    fresh_fail "unknown" "last_success_ts '$ok_ts' is not a timestamp"; return 1
  fi
  if [ "$ok_ts" -gt $(( now + FUTURE_SKEW_SEC )) ]; then
    fresh_fail "future" "last_success_ts is $(( ok_ts - now ))s in the future - clock or file tampering"; return 1
  fi
  if [ $(( now - ok_ts )) -gt $(( TTL_H * 3600 )) ]; then
    fresh_fail "stale" "last verified sync $(( (now - ok_ts) / 3600 ))h ago (> ${TTL_H}h)"; return 1
  fi
  alert_recovered "${NAME}.gate" "consumer gate passes again"
  return 0
}

# --- read -------------------------------------------------------------------------

cmd_read() {
  parse_args "$@"
  require_name
  local path reason key
  path=$(state_path "$NAME")
  if ! reason=$(state_check_file "$path"); then
    echo "$LOG_TAG: $NAME: $reason" >&2; return 1
  fi
  for key in schema_version repo remote branch sha upstream_sha status last_success_ts last_attempt_ts last_error; do
    printf '%s=%s\n' "$key" "$(state_get "$path" "$key")"
  done
}

# --- dispatch ---------------------------------------------------------------------

[ $# -ge 1 ] || usage
case "$1" in
  sync)  shift; cmd_sync "$@" ;;
  fresh) shift; cmd_fresh "$@" ;;
  read)  shift; cmd_read "$@" ;;
  -h|--help|help) usage ;;
  *) die_usage "unknown subcommand: $1" ;;
esac
