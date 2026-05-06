# Day Close Extensions (after) — Авторские

<!-- AUTHOR-ONLY -->

### Emit day_plan_closed (WP-151 Блок B)

> Выполнить **после** `day-close.sh` (основных шагов Close) и commit DayPlan.
> `executed_slots_count` — взять из DayPlan: число РП со статусом done/✅ за день.
> Идемпотентно: повторный запуск → 200 `{idempotent: true}`.

Перед запуском: определить `EXECUTED_SLOTS` из DayPlan (число закрытых за день) и `GOLDEN_HOUR_USED` (true/false).

```bash
DATE=$(date +%Y-%m-%d)
ENV_FILE="$HOME/.config/aist/env"
ACCOUNT_ID=$(grep '^export DT_USER_ID=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
EVENT_GW="${EVENT_GATEWAY_URL:-https://event-gateway.aisystant.workers.dev}"
EXT_ID="day-plan-closed-${DATE}-${ACCOUNT_ID:0:8}"

# Заполнить по контексту DayPlan:
EXECUTED_SLOTS=<число done-РП из DayPlan>
SELF_RATING=<самооценка результата 1-5>
GOLDEN_HOUR=<true или false>

if [ -z "$ACCOUNT_ID" ]; then
  echo "⚠️ DT_USER_ID не задан — пропуск emit day_plan_closed"
else
  RESP=$(curl -sf -X POST "$EVENT_GW/events" \
    -H "Content-Type: application/json" \
    -d "{\"source\":\"iwe\",\"event_type\":\"day_plan_closed\",\"schema_version\":\"v1\",\"external_id\":\"$EXT_ID\",\"account_id\":\"$ACCOUNT_ID\",\"payload\":{\"plan_date\":\"$DATE\",\"executed_slots_count\":$EXECUTED_SLOTS,\"self_rating_outcome\":$SELF_RATING,\"golden_hour_used\":$GOLDEN_HOUR}}" 2>&1)
  echo "$RESP" | grep -q '"inserted"' && echo "✅ day_plan_closed → learning.domain_event" || echo "⚠️ emit: $RESP (non-blocking)"
fi
```

<!-- /AUTHOR-ONLY -->
