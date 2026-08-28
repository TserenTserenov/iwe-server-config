#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# git-dirty-guard.sh — protects a repo's periodic pull from a dirty working tree.
#
# WP-484 (2026-07-19). Root cause of the recurring tsekh-1 cleanup: sync-strategy-files.sh
# (and the fleeting-notes sync) write files straight from origin's blobs without ever
# committing, so DS-my-strategy's working tree on the server accumulates "dirty" entries
# whose content is byte-identical to origin — not real work, just a stale local HEAD.
# `git pull --rebase` refuses to run on a dirty tree, so local HEAD never catches up, and
# any guard relying on local git log (e.g. day-open-pipeline.sh step 1.1) goes blind to
# commits origin already has — the day this was written, the server was found 33 commits
# behind with 21 dirty tracked files, all 21 byte-identical to origin (verified live).
#
# This script tells the two cases apart before a caller attempts pull/rebase:
#   - every dirty TRACKED file byte-identical to origin/<branch>  → stale mirror, safe to
#     `git reset --hard origin/<branch>` (untracked files are never touched — reset --hard
#     doesn't remove them, and they're exactly the shape of real new work found live on
#     2026-07-18/19: WP-406 Ф22, WP-455 Ф11, WP-493 Ф7, none yet on origin).
#   - any dirty tracked file DIFFERS from origin/<branch>          → real uncommitted work,
#     never touched automatically — loud Telegram alert instead, caller must skip pull
#     this round rather than attempt a doomed rebase.
#
# Usage: git-dirty-guard.sh <repo-path> [branch]
# Set GIT_DIRTY_GUARD_TG_ALERTS=false when the caller owns throttled alerting.
# Exit codes: 0 = repo clean, or safely self-healed — caller may proceed with pull.
#             1 = real uncommitted work present, repo mid-rebase/merge, or self-heal
#                 deferred because commit-push.sh holds the commit lock — caller must
#                 NOT pull/rebase this round (WP-484 Ф141, 2026-08-28: this third case
#                 defers rather than races a concurrent commit; retry next cycle).
#             2 = usage/repo error.

set -uo pipefail

REPO="${1:?usage: git-dirty-guard.sh <repo-path> [branch]}"
BRANCH="${2:-}"

AIST_ENV="$HOME/.config/aist/env"
[ -f "$AIST_ENV" ] && { set -a; source "$AIST_ENV"; set +a; }

# Interactive callers need an immediate warning, while periodic supervisors need
# to aggregate repeated failures before notifying. Without this switch the
# supervisor's throttled alert is preceded by one direct alert on every tick.
# The default stays fail-safe for every existing caller; only an explicit false
# value suppresses Telegram delivery. Diagnostics and exit codes are unchanged.
GIT_DIRTY_GUARD_TG_ALERTS="${GIT_DIRTY_GUARD_TG_ALERTS:-true}"

tg_alert() {
  local msg="$1"
  case "$GIT_DIRTY_GUARD_TG_ALERTS" in
    0|false|no|off) return 0 ;;
  esac
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
  curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$msg" > /dev/null || true
}

cd "$REPO" 2>/dev/null || { echo "git-dirty-guard: cannot cd to $REPO" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "git-dirty-guard: $REPO is not a git repo" >&2; exit 2; }

GIT_DIR=$(git rev-parse --git-dir)

# A repo mid-rebase/merge is a different, more serious class of problem (see
# lessons_stale_rebase_merge_recovery.md) — resetting through it would compound the
# mess, not clean it up. Bail out loudly and leave it for manual recovery.
if [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ] || [ -f "$GIT_DIR/MERGE_HEAD" ]; then
  echo "git-dirty-guard: $REPO is mid-rebase/merge — refusing to touch, needs manual recovery" >&2
  tg_alert "🚨 git-dirty-guard: $REPO застрял в rebase/merge — не тронул, нужно ручное восстановление."
  exit 1
fi

[ -n "$BRANCH" ] || BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  echo "git-dirty-guard: detached HEAD in $REPO, refusing" >&2
  exit 2
fi

# Serialize against a concurrent guard run on the same repo. DS-my-strategy is
# deliberately excluded from the shared .iwe-git-ops.lock (see systemd-timers.nix
# pullScript comment) so this gets its own lock, scoped to .git/. mkdir is used
# instead of flock — atomic on POSIX and, unlike flock, available on macOS out of
# the box (this guard runs on both the Mac and the Linux server).
#
# Stale-lock recovery (WP-484 Ф70): a killed caller (e.g. systemd's
# TimeoutStartSec on a hung `git fetch`) cannot run the EXIT trap, so `mkdir`
# alone left the lock permanently held -- every later call then hit the "busy"
# branch and returned exit 0, which every caller reads as "clean, proceed",
# turning the guard into an unconditional rubber stamp with no alert anywhere.
# Same PID+hostname liveness check already used by ledger-append.sh's
# mkdir-fallback lock: only reclaim a lock proven dead on THIS host; a live
# owner, another host, or metadata not yet written is only waited out.
LOCK_DIR="$GIT_DIR/dirty-guard.lock"
LOCK_META="$LOCK_DIR/owner"
HOSTNAME_NOW="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -f "$LOCK_META" ]; then
    OTHER_HOST=$(awk -F= '$1=="host"{print $2}' "$LOCK_META" 2>/dev/null)
    OTHER_PID=$(awk -F= '$1=="pid"{print $2}' "$LOCK_META" 2>/dev/null)
    if [ "$OTHER_HOST" = "$HOSTNAME_NOW" ] && [ -n "$OTHER_PID" ] && ! kill -0 "$OTHER_PID" 2>/dev/null; then
      echo "git-dirty-guard: reclaiming stale lock (pid=$OTHER_PID on $OTHER_HOST no longer running)" >&2
      rm -rf "$LOCK_DIR" 2>/dev/null
    fi
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "git-dirty-guard: lock busy (live owner or unproven), skipping" >&2
    # A caller that proceeds after this result can rebase while another guard
    # is still deciding whether the worktree is safe. Lock contention is a
    # fail-closed condition, not a clean result.
    exit 1
  fi
fi
echo "host=$HOSTNAME_NOW" > "$LOCK_META"
echo "pid=$$" >> "$LOCK_META"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT

if ! git fetch origin "$BRANCH" --quiet 2>/dev/null; then
  echo "git-dirty-guard: fetch failed (offline?) — nothing to check"
  exit 0
fi

if ! git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  echo "git-dirty-guard: no origin/$BRANCH — nothing to check"
  exit 0
fi

# Collect tracked dirty paths (staged or unstaged). Untracked (`??`) is skipped on
# purpose — reset --hard never removes it, and treating it as dirty-to-heal would risk
# discarding genuinely new work.
TRACKED_DIRTY=()
while IFS= read -r -d '' entry; do
  status="${entry:0:2}"
  rest="${entry:3}"
  case "$status" in
    "??") continue ;;
    R*|C*)
      # -z emits "new\0old\0" for renames/copies — `rest` is already the current
      # (destination) path, the one worth diffing against origin. Consume and
      # discard the second field (the pre-rename source path).
      IFS= read -r -d '' _origpath
      TRACKED_DIRTY+=("$rest")
      ;;
    *)
      TRACKED_DIRTY+=("$rest")
      ;;
  esac
done < <(git status --porcelain -z)

if [ "${#TRACKED_DIRTY[@]}" -eq 0 ]; then
  echo "git-dirty-guard: clean (or untracked-only) — nothing to heal"
  exit 0
fi

DIFFERING=()
for f in "${TRACKED_DIRTY[@]}"; do
  if ! git diff --quiet "origin/$BRANCH" -- "$f" 2>/dev/null; then
    DIFFERING+=("$f")
  fi
done

# WP-484 Ф141 (2026-08-28, peer-session with Kimi+Codex; cold-review found 2
# Critical in the first pass, both fixed here): commit-push.sh's own lock
# (DS_COMMIT_LOCK_FILE) guards its commit phase but this guard's ancestry
# check below has no way to see it — a commit landing between the ancestry
# check and the reset raced straight through and got rolled back (live
# incident 2026-08-25, recovered by hand via cherry-pick). Reusing
# commit-push.sh's own lock file (same default resolution: IWE_ROOT falls back
# to $HOME/IWE exactly like commit-push.sh does) closes that window instead of
# adding a second, uncoordinated lock.
#
# Fixed FD (8), not `exec {VAR}>...`: this repo's callers invoke this guard
# via bare `bash "$GUARD" ...` (iwe-safe-pull.sh, day-open-pipeline.sh,
# week-open-day-section-patch.sh), so the interpreter is whatever `bash`
# resolves to in the CALLER's PATH — on this machine most launchd jobs still
# resolve to macOS's bundled bash 3.2, and the `{fd}>` dynamic-fd form is a
# bash 4.1+ feature. Under 3.2 it's not a soft failure caught by `if`, it's a
# parse-time abort of the whole script (same bash-3.2-on-macOS class already
# called out in session-guard.sh's own comments) — the exact self-heal path
# this file exists for would go dark on every scheduled run.
#
# `command -v flock` checked explicitly: without it, a missing `flock` binary
# (already a recurring failure mode elsewhere in this codebase — see
# ledger-append.sh's own guard for the same binary) returns 127, which
# `! flock ...` cannot tell apart from "lock genuinely held" — self-heal would
# silently and permanently disable itself instead of degrading loudly.
#
# Busy lock -> exit 1, not 0: the file's own contract above says 0 means
# "clean, or safely self-healed" — a skipped cycle leaves the tree exactly as
# dirty as it started, so callers (iwe-safe-pull.sh etc.) must see the same
# "do not pull this round" signal as the real-uncommitted-work case, not a
# false "proceed".
#
# Gated on is_ds_repo_by_origin (round-2 cold-review, WP-484 Ф141): this guard
# runs against ANY repo (iwe-safe-pull.sh's Pull-on-Touch calls it for
# whatever repo a session first touches), but DS_COMMIT_LOCK_FILE is only ever
# taken by commit-push.sh for DS-my-strategy itself
# (commit-push.sh:_acquire_commit_lock, same is_ds_repo_by_origin gate) —
# without this check, a commit landing in DS-my-strategy would make an
# unrelated repo's self-heal falsely defer with a misleading "commit-push
# держит блокировку" message. Missing publish-gate.sh (non-DS-my-strategy
# checkout of this repo, or a template install without it) -> skip the whole
# lock dance, same as before this phase.
DS_COMMIT_LOCK_FILE="${DS_COMMIT_LOCK_FILE:-${IWE_ROOT:-$HOME/IWE}/.claude/state/ds-commit.lock}"
PUBLISH_GATE_LIB="${IWE_ROOT:-$HOME/IWE}/DS-my-strategy/scripts/lib/publish-gate.sh"
if [ -f "$PUBLISH_GATE_LIB" ] && . "$PUBLISH_GATE_LIB" && is_ds_repo_by_origin "$REPO"; then
  if ! command -v flock >/dev/null 2>&1; then
    echo "git-dirty-guard: flock недоступен — продолжаю без блокировки коммит-скрипта" >&2
  elif [ ! -d "$(dirname "$DS_COMMIT_LOCK_FILE")" ]; then
    echo "git-dirty-guard: каталог для $DS_COMMIT_LOCK_FILE не существует — продолжаю без блокировки" >&2
  elif exec 8>"$DS_COMMIT_LOCK_FILE" 2>/dev/null; then
    if ! flock -n 8; then
      echo "git-dirty-guard: commit-push держит блокировку записи — self-heal отложен до следующего цикла, дерево остаётся как есть" >&2
      exit 1
    fi
  else
    echo "git-dirty-guard: lock-файл $DS_COMMIT_LOCK_FILE недоступен — продолжаю без блокировки" >&2
  fi
fi

# Cold-review finding (2026-07-19), confirmed live: dirty-file content matching origin is
# NOT sufficient to make `git reset --hard` safe. Reset also moves the branch ref itself,
# so an unpushed local commit — the exact call pattern strategist.sh routes through this
# guard for — gets silently orphaned (and any file unique to it deleted) even though every
# currently-dirty file happened to be a harmless stale mirror. Ancestry, not dirty-file
# content, is the real safety condition for a hard reset.
UNPUSHED=false
git merge-base --is-ancestor HEAD "origin/$BRANCH" 2>/dev/null || UNPUSHED=true

if [ "${#DIFFERING[@]}" -eq 0 ] && [ "$UNPUSHED" = "false" ]; then
  echo "git-dirty-guard: ${#TRACKED_DIRTY[@]} dirty file(s), all byte-identical to origin/$BRANCH — stale mirror, self-healing"
  git reset --hard "origin/$BRANCH" >/dev/null
  tg_alert "🩹 git-dirty-guard: $REPO самовосстановился (${#TRACKED_DIRTY[@]} устаревших файлов сброшено на origin/$BRANCH, содержимое не менялось)."
  exit 0
fi

if [ "$UNPUSHED" = "true" ]; then
  echo "git-dirty-guard: HEAD has commit(s) origin/$BRANCH doesn't have — self-heal would orphan them, not touching" >&2
  tg_alert "🚨 git-dirty-guard: $REPO — есть незапушенные коммиты, self-heal пропущен (не тронул). Нужен pull/push вручную."
  exit 1
fi

echo "git-dirty-guard: ${#DIFFERING[@]} file(s) genuinely differ from origin/$BRANCH — NOT touching, real work present:" >&2
printf '  %s\n' "${DIFFERING[@]}" >&2
LIST=$(printf '%s, ' "${DIFFERING[@]:0:5}")
LIST="${LIST%, }"
tg_alert "🚨 git-dirty-guard: $REPO — ${#DIFFERING[@]} файл(ов) с реальными несохранёнными правками (не тронул): $LIST. Pull пропущен, нужна ручная проверка."
exit 1
