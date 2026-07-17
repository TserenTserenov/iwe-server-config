#!/usr/bin/env bash
# see DP.SC.192, DP.ROLE.086 — WP-487
#
# kimi-wp-queue.sh — постановка РП в очередь отложенного запуска (launchd, будит Мак из сна).
#
# Usage:
#   kimi-wp-queue.sh add "2026-07-14 11:00" WP-486 kimi [--timeout 50] [--max-turns 40] [--prompt "..."]
#   kimi-wp-queue.sh add "11:00" WP-486 claude          # HH:MM = ближайшее такое время (сегодня или завтра)
#   kimi-wp-queue.sh add "21:00" TASK-transcribe-m4 kimi --prompt "..."  # задача без РП (housekeeping)
#   kimi-wp-queue.sh list
#   kimi-wp-queue.sh remove <id>
#   kimi-wp-queue.sh report
#
# Очередь:  .iwe-runtime/wp-queue/queue.tsv
# Логи:     .iwe-runtime/logs/wp-queue/
# Задачи:   ~/Library/LaunchAgents/ai.iwe.wp-queue.<id>.plist (одноразовые, самоудаляются)

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
QUEUE_DIR="$IWE_ROOT/.iwe-runtime/wp-queue"
QUEUE_FILE="$QUEUE_DIR/queue.tsv"
LOG_DIR="$IWE_ROOT/.iwe-runtime/logs/wp-queue"
PLIST_DIR="$HOME/Library/LaunchAgents"
RUNNER="$IWE_ROOT/scripts/kimi-wp-run-scheduled.sh"
LABEL_PREFIX="ai.iwe.wp-queue"

mkdir -p "$QUEUE_DIR" "$LOG_DIR" "$PLIST_DIR"
[ -f "$QUEUE_FILE" ] || printf 'id\tdatetime\twp\tagent\ttimeout_min\tmax_turns\tstatus\tlog\n' > "$QUEUE_FILE"

fail() { echo "ERROR: $*" >&2; exit 1; }

# --- add -------------------------------------------------------------------
cmd_add() {
  local dt="${1:-}" wp="${2:-}" agent="${3:-}"; shift 3 2>/dev/null || fail "usage: add <\"YYYY-MM-DD HH:MM\"|\"HH:MM\"> <WP-NNN> <kimi|claude> [opts]"
  [ -n "$dt" ] && [ -n "$wp" ] && [ -n "$agent" ] || fail "usage: add <datetime> <WP-NNN> <kimi|claude> [opts]"

  local timeout_min=50 max_turns=40 prompt="" dry_run=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout)   timeout_min="$2"; shift 2 ;;
      --max-turns) max_turns="$2"; shift 2 ;;
      --prompt)    prompt="$2"; shift 2 ;;
      --dry-run)   dry_run=1; shift ;;
      *) fail "unknown option: $1" ;;
    esac
  done

  [[ "$wp" =~ ^WP-[0-9]+$ ]] || [[ "$wp" =~ ^TASK-[a-z0-9-]+$ ]] || fail "wp must look like WP-NNN or TASK-<slug>, got: $wp"
  case "$agent" in kimi|claude) ;; *) fail "agent must be kimi or claude, got: $agent" ;; esac
  [[ "$timeout_min" =~ ^[0-9]+$ ]] || fail "--timeout must be minutes (integer)"
  if [[ "$wp" =~ ^TASK- ]]; then
    [ -n "$prompt" ] || fail "TASK-<slug> requires --prompt (no WP context to read)"
  else
    [ -f "$IWE_ROOT/DS-my-strategy/inbox/$wp/$wp.md" ] || echo "WARN: context file DS-my-strategy/inbox/$wp/$wp.md not found — runner will stop at WP Gate." >&2
  fi

  # Нормализация времени → epoch + компоненты
  local epoch month day hour minute
  if [[ "$dt" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
    # HH:MM — ближайшее такое время
    local today_epoch
    today_epoch=$(date -j -f "%Y-%m-%d %H:%M" "$(date +%Y-%m-%d) $dt" +%s 2>/dev/null) || fail "bad time: $dt"
    if [ "$today_epoch" -le "$(date +%s)" ]; then
      epoch=$(date -j -v+1d -f "%s" "$today_epoch" +%s)
    else
      epoch="$today_epoch"
    fi
  else
    epoch=$(date -j -f "%Y-%m-%d %H:%M" "$dt" +%s 2>/dev/null) || fail "bad datetime: $dt (use \"YYYY-MM-DD HH:MM\" or \"HH:MM\")"
  fi
  [ "$epoch" -gt "$(date +%s)" ] || fail "datetime is in the past: $(date -j -f %s "$epoch" '+%Y-%m-%d %H:%M')"
  month=$(date -j -f %s "$epoch" +%-m); day=$(date -j -f %s "$epoch" +%-d)
  hour=$(date -j -f %s "$epoch" +%-H);  minute=$(date -j -f %s "$epoch" +%-M)
  local dt_norm; dt_norm=$(date -j -f %s "$epoch" '+%Y-%m-%d %H:%M')

  local id; id="$(echo "$wp" | tr '[:upper:]' '[:lower:]')-$(date -j -f %s "$epoch" +%Y%m%d-%H%M)"
  grep -q "^$id"$'\t' "$QUEUE_FILE" && fail "already queued: $id"

  local plist="$PLIST_DIR/$LABEL_PREFIX.$id.plist"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL_PREFIX.$id</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$RUNNER</string>
    <string>$id</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Month</key><integer>$month</integer>
    <key>Day</key><integer>$day</integer>
    <key>Hour</key><integer>$hour</integer>
    <key>Minute</key><integer>$minute</integer>
  </dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>IWE_WP_QUEUE_DRYRUN</key>
    <string>$dry_run</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/$id.launchd.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/$id.launchd.log</string>
</dict>
</plist>
EOF

  launchctl unload "$plist" >/dev/null 2>&1 || true
  launchctl load -w "$plist" || fail "launchctl load failed for $plist"

  printf '%s\t%s\t%s\t%s\t%s\t%s\tpending\t%s\n' \
    "$id" "$dt_norm" "$wp" "$agent" "$timeout_min" "$max_turns" "$LOG_DIR/$id.log" >> "$QUEUE_FILE"
  # Кастомный промпт храним отдельным файлом (TSV держим плоским)
  [ -n "$prompt" ] && printf '%s' "$prompt" > "$QUEUE_DIR/$id.prompt"

  echo "OK: queued $id — $wp via $agent at $dt_norm (timeout ${timeout_min}m, max-turns $max_turns)"
  echo "    plist: $plist"
}

# --- list ------------------------------------------------------------------
cmd_list() {
  echo "=== WP queue ($QUEUE_FILE) ==="
  column -t -s $'\t' < "$QUEUE_FILE"
  echo
  echo "=== Loaded launchd jobs ==="
  launchctl list | grep "$LABEL_PREFIX" || echo "(none loaded)"
}

# --- remove ----------------------------------------------------------------
cmd_remove() {
  local id="${1:-}"; [ -n "$id" ] || fail "usage: remove <id>"
  local plist="$PLIST_DIR/$LABEL_PREFIX.$id.plist"
  if [ -f "$plist" ]; then
    launchctl unload "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
  fi
  if grep -q "^$id"$'\t' "$QUEUE_FILE"; then
    local tmp; tmp=$(mktemp)
    awk -F'\t' -v OFS='\t' -v id="$id" '$1==id {$7="removed"} {print}' "$QUEUE_FILE" > "$tmp" && mv "$tmp" "$QUEUE_FILE"
    echo "OK: removed $id"
  else
    echo "WARN: $id not found in queue (plist cleaned if existed)"
  fi
}

# --- report ----------------------------------------------------------------
cmd_report() {
  local f="$LOG_DIR/report.md"
  [ -f "$f" ] && cat "$f" || echo "(no report yet — $f)"
}

case "${1:-}" in
  add)    shift; cmd_add "$@" ;;
  list)   cmd_list ;;
  remove) shift; cmd_remove "$@" ;;
  report) cmd_report ;;
  *) echo "usage: kimi-wp-queue.sh {add|list|remove|report}" >&2; exit 1 ;;
esac
