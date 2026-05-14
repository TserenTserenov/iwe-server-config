#!/bin/bash
# iwe-orz-tracker.sh
# see DP.SC.020, WP-214 Ф7.2
# Stop-хук: детектирует завершение ОРЗ-протоколов в сессии и эмитит события в event-gateway.
#
# Детектируемые события:
#   week_plan_closed          — /week-close завершён
#   month_plan_closed         — /month-close завершён
#   strategy_session_completed — /strategy-session завершена
#   knowledge_extracted       — /ke завершён (Knowledge Extraction)
#   wp_closed                 — РП закрыт в эту сессию
#   iwe_session               — сессия ≥15 мин (WakaTime-прокси)
#
# Принципы:
#   - Консервативный (лучше пропустить, чем ложно сработать)
#   - Идемпотентен (external_id = event_type + session_id)
#   - Non-blocking (exit 0 всегда)

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
[ "$HOOK_EVENT" != "Stop" ] && exit 0

TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

[ -z "$SESSION_ID" ] && exit 0
[ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ] && exit 0

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
EMIT="$IWE_ROOT/.claude/lib/iwe_event_emit.sh"
[ ! -f "$EMIT" ] && exit 0
chmod +x "$EMIT" 2>/dev/null || true

# Извлечь текст агента из транскрипта (последние assistant-сообщения)
AGENT_TEXT=$(jq -r '
  select(.role == "assistant")
  | if (.content | type) == "array" then
      .content[] | select(.type == "text") | .text
    elif (.content | type) == "string" then
      .content
    else empty
    end
' "$TRANSCRIPT_PATH" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tail -c 4000)

HUMAN_TEXT=$(jq -r '
  select(.role == "user")
  | if (.content | type) == "array" then
      .content[] | select(.type == "text") | .text
    elif (.content | type) == "string" then
      .content
    else empty
    end
' "$TRANSCRIPT_PATH" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tail -c 2000)

ALL_TEXT="${AGENT_TEXT} ${HUMAN_TEXT}"

# Проект из CWD
PROJECT=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  PROJECT=$(cd "$CWD" && git config --local remote.origin.url 2>/dev/null | sed 's#.*/\([^.]*\)\.git#\1#' || basename "$CWD")
fi

TS_SUFFIX=$(date +%Y%m%dT%H%M)

# ── ДЕТЕКТОР: week_plan_closed ──────────────────────────────────────────────
# Паттерн: упоминание "week close" / "неделя закрыта" / "week-close" в тексте агента
if echo "$AGENT_TEXT" | grep -qE \
  '(week.?close|неделя закрыта|week close завершён|week_plan_closed|закрытие недели.*(done|выполнено|✅)|протокол.*week.close.*(done|pass|✅))'; then

  PAYLOAD=$(python3 -c "
import json
print(json.dumps({'session_id': '${SESSION_ID}', 'project': '${PROJECT}', 'source': 'week-close-skill'}))
" 2>/dev/null || echo '{}')
  "$EMIT" "week_plan_closed" "${SESSION_ID}-${TS_SUFFIX}" "$PAYLOAD"
fi

# ── ДЕТЕКТОР: month_plan_closed ────────────────────────────────────────────
if echo "$AGENT_TEXT" | grep -qE \
  '(month.?close|месяц закрыт|month close завершён|закрытие месяца.*(done|выполнено|✅)|протокол.*month.close.*(done|pass|✅))'; then

  PAYLOAD=$(python3 -c "
import json
import datetime
print(json.dumps({'session_id': '${SESSION_ID}', 'month': datetime.date.today().strftime('%Y-%m'), 'source': 'month-close-skill'}))
" 2>/dev/null || echo '{}')
  "$EMIT" "month_plan_closed" "${SESSION_ID}-${TS_SUFFIX}" "$PAYLOAD"
fi

# ── ДЕТЕКТОР: strategy_session_completed ──────────────────────────────────
if echo "$AGENT_TEXT" | grep -qE \
  '(strategy.?session.*(завершена|done|complete)|стратег.*сессия.*(закрыта|завершена)|strategy session.*(✅|pass)|weekplan.*(обновлён|создан|✅))'; then

  PAYLOAD=$(python3 -c "
import json
print(json.dumps({'session_id': '${SESSION_ID}', 'project': '${PROJECT}', 'source': 'strategy-session-skill'}))
" 2>/dev/null || echo '{}')
  "$EMIT" "strategy_session_completed" "${SESSION_ID}-${TS_SUFFIX}" "$PAYLOAD"
fi

# ── ДЕТЕКТОР: knowledge_extracted ─────────────────────────────────────────
# Паттерн: "Capture:" в тексте агента (KE-маркер из протокола работы)
KE_COUNT=$(echo "$AGENT_TEXT" | grep -c "capture:" 2>/dev/null || echo "0")
if [ "$KE_COUNT" -gt 0 ]; then
  # Извлечь домен (куда → pack/memory/claude.md)
  DOMAIN=$(echo "$AGENT_TEXT" | grep -o "capture:.*→.*" | head -1 | sed 's/capture://;s/^[[:space:]]*//' | cut -c1-80 || echo "unknown")

  PAYLOAD=$(python3 -c "
import json
print(json.dumps({'session_id': '${SESSION_ID}', 'ke_count': ${KE_COUNT}, 'domain': '${DOMAIN}', 'project': '${PROJECT}'}))
" 2>/dev/null || echo '{}')
  "$EMIT" "knowledge_extracted" "${SESSION_ID}-${TS_SUFFIX}" "$PAYLOAD"
fi

# ── ДЕТЕКТОР: wp_closed ───────────────────────────────────────────────────
# Паттерн: явное закрытие РП (WP-NNN done/closed/✅/закрыт в тексте агента)
# Эмитит по одному событию на WP-номер (external_id per-wp → идемпотентно).
WP_CLOSED_NUMS=$(echo "$AGENT_TEXT" | grep -oE "wp-[0-9]+" | \
  while read -r WP_TAG; do
    NUM=$(echo "$WP_TAG" | grep -oE "[0-9]+")
    # Проверяем: рядом с этим тегом есть маркер закрытия?
    CONTEXT=$(echo "$AGENT_TEXT" | grep -oP "(?:wp-${NUM}|рп-${NUM}).{0,40}" 2>/dev/null | head -3)
    if echo "$CONTEXT" | grep -qiE "(done|closed|закрыт|✅|завершён|завершен|выполнен|complete)"; then
      echo "$NUM"
    fi
  done | sort -un | head -10)

for WP_NUM_C in $WP_CLOSED_NUMS; do
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({'wp_number': int('${WP_NUM_C}'), 'session_id': '${SESSION_ID}', 'project': '${PROJECT}'}))
" 2>/dev/null || echo '{}')
  "$EMIT" "wp_closed" "wp-${WP_NUM_C}" "$PAYLOAD"
done

# ── ДЕТЕКТОР: day_open ───────────────────────────────────────────────────
# Паттерн: DayPlan YYYY-MM-DD.md существует в DS-my-strategy/current/
# external_id = day-open-YYYY-MM-DD → идемпотентно (один per day).
TODAY=$(date +%Y-%m-%d)
DAYPLAN_PATH="$IWE_ROOT/DS-my-strategy/current/DayPlan $TODAY.md"
if [ -f "$DAYPLAN_PATH" ]; then
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({'date': '${TODAY}', 'session_id': '${SESSION_ID}', 'source': 'day-open-skill'}))
" 2>/dev/null || echo '{}')
  "$EMIT" "day_open" "day-open-${TODAY}" "$PAYLOAD"
fi

# ── ДЕТЕКТОР: day_close ───────────────────────────────────────────────────
# Паттерн 1: текст агента содержит маркеры закрытия дня
# Паттерн 2: git-commit в DS-my-strategy сегодня упоминает DayPlan/day-close
# external_id = day-close-YYYY-MM-DD → идемпотентно (один per day).
# payload: wakatime_h + multiplier из текста агента.
TODAY="${TODAY:-$(date +%Y-%m-%d)}"
DAYCLOSE_TRIGGERED=false
if echo "$AGENT_TEXT" | grep -qiE '(день закрыт|day.?close завершён|day.?close.*✅|день закрыт.*✅|dayplan.*закрыт|закрытие дня.*✅|day close.*done|verify.*day.?close|чеклист.*day.?close)'; then
  DAYCLOSE_TRIGGERED=true
fi
DS_STRATEGY="$IWE_ROOT/DS-my-strategy"
if ! $DAYCLOSE_TRIGGERED && [ -d "$DS_STRATEGY/.git" ]; then
  RECENT=$(git -C "$DS_STRATEGY" log --since="today 00:00" --oneline 2>/dev/null | \
    grep -iE "(day.?close|dayplan|закрытие дня)" | head -1)
  [ -n "$RECENT" ] && DAYCLOSE_TRIGGERED=true
fi
if $DAYCLOSE_TRIGGERED; then
  WAKATIME_H=$(echo "$AGENT_TEXT" | grep -oE '[0-9]+ ч [0-9]+ мин' | head -1 | \
    awk '{h=$1; m=$3; printf "%.2f", h + m/60}' 2>/dev/null || echo "0")
  MULTIPLIER=$(echo "$AGENT_TEXT" | grep -oE '~[0-9]+\.[0-9]+x' | head -1 | \
    grep -oE '[0-9]+\.[0-9]+' || echo "0")
  TODAY=$(date +%Y-%m-%d)
  PAYLOAD=$(python3 -c "
import json
wh = float('${WAKATIME_H}') if '${WAKATIME_H}' else 0.0; mx = float('${MULTIPLIER}') if '${MULTIPLIER}' else 0.0
print(json.dumps({'wakatime_h': wh, 'multiplier': mx, 'date': '${TODAY}', 'session_id': '${SESSION_ID}', 'source': 'day-close-skill'}))
" 2>/dev/null || echo '{}')
  "$EMIT" "day_close" "day-close-${TODAY}" "$PAYLOAD"
fi

# ── ДЕТЕКТОР: iwe_session (всегда — базовое событие сессии) ───────────────
# Каждый Stop = одна Claude Code сессия. Считаем time via transcript timestamps.
FIRST_TS=$(jq -r '.timestamp // empty' "$TRANSCRIPT_PATH" 2>/dev/null | head -1)
LAST_TS=$(jq -r '.timestamp // empty' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1)

DURATION_MIN=0
if [ -n "$FIRST_TS" ] && [ -n "$LAST_TS" ]; then
  FIRST_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${FIRST_TS%%.*}" "+%s" 2>/dev/null || echo "0")
  LAST_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${LAST_TS%%.*}" "+%s" 2>/dev/null || echo "0")
  if [ "$LAST_EPOCH" -gt "$FIRST_EPOCH" ] 2>/dev/null; then
    DURATION_MIN=$(( (LAST_EPOCH - FIRST_EPOCH) / 60 ))
  fi
fi

# Эмитим только если сессия ≥5 мин (убираем однострочники)
if [ "$DURATION_MIN" -ge 5 ] 2>/dev/null; then
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({'session_id': '${SESSION_ID}', 'duration_min': ${DURATION_MIN}, 'project': '${PROJECT}', 'cwd': '${CWD}'}))
" 2>/dev/null || echo '{}')
  "$EMIT" "iwe_session" "${SESSION_ID}" "$PAYLOAD"
fi

exit 0
