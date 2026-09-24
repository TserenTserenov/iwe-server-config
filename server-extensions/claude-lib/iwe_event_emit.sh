#!/bin/bash
# iwe_event_emit.sh
# see DP.SC.020 (event-gateway contract)
# Универсальный эмиттер IWE-событий в event-gateway.
# Источник: source="iwe-hooks" (в ALLOWED_SOURCES event-gateway).
#
# Usage:
#   iwe_event_emit.sh <event_type> <external_id_suffix> [json_payload]
#
# Args:
#   event_type         — строка (wp_closed, week_plan_closed, ...)
#   external_id_suffix — уникальный суффикс (session_id, commit_hash, ...)
#   json_payload       — опциональный JSON объект (строка), по умолчанию {}
#
# Exit: 0 всегда (non-blocking, ошибки в stderr) — кроме IWE_EMIT_SYNC=1 (см. ниже).
#
# Env:
#   IWE_EVENT_GATEWAY_URL  — URL event-gateway (default: https://event-gateway.aisystant.workers.dev)
#   IWE_OWNER_ORY_UUID     — Ory UUID владельца IWE (для account_id резолвинга в gateway)
#   IWE_EMIT_SYNC          — "1": подтверждённая доставка. POST выполняется СИНХРОННО
#                            (вызывающий блокируется до max-time=5s), exit-код 0/1 отражает
#                            реальный результат POST. Для событий, где тихая потеря в фоне
#                            недопустима (напр. slot_logged, WP-571). По умолчанию (0/unset) —
#                            прежнее поведение: fire-and-forget в фоне, exit 0 всегда.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

EVENT_TYPE="${1:-}"
EXT_SUFFIX="${2:-}"
PAYLOAD="${3:-{}}"

[ -z "$EVENT_TYPE" ] && exit 0
[ -z "$EXT_SUFFIX" ] && exit 0

GATEWAY_URL="${IWE_EVENT_GATEWAY_URL:-https://event-gateway.aisystant.workers.dev}"
OWNER_UUID="${IWE_OWNER_ORY_UUID:-}"

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EXTERNAL_ID="iwe-${EVENT_TYPE}-${EXT_SUFFIX}"

# Строим envelope через tmpfile (избегаем проблем с escaping shell-строк в python -c)
TMPFILE=$(mktemp "/tmp/iwe_emit_${EVENT_TYPE}_XXXXXX.json")
trap 'rm -f "$TMPFILE"' EXIT

python3 - "$EVENT_TYPE" "$EXTERNAL_ID" "$TS" "$OWNER_UUID" "$PAYLOAD" > "$TMPFILE" 2>/dev/null <<'PYEOF'
import json, sys
event_type, external_id, ts, owner_uuid, payload_str = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
try:
    payload = json.loads(payload_str)
except Exception:
    payload = {}
if owner_uuid:
    payload['ory_uuid'] = owner_uuid

# activity_domain tagging — WP-253 Блок 2 Ф0.4 (canon: iwe-actions-catalog.md §2.1-2.7)
# Caller может override через payload['activity_domain'] (например, для wp_closed
# в продуктовом репо нужно 'work' — определяется через reference.repo_domain_map в caller'е).
ACTIVITY_DOMAIN_MAP = {
    # ОРЗ-протоколы (practice)
    'day_plan_opened': 'practice', 'day_plan_closed': 'practice',
    'week_plan_closed': 'practice', 'month_plan_closed': 'practice',
    # Знание/стратегирование (learning)
    'strategy_session_completed': 'learning',
    'knowledge_extracted': 'learning',
    # Pack-обновления — practice (правка инструмента)
    'pack_updated': 'practice',
    # WP (practice по умолчанию; caller override на 'work' для продуктовых репо)
    'wp_created': 'practice', 'wp_closed': 'practice', 'wp_blocked': 'practice',
    # Сессии Claude Code и редактирование
    'iwe_session': 'practice', 'file_edited': 'practice', 'iwe_research': 'practice',
    # Git (practice по умолчанию; caller override на 'work' через payload)
    'git_commit': 'practice', 'git_push': 'practice',
    # Бот-команды (practice)
    'slot_logged': 'practice', 'command_invoked': 'practice', 'bot_reflection': 'practice',
}
if 'activity_domain' not in payload:
    domain = ACTIVITY_DOMAIN_MAP.get(event_type)
    if domain:
        payload['activity_domain'] = domain

envelope = {
    'source': 'iwe',
    'external_id': external_id,
    'event_type': event_type,
    'schema_version': 'v1',
    'occurred_at': ts,
    'account_id': owner_uuid if owner_uuid else None,
    'payload': payload,
}
print(json.dumps(envelope))
PYEOF

BODY=$(cat "$TMPFILE" 2>/dev/null)
if [ -z "$BODY" ] || [ "$BODY" = "null" ]; then
  echo "[iwe_event_emit] ERROR: failed to build JSON body for ${EVENT_TYPE}" >&2
  exit 0
fi

_post() {
  local resp curl_exit http_code body_resp
  resp=$(curl -s -w "\n%{http_code}" \
    -X POST "${GATEWAY_URL}/events" \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    --max-time 5 \
    2>/dev/null)
  curl_exit=$?

  http_code=$(echo "$resp" | tail -1)
  body_resp=$(echo "$resp" | head -1)

  # curl-уровня сбой (DNS/connection refused до HTTP-ответа) не оставляет
  # http_code — без этой ветки WARN ниже печатался бы пустым и неотличимым
  # от полученного, но нераспознанного HTTP-статуса.
  if [ -z "$http_code" ]; then
    echo "[iwe_event_emit] WARN curl exit ${curl_exit}: ${EVENT_TYPE} — сеть/DNS недоступны" >&2
    return 1
  fi

  if [ "$http_code" = "201" ]; then
    echo "[iwe_event_emit] OK 201: ${EVENT_TYPE} (${EXTERNAL_ID})" >&2
    return 0
  elif [ "$http_code" = "200" ]; then
    echo "[iwe_event_emit] OK 200 idempotent: ${EVENT_TYPE} (${EXTERNAL_ID})" >&2
    return 0
  else
    echo "[iwe_event_emit] WARN ${http_code}: ${EVENT_TYPE} — ${body_resp}" >&2
    return 1
  fi
}

if [ "${IWE_EMIT_SYNC:-0}" = "1" ]; then
  # Подтверждённая доставка: вызывающий (напр. self-report часов, WP-571)
  # обязан знать, долетело ли событие — тихая потеря в фоне здесь недопустима.
  _post
  exit $?
fi

# POST в background (non-blocking) — дефолт для хуков, где доставка не критична.
( _post ) &

exit 0
