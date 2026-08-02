---
name: day-close
description: "Протокол закрытия дня (Day Close). Алиас для /run-protocol close day — симметрия с /day-open."
argument-hint: ""
version: 1.1.0
layer: L1
status: active
triggers:
  slash: [/day-close]
  phrases: []
routing:
  executor: haiku
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# Day Close (протокол закрытия дня)

> **Роль:** R1 Стратег. **Бюджет с пилотом: ~3 мин** (ретро + приоритеты) + **полное закрытие агент доводит один** (~10 мин, без пилота).
> **Принцип (DP.D.288, WP-484 30.07 — быстрое закрытие ≠ полное закрытие):** быстрое закрытие происходит быстро ДЛЯ ПИЛОТА — короткий свод + рефлексия, не механика. Полное закрытие агент делает сам сразу после, архивирует, пилот видит на следующий день/по запросу.
> **Принцип:** SKILL.md = L1 платформенный файл. Пользователь не редактирует напрямую — только через `extensions/`.

## When to use

Протокол закрытия дня (Day Close). Алиас для /run-protocol close day — симметрия с /day-open.

## БЛОКИРУЮЩЕЕ: пошаговое исполнение

Day Close = протокол. Исполнять ТОЛЬКО пошагово через TodoWrite.
**Шаг 0 — ПЕРВОЕ действие:** создать список задач ТОЛЬКО для Части А (все шаги до «Ты свободен» включительно) — пилот не должен видеть механику Части Б раньше хендоффа (принцип DP.D.288 выше).
**Сразу после «Ты свободен»:** одним пакетом завести в списке задач все шаги Части Б — теперь можно, пилот уже свободен.
Каждый шаг алгоритма → отдельная задача (pending → in_progress → completed).
Переход к следующему — ТОЛЬКО после отметки текущего. Шаг невозможен → blocked (не пропускать молча).

## Algorithm

### 0. Extensions (before) [[narrative]]
Загрузить: `bash .claude/scripts/load-extensions.sh day-close before`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить как первые шаги. Exit 1 → пропустить. Поддерживает `extensions/day-close.before.md` И `extensions/day-close.before.<suffix>.md`.

### 0.5. Housekeeping-сессия Day Close [[gate]]
Day Close — кросс-РП инфраструктурная операция. Открыть упрощённую housekeeping-сессию, чтобы `session-guard` не блокировал коммит файлов, к которым нет привязки к открытому РП (например, backup `exocortex/` или архивация DayPlan).

```bash
bash ~/IWE/scripts/day-close-step-log.sh start 0.5
bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" open --housekeeping day-close --agent claude-code
bash ~/IWE/scripts/day-close-step-log.sh end 0.5
```

Закрыть её — только после п. 10 (после `git push`). Если сессия прервалась, TTL 30 мин переименует семафор в `.stale` при следующем запуске.

### 0.6. Git-lock против гонки двух закрытий (WP-484 Ф2) [[gate]]

> Инцидент 17.07: сервер (tsekh-1) и пилот вручную закрыли один день независимо, разъезд обнаружился только на commit+push. Применяется одинаково к обоим путям закрытия — серверный `run_claude day-close` (диспетчер `scheduler.sh`) заходит в этот же SKILL.md, отдельно патчить `scheduler.sh` не нужно.

```bash
bash ~/IWE/scripts/day-close-step-log.sh start 0.6
bash {{HOME_DIR}}/IWE/scripts/day-close-lock.sh acquire
bash ~/IWE/scripts/day-close-step-log.sh end 0.6
```

- Exit 0 → лок взят (закоммичен и запушен маркер `day-close-start: YYYY-MM-DD`), продолжать к шагу 1.
- Exit 1 → день уже закрыт сегодня (найден финальный коммит `day-close:`) — **остановиться немедленно**, закрыть housekeeping-семафор (`bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" close --housekeeping day-close --agent claude-code`), сообщить пилоту «день уже закрыт», не выполнять шаги 1-16 повторно.
- Exit 3 → кто-то закрывает день прямо сейчас (свежий, <30 мин, маркер `day-close-start:` от другого агента/хоста) — **остановиться**, закрыть housekeeping-семафор (`bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" close --housekeeping day-close --agent claude-code`), сообщить пилоту кем и когда, предложить подождать или проверить вручную.
- Exit 2 → git-операция не удалась (сеть/конфликт) — не считать день закрытым, сообщить пилоту причину, предложить повтор. Housekeeping-семафор не закрывать — повторный `acquire` пойдёт в рамках той же сессии.

---

## ЧАСТЬ А. Быстрое закрытие (с пилотом, ~3 мин)

> **DP.D.288.** Единственная цель этой части — короткий свод + рефлексия пилота. Никакой механики здесь не считается и не пишется (кроме самого свода из уже готовых данных) — механика вся в Части Б, без пилота.

### 1. Предварительный свод дня [[narrative]]

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

Показать пилоту 3-5 строк: что сделано сегодня (не таблицу статусов РП — та собирается в Части Б без него). Начать с подписи: **«Предварительный свод дня — снимок для рефлексии, не итоговые цифры»**. Это ранний снимок накопленного, который стимулирует рефлексию (DP.D.288); окончательные цифры и проверки появятся только после Части Б.

### 2. Единый блок вопросов (WP-484 Ф36, 01.08 — было 2 отдельных хода пилота, слито в один) [[gate]]

> Раньше ретро (шаг 2) и приоритеты+часы (шаг 3) были двумя отдельными ожиданиями ответа пилота подряд — два раунд-трипа вместо одного. Объединение не меняет, ЧТО спрашивается и куда пишется — только сколько раз пилот отвечает.

Подсказка активных РП, чтобы пилот не вспоминал номера вручную:
```bash
grep -oE "WP-[0-9]+" "{{HOME_DIR}}/IWE/DS-my-strategy/current/DayPlan $(date +%F).md" 2>/dev/null | sort -u | head -10
```

Задать ОДНИМ сообщением (не тремя отдельными ходами), рефлексия по-прежнему обязательна (решение пилота 30.07, CONCEPT-night-cycle.md §22), приоритеты и часы — можно пропустить по отдельности:
- «Что сегодня сработало хорошо? Что не сработало, какой был затык?»
- «1–3 приоритета на завтра (номера РП из списка выше или свои, первый = важнее всего) — или "пропустить"»
- «Часы саморазвития сегодня (0/0.5/1/2/3/4 или свой ответ) — или "пропустить"»

Дождаться ОДНОГО ответа пилота на всё сразу (по пунктам или общей фразой — разобрать по смыслу, не требовать строгого формата). Пустой ответ на рефлексию — записать «нет ответа», не пропускать вопрос молча.

Разнести ответы по получателям (объединение сообщения не объединяет хранилище):

**1. Ретро → ledger:**
```bash
python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "<ответ на вопрос 1>" # экранирование
```
```bash
RETRO_JSON="{\"subtype\": \"preclose_retro\", \"retro_worked\": <экранированный ответ 1>, \"retro_failed\": <экранированный ответ 2>}"
bash ~/IWE/DS-my-strategy/scripts/ledger-append.sh day "$(date +%F)" pilot_answer "$RETRO_JSON" day-close
```
Формулировка и поля идентичны `scripts/day-preclose.sh` — тот же скрипт остаётся терминальным запасным путём.

**2. Приоритеты → `current/priorities.yaml`** (пропущено пилотом → файл не трогать; Day Open покажет stale-предупреждение при устаревании ≥3 дня):
```yaml
# Утренние приоритеты на сегодня — обновлять вечером или утром
# Порядок = убывающий приоритет (первый = самый важный)
# Пустой список = fallback на вчерашний перенос в Day Open
last_updated: "YYYY-MM-DD"
today:
  - WP-NNN
  - WP-MMM
```
`last_updated` = завтрашняя дата (`date -v+1d +%Y-%m-%d 2>/dev/null || date -d "tomorrow" +%Y-%m-%d`). Добавить файл в список изменений для коммита на шаге 15 (если перезаписывался).

**3. Часы саморазвития (WP-310 Ф13c) → подсказка боту, не файл.** Пропущено пилотом → пометить «не записано», не блокировать. Иначе — подсказать команду `/slot N` в @aist_pilot_me или @aist_me_bot (handler пишет slot_logged event с source='self_report_daily').

### 3. «Ты свободен» [[gate]]

Сказать пилоту: **«Ты свободен, дальше довожу закрытие дня сам»** — и продолжить Часть Б (governance-batch, архивация, метрики, верификация, коммит) без дальнейшего участия пилота. Записать факт передачи в ledger:

```bash
bash ~/IWE/DS-my-strategy/scripts/ledger-append.sh day "$(date +%F)" conversational_close_done '{"source":"interactive-skill","handoff":"pilot_free"}'
```

---

## ЧАСТЬ Б. Полное закрытие (агент один, без пилота)

> Всё, что ниже, — существующий состав Day Close без единого удалённого шага (WP-484, исправление 30.07 — night-cycle-day.sh/day-close-mechanical.sh покрывают ТОЛЬКО архивацию DayPlan + чистку open-sessions.log + index-health, не весь governance-batch; удалять остальное значило бы тихо терять WP-REGISTRY-синк, Linear-синк, бэкапы, мультипликатор). Разница с прежним порядком — только в том, что пилот уже свободен и не ждёт.
> Нумерация ниже намеренно продолжает старую (5, 6, 7...) — «шаг 4» не существует (Ф36, 01.08 — старые шаги 2+3 слиты в один «2», Часть Б не перенумерована во избежание рассинхрона перекрёстных ссылок между файлами).

### 5. Governance batch

**5a.** `bash ~/IWE/scripts/day-close-step-log.sh start 2a` — Обновить WeekPlan (`DS-my-strategy/current/Plan W{N}...`): статусы РП. **Grep по номеру РП** — обновить ВСЕ упоминания. `bash ~/IWE/scripts/day-close-step-log.sh end 2a` [[gate]]

**5b.** `bash ~/IWE/scripts/day-close-step-log.sh start 2b` — Обновить DayPlan `DS-my-strategy/current/DayPlan YYYY-MM-DD.md`: статусы ВСЕХ строк (РП + ad-hoc). Done → зачеркнуть. `bash ~/IWE/scripts/day-close-step-log.sh end 2b` [[gate]]

**5c.** `bash ~/IWE/scripts/day-close-step-log.sh start 2c` — Обновить `DS-my-strategy/docs/WP-REGISTRY.md`: статусы + даты + **done-форматирование**. Done-РП → зачеркнуть номер, приоритет, название, репо, бюджет (`~~...~~`); снять bold с названия; эмодзи ✅ НЕ зачёркивать (см. `.claude/rules/formatting.md §Таблицы с РП`). Тильду внутри ячеек заменить (`~6.5h` → `6.5h`). `bash ~/IWE/scripts/day-close-step-log.sh end 2c` [[gate]]

**5d.** `bash ~/IWE/scripts/day-close-step-log.sh start 2d` — Обновить `DS-my-strategy/inbox/open-sessions.log`: удалить строки закрытых сессий. `bash ~/IWE/scripts/day-close-step-log.sh end 2d` [[gate]]

**5e.** Governance-синхронизация: новые репо/сервисы за день? → REPOSITORY-REGISTRY, navigation.md, MAP.002. [[narrative]]

**5f. WeekReport — ФАКТЫ ДНЯ (новый шаг, ОПТ-5):** [[narrative]] Если Week Open завершена (есть WeekReport W{N}.md):
  - Открыть `DS-my-strategy/current/WeekReport W{N} YYYY-MM-DD.md`
  - Добавить новый раздел `<details><summary><b>Итоги {День} {Дата}</b></summary>` **перед** `Итоги Пн-Вс` (в обратном порядке дат: сегодня → старше)
  - Содержимое: коммиты по репо, РП-статусы за день, carry-over блокеры
  - Формат: смотреть существующие разделы в WeekReport (таблицы, метрики, мультипликатор)
  - **Правило ОПТ-5:** WeekPlan содержит ТОЛЬКО намерения (план, carry-over на завтра), WeekReport содержит ТОЛЬКО факты (что было, коммиты, результаты)
  - **strategy_day (Пн без DayPlan):** Итоги пишутся в WeekReport как обычный день — только факты (РП-результаты, коммиты, мультипликатор). Плановые строки (`strategy_day → план живёт в WeekPlan`) в WeekReport НЕ копировать. Позиция в обратной хронологии: если Пн — ставить в конец (самый старый день недели).

**5g. WP Context Freshness (БЛОКИРУЮЩЕЕ).** [[gate]] `bash ~/IWE/scripts/day-close-step-log.sh start 2g`. 5a-5c обновляют трекеры (WeekPlan/DayPlan/REGISTRY) — статус-строку, не сам контекст-файл РП. Для каждого РП, тронутого хотя бы одной сессией сегодня (`grep "$(date +%Y-%m-%d)" sessions/00-index.md` + одиночные Quick Close сессии за день): открыть `inbox/WP-N/WP-N.md` **точечно** (grep по номеру/дате сегодняшней сессии → Read с `offset` вокруг найденной строки, не весь файл целиком — для зонтичных РП полное перечитывание дорого, WP-484 peer-session 2026-07-18-13 находка), свериться с §4/§6 отчётов всех сегодняшних сессий по этому РП — суб-пункты, которые сессия закрыла или нашла уже закрытыми, должны быть отмечены done в контекст-файле, а не только в статус-строке трекера. Несколько сессий трогали один зонтичный РП за день → одно согласованное состояние на конец дня, не разрозненные пере-перезаписи. Source: [2026-07-09-17-close-actualization-gap](../../../DS-my-strategy/sessions/2026-07/2026-07-09-17-close-actualization-gap/report.md). `bash ~/IWE/scripts/day-close-step-log.sh end 2g`

### 6. Архивация [[gate]]

`bash ~/IWE/scripts/day-close-step-log.sh start 3`

- **DayPlan сегодняшнего дня** → `git mv current/DayPlan $(date +%Y-%m-%d).md archive/day-plans/`. Если есть DayPlan'ы прошлых дней в `current/` (накопленный мусор) — заархивировать их тоже одной командой.
- Done WP context files → `mv inbox/WP-{N}-*.md → archive/wp-contexts/`
- Done РП → удалить строку из MEMORY.md (они уже в WP-REGISTRY и WeekPlan)

> MEMORY.md хранит ТОЛЬКО активные РП (in_progress + pending). Done = удалить.
> Архивация DayPlan ОБЯЗАТЕЛЬНА: следующий Day Open читает carry-over из `archive/day-plans/DayPlan {вчера}.md` и предполагает, что `current/` чистый.

`bash ~/IWE/scripts/day-close-step-log.sh end 3`

### 7. Memory Drift Scan [[gate]]

`bash ~/IWE/scripts/day-close-step-log.sh start 4b`

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

`bash ~/IWE/scripts/day-close-step-log.sh end 4b`

### 8. Index Health Check [[gate]]

`bash ~/IWE/scripts/day-close-step-log.sh start 4v`

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

`bash ~/IWE/scripts/day-close-step-log.sh end 4v`

### 9. Lesson Hygiene [[gate]]

`bash ~/IWE/scripts/day-close-step-log.sh start 4-lessons`

- Просмотреть секцию «Уроки» в MEMORY.md
- Урок применялся сегодня? → оставить
- Урок не применялся >1 нед и есть в тематическом файле (`lessons_*.md`)? → удалить из MEMORY.md
- Новый урок за день? → записать в MEMORY.md (краткая строка) + тематический файл (подробно)
- Цель: ≤8 уроков в MEMORY.md

`bash ~/IWE/scripts/day-close-step-log.sh end 4-lessons`

### 10. Автоматические шаги [[gate]]

```bash
bash ~/IWE/scripts/day-close-step-log.sh start 5
cd {{HOME_DIR}}/IWE/DS-my-strategy && python3 scripts/process-runner.py start day-close
bash ~/IWE/scripts/day-close-step-log.sh end 5
```

Раннер проходит `scripts/processes/day-close.yaml` целиком за один вызов (оба шага — reflex, без паузы на пилота, WP-482 Ф4): `run-automated-steps` вызывает тот же `day-close.sh` (Linear sync, downstream sync, backup memory/+CLAUDE.md+AGENTS.md), но проверяет реальный результат по строке статуса в выводе, а не по exit-коду (`day-close.sh` его не выставляет) — `handlers/day-close-run.sh` ловит то, что раньше при голом вызове проходило молча как успех; затем `facts-digest-append` пишет `facts_digest` в леджер (дублирует шаг 11 ниже — безопасно, тот идемпотентен, не создаёт дубль записи).

Прочитать JSON-вывод раннера: `"status": "completed"` → всё прошло, продолжать. Другой статус (`waiting_input`/`blocked`, шаг `run-automated-steps` вернул `passed: false`) → пилота уже нет, ждать некого — записать деталь из карточки (`.results."run-automated-steps".detail`) в DayPlan «Требует внимания» и продолжить к шагу 11, не останавливая Часть Б.

> **Смена поведения (2026-07-31):** до этой правки шаг вызывал `day-close.sh` напрямую и не проверял результат вообще — сбой синка проходил молча. Решение о переносе на раннер согласовано 24.07 (WP-484.md, «Закрытие дня — НЕ переключать» — единственный тогда одобренный вариант: раннер только ВНУТРИ этого шага, остальные 19 шагов не трогать), отложено до снятия блокера (read-only копия файла) и с тех пор не доведено. Блокер снят (файл перестал быть read-only), правка внесена сейчас.

### 11. Facts Digest (ledger) — WP-484 Ф16.3 [[narrative]]

```bash
bash ~/IWE/scripts/day-close-step-log.sh start 5b
bash "{{HOME_DIR}}/IWE/DS-my-strategy/scripts/day-close-prepare.sh" --for-date "$(date +%F)" || true
bash ~/IWE/scripts/day-close-step-log.sh end 5b
```

Записывает одно событие `facts_digest` в дневной ledger (`DS-my-strategy/machine/ledger/day-YYYY-MM-DD.yaml`) — источник данных для завтрашнего Day Open (шаг «4.3. Ledger render», `day-open-ledger-render-patch.py`, WP-484 Ф16.2). Место шага: сразу после автоматических шагов (10), потому что `day-close-prepare.sh` читает `linear=...` из свежего лога `day-close.sh` (шаг 10) и требует, чтобы данные по коммитам/сессиям за день уже устоялись. Идемпотентно (проверяет по факту в ledger, не по exit-коду) — повторный запуск в тот же день не создаёт дубль.

**Некритичный шаг (как и `14b. Rule Classifier` ниже):** `|| true` — сбой `day-close-prepare.sh` или недоступность `ledger-append.sh` НЕ блокирует остальной прогон Day Close. При сбое Day Open просто покажет честный PENDING вместо реальных данных вместо того, чтобы прогон остановился (CONCEPT-night-cycle.md §5: «сбой шага → Telegram + честный PENDING, не блокирует остальной прогон»).

### 12. Мультипликатор IWE [[gate]]

`bash ~/IWE/scripts/day-close-step-log.sh start 6`

> Условный шаг: если `params.yaml → multiplier_enabled: false` → пропустить.

**Алгоритм:**

1. **WakaTime** — физическое время за день:
   - Сначала CLI: `~/.wakatime/wakatime-cli --today` (CLI не в PATH, бинарник в `~/.wakatime/`)
   - Если CLI недоступен → **fallback Neon**: `SELECT payload->>'human_readable', payload->>'total_seconds' FROM learning.public.domain_event WHERE event_type='coding_time' AND account_id='{DT_USER_ID}' AND external_id='wakatime:{DT_USER_ID}:{YYYY-MM-DD}'`
   - Если Neon тоже пуст (данные синхронизируются ночью) → пометить «pending Neon» и пересчитать при следующей сессии
   - Поле: `payload->>'human_readable'` (напр. «9 hrs»); `total_seconds` для мультипликатора
2. **Бюджет закрыт — считать ПО ФАКТУ, не по букве плана** (БЛОКИРУЮЩЕЕ, урок 27 мая):
   - **Шаг 2.0 (обязательный prerequisite):** открыть `<governance-repo>/sessions/00-index.md`, отфильтровать строки за сегодня (`grep "$(date +%Y-%m-%d)"`), составить полный список peer-сессий с числом ходов. Без этого расчёт занижен ×2. **Число ходов — не пересчитывать вручную**: `turns_count` уже посчитан в `meta.yaml` каждой сессии (`grep turns_count sessions/2026-MM/DD/2026-MM-DD-*/meta.yaml`) — брать оттуда (WP-484 peer-session 2026-07-18-13).
   - done → полный бюджет (или пропорционально фазам для зонтичных)
   - partial → % выполнения × бюджет; **если сверхплановая работа в плановом РП** (например, план Ф1, реализовано Ф1+Ф7) — засчитывать ФАКТ, не плановый бюджет
   - not started → 0h
   - **ad-hoc peer-сессии (без РП-метки в DayPlan): оценка по числу ходов**, НЕ заглушка 0.25h:
     - 2-4 хода → 0.25-0.5h
     - 5-7 ходов → 0.75-1h
     - 8+ ходов → 1-1.5h
   - **Мелкие правки/чистки без peer-сессии** (бюджет «—» / merged) → 0.25h
3. **Мультипликатор дня** = Бюджет закрыт / WakaTime. Формат: `N.Nx`
4. **Sanity check (БЛОКИРУЮЩЕЕ):** если получившийся мультипликатор <1.5x при дне с ≥10 peer-сессий — пересчитать (вероятен недосчёт ad-hoc или сверхпланового). Пилота уже нет на связи (Часть А завершена) — записать все 3 метода (буква SKILL / по факту / компромисс) в DayPlan секцию «Требует внимания» с явной пометкой «мультипликатор пересчитан автоматически методом X, сверить при следующей сессии», не блокировать закрытие ожиданием ответа. Урок: `lessons_multiplier_peer_sessions_uncounted.md`.

`bash ~/IWE/scripts/day-close-step-log.sh end 6`

### 13. Черновик итогов (записать в DayPlan) [[narrative]]

> Пилот уже свободен (Часть А завершена) — этот шаг больше не ждёт согласования (см. п.14 ниже), это фиксация фактов агентом в одиночку.

**а) Обзор:** таблица «что сделано» (РП × статус)

**б) Что нового узнал:** captures в Pack, различения, инсайты.

**в) Похвала:** что получилось, что было непросто но сделано.

**г) Не забыто?**
- Незакоммиченные изменения: `${IWE_SCRIPTS}/check-dirty-repos.sh` (сканирует ВСЕ репо, включая вложенные DS-IT-systems/*, DS-MCP/*). Если есть грязные → закоммитить и запушить ДО продолжения. [[gate]]
- **EXTENSION POINT (day-close checks):** `bash .claude/scripts/load-extensions.sh day-close checks` — exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/day-close.checks.md` И `extensions/day-close.checks.<suffix>.md`.
- Незаписанные мысли / обещания кому-то — если упоминались раньше в сессии, зафиксировать в «Требует внимания», не спрашивать (пилот свободен).

**д) Видео за день:** если `video.enabled: true` → проверить новые видео. [[narrative]]

**е) Draft-list:** Pack обогащён за день → записать кандидата в `drafts/draft-list.md` (пилот уже свободен — не спрашивать вживую, зафиксировать как candidate на следующий разбор). [[narrative]]

**ж) Задел на завтра:** [[narrative]]
- С чего начать утром
- Незавершённые РП: что именно осталось (конкретный next action по каждому)

### 14. Запись итогов

`bash ~/IWE/scripts/day-close-step-log.sh start 9a`

**14a.** [[gate]] Дописать секцию «Итоги дня» в DayPlan (шаблон — см. `memory/templates-dayplan.md § Шаблон итогов дня`).

**Валидация «Завтра начать с» (ADR-207):** поле не пустое + каждый pending РП упомянут + каждый содержит конкретный next action (не «продолжить работу»).

**Postcondition 14a (машинная проверка — НЕ пропускать):**
```bash
TODAY=$(date +%Y-%m-%d)
bash ~/IWE/DS-my-strategy/scripts/day-close-prepare.sh --verify-dayplan --for-date "$TODAY"
```
Результат `14a FAIL` → шаг НЕ помечать completed, вернуться к записи.

`bash ~/IWE/scripts/day-close-step-log.sh end 9a`
`bash ~/IWE/scripts/day-close-step-log.sh start 9b`

**14b.** [[gate]] Дописать сводку итогов в WeekReport (split, ОПТ-5 WP-297):
- Файл: `DS-my-strategy/current/WeekReport W{N} YYYY-MM-DD.md` (дата = первый день недели)
- Если файла нет (старый цикл) — fallback в WeekPlan, пометить «требует split в session-prep следующей недели»
- Формат: `<details><summary><b>Итоги {день} {дата}</b></summary>...</details>`
- Порядок: свежие итоги СВЕРХУ (обратная хронология). Проверять: вставлять сразу ниже `</details>` последнего W18-summary, а не в конец файла.
- Содержание: таблица коммитов по репо, закрытые РП, продвинутые РП, мультипликатор

**Postcondition 14b (машинная проверка — НЕ пропускать):**
```bash
TODAY=$(date +%Y-%m-%d)
# Сначала проверяет WeekReport (split ОПТ-5), затем WeekPlan; имена с пробелами безопасны.
bash ~/IWE/DS-my-strategy/scripts/day-close-prepare.sh --verify-week-summary --for-date "$TODAY"
```
Результат `14b FAIL` → шаг НЕ помечать completed, вернуться к записи.

`bash ~/IWE/scripts/day-close-step-log.sh end 9b`

### 15. Закоммитить DS-my-strategy [[gate:AR.005]]

```bash
bash ~/IWE/scripts/day-close-step-log.sh start 10
cd {{HOME_DIR}}/IWE/DS-my-strategy
git status --short
# НЕ git add -A/git add ./git add -u — AGENTS.md CRITICAL (может захватить работу других агентов)
# Стейджить ТОЛЬКО файлы, изменённые в шагах 5-14 (в массив для pathspec):
DC_FILES=(<каждый файл явным путём: WeekPlan, WeekReport, WP-REGISTRY, archive/day-plans/*, inbox/WP-*.md и т.д.>)
# Если на шаге 3 обновлялись утренние приоритеты:
DC_FILES+=({{HOME_DIR}}/IWE/DS-my-strategy/current/priorities.yaml)
git add "${DC_FILES[@]}"
git diff --cached --name-only  # проверить scope — только day-close файлы
# pathspec после `--`: commit ТОЛЬКО свои файлы, не подметаем чужой индекс
git commit -m "day-close: $(TZ=UTC date +%Y-%m-%d)" -- "${DC_FILES[@]}"
git push

# Закрыть housekeeping-сессию Day Close (открыта в п. 0.5)
bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" close --housekeeping day-close --agent claude-code
bash ~/IWE/scripts/day-close-step-log.sh end 10
```

### 16. Rule Classifier (WP-272 Ф5.2) [[narrative]]

```bash
python3 $HOME/IWE/.claude/scripts/rule-classifier.py
```

Запускается после коммита. Обогащает журнал `~/logs/rule-engine/YYYY-MM-DD.jsonl` → `YYYY-MM-DD-classified.jsonl`. Exit код игнорировать (launchd тоже запускает раз в час — идемпотентно). Не ждать завершения если >60 сек (kill).

### 17. Верификация (Haiku R23) [[gate:AR.007]]

`bash ~/IWE/scripts/day-close-step-log.sh start 11`

Перед запуском R23 — `bash .claude/hooks/rule-engine.sh check-trace-satisfaction --protocol .claude/skills/day-close/SKILL.md` (WP-481 Ф5.1: удовлетворённость набора gate протокола, не линейность; narrative-пропуски не блокируют). **Без `--protocol`** дефолт — `memory/protocol-close.md`, который содержит гейты Quick Close/Week Close/Exit Protocol, а не Day Close — блок гарантирован на посторонних гейтах. Шаги 0-16 выше размечены `[[gate]]`/`[[narrative]]` (WP-481 Ф5.1) — каждый `[[gate]]` выведен из соответствующей строки «Чеклист Day Close» ниже, не придуман заново. Verdict block → вернуться на незакрытый gate, потом R23.

**Проверка целостности тайминга шагов (WP-484 peer-session 2026-07-18-13).** `day-close-step-log.sh` пишет метки в `TZ=UTC` — дата в проверке ниже ОБЯЗАНА браться тем же поясом (иначе возле полуночи по местному времени пилота проверка ложно найдёт «0 аномалий», просто заглянув не в ту календарную дату — сама метрика тогда врёт молча, ровно то, против чего она построена): `grep "$(TZ=UTC date +%Y-%m-%d)" ~/logs/day-close-integrity.log` — есть ли аномалии за сегодня (неизвестный step_id, дубль start, end без start, немонотонность)? И `grep -c "$(TZ=UTC date +%Y-%m-%d).*start" ~/logs/day-close-steps.log` vs `grep -c "$(TZ=UTC date +%Y-%m-%d).*end" ~/logs/day-close-steps.log` — совпадает число start/end? Не блокирует закрытие дня — только доверие к метрике за сегодня (см. чеклист ниже).

Запустить sub-agent Haiku в роли R23 Верификатор (context isolation).
Передать: (1) чеклист Day Close, (2) черновик итогов, (3) список обновлённых файлов, (4) результат шага 5g (по каждому РП: контекст-файл поправлен или расхождений не было), (5) JSON вердикта trace-satisfaction, (6) результат проверки целостности тайминга шагов (аномалии из `day-close-integrity.log` + баланс start/end).
По ❌ — исправить до показа пользователю. Исключение: ❌ только по пункту «тайминг шагов» (последний чеклист-пункт ниже) — не исправлять постфактум (дописывать правдоподобный timestamp запрещено, это и есть тихая подмена данных), просто показать пилоту предупреждение «данные тайминга за сегодня не заслуживают доверия» и продолжить закрытие дня.

`bash ~/IWE/scripts/day-close-step-log.sh end 11`

### Recovery: `night_cycle_complete` за сегодня отсутствует (WP-484 Нить 4) [[narrative]]

Если интерактивное закрытие дня запускается ПОСЛЕ обычного времени ночного тика, и в `machine/ledger/day-YYYY-MM-DD.yaml` уже есть `night_cycle_complete` за сегодня — это означает, что часть работы Части Б могла уже выполниться автоматически. Проверить `data.steps` этого события: шаги со `status: ok` — пропустить (не переигрывать), шаги `missing`/`fail` — выполнить как обычно. Записи нет вообще → выполнять всю Часть Б как есть (честный худший случай).

---

## Чеклист Day Close

- [ ] **Единый блок вопросов задан одним ходом (шаг 2, Часть А, WP-484 Ф36):** ретро (оба вопроса, ответ записан в ledger через `pilot_answer/preclose_retro`, пустой ответ — «нет ответа», не пропуск), приоритеты (`current/priorities.yaml` обновлён или пилот явно пропустил), часы саморазвития (подсказка `/slot` дана или пилот пропустил) — всё за один раунд-трип, не три отдельных
- [ ] **«Ты свободен» сказано и записано в ledger (шаг 3)** — Часть Б идёт без пилота
- [ ] **Git-lock взят перед началом работы (шаг 0.6, WP-484 Ф2):** `day-close-lock.sh acquire` вернул 0, день не был закрыт/не закрывался параллельно (финальный коммит `day-close: YYYY-MM-DD` на шаге 15 сам служит завершающей меткой — отдельного снятия лока не требуется)
- [ ] Все изменения закоммичены и запушены (по всем репо)
- [ ] MEMORY.md: done-РП удалены, активные актуальны, drift-scan выполнен (шаг 7)
- [ ] Index Health Check (шаг 8): `check-index-health.py` — все FAIL/WARN разобраны или помечены skip
- [ ] **FPF sync decision-log (РП499 Ф15 Б3):** нет строк `pending` старше 7 дней в `DS-my-strategy/inbox/fpf-sync-decision-log.md` — `awk -F'|' -v cutoff="$(date -v-7d +%Y-%m-%d)" 'NR>2{gsub(/ /,"",$2);gsub(/ /,"",$5);if($5=="pending"&&$2<cutoff)print $2}' DS-my-strategy/inbox/fpf-sync-decision-log.md`; непустой вывод → сообщить пилоту список дат, не решать самостоятельно (решение задним числом — за пилотом)
- [ ] WP-REGISTRY.md обновлён: статусы + done-форматирование (done-строки зачёркнуты, ✅ не зачёркнут)
- [ ] WeekPlan обновлён (grep по номерам РП — ВСЕ упоминания)
- [ ] DayPlan обновлён (статусы ВСЕХ строк: РП + ad-hoc)
- [ ] **WP Context Freshness (шаг 5g):** для каждого РП с сессией сегодня — `inbox/WP-N/WP-N.md` сверен с §4/§6 сегодняшних отчётов, суб-пункты done отмечены в контекст-файле (не только в трекерах)
- [ ] open-sessions.log: строки закрытых сессий удалены
- [ ] Captures за день применены (все Quick Close → KE пройден)
- [ ] Синхронизация downstream: `update.sh` выполнен
- [ ] Linear sync: статусы соответствуют git. Пост-sync чек: кол-во active РП в REGISTRY = кол-во active issues в Linear
- [ ] Repo CLAUDE.md: feat-коммиты → новые правила?
- [ ] DayPlan сегодня → `archive/day-plans/` (старые DayPlan'ы в `current/` тоже)
- [ ] WP context: done → `mv inbox/ → archive/wp-contexts/`
- [ ] Lesson Hygiene: уроки MEMORY.md ≤8
- [ ] Draft-list: Pack обогащён → кандидат записан в draft-list.md?
- [ ] Видео: обработанные помечены (если video.enabled)
- [ ] Governance: REPOSITORY-REGISTRY, navigation.md, MAP.002
- [ ] Backup: `day-close.sh` выполнен
- [ ] **Rule-engine FP-stats** (WP-272 Ф2.5): `python3 ~/IWE/.claude/scripts/fp-stats.py --date $(date +%Y-%m-%d)` → если есть `⚠️ REVISE` (FP > 20%) — записать в «Завтра начать с» правило + FP%. Флоу ревизии: `~/IWE/PACK-agent-rules/revision-flow.md`.
- [ ] Верификация compliance: /verify запускался сегодня?
- [ ] WakaTime + Мультипликатор: часы / **бюджет ПО ФАКТУ** (sessions/00-index.md перечислен; ad-hoc peer-сессии оценены по числу ходов; сверхплановая работа в плановом РП — по факту); остаток недели. Sanity check: мультипликатор <1.5x при ≥10 peer-сессий = пересчитать и пометить в «Требует внимания»
- [ ] Итоги дня записаны в DayPlan **(postcondition 14a: grep подтверждён)**
- [ ] Handoff-валидация: «Завтра начать с» содержит ВСЕ pending РП с конкретным next action
- [ ] Сводка итогов записана в WeekReport (`<details>`, обратная хронология) **(postcondition 14b: grep подтверждён)**
- [ ] Новое репо → MAPSTRATEGIC.md + Strategy.md
- [ ] **Тайминг шагов (WP-484, не блокирует закрытие):** `day-close-integrity.log` за сегодня пуст (нет аномалий) И число `start`/`end` в `day-close-steps.log` за сегодня совпадает — при расхождении просто пометить «данные тайминга за сегодня не заслуживают доверия», не чинить постфактум

Все ✅ (кроме тайминга шагов — этот пункт информативный, не блокирует) → «День закрыт.» Иначе — указать что осталось.
