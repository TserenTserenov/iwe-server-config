# Day Open Extensions (before) — Авторские

> Выполняется в шаге 0 SKILL.md перед шагом 1.
> Автор: Tseren (author_mode). Слой 3 (extensions).

## 0a-fault. Agent Fault Reminder (WP-316, ОБЯЗАТЕЛЬНО первым)

> Выводит 2-3 горячих напоминания из SQLite базы косяков агента. Выполнять ДО scaffold — пока контекст чистый.

```bash
python3 ~/IWE/DS-my-strategy/scripts/agent_fault_remind.py --protocol open 2>/dev/null || echo "⚠️ agent_fault_remind.py недоступен — пропуск (non-blocking)"
```

**Что делать с выводом:** прочитать 2-3 🔴-напоминания → удержать в голове при формировании DayPlan. Если напоминание релевантно сегодняшней задаче — применить немедленно (не «учту позже»).

> **Почему не работало ранее:** скрипт существует с WP-316 (апр 2026), но не был встроен в extensions. Добавлено 2026-05-17 после 3 дней пропуска шага 5e.

## 0a-pre. Pull-on-Touch для индексных репо (WP-283 follow-up, 6 мая)

Перед scaffold — `git pull --rebase` для двух репо, чьи отчёты используются в светофоре. Иначе ложно-🟡 (локальная копия отстаёт, серверный отчёт уже в origin):

```bash
for repo in DS-agent-workspace; do
  dir="$IWE_WORKSPACE/$repo"
  if [ -d "$dir/.git" ]; then
    (cd "$dir" && git diff --quiet && git pull --rebase --quiet 2>/dev/null) || \
      echo "  ⚠ $repo: dirty или pull failed — данные potentially stale"
  fi
done
```

DS-my-strategy уже покрыт §2 п.4 платформенным правилом. DS-agent-workspace — отдельно потому что scaffold читает scheduler/feedback-triage отчёты ДО первого касания репо в сессии.

## 0a-stale. Архивация зависших DayPlan (WP-356, defense-in-depth)

> Выполнять ДО scaffold. Если Day Close не заархивировал вчерашний DayPlan — сделать это сейчас + записать флаг для alarm в after.md.
> Источник: peer-сессия 2026-05-29-04-day-open-two-defects.

```bash
TODAY=$(date +%Y-%m-%d)
cd "$HOME/IWE/DS-my-strategy"
# git ls-files: только файлы под git-контролем (идемпотентно при повторном запуске)
STALE=$(git ls-files current/ 2>/dev/null | grep -E "^current/DayPlan [0-9]{4}-[0-9]{2}-[0-9]{2}\.md$" | grep -v "current/DayPlan $TODAY\.md" || true)
if [ -n "$STALE" ]; then
  # while IFS= read -r: корректно обрабатывает пробелы в именах файлов
  while IFS= read -r f; do
    [ -n "$f" ] && git mv "$f" "archive/day-plans/"
  done <<< "$STALE"
  # Ограничить коммит только archive/day-plans/ — не захватывать чужой staged index
  git commit -- "archive/day-plans/" -m "archive(day-open): stale DayPlan before new open — Day Close incomplete"
  # Флаг для after.md: только базовые имена файлов
  echo "$STALE" | xargs -I{} basename {} > "/tmp/iwe-stale-dayplan-$TODAY.flag"
  echo "⚠️ Заархивированы зависшие DayPlan (Day Close был неполным)"
else
  echo "✅ current/: нет зависших DayPlan"
fi
```

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
  echo "STRATEGY_DAY=true"
  echo "Сегодня strategy_day, DayPlan не создаётся (SKILL.md шаг 4). План в WeekPlan W${WEEK_NUM}. Пропустить шаги 1-7, перейти к compact dashboard на основе WeekPlan."
fi
```

**Если `STRATEGY_DAY=true`:** сразу вывести compact dashboard из WeekPlan без ожидания полного прогона SKILL.md шагов 1-7:

```bash
# compact dashboard для strategy_day (не зависит от полного Day Open)
WEEKPLAN="$IWE_WORKSPACE/DS-my-strategy/current/WeekPlan W${WEEK_NUM} $(date +%Y)-*.md"
KE_STATS=$(bash "$IWE_WORKSPACE/DS-my-strategy/scripts/ke-queue-stats.sh" --human 2>/dev/null || echo "| KE-очередь | ⚠️ | ke-queue-stats.sh недоступен |")
echo "--- Compact Dashboard (strategy_day) ---"
echo "$KE_STATS"
```

Далее — вывести compact dashboard по шаблону `memory/templates-dayplan.md` с данными из WeekPlan:
- **Вчера:** коммиты за вчера из всех репо (`git log --oneline --since=yesterday`)
- **Бюджет:** из WeekPlan frontmatter
- **ТОС:** из WeekPlan секция «Фокус»
- **План дня:** топ-3 РП из WeekPlan с `in_progress` или `pending`
- **Требует внимания:** KE SLA + любые 🔴 из IWE-светофора

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

## 0b-ke. Override для шага 5e: KE-очередь (БЛОКИРУЮЩЕЕ)

**Единственный источник данных KE SLA — `ke-queue-stats.sh`.** Не считать вручную через grep/find никогда.

Fallback при недоступности скрипта (exit != 0 или команда не найдена):
```bash
KE_STATS=$(bash "$IWE_WORKSPACE/DS-my-strategy/scripts/ke-queue-stats.sh" --human 2>/dev/null)
if [ -z "$KE_STATS" ]; then
  echo "| KE-очередь | ⚠️ | ke-queue-stats.sh недоступен — данные KE отсутствуют |"
fi
```

**При недоступности скрипта:**
- Записать в DayPlan: «KE-очередь: данные недоступны (ke-queue-stats.sh не запустился)»
- НЕ считать файлы через grep/find самостоятельно
- НЕ использовать цифры из предыдущего DayPlan как «приблизительные»

**Почему запрет ручного подсчёта:** ручной grep захватывает файлы с `defer_until`, которые скрипт корректно исключает. Результат — завышенный count и завышенный oldest_age_days.

## 0b. Работа с PENDING-маркерами (шаги 1-6)

Шаги 1-6 SKILL.md → дополнение PENDING-маркеров через Edit. Не переписывать файл целиком.

**Паттерн:** каждый шаг 1-6 SKILL.md → Edit(old=`<!-- PENDING: X -->`, new=реальное содержимое).

**Финальная проверка перед commit (шаг 7c):** `grep -c '<!-- PENDING:' DayPlan*.md` должно быть `0`. Если >0 — заполнить оставшиеся PENDING (либо явно «нет данных», но не оставлять PENDING-маркер).

## Связь

- Скрипт: [scripts/day-open-scaffold.sh](../scripts/day-open-scaffold.sh)
- WP-264: [DS-my-strategy/inbox/WP-264-day-open-enforcement.md](../DS-my-strategy/inbox/WP-264-day-open-enforcement.md)
- Hook валидации: [.claude/hooks/protocol-artifact-validate.sh](../.claude/hooks/protocol-artifact-validate.sh)
- SKILL: [.claude/skills/day-open/SKILL.md](../.claude/skills/day-open/SKILL.md) шаг 0
