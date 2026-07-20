# Day Close Extensions (after) — Авторские

<!-- AUTHOR-ONLY -->

### Emit day_close (WP-151 Блок B)

> Выполнить **после** `day-close.sh` (основных шагов Close) и commit DayPlan.
> `executed_slots_count` — взять из DayPlan: число РП со статусом done/✅ за день.
> Идемпотентно: повторный запуск → 200 `{idempotent: true}`.

Перед запуском: определить `EXECUTED_SLOTS` из DayPlan (число закрытых за день) и `GOLDEN_HOUR_USED` (true/false).

```bash
DATE=$(date +%Y-%m-%d)
ENV_FILE="$HOME/.config/aist/env"
ACCOUNT_ID=$(grep '^export DT_USER_ID=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
EVENT_GW="${EVENT_GATEWAY_URL:-https://event-gateway.aisystant.workers.dev}"
EXT_ID="day-close-${DATE}-${ACCOUNT_ID:0:8}"

# Заполнить по контексту DayPlan:
EXECUTED_SLOTS=<число done-РП из DayPlan>
SELF_RATING=<самооценка результата 1-5>
GOLDEN_HOUR=<true или false>

if [ -z "$ACCOUNT_ID" ]; then
  echo "⚠️ DT_USER_ID не задан — пропуск emit day_close"
else
  RESP=$(curl -sf -X POST "$EVENT_GW/events" \
    -H "Content-Type: application/json" \
    -d "{\"source\":\"iwe\",\"event_type\":\"day_close\",\"schema_version\":\"v1\",\"external_id\":\"$EXT_ID\",\"account_id\":\"$ACCOUNT_ID\",\"payload\":{\"plan_date\":\"$DATE\",\"executed_slots_count\":$EXECUTED_SLOTS,\"self_rating_outcome\":$SELF_RATING,\"golden_hour_used\":$GOLDEN_HOUR}}" 2>&1)
  echo "$RESP" | grep -q '"inserted"' && echo "✅ day_close → learning.domain_event" || echo "⚠️ emit: $RESP (non-blocking)"
fi
```

### Заметка дня — сырьё дневника созидателя (WP-442 Ф14)

> Выполнить **перед** финальным commit Day Close (та же секция, что пишет DayPlan). Не публикуется сама по себе — только копится, пока пилот не попросит собрать выпуск дневника.
> Пропустить молча, если день не содержал ничего похожего на фокус/поток/стоп-момент (короткий технический день) — не тянуть 4 строки из воздуха.

**Алгоритм:**
1. Прочитать DayPlan дня (закрытые РП, разговоры сессии) — не придумывать, а извлекать.
2. Сформировать 3-5 строк:
   - **Фокус:** одна-две вещи, куда реально уходило внимание сегодня (не список задач).
   - **Потоки** (что применимо, не натягивать все три): творческий-рабочий / познавательный-исследовательский / опытный-личный.
   - **Стоп-момент** (если был): где неудовлетворённость отвела от автоматической реакции.
   - **Нерешённое:** что осталось открытым.
3. Дописать блок в конец `DS-Tseren-Brand/content/diary-notes.md` (создать файл при первом запуске, см. шаблон записи ниже) под сегодняшней датой.

**Шаблон записи:**
```markdown
## YYYY-MM-DD

**Фокус:** ...
**Потоки:** творческий-рабочий: ... / познавательный: ... / личное: ...
**Стоп-момент:** ...
**Нерешённое:** ...
```

**Сборка выпуска:** по команде пилота «собери дневник» — агент читает все записи `diary-notes.md` без пометки `<!-- used: post_number -->`, собирает пост-рефлексию (club + telegram, `new-post.py`, audience: wide), после публикации помечает использованные записи `<!-- used: NNN -->` (не удаляет — история).

### Обновить priorities.yaml на завтра

> Выполнить в самом конце Day Close, после commit DayPlan.
> Цель: автогенератор завтрашнего дня прочитает файл и подставит корректные «Утренние приоритеты» вместо заглушки `(не задано)`.

**Алгоритм:**
1. Взять секцию «Carry-over» из сегодняшнего DayPlan + незакрытые пункты «Требует внимания» (🔴 first).
2. Отобрать top-5 по срочности/приоритету. Формат записи: `WP-NNN   # <одна строка контекста>`.
3. Если есть явный дедлайн завтра — поставить первым.
4. Записать в `current/priorities.yaml` (поля `last_updated` + `today`).
5. Опционально: если завтра известен конкретный физический бюджет (например, только 3h из-за встречи) — добавить поле `phys_hours: N` — автогенератор подхватит его при расчёте мультипликатора.

```yaml
# Пример обновлённого файла:
last_updated: "YYYY-MM-DD"          # завтрашняя дата
phys_hours: 5                       # опционально; если не задано — бюджет = сумма h из плана
today:
  - WP-NNN   # контекст — почему первый
  - WP-NNN   # ...
```

Коммитить вместе с архивированным DayPlan в том же commit Day Close.

### Пересобрать сегодняшний DayPlan свежими данными (bug-2026-07-01)

> **Источник:** 2026-07-01 launchd открыл день в 01:04, а Day Close за 30 июня прошёл в 05:29.
> Day Open прочитал stale-данные → галлюцинация «10 РП закрыто», выпавший РП, выдуманный черновик.
> Day Open теперь откладывается, если Day Close за вчера не закоммичен (guard в day-open-pipeline.sh).
> Значит после закрытия дня плановый файл надо пересобрать явно — это авторитетный сигнал «вчера финализировано».

> Выполнить **в самом конце** Day Close, после commit+push (priorities.yaml обновлён выше).

```bash
# Regenerate today's DayPlan with fresh data now that yesterday's close is committed.
# --force bypasses the race guard; deterministic sections (closed-WP count, self-dev,
# strategy priorities) now come from real data, not LLM guesses.
bash "$HOME/IWE/DS-my-strategy/scripts/day-open-pipeline.sh" --force >> \
  "$HOME/IWE/DS-my-strategy/logs/day-open-pipeline.log" 2>&1 &
echo "🔄 DayPlan пересобирается свежими данными (фоново, --force)"
```

<!-- /AUTHOR-ONLY -->
