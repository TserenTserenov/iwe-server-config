---
name: day-open
description: "Протокол открытия дня (Day Open). Собирает вчерашние коммиты, issues, заметки, календарь, бота QA, Scout, мир — формирует DayPlan и compact dashboard."
argument-hint: ""
version: 1.1.0
layer: L1
status: active
triggers:
  slash: [/day-open]
  phrases: []
routing:
  executor: sonnet
  deterministic: false
---

# Day Open (протокол открытия дня)

> **Роль:** R1 Стратег. **Два выхода:** DayPlan (git, 80+ строк) + compact dashboard (VS Code, 20-30 строк).
> **Порядок:** сначала DayPlan → потом compact. **Дата:** ПЕРВОЕ действие = `date`.
> **Режим:** `memory/day-rhythm-config.yaml` → `interactive: false` = одним блоком, решения → «Требует внимания».
> **Фильтр свежести:** issues, видео, заметки — за 2 дня. Urgent — всегда.
> **Issues — только actionable:** пропускать read-only репо (CLAUDE.md) и upstream без push-доступа (Base, чужие fork).
> **Шаблоны:** ниже (после алгоритма).
> **Стиль текста:** DayPlan и compact dashboard читает пилот → весь текст синтезировать в базе разговорного стиля (S0 база + S1 автор, источник DP.SC.050): русский, без машинных меток, путь к файлу и код РП не подлежащее (только после русского описания в скобках), главная мысль первой. Применяется и к встроенным блокам-выводам скриптов (Gate-метрики, светофор IWE за ночь).

## БЛОКИРУЮЩЕЕ: пошаговое исполнение

Day Open = протокол. Исполнять ТОЛЬКО пошагово через TodoWrite.
Каждый шаг алгоритма ниже → отдельная задача (pending → in_progress → completed).
Переход к следующему — ТОЛЬКО после отметки текущего. Шаг невозможен → blocked (не пропускать молча).
**Почему:** без TodoWrite агент пропускает шаги из-за загрязнения контекста (SOTA.002).

## Профиль повторяющихся ошибок агента

Инжектится в **системный промпт агента** через UserPromptSubmit hook (`.claude/hooks/inject-fault-profile.sh`), НЕ показывается в DayPlan. DayPlan — артефакт пилота, профиль ошибок — внутренний инструмент агента.

Источник правила: peer-сессия 2026-05-30-07 + уточнение пилота 30 мая. Альтернативный путь (для cron-агента без интерактива): инжекция первой строкой в `day-open-scaffold.sh` промпт-инструкцию стратегу.

## Алгоритм

### 0. Extensions (before)
Загрузить: `bash .claude/scripts/load-extensions.sh day-open before`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить содержимое как первые шаги. Exit 1 → пропустить. Поддерживает `extensions/day-open.before.md` И `extensions/day-open.before.<suffix>.md`.

### 1. Вчера
Прочитать вчерашний DayPlan (`archive/day-plans/` или `current/`). Взять:
- Секцию «Итоги» → 1-3 результата
- Секцию «Завтра начать с:» / carry-over РП → **приоритетный вход** для шага 2
- Незакрытые вопросы из «Требует внимания»

Fallback: файла нет → пропустить, работать из коммитов.

Коммиты за вчера по всем `$HOME/IWE/*/` репо. Сопоставить с DayPlan.

### 1b. GitHub Issues
`gh issue list` по всем репо (включая вложенным). Фильтр 2 дня. Связь с РП по ключевым словам.
**Только actionable:** пропускать read-only и upstream без push-доступа.

### 1c. Заметки
`DS-my-strategy/inbox/fleeting-notes.md` → категоризация: → РП / → Backlog / → Контент / → Pack / → Обсудить / → Шум. НЕ удалять.
**Carry-over заметок из вчерашнего DayPlan:** проверить по git log (`note-review`), были ли обработаны. Если да → секция «Разбор заметок» = «все обработаны» (с ссылкой на коммит). Не переносить обработанные заметки как carry-over.
**Гиперссылки на заметки (БЛОКИРУЮЩЕЕ):** каждая заметка в секции «Разбор заметок» DayPlan — markdown-ссылка на её источник (`inbox/fleeting-notes.md` для свежих, `archive/notes/Notes-Archive.md#L<line>` для обработанных, `inbox/captures.md` для знания). Причина: после Note-Review сама заметка исчезает из fleeting-notes.md, и без ссылки суть заметки теряется через день. Формат строки таблицы: `[«заголовок»](путь#L<line>) (DD мес HH:MM)`.
**Знаниевые заметки = кандидаты (БЛОКИРУЮЩЕЕ, 2026-04-17):** заметки категории «Знание доменное» без явного маркера «Экстрактору» в тексте → в DayPlan секция «Разбор заметок» таблицей **Кандидаты Экстрактору** с колонками «Заметка | Тип | Предполагаемый Pack | Действие». Решение «отдать / оставить» принимает пользователь в живом разборе. Note-Review в `captures.md` пишет ТОЛЬКО при явном маркере. Причина: `captures.md` = очередь Экстрактора; любое знание туда = неявное согласие на формализацию, которое Note-Review делать не уполномочен.

### 2. План на сегодня
**Приоритет входов (строгий порядок):**
1. **Carry-over из Day Close (БЛОКИРУЮЩЕЕ):** ВСЕ РП из секции «Завтра начать с» → в план без обрезки. Это решение пользователя — Day Open не фильтрует и не сокращает этот список
2. **WeekPlan (ОБЯЗАТЕЛЬНО):** прочитать WeekPlan → ВСЕ in_progress и pending РП → проверить каждый: релевантен сегодня? Есть дата/дедлайн сегодня? Просрочен? → добавить.
   **Budget Spread** (если `budget_spread.enabled: true` в day-rhythm-config.yaml): для каждого РП с бюджетом ≥ `threshold_h` (колонка «h» в таблице WeekPlan):
   - `days_left` = оставшиеся рабочие дни пн–пт включая сегодня
   - `daily_slot` = round(budget_week / days_left, `rounding`)
   - Нет бюджета в WeekPlan → пропустить, добавить в «Требует внимания»
   - РП уже в плане (carry-over) → взять max(carry_over_budget, daily_slot)
   - Иначе → добавить с daily_slot
   Не ограничиваться «2-4 штуки» — план дня отражает реальную нагрузку
3. **MEMORY.md → «РП текущей недели»:** сверить — нет ли РП, упущенных в WeekPlan (ad-hoc, reopened)
4. `day-rhythm-config.yaml → mandatory_daily_wps` — обязательные РП (проверить наличие в плане, если нет → добавить)
5. `day-rhythm-config.yaml → daily_checkpoint_wps` — РП-checkpoint'ы (упомянуть в плане строкой с бюджетом ≤0.5h каждый; пилот при необходимости корректирует). Источник правила: peer-сессия 2026-05-30-07. Альтернативный сигнал: `daily_checkpoint: true` в frontmatter `inbox/WP-N.md` — учитывать наравне с config.

**Слот 1 = саморазвитие.**
Mandatory РП отсутствуют в WeekPlan → «Требует внимания».

### 3. Саморазвитие
Руководство, где остановился, черновики (`DS-my-strategy/drafts/`).

### 4. Стратегирование
Если strategy_day → DayPlan НЕ создавать, план в WeekPlan. Пропустить шаг 7.

### 4b. Помидорки
Из `day-rhythm-config.yaml → pomodoro`.

### 4c. Календарь (Day Mode)
`bash scripts/server-calendar.sh YYYY-MM-DD` — секция «Календарь» для DayPlan.

**Что делает скрипт:**
1. Запрашивает ВСЕ календари из `calendar_ids` (см. feedback `feedback_calendar_query_day_open` — никаких сокращений).
2. Фильтрует только по `visibility == "private"` (не по названию).
3. Классифицирует:
   - **Встречи** — несколько участников, длительность >30 мин, нет маркеров задачи.
   - **Напоминания / Тех-операции** — маркеры 🔧 ✅ ⏰ 🔔 📋 ❗ или ключевые слова (backup, проверить, remind, smoke, test), либо ≤30 мин без участников.
4. Статус относительно текущего времени:
   - ⏳ предстоит / 🔄 идёт / ✅ завершено.
5. Считает свободные блоки ≥1h в рамках 09:00–22:00.

**Формат в DayPlan:** две таблицы (Встречи + Напоминания) по шаблону `templates-dayplan.md`.

### 4c-alt. Календарь недели (Week Mode, strategy_day)
Если сегодня `strategy_day` (из `day-rhythm-config.yaml`) — перед формированием WeekPlan запустить:
```bash
bash scripts/server-calendar.sh --week YYYY-MM-DD
```
Результат → вставить в WeekPlan секцию **«Календарь недели W{N}»** (шаблон `templates-dayplan.md`). Это позволяет при планировании сразу учитывать встречи и тех-операции.

### 5. IWE за ночь (светофор)
update.sh, template-sync, MCP reindex, Scout. 🟢/🟡/🔴.

**Smoke split (peer-консенсус 2026-05-30-07):**
- **Core smoke (≤10с, синхронно в скаффолде):** `bash $IWE_SCRIPTS/day-open-smoke.sh` — scheduler-pulse (локальный файл `current/.scheduler-last-run`, fallback Neon) + KE-count + oldest-age. Подставлять PASS/FAIL в светофор.
- **Extended smoke (hourly cron, кэш):** `current/.smoke-cache.json` (TTL 90 мин). Включает dt-collect dry-run, projection cursor age, FPF upstream check. Day Open читает кэш, не запускает заново. Кэш устарел → подставить `stale-cache: <age>`, не падать.

**Scheduler failure modes (различить!):**
- **Mode A** (`feedback-watchdog-{сегодня}.log` отсутствует И юнита нет в `launchctl list`) → cron не отработал. Авто-создать `inbox/INCIDENT-scheduler-cron-not-fired-YYYY-MM-DD.md`. ≥2 дней → TG-эскалация.
- **Mode B** (юнит есть, лог есть, отчёт пустой) → всё чисто, жалоб нет = норм 🟢.
- НЕ литерал «Scheduler/триаж 🔴 — отчёт за сегодня отсутствует» (это слепой placeholder).

**Проверка обновлений:** `cd "$IWE_TEMPLATE" && bash update.sh --check 2>&1`. Если доступно обновление → добавить в «Требует внимания»: «Доступно обновление IWE → `/iwe-update`».

**Проверка Base-репо (FPF, SPF, ZP):**
```bash
for repo in FPF SPF ZP; do
  dir="$IWE_WORKSPACE/$repo"
  [ -d "$dir/.git" ] && (cd "$dir" && git fetch --quiet 2>/dev/null && behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0) && [ "$behind" -gt 0 ] && echo "$repo: $behind новых коммитов" || echo "$repo: актуален")
done
```
Если есть новые коммиты → добавить в «Требует внимания»: «[repo] обновлён upstream → `cd "$IWE_WORKSPACE/[repo]" && git pull --rebase`». После pull FPF/SPF → reindex: `bash "$IWE_WORKSPACE/DS-MCP/knowledge-mcp/scripts/selective-reindex.sh" FPF` (или SPF).

### 5a2. Видео
Если `day-rhythm-config.yaml → video.enabled: true`:
1. Сканировать директории из `video.directories` на файлы с расширениями из `video.extensions`
2. Показать ТОЛЬКО новые записи за сегодня (`-mtime 0`). Старые файлы — не оповещать (архивный долг, не daily concern)
3. Есть новые → «N новых видеозаписей сегодня (X ГБ)». Нет → «0 новых записей сегодня»
4. `video.enabled: false` → пропустить

### 5b. Бот QA
Feedback-triage report: `DS-agent-workspace/scheduler/feedback-triage/YYYY-MM-DD.md`. Проверить дату файла. Фильтр 2 дня. Нет файла → «нет отчёта». Дельта, urgent.

### 5e. KE-очередь (Knowledge Extraction)
`bash $IWE_SCRIPTS/ke-queue-stats.sh` → возвращает `(count, oldest_age_days, estimated_minutes)`. Подставлять в DayPlan реальный бюджет (например, `apply-captures 44 reports, oldest 6d, ~3.5h оценка`), НЕ литерал «1h pending».

**SLA-блокер (peer-консенсус 2026-05-30-07):** `oldest_age_days ≥ 3` → строка в «Требует внимания» = 🔴 (не 🟡).

**Auto-batch classifier** (для `apply-captures --auto-batch`):
- **Primary:** frontmatter `domain:` tag. Отсутствует → auto-reject (pending-review), regex не применяется.
- **Secondary** (только при `domain: course-content | personal-notes | bot-conversation`): regex проверяет отсутствие ссылок на `.claude/`, `scripts/`, `extensions/`, `memory/feedback_*.md` + объём ≤30 строк.
- `domain: system | infrastructure | meta-skill` → блок auto-accept (всегда human review).

### 5c. Контент
Стратегия маркетинга + draft-list. 1-3 темы.

### 5d. Scout
Scout report. Не проревьюен → «Требует внимания».

### 6. Мир
`day-rhythm-config.yaml → news`. Feeds/WebSearch. `enabled: false` → пропустить.
**Ссылки на источники обязательны** (URL).

**6a. News Lens (анализ через субагент).**
После сбора заголовков — вызвать субагент (Haiku, context isolation) с промптом:

> Ты — разведчик новостей. Тебе дан список заголовков + список активных РП пользователя.
> Задача: написать 2-4 предложения «Что из этого важно для работы сегодня?»
> Отвечай только на русском. Без перечисления всех новостей — только синтез.
> Входные данные:
> НОВОСТИ: {заголовки с темами}
> АКТИВНЫЕ РП: {топ-5 РП по приоритету из DayPlan}

Вывод субагента → поле **«Вывод:»** в начале секции «Мир». Формат секции:

```
**Вывод:** <2-4 предложения синтеза>

**AI/LLM:** [Заголовок 1](url) · [Заголовок 2](url) · ...
**Инженерия:** [Заголовок 1](url) · ...
**Мировые события:** [Заголовок 1](url) · ...
```

Субагент недоступен / таймаут → пропустить «Вывод», показать только ссылки.

### 6b. Требует внимания
Собрать из шагов 1–6. Нет → не выводить.

### 6b2. Разметка ТВС (режим работ дня)
> Модель ТВС — Текущее · Важное · Срочное ([[Текущее ≠ Важное ≠ Срочное (ТВС)]]). Источник: руководство «Методы саморазвития» § 9.11, 3.3.

При сборке плана дня пометить каждый РП/блок режимом ТВС:
- **Важное (развитие)** — ставить на максимально защищённый слот (утро, после завтрака): вероятность выполнить выше. Хотя бы один блок важного в день обязателен — иначе копится срочное.
- **Текущее (текучка)** — операционка, во вторую половину дня.
- **Срочное** — только угроза остановки конвейера; в план дня не закладывается заранее, попадает через трекер в течение дня. **Проверка нового дела:** «может подождать до ближайшей сессии стратегирования?» Да → мимолётная заметка, НЕ срочное. Нет → в план работ на сегодня. Дедлайн или «горит» сам по себе срочным не делает ([[Дедлайн ≠ Срочность]]).

### 6c. Extensions (after)
Загрузить: `bash .claude/scripts/load-extensions.sh day-open after`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить содержимое (smoke-тесты, Scout gate, доп. проверки). Exit 1 → пропустить. Поддерживает `extensions/day-open.after.md` И `extensions/day-open.after.<suffix>.md`.

### 7. Запись
**7a.** Записать DayPlan в `DS-my-strategy/current/DayPlan YYYY-MM-DD.md` по шаблону ниже. `current/` — рабочая директория для текущего WeekPlan и DayPlan; архивация в `archive/day-plans/` выполняется при Day Close / Week Close. **Исключение:** день = `strategy_day` (из `day-rhythm-config.yaml`) → DayPlan **не** создаётся, план живёт в WeekPlan (см. шаг 4).
**7b.** Загрузить: `bash .claude/scripts/load-extensions.sh day-open checks`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить верификацию. Exit 1 → пропустить. БЛОКИРУЮЩЕЕ: commit запрещён до прохождения всех checks. Поддерживает `extensions/day-open.checks.md` И `extensions/day-open.checks.<suffix>.md`.
**7c.** `git commit` + `git push`.
**7d.** Compact dashboard → вывести в VS Code по шаблону ниже.

---

## Шаблоны

> Шаблоны DayPlan, compact dashboard и WeekPlan → `memory/templates-dayplan.md` (единый источник для day-open и day-close).
> Прочитать при шаге 7 (запись DayPlan): `Read memory/templates-dayplan.md`
