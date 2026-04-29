# Day Open Extensions (before) — Авторские

> Выполняется в шаге 0 SKILL.md перед шагом 1.
> Автор: Tseren (author_mode). Слой 3 (extensions).

## 0a. Scaffold (детерминированный каркас, БЛОКИРУЮЩЕЕ — WP-264 Ф2)

Сгенерировать болванку DayPlan со всеми 11 обязательными секциями + PENDING-маркерами:

```bash
DATE=$(date +%Y-%m-%d)
WEEK_NUM=$(date +%V)
DAYPLAN_FILE="$IWE_WORKSPACE/DS-my-strategy/current/DayPlan $DATE.md"
bash "$IWE_WORKSPACE/scripts/day-open-scaffold.sh" "$DATE" > "$DAYPLAN_FILE"
SCAFFOLD_EXIT=$?
if [ "$SCAFFOLD_EXIT" -eq 2 ]; then
  rm -f "$DAYPLAN_FILE"
  echo "Сегодня strategy_day, DayPlan не создаётся (SKILL.md шаг 4). План в WeekPlan W${WEEK_NUM}. Пропустить шаги 1-7, перейти к compact dashboard на основе WeekPlan."
fi
```

**Что заполняет детерминированно (без LLM):**
- Помидорки (из `day-rhythm-config.yaml`)
- Видео (`find` за сегодня в директориях из конфига)
- Бот QA (выдержка из `DS-agent-workspace/scheduler/feedback-triage/$DATE.md`)
- IWE-светофор: Scheduler / template-sync / Scout / gate_log / Update IWE / Base repos (FPF/SPF/ZP behind count)
- Scout (находки + capture-кандидаты из `scout/results/YYYY/MM/DD/`)
- Итоги вчера: коммитов в N репо

**Остальные секции — `<!-- PENDING: X -->` маркеры** (заполнить в шагах 1-6 ниже):
- План на сегодня (синтез из WeekPlan + carry-over + budget_spread)
- Календарь (MCP `mcp__ext-google-calendar__list-events`)
- Здоровье бота smoke-tests (если запущены)
- Контент-план (из drafts/)
- Разбор заметок (категоризация fleeting-notes.md)
- Мир (RSS curl / WebSearch)
- Контекст недели (из WeekPlan)
- Итоги вчера: РП закрыто + ключевое (синтез из коммитов)
- Требует внимания (агрегация всех 🟡/🔴 из шагов 1-6)

**Архитектурный принцип** (Ф5 ADR будет): «Enforcement требует наблюдателя вне субъекта». Bash-скрипт — наблюдатель: гарантирует наличие 11 секций ДО того, как Claude начнёт синтез. Claude не может «сократить» структуру, может только заполнять PENDING.

## 0b. Работа с PENDING-маркерами (шаги 1-6)

Шаги 1-6 SKILL.md → дополнение PENDING-маркеров через Edit. Не переписывать файл целиком.

**Паттерн:** каждый шаг 1-6 SKILL.md → Edit(old=`<!-- PENDING: X -->`, new=реальное содержимое).

**Финальная проверка перед commit (шаг 7c):** `grep -c '<!-- PENDING:' DayPlan*.md` должно быть `0`. Если >0 — заполнить оставшиеся PENDING (либо явно «нет данных», но не оставлять PENDING-маркер).

## Связь

- Скрипт: [scripts/day-open-scaffold.sh](../scripts/day-open-scaffold.sh)
- WP-264: [DS-my-strategy/inbox/WP-264-day-open-enforcement.md](../DS-my-strategy/inbox/WP-264-day-open-enforcement.md)
- Hook валидации: [.claude/hooks/protocol-artifact-validate.sh](../.claude/hooks/protocol-artifact-validate.sh)
- SKILL: [.claude/skills/day-open/SKILL.md](../.claude/skills/day-open/SKILL.md) шаг 0
