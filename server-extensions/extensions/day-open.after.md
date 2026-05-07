# Day Open — авторские расширения

<!-- AUTHOR-ONLY -->

### Здоровье платформы (секция DayPlan — вставлять между «Календарь» и «IWE за ночь»)

> Агрегированная секция по всем сервисам платформы (бот, digital-twin, gateway, content-pipeline, knowledge-mcp). Внутри — подзаголовки по сервисам. Вставлять как отдельный `<details>`-блок при записи DayPlan.

```markdown
<details>
<summary><b>Здоровье платформы</b></summary>

### Бот @aist_me_bot (QA)

**Smoke-тесты:** 🟢 N passed (Xs) / 🔴 N failed

**Дельта:** Сегодня: N (↑↓X vs вчера) | Urgent: N (↑↓X) | За 7д: N (↑↓X vs пред. 7д)

**Lifecycle (30д):**

| Статус | Кол-во | Urgent |
|--------|--------|--------|
| new | N | N |
| classified | N | N |

**Статистика (за всё время):** N вопросов, N полезных (👍), N неудовлетворённых (🔍), N без оценки.

**Кластеры (7д)** — группы похожих жалоб, K = пробел в знаниях бота, U = UX/юзабилити:

| Кластер | Кол-во | Sev | Что значит |
|---------|--------|-----|-----------|
| [название] | N | low/medium/high | [краткое пояснение на русском] |

### Остальные MCP-сервисы

⬜ Нет AI quality отчётов / см. [WP-255](...).

### Operational health

⬜ Нет данных / ссылка на dashboard.

</details>
```

### 5b. Бот QA (расширение)

`DS-agent-workspace/scheduler/feedback-triage/YYYY-MM-DD.md` → дельта, urgent. Проверить дату отчёта. Фильтр 2 дня: только новые жалобы. Нет новых → «нет новых за 2 дня».

**Smoke-тесты (ежедневно):**
```bash
cd ~/IWE/DS-IT-systems/aist_bot_newarchitecture
if [ -d ".venv" ]; then .venv/bin/python -m pytest tests/smoke/ -q --tb=line 2>&1; fi
```
64 теста, <1s. Показать: `🟢 64 passed` или `🔴 N failed` (с именами упавших).

### 5b2. QA Тестировщик (S58, понедельник)

`DS-agent-workspace/tester/weekly-YYYY-MM-DD.md`. Только понедельник (или если файл новый). Показать: L1-L4 статус, failed метрики, red team findings. Нет файла → «QA cron не запускался».

### 5d. Scout + WP-170 (зонтичный)

`DS-agent-workspace/scout/results/YYYY/MM/DD/report.md`. Не проревьюен → «Требует внимания».

**WP-170 Gate:** Проверить накопленные captures:
1. Непроревьюенные report.md за последние 2 дня (⬜ не проверен)?
2. `DS-my-strategy/inbox/captures.md` — есть записи без `[processed]`?
3. `DS-agent-workspace/scout/backlog.yaml` — есть `status: pending` + `type: scan` старше 3 дней?

Если хотя бы одно «да» → добавить WP-170 в план дня (~30-60 мин).

### 5e. KE-кандидаты (Knowledge Extraction)

> Проверить: есть ли extraction-reports, ожидающих разбора R15 Валидатором.
> Молча пропустить если N = 0. Показать секцию если N > 0 — пользователь решит сам.

```bash
REPORTS_DIR="$HOME/IWE/DS-my-strategy/inbox/extraction-reports"
PENDING=$(grep -l "status: pending-review" "$REPORTS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
echo "KE_PENDING=$PENDING"
```

**Если KE_PENDING > 0** → добавить в DayPlan отдельную секцию перед «Требует внимания»:

```markdown
### 📚 KE-кандидаты (Knowledge Extraction)

> N extraction-report(ов) ожидают разбора R15 Валидатором.
> Запустить `/apply-captures` в отдельной сессии (~15 мин).

| Отчёт | Дата | Статус |
|-------|------|--------|
| [список файлов из grep выше] | [дата из frontmatter] | pending-review |

**SLA:** разобрать ≤24ч (DP.SC.004). Команда: `/apply-captures`
```

**Если KE_PENDING = 0** → ничего не выводить, пропустить молча.

**Как заполнить таблицу (bash):**
```bash
for f in "$REPORTS_DIR"/*.md; do
  st=$(grep "^status:" "$f" 2>/dev/null | awk '{print $2}')
  dt=$(grep "^date:" "$f" 2>/dev/null | awk '{print $2}')
  [ "$st" = "pending-review" ] && echo "$(basename $f) | $dt | pending-review"
done
```

### 7b. Верификация DayPlan (БЛОКИРУЮЩЕЕ перед коммитом)

> Загрузить и выполнить `extensions/day-open.checks.md` ПОСЛЕ записи файла DayPlan, ДО `git commit`.
> Порядок шага 7: записать файл → пройти checks → `git commit` → `git push` → compact dashboard.

### 8. Emit day_plan_opened (WP-151 Блок B)

> После commit DayPlan (шаг 7, финал) → отправить событие в event-gateway.
> Идемпотентно: повторный запуск → 200 `{idempotent: true}`, не дублирует.

```bash
DATE=$(date +%Y-%m-%d)
ENV_FILE="$HOME/.config/aist/env"
ACCOUNT_ID=$(grep '^export DT_USER_ID=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
EVENT_GW="${EVENT_GATEWAY_URL:-https://event-gateway.aisystant.workers.dev}"
IS_STRATEGY=$([ "$(date +%u)" = "1" ] && echo "true" || echo "false")
EXT_ID="day-plan-opened-${DATE}-${ACCOUNT_ID:0:8}"

if [ -z "$ACCOUNT_ID" ]; then
  echo "⚠️ DT_USER_ID не задан в $ENV_FILE — пропуск emit day_plan_opened"
else
  RESP=$(curl -sf -X POST "$EVENT_GW/events" \
    -H "Content-Type: application/json" \
    -d "{\"source\":\"iwe\",\"event_type\":\"day_plan_opened\",\"schema_version\":\"v1\",\"external_id\":\"$EXT_ID\",\"account_id\":\"$ACCOUNT_ID\",\"payload\":{\"plan_date\":\"$DATE\",\"is_strategy_day\":$IS_STRATEGY}}" 2>&1)
  echo "$RESP" | grep -q '"inserted"' && echo "✅ day_plan_opened → learning.domain_event" || echo "⚠️ emit: $RESP (non-blocking)"
fi
```

<!-- /AUTHOR-ONLY -->
