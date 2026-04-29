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

### 7b. Верификация DayPlan (БЛОКИРУЮЩЕЕ перед коммитом)

> Загрузить и выполнить `extensions/day-open.checks.md` ПОСЛЕ записи файла DayPlan, ДО `git commit`.
> Порядок шага 7: записать файл → пройти checks → `git commit` → `git push` → compact dashboard.

<!-- /AUTHOR-ONLY -->
