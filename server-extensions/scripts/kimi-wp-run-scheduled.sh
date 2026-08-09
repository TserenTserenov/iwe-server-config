#!/usr/bin/env bash
# see DP.SC.192, DP.ROLE.086 — WP-487
#
# kimi-wp-run-scheduled.sh <id> — исполнитель отложенного запуска РП.
# Вызывается launchd в заданное время. Шаги:
#   1. прочитать задание из queue.tsv
#   2. session-guard open → preflight (kimi) → headless-запуск агента под таймаутом
#   3. статус (done/failed/timeout) → report.md + queue.tsv
#   4. session-guard close, самоудаление одноразовой задачи launchd
#
# Предохранитель токенов: wall-clock таймаут (perl alarm, default 50 мин) +
# --max-turns у claude. Падение одного РП не влияет на остальную очередь.

set -uo pipefail  # без -e: любой сбой должен завершаться отчётом, а не тихой смертью

ID="${1:-}"
[ -n "$ID" ] || { echo "ERROR: usage: kimi-wp-run-scheduled.sh <id>" >&2; exit 1; }

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
# launchd runs this with a bare environment (no .claude/settings.json injection) —
# without this, IWE_GOVERNANCE_REPO stays unset and session-guard.sh falls back
# to the template default, misfiling sessions into the wrong directory.
# shellcheck source=/dev/null
source "$IWE_ROOT/.claude/lib/iwe-env-bootstrap.sh" || exit 1
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
QUEUE_DIR="$IWE_ROOT/.iwe-runtime/wp-queue"
QUEUE_FILE="$QUEUE_DIR/queue.tsv"
LOG_DIR="$IWE_ROOT/.iwe-runtime/logs/wp-queue"
PLIST="$HOME/Library/LaunchAgents/ai.iwe.wp-queue.$ID.plist"
LABEL="ai.iwe.wp-queue.$ID"
LOG="$LOG_DIR/$ID.log"
REPORT="$LOG_DIR/report.md"

mkdir -p "$LOG_DIR"
cd "$IWE_ROOT" || exit 1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# Sanity check: session-guard.sh writes sessions/open-sessions.log under this
# repo blind — a wrong IWE_GOVERNANCE_REPO would misfile every session record
# with no error. Refuse to proceed into a repo that doesn't look real instead.
if [ ! -f "$IWE_ROOT/$IWE_GOVERNANCE_REPO/docs/WP-REGISTRY.md" ]; then
  log "ERROR: IWE_GOVERNANCE_REPO='$IWE_GOVERNANCE_REPO' does not look like a real governance repo (no docs/WP-REGISTRY.md) — check IWE_GOVERNANCE_REPO in .exocortex.env"
  exit 1
fi

# --- прочитать задание ------------------------------------------------------
ROW=$(grep "^$ID"$'\t' "$QUEUE_FILE" || true)
[ -n "$ROW" ] || { log "ERROR: id $ID not found in queue.tsv"; exit 1; }
WP=$(echo "$ROW" | cut -f3)
AGENT=$(echo "$ROW" | cut -f4)
TIMEOUT_MIN=$(echo "$ROW" | cut -f5)
MAX_TURNS=$(echo "$ROW" | cut -f6)
TIMEOUT_SEC=$(( TIMEOUT_MIN * 60 ))

set_status() {  # set_status <new-status>
  local tmp; tmp=$(mktemp)
  awk -F'\t' -v OFS='\t' -v id="$ID" -v st="$1" '$1==id {$7=st} {print}' "$QUEUE_FILE" > "$tmp" && mv "$tmp" "$QUEUE_FILE"
}

cleanup() {  # выгрузить и удалить одноразовую задачу launchd
  # ВАЖНО: unload собственной задачи посылает SIGTERM текущему процессу —
  # поэтому сначала удаляем plist, unload делаем ПОСЛЕДНИМ действием скрипта.
  rm -f "$PLIST"
  launchctl remove "$LABEL" >/dev/null 2>&1 || true
}

report_line() {  # report_line <status> <note>
  printf -- '- **%s** `%s` — %s via %s: **%s** (%s). Лог: `.iwe-runtime/logs/wp-queue/%s.log`\n' \
    "$(date '+%Y-%m-%d %H:%M')" "$ID" "$WP" "$AGENT" "$1" "$2" "$ID" >> "$REPORT"
}

log "=== scheduled run $ID: $WP via $AGENT (timeout ${TIMEOUT_MIN}m) ==="
set_status running

# bug-2026-07-17-kimi-queue-autostash-conflict-and-orphaned-semaphores п.3:
# sweep_orphaned_semaphores exists in session-guard.sh (audit --cleanup-orphans)
# but nothing called it periodically -- orphaned .open files (dead pid or no
# parseable timestamp) accumulated across a whole night's queue with no
# cleanup between runs. This runner already fires once per queued WP through
# the night, which makes it the natural periodic trigger -- no separate cron
# needed. Best-effort: a sweep failure must not abort this WP's own run.
bash "$IWE_ROOT/scripts/session-guard.sh" audit --cleanup-orphans >>"$LOG" 2>&1 || \
  log "WARN: orphan semaphore sweep failed (non-fatal, continuing)"

# --- dry-run (тестовый режим: не запускает LLM, проверяет launchd+plumbing) ---
if [ "${IWE_WP_QUEUE_DRYRUN:-0}" = "1" ]; then
  log "DRY-RUN: simulating agent run (no LLM call)"
  sleep 2
  set_status done-dryrun
  report_line done-dryrun "dry-run, no LLM call"
  log "=== done: $ID (done-dryrun) ==="
  cleanup  # последнее действие: unload убивает текущий процесс
  exit 0
fi

# --- collision guard: skip if this WP already has an active session --------
# Root cause of 6 failed Claude runs, ночь 17-18.07: scheduled run launched
# while a manual peer-session was already open on the same WP — both edited
# the context file concurrently, burning the turn budget on lock contention
# instead of the actual task. No existing check catches this (session-guard.sh
# open always creates a semaphore, cross-session/cross-agent collision is
# unchecked) — so skip up front instead of paying for a doomed run.
IS_TASK=0
[[ "$WP" =~ ^TASK- ]] && IS_TASK=1
if [ "$IS_TASK" != "1" ]; then
  for f in "$IWE_ROOT/.iwe-runtime/sessions/"*.open; do
    [ -f "$f" ] || continue
    OTHER_WP=$(grep "^wp: " "$f" | head -1 | cut -d' ' -f2-)
    [ "$OTHER_WP" = "$WP" ] || continue
    F_MTIME=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
    F_AGE=$(( $(date +%s) - F_MTIME ))
    [ "$F_AGE" -gt 1800 ] && continue  # older than session-guard's own orphan TTL — stale, ignore
    log "SKIP: $WP already has an active session ($(basename "$f"), age ${F_AGE}s) — avoiding collision"
    set_status skipped-collision
    report_line skipped-collision "active session already open: $(basename "$f")"
    cleanup; exit 0
  done
fi

# --- session-guard open -----------------------------------------------------
if [ "$IS_TASK" = "1" ] || [ "$AGENT" = "codex" ]; then
  # задача без РП или Codex peer pass: housekeeping-сессия (без ORZ, без WP Gate)
  if ! bash "$IWE_ROOT/scripts/session-guard.sh" open --housekeeping "sched-$ID" --agent "$AGENT" >>"$LOG" 2>&1; then
    log "ERROR: session-guard open (housekeeping) failed"
    set_status failed; report_line failed "session-guard open failed"; cleanup; exit 1
  fi
  if [ "$IS_TASK" = "1" ]; then
    [ -f "$QUEUE_DIR/$ID.prompt" ] || { log "ERROR: TASK without prompt file"; set_status failed; report_line failed "TASK without prompt"; bash "$IWE_ROOT/scripts/session-guard.sh" close --housekeeping "sched-$ID" --agent "$AGENT" >>"$LOG" 2>&1; cleanup; exit 1; }
  fi
  PROMPT_FILE="$QUEUE_DIR/$ID.prompt"
elif ! bash "$IWE_ROOT/scripts/session-guard.sh" open \
      --wp "$WP" --task "Scheduled run ($ID)" --slug "sched-$ID" \
      --files "$IWE_GOVERNANCE_REPO/inbox/$WP/$WP.md" --agent "$AGENT" >>"$LOG" 2>&1; then
  log "ERROR: session-guard open failed"
  set_status failed; report_line failed "session-guard open failed"; cleanup; exit 1
fi

# --- промпт -----------------------------------------------------------------
if [ "$IS_TASK" != "1" ] && [ "$AGENT" != "codex" ]; then
PROMPT_FILE="$QUEUE_DIR/$ID.prompt"
if [ ! -f "$PROMPT_FILE" ]; then
  PROMPT_FILE=$(mktemp)
  # bug-2026-07-17-...-orphaned-semaphores п.4: session-guard.sh open (above)
  # already computed and scaffolded this exact path -- the old prompt only
  # said "запиши итог в ORZ сессии" with no path, so the agent picked its own
  # filename by habit, diverging from the scaffold (14 empty scaffolds found
  # dead in one night's queue, real ORZ content landing elsewhere). Same
  # basename formula session-guard.sh itself uses (now_month/now_date-slug.md,
  # date-prefix stripped from slug if already present) -- computed here
  # independently rather than parsed out of the open log, so a log-format
  # change can't silently desync the two again.
  ORZ_SLUG="sched-$ID"
  ORZ_PATH="$IWE_GOVERNANCE_REPO/sessions/$(date '+%Y-%m')/$(date '+%Y-%m-%d')-${ORZ_SLUG}.md"
  cat > "$PROMPT_FILE" <<EOF
Автономный запуск по расписанию (планировщик WP-487, DP.SC.192). WP Gate для этого РП уже согласован пилотом заранее — Ритуал согласования не требуется, работай сразу.

Задача: выполни рабочий продукт $WP. Первым делом прочитай контекст: ~/IWE/$IWE_GOVERNANCE_REPO/inbox/$WP/$WP.md. Иерархия доверия: код → документы → WP context.

Правила автономного прогона:
- Работай только по этому РП, не начинай других задач.
- Если заблокирован решением пилота — запиши blocker в frontmatter контекст-файла РП ($IWE_GOVERNANCE_REPO/inbox/$WP/$WP.md) и завершись, не жди.
- Git: стейджь только конкретные свои файлы (никаких git add -A/-u/.), trailer Co-Authored-By по своему агенту.
- Не начинай операций, которые могут не уложиться в оставшееся время — тебя принудительно завершат по таймауту.
- По завершении обнови статус фаз в frontmatter контекст-файла РП и запиши краткий итог в ORZ-файл, который уже создан по пути: $ORZ_PATH (не создавай новый файл с другим именем — редактируй именно этот).
EOF
fi
fi  # IS_TASK

# --- запуск агента под таймаутом --------------------------------------------
RC=0
case "$AGENT" in
  kimi)
    KIMI_BIN="$(command -v kimi 2>/dev/null || true)"
    if [ -z "$KIMI_BIN" ]; then
      for c in "$HOME/Library/Application Support/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi"; do
        [ -x "$c" ] && KIMI_BIN="$c" && break
      done
    fi
    if [ -z "$KIMI_BIN" ]; then
      log "ERROR: kimi binary not found"
      set_status failed; report_line failed "kimi binary not found"
      bash "$IWE_ROOT/scripts/session-guard.sh" close --agent "$AGENT" >>"$LOG" 2>&1
      cleanup; exit 1
    fi
    # preflight: проверяет, что сессия открыта (мы только что открыли)
    bash "$IWE_ROOT/scripts/kimi-standalone-preflight.sh" >>"$LOG" 2>&1 || log "WARN: preflight non-zero, continuing"
    # OAuth-refresh serialization — same shared lock resource and mkdir-based
    # mechanism as kimi-peer-adapter.sh (peer-session 2026-08-04-08-wp7-f44-
    # sandbox-review): must be the SAME lock path, not just the same technique
    # — a scheduled run and a peer-adapter call racing on Kimi's OAuth refresh
    # token only actually serialize against each other if they contend for one
    # identical resource. The prior `lockf` binary is BSD/macOS-only and was
    # silently skipped when absent (e.g. Linux); no external dependency here.
    OAUTH_LOCK_DIR="${IWE_PEER_LOCK_DIR:-/tmp/kimi-peer-locks}/kimi-oauth-refresh.lockdir"
    acquire_oauth_lock() {
      mkdir -p "$(dirname "$OAUTH_LOCK_DIR")" 2>/dev/null
      local waited=0
      while true; do
        if mkdir "$OAUTH_LOCK_DIR" 2>/dev/null; then
          echo "$$" > "$OAUTH_LOCK_DIR/pid" 2>/dev/null
          return 0
        fi
        local holder_pid
        holder_pid=$(cat "$OAUTH_LOCK_DIR/pid" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
          rm -rf "$OAUTH_LOCK_DIR" 2>/dev/null
        fi
        [ "$waited" -ge 90 ] && return 1
        sleep 1
        waited=$((waited + 1))
      done
    }
    if ! acquire_oauth_lock; then
      log "ERROR: OAuth refresh lock busy after 90s — another Kimi process is mid-refresh on $OAUTH_LOCK_DIR"
      set_status failed; report_line failed "OAuth refresh lock busy after 90s"
      bash "$IWE_ROOT/scripts/session-guard.sh" close --agent "$AGENT" >>"$LOG" 2>&1
      cleanup; exit 1
    fi
    log "starting kimi (timeout ${TIMEOUT_SEC}s, max-steps 100)"
    perl -e 'my $t=shift; alarm $t; exec @ARGV' -- "$TIMEOUT_SEC" \
      "$KIMI_BIN" --quiet --yolo --max-steps-per-turn "${IWE_WP_QUEUE_MAX_STEPS:-100}" < "$PROMPT_FILE" >>"$LOG" 2>&1
    RC=$?
    rm -rf "$OAUTH_LOCK_DIR" 2>/dev/null
    ;;
  claude)
    CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
    if [ -z "$CLAUDE_BIN" ]; then
      log "ERROR: claude binary not found"
      set_status failed; report_line failed "claude binary not found"
      bash "$IWE_ROOT/scripts/session-guard.sh" close --agent "$AGENT" >>"$LOG" 2>&1
      cleanup; exit 1
    fi
    log "starting claude (timeout ${TIMEOUT_SEC}s, max-turns $MAX_TURNS)"
    perl -e 'my $t=shift; alarm $t; exec @ARGV' -- "$TIMEOUT_SEC" \
      "$CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" --max-turns "$MAX_TURNS" --dangerously-skip-permissions >>"$LOG" 2>&1
    RC=$?
    ;;
  codex)
    WP502_SCRIPT="$IWE_ROOT/$IWE_GOVERNANCE_REPO/scripts/wp502-codex-peer-pass.sh"
    if [ ! -x "$WP502_SCRIPT" ]; then
      log "ERROR: wp502-codex-peer-pass.sh not found/executable: $WP502_SCRIPT"
      set_status failed; report_line failed "wp502 script missing"
      bash "$IWE_ROOT/scripts/session-guard.sh" close --housekeeping "sched-$ID" --agent "$AGENT" >>"$LOG" 2>&1 || true
      cleanup; exit 1
    fi
    if [ ! -f "$PROMPT_FILE" ]; then
      log "ERROR: codex run requires custom prompt (task description)"
      set_status failed; report_line failed "codex missing prompt"
      bash "$IWE_ROOT/scripts/session-guard.sh" close --housekeeping "sched-$ID" --agent "$AGENT" >>"$LOG" 2>&1 || true
      cleanup; exit 1
    fi
    TASK_TEXT=$(cat "$PROMPT_FILE")
    log "starting codex wp502 peer pass (timeout ${TIMEOUT_SEC}s)"
    perl -e 'my $t=shift; alarm $t; exec @ARGV' -- "$TIMEOUT_SEC" \
      bash "$WP502_SCRIPT" "$WP" "$TASK_TEXT" >>"$LOG" 2>&1
    RC=$?
    ;;
  *)
    log "ERROR: unknown agent $AGENT"; RC=1 ;;
esac

# --- результат ---------------------------------------------------------------
case "$RC" in
  0)   STATUS=done;    NOTE="exit 0" ;;
  142|124) STATUS=timeout; NOTE="killed by ${TIMEOUT_MIN}m timeout (exit $RC)" ;;
  *)   STATUS=failed;  NOTE="exit $RC" ;;
esac
log "finished: $STATUS (exit $RC)"

# bug-2026-07-17-...-orphaned-semaphores п.1: the agent commits its own work as
# part of executing the WP, but this runner never independently verified the
# push actually landed -- the incident it caused (6 real unpushed commits
# after a night's queue) went unnoticed until a manual `git status` the next
# morning, because RC=0 from the agent binary says nothing about whether its
# own push succeeded. Defense-in-depth, not a replacement for the agent's own
# push: if commits are still ahead of upstream after the run, attempt one
# explicit push and log the outcome either way, so a silent push failure shows
# up in the SAME log this runner already writes instead of surfacing days
# later as a "why isn't this on GitHub" investigation.
GOV_REPO_DIR="$IWE_ROOT/$IWE_GOVERNANCE_REPO"
if [ "$IS_TASK" != "1" ] && [ -d "$GOV_REPO_DIR/.git" ]; then
  AHEAD=$(git -C "$GOV_REPO_DIR" rev-list "@{u}.." --count 2>/dev/null || echo "")
  if [ -n "$AHEAD" ] && [ "$AHEAD" -gt 0 ]; then
    log "push-check: $AHEAD unpushed commit(s) in $IWE_GOVERNANCE_REPO after agent run — pushing explicitly"
    if git -C "$GOV_REPO_DIR" push >>"$LOG" 2>&1; then
      log "push-check: OK ($AHEAD commit(s) pushed)"
    else
      log "push-check: FAILED — $AHEAD commit(s) still unpushed, needs manual attention"
    fi
  else
    log "push-check: up to date with upstream (or no tracking branch), nothing to push"
  fi
fi

set_status "$STATUS"
report_line "$STATUS" "$NOTE"

# --- session-guard close + самоудаление задачи -------------------------------
if [ "$IS_TASK" = "1" ] || [ "$AGENT" = "codex" ]; then
  bash "$IWE_ROOT/scripts/session-guard.sh" close --housekeeping "sched-$ID" --agent "$AGENT" >>"$LOG" 2>&1 || log "WARN: session-guard close non-zero"
else
  bash "$IWE_ROOT/scripts/session-guard.sh" close --agent "$AGENT" >>"$LOG" 2>&1 || log "WARN: session-guard close non-zero"
fi
[ -f "$QUEUE_DIR/$ID.prompt" ] && rm -f "$QUEUE_DIR/$ID.prompt"
log "=== done: $ID ($STATUS) ==="
cleanup  # последнее действие: unload убивает текущий процесс
exit 0
