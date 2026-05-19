#!/usr/bin/env bash
# day-open-preflight.sh — pre-flight healthcheck для Day Open
# WP-7 ФDay-Open-Hardening
# Возвращает единый JSON: {"calendar":"ok|fail|pending","scout":"ok|fail|pending","triage":"ok|fail|pending"}

set -uo pipefail

# Загрузка Telegram credentials (если доступны)
AIST_ENV="$HOME/.config/aist/env"
if [ -f "$AIST_ENV" ]; then
  set -a
  source "$AIST_ENV"
  set +a
fi

DATE="${1:-$(date +%Y-%m-%d)}"
CONFIG="${2:-$HOME/IWE/DS-my-strategy/exocortex/day-rhythm-config.yaml}"
IWE="${IWE_ROOT:-$HOME/IWE}"

# --- Calendar: server-calendar.sh ---
CALENDAR_STATUS="unknown"
CALENDAR_OUT=$(bash "$IWE/scripts/server-calendar.sh" "$DATE" "$CONFIG" 2>/dev/null || echo "")
if [ -n "$CALENDAR_OUT" ]; then
  if echo "$CALENDAR_OUT" | grep -q "PENDING"; then
    CALENDAR_STATUS="pending"
  elif echo "$CALENDAR_OUT" | grep -qE '\| [0-9]{2}:[0-9]{2} \|'; then
    CALENDAR_STATUS="ok"
  else
    CALENDAR_STATUS="fail"
  fi
else
  CALENDAR_STATUS="fail"
fi

# --- Scout: check backlog + latest log ---
SCOUT_STATUS="unknown"
BACKLOG_FILE="$IWE/DS-agent-workspace/scout/backlog.yaml"
HAS_PENDING=false
if [ -f "$BACKLOG_FILE" ] && grep -q "status: pending" "$BACKLOG_FILE" 2>/dev/null; then
  HAS_PENDING=true
fi

SCOUT_LOG=$(ls -t "$IWE/DS-autonomous-agents/logs/scout-"*.log 2>/dev/null | head -1 || echo "")
if [ -n "$SCOUT_LOG" ]; then
  LOG_DATE=$(basename "$SCOUT_LOG" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo "")
  if [ "$LOG_DATE" = "$DATE" ]; then
    SCOUT_STATUS="ok"
  elif [ "$HAS_PENDING" = "false" ]; then
    # Нет заданий в backlog — отсутствие лога = норма (Scout вышел с NO_TASKS)
    SCOUT_STATUS="ok"
  else
    SCOUT_STATUS="fail"
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
      curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"🚨 Scout silent failure: last log $LOG_DATE (expected $DATE), backlog has pending tasks\"}" > /dev/null
    fi
  fi
else
  if [ "$HAS_PENDING" = "false" ]; then
    SCOUT_STATUS="ok"
  else
    SCOUT_STATUS="fail"
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
      curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"🚨 Scout silent failure: no logs found at all, backlog has pending tasks\"}" > /dev/null
    fi
  fi
fi

# --- Triage: check file ---
TRIAGE_STATUS="unknown"
TRIAGE_FILE="$IWE/DS-agent-workspace/scheduler/feedback-triage/$DATE.md"
if [ -f "$TRIAGE_FILE" ]; then
  TRIAGE_STATUS="ok"
else
  TRIAGE_STATUS="fail"
  YESTERDAY=""
  if date -v-1d +%Y-%m-%d > /dev/null 2>&1; then
    YESTERDAY=$(date -v-1d +%Y-%m-%d)
  else
    YESTERDAY=$(date -d yesterday +%Y-%m-%d)
  fi
  YESTERDAY_FILE="$IWE/DS-agent-workspace/scheduler/feedback-triage/$YESTERDAY.md"
  if [ ! -f "$YESTERDAY_FILE" ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"🚨 Feedback-triage silent failure: no reports since before $YESTERDAY\"}" > /dev/null
  fi
fi

# --- active-wp.md stale check ---
MEMORY_STATUS="ok"
ACTIVE_WP="$IWE/DS-my-strategy/current/active-wp.md"
if [ -f "$ACTIVE_WP" ]; then
  if stat -f%m "$ACTIVE_WP" > /dev/null 2>&1; then
    AGE_DAYS=$(( ( $(date +%s) - $(stat -f%m "$ACTIVE_WP") ) / 86400 ))
  else
    AGE_DAYS=$(( ( $(date +%s) - $(stat -c%Y "$ACTIVE_WP") ) / 86400 ))
  fi
  if [ "$AGE_DAYS" -gt 7 ]; then
    MEMORY_STATUS="stale"
  fi
else
  MEMORY_STATUS="missing"
fi

# Output unified JSON
jq -n \
  --arg calendar "$CALENDAR_STATUS" \
  --arg scout "$SCOUT_STATUS" \
  --arg triage "$TRIAGE_STATUS" \
  --arg memory "$MEMORY_STATUS" \
  '{calendar: $calendar, scout: $scout, triage: $triage, memory: $memory}'
