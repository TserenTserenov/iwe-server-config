---
name: day-close
description: "Протокол закрытия дня (Day Close). Алиас для /run-protocol close day — симметрия с /day-open."
argument-hint: ""
version: 1.0.0
---

# Day Close (протокол закрытия дня)

> **Роль:** R1 Стратег. **Бюджет:** ~10 мин.
> **Принцип:** SKILL.md = L1 платформенный файл. Пользователь не редактирует напрямую — только через `extensions/`.

## БЛОКИРУЮЩЕЕ: пошаговое исполнение

Day Close = протокол. Исполнять ТОЛЬКО пошагово через TodoWrite.
**Шаг 0 — ПЕРВОЕ действие:** создать список задач прямо сейчас (до любых других действий).
Каждый шаг алгоритма → отдельная задача (pending → in_progress → completed).
Переход к следующему — ТОЛЬКО после отметки текущего. Шаг невозможен → blocked (не пропускать молча).

## Алгоритм

### 0. Extensions (before)
Загрузить: `bash .claude/scripts/load-extensions.sh day-close before`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить как первые шаги. Exit 1 → пропустить. Поддерживает `extensions/day-close.before.md` И `extensions/day-close.before.<suffix>.md`.

### 1. Сбор данных

```bash
for repo in $(ls {{HOME_DIR}}/IWE/); do
  if [ -d {{HOME_DIR}}/IWE/$repo/.git ]; then
    commits=$(git -C {{HOME_DIR}}/IWE/$repo log --since="today 00:00" --oneline --no-merges 2>/dev/null \
      | grep -vE "^(docs|chore|ci|style|perf|test)(\\(|:| )" \
      | grep -vE "memory/|\.claude/rules/|template-sync|backup|reindex" \
      || true)
    [ -n "$commits" ] && echo "=== $repo ===" && echo "$commits"
  fi
done
```

Сопоставить коммиты с таблицей «На сегодня» из DayPlan → определить статусы.

### 2. Governance batch

**2a.** Обновить WeekPlan (`DS-my-strategy/current/Plan W{N}...`): статусы РП. **Grep по номеру РП** — обновить ВСЕ упоминания.

**2b.** Обновить DayPlan `DS-my-strategy/current/DayPlan YYYY-MM-DD.md`: статусы ВСЕХ строк (РП + ad-hoc). Done → зачеркнуть.

**2c.** Обновить `DS-my-strategy/docs/WP-REGISTRY.md`: статусы + даты.

**2d.** Обновить `DS-my-strategy/inbox/open-sessions.log`: удалить строки закрытых сессий.

**2e.** Governance-синхронизация: новые репо/сервисы за день? → REPOSITORY-REGISTRY, navigation.md, MAP.002.

**EXTENSION POINT (day-close checks):** `bash .claude/scripts/load-extensions.sh day-close checks` — exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/day-close.checks.md` И `extensions/day-close.checks.<suffix>.md`.

### 3. Архивация

- **DayPlan сегодняшнего дня** → `git mv current/DayPlan $(date +%Y-%m-%d).md archive/day-plans/`. Если есть DayPlan'ы прошлых дней в `current/` (накопленный мусор) — заархивировать их тоже одной командой.
- Done WP context files → `mv inbox/WP-{N}-*.md → archive/wp-contexts/`
- Done РП → удалить строку из MEMORY.md (они уже в WP-REGISTRY и WeekPlan)

> MEMORY.md хранит ТОЛЬКО активные РП (in_progress + pending). Done = удалить.
> Архивация DayPlan ОБЯЗАТЕЛЬНА: следующий Day Open читает carry-over из `archive/day-plans/DayPlan {вчера}.md` и предполагает, что `current/` чистый.

### 4б. Memory Drift Scan

> Страховочная сетка — ловит то, что не обновили в Quick Close сессий за день.

```bash
grep -nE "→ ждёт|ждёт|dep:|блокер|blocked:|остановлен|ждёт согласования" \
  {{HOME_DIR}}/.claude/projects/*/memory/MEMORY.md 2>/dev/null
```

Для каждого найденного паттерна:
1. Определить номер РП (WP-NNN) из контекста строки
2. Найти WP-context: `ls DS-my-strategy/inbox/WP-{N}-*.md` (если заархивирован — `archive/wp-contexts/`)
3. Прочитать секцию «Что узнали» / «Осталось» / финальный статус
4. Если там есть признак закрытия (`DONE`, `РЕШЕНО`, `✅`, `починил`, `закрыт`, `снят`) рядом с тем же именем/системой → обновить MEMORY.md, анонс: *«Memory drift: [факт] устарел → обновлён»*
5. Если WP-context не найден → отметить в итогах: *«Memory drift: WP-N — context не найден, проверить вручную»*

Анонс при 0 изменениях: *«Drift-scan: проверено N паттернов, устаревших фактов не найдено»*

### 4в. Index Health Check

> Ловит раздутие индекс-файлов (MEMORY.md, WP-REGISTRY.md, MAPSTRATEGIC.md, *-registry.md, *-index.md, *-catalog.md). Правило: [feedback_memory_index_discipline.md](../../../memory/feedback_memory_index_discipline.md) — шапки и колонки индексов = hook-строки, не дамп контекста.

```bash
python3 {{HOME_DIR}}/IWE/DS-my-strategy/scripts/check-index-health.py
```

Для каждого FAIL/WARN в отчёте:
1. Открыть файл, посмотреть конкретные строки/ячейки из отчёта.
2. Диагностика: это дамп контекста (болезнь) или методологическая таблица (жанр)?
   - Дамп → перенести контекст в source-of-truth (inbox/WP-NNN-*.md, WeekPlan, отдельный `*-changelog.md`); в индексе — hook + ссылка.
   - Жанр (таблица-матрица, каталог доменных сущностей) → пометить в начале файла: `<!-- index-health: skip-cells -->` или `<!-- index-health: skip -->` с обоснованием в комментарии.
3. Если FAIL в Pack-файле — не чистить автоматически, это вопрос к владельцу домена (только пометить skip с обоснованием).

Анонс при 0 WARN/FAIL: *«Index-health: N файлов OK, M skip»*. При наличии — перечислить FAIL/WARN с кратким действием.

### 4. Lesson Hygiene

- Просмотреть секцию «Уроки» в MEMORY.md
- Урок применялся сегодня? → оставить
- Урок не применялся >1 нед и есть в тематическом файле (`lessons_*.md`)? → удалить из MEMORY.md
- Новый урок за день? → записать в MEMORY.md (краткая строка) + тематический файл (подробно)
- Цель: ≤8 уроков в MEMORY.md

### 5. Автоматические шаги

```bash
"$IWE_SCRIPTS/day-close.sh"
```

Скрипт выполняет: Linear sync, downstream sync (update.sh), backup (memory/ + CLAUDE.md).

### 6. Мультипликатор IWE

> Условный шаг: если `params.yaml → multiplier_enabled: false` → пропустить.

**Алгоритм:**

1. **WakaTime** — физическое время за день (`wakatime --today`)
2. **Бюджет закрыт** — сумма бюджетов по ВСЕМ РП за день:
   - done → полный бюджет (или пропорционально фазам для зонтичных)
   - partial → % выполнения × бюджет
   - not started → 0h
   - Мелкие РП (бюджет «—» / merged) → 0.25h, не 0
3. **Мультипликатор дня** = Бюджет закрыт / WakaTime. Формат: `N.Nx`

### 7. Черновик итогов (показать пользователю)

**а) Обзор:** таблица «что сделано» (РП × статус)

**б) Что нового узнал:** captures в Pack, различения, инсайты.

**в) Похвала:** что получилось, что было непросто но сделано.

**г) Не забыто?**
- Незакоммиченные изменения: `${IWE_SCRIPTS}/check-dirty-repos.sh` (сканирует ВСЕ репо, включая вложенные DS-IT-systems/*, DS-MCP/*). Если есть грязные → закоммитить и запушить ДО продолжения.
- **EXTENSION POINT (day-close checks):** `bash .claude/scripts/load-extensions.sh day-close checks` — exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/day-close.checks.md` И `extensions/day-close.checks.<suffix>.md`.
- Незаписанные мысли? (спросить пользователя)
- Обещания кому-то? (спросить пользователя)

**д) Видео за день:** если `video.enabled: true` → проверить новые видео.

**е) Draft-list:** Pack обогащён → предложить черновик?

**ж) Задел на завтра:**
- С чего начать утром
- Незавершённые РП: что именно осталось (конкретный next action по каждому)

### 8. Согласование

Пользователь читает черновик → корректирует → одобряет.

### 9. Запись итогов

**9a.** Дописать секцию «Итоги дня» в DayPlan (шаблон — см. `memory/templates-dayplan.md § Шаблон итогов дня`).

**Валидация «Завтра начать с» (ADR-207):** поле не пустое + каждый pending РП упомянут + каждый содержит конкретный next action (не «продолжить работу»).

**9b.** Дописать сводку итогов в WeekReport (split, ОПТ-5 WP-297):
- Файл: `DS-my-strategy/current/WeekReport W{N} YYYY-MM-DD.md` (дата = первый день недели)
- Если файла нет (старый цикл) — fallback в WeekPlan, пометить «требует split в session-prep следующей недели»
- Формат: `<details><summary><b>Итоги {день} {дата}</b></summary>...</details>`
- Порядок: свежие итоги СВЕРХУ (обратная хронология)
- Содержание: таблица коммитов по репо, закрытые РП, продвинутые РП, мультипликатор

**Postcondition 9b (машинная проверка — НЕ пропускать):**
```bash
TODAY=$(date +%Y-%m-%d)
DAY_NUM=$(date +%-d)
# Сначала проверь WeekReport (split ОПТ-5), fallback на WeekPlan
( grep -rl "Итоги.*${DAY_NUM}" ~/IWE/DS-my-strategy/current/WeekReport\ W*.md 2>/dev/null \
  || grep -rl "Итоги.*${DAY_NUM}" ~/IWE/DS-my-strategy/current/WeekPlan\ W*.md 2>/dev/null ) \
  | grep -q . && echo "9b OK" || echo "9b FAIL: итоги не найдены ни в WeekReport, ни в WeekPlan"
```
Результат `9b FAIL` → шаг НЕ помечать completed, вернуться к записи.

### 10. Закоммитить DS-my-strategy

### 10b. Rule Classifier (WP-272 Ф5.2)

```bash
python3 $HOME/IWE/.claude/scripts/rule-classifier.py
```

Запускается после коммита. Обогащает журнал `~/logs/rule-engine/YYYY-MM-DD.jsonl` → `YYYY-MM-DD-classified.jsonl`. Exit код игнорировать (launchd тоже запускает раз в час — идемпотентно). Не ждать завершения если >60 сек (kill).

### 11. Верификация (Haiku R23)

Запустить sub-agent Haiku в роли R23 Верификатор (context isolation).
Передать: (1) чеклист Day Close, (2) черновик итогов, (3) список обновлённых файлов.
По ❌ — исправить до показа пользователю.

**EXTENSION POINT (day-close checks):** `bash .claude/scripts/load-extensions.sh day-close checks` — exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/day-close.checks.md` И `extensions/day-close.checks.<suffix>.md`.

---

## Чеклист Day Close

- [ ] Все изменения закоммичены и запушены (по всем репо)
- [ ] MEMORY.md: done-РП удалены, активные актуальны, drift-scan выполнен (шаг 4б)
- [ ] Index Health Check (шаг 4в): `check-index-health.py` — все FAIL/WARN разобраны или помечены skip
- [ ] WP-REGISTRY.md обновлён
- [ ] WeekPlan обновлён (grep по номерам РП — ВСЕ упоминания)
- [ ] DayPlan обновлён (статусы ВСЕХ строк: РП + ad-hoc)
- [ ] open-sessions.log: строки закрытых сессий удалены
- [ ] Captures за день применены (все Quick Close → KE пройден)
- [ ] Синхронизация downstream: `update.sh` выполнен
- [ ] Linear sync: статусы соответствуют git. Пост-sync чек: кол-во active РП в REGISTRY = кол-во active issues в Linear
- [ ] Repo CLAUDE.md: feat-коммиты → новые правила?
- [ ] DayPlan сегодня → `archive/day-plans/` (старые DayPlan'ы в `current/` тоже)
- [ ] WP context: done → `mv inbox/ → archive/wp-contexts/`
- [ ] Lesson Hygiene: уроки MEMORY.md ≤8
- [ ] Draft-list: Pack обогащён → черновик предложен?
- [ ] Видео: обработанные помечены (если video.enabled)
- [ ] Governance: REPOSITORY-REGISTRY, navigation.md, MAP.002
- [ ] Backup: `day-close.sh` выполнен
- [ ] **Rule-engine FP-stats** (WP-272 Ф2.5): `python3 ~/IWE/.claude/scripts/fp-stats.py --date $(date +%Y-%m-%d)` → если есть `⚠️ REVISE` (FP > 20%) — записать в «Завтра начать с» правило + FP%. Флоу ревизии: `~/IWE/PACK-agent-rules/revision-flow.md`.
- [ ] Верификация compliance: /verify запускался сегодня?
- [ ] WakaTime + Мультипликатор: часы, бюджет, остаток недели
- [ ] Итоги дня записаны в DayPlan
- [ ] Handoff-валидация: «Завтра начать с» содержит ВСЕ pending РП с конкретным next action
- [ ] Сводка итогов записана в WeekReport (`<details>`, обратная хронология) **(postcondition 9b: grep подтверждён)**
- [ ] Новое репо → MAPSTRATEGIC.md + Strategy.md

Все ✅ → «День закрыт.» Иначе — указать что осталось.
