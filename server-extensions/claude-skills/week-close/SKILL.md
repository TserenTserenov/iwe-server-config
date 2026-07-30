---
name: week-close
description: "Протокол закрытия недели (Week Close). Ретро 7 дней + carry-over в новую неделю + платформенные шаги (бэкап, dirty repos)."
argument-hint: ""
version: 1.2.0
layer: L1
status: active
triggers:
  slash: [/week-close]
  phrases: []
routing:
  executor: sonnet
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# Week Close (протокол закрытия недели)

> **Роль:** R1 Стратег. **Бюджет:** ~30 мин.
> **Принцип:** SKILL.md = L1 платформенный файл. Пользователь не редактирует напрямую — только через `extensions/`.
> **Стиль текста:** ретро недели и новый WeekPlan читает пилот → весь текст синтезировать в базе разговорного стиля (S0 база + S1 автор, источник DP.SC.050): русский, без машинных меток, главная мысль первой, код РП и путь не подлежащее.

## When to use

Протокол закрытия недели (Week Close). Ретро 7 дней + carry-over в новую неделю + платформенные шаги (бэкап, dirty repos).

## БЛОКИРУЮЩЕЕ: пошаговое исполнение

Week Close = протокол. Исполнять ТОЛЬКО пошагово через TodoWrite.
**Шаг 0 — ПЕРВОЕ действие:** создать список задач прямо сейчас (до любых других действий).
Каждый шаг алгоритма → отдельная задача (pending → in_progress → completed).

## Algorithm

### 0. Extensions (before)
Загрузить: `bash .claude/scripts/load-extensions.sh week-close before`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить как первые шаги. Exit 1 → пропустить. Поддерживает `extensions/week-close.before.md` И `extensions/week-close.before.<suffix>.md`.

### 1. Сбор данных за 7 дней

**Предзаготовка (WP-484 Ф4a, если есть).** Проверить `DS-my-strategy/archive/WeekClose-facts-{YYYY-MM-DD}.md` (`{YYYY-MM-DD}` = понедельник закрывающейся недели). Файл найден → прочитать `generated_at` из frontmatter. **Свежий** = `generated_at` не раньше конца недели (воскресенье того же периода — неделя завершилась → факты полные; прогон в середине недели, например ручной тест, даёт частичный срез — не финальный). Свежий → читать из него §1 (коммиты, календарь), §5b (pending-фазы), §6 (полнота переноса), §7a (здоровье бэкапов), §7d (Memory Validate), semantic-check реестра, счётчик `[no-registry-touch]` и §9 (данные R-вопросника, шаг 6b) вместо живого сбора ниже (тот же скрипт `scripts/week-close-scaffold.sh --as-of YYYY-MM-DD` можно прогнать заранее вручную, если ещё не запускался автоматически). Файла нет, или `generated_at` раньше конца недели → выполнять шаги ниже вручную, как раньше (никогда не блокировать Week Close частичной предзаготовкой — тот же принцип «нет данных → явный шаг, не тихая подмена»).

**Коммиты:**
```bash
for repo in $(ls {{WORKSPACE_DIR}}/); do
  if [ -d {{WORKSPACE_DIR}}/$repo/.git ]; then
    commits=$(git -C {{WORKSPACE_DIR}}/$repo log --since="last monday 00:00" --until="today 00:00" --oneline --no-merges 2>/dev/null)
    [ -n "$commits" ] && echo "=== $repo ===" && echo "$commits"
  fi
done
```

**Календарь недели:**
```bash
bash {{WORKSPACE_DIR}}/scripts/server-calendar.sh --week $(date -v-mon +%Y-%m-%d 2>/dev/null || date -d "last monday" +%Y-%m-%d)
```
Сверить запланированные встречи/задачи с фактом: что состоялось, что перенеслось, что отменилось. Для задач с отчётами (🔧 backup stress-test и т.п.) — проверить наличие артефакта.

Сопоставить коммиты и календарь с РП в WeekPlan → определить статусы (done/partial/not started).

### 2. Headless week-review (если включён launchd Пн 00:00)

> **Условный шаг:** если запущен через `strategist.sh week-review` (Пн 00:00 launchd) — алгоритм идёт через `{{IWE_TEMPLATE}}/roles/strategist/prompts/week-review.md`. В интерактивном режиме `/week-close` (вечер Вс) — выполнять следующие шаги вручную.

### 3. Ретро (closed/partial/not_started/blocked)

**3a.** Закрытые РП: что сделано, ключевые артефакты, мультипликатор за неделю.
**3b.** Частичные: % выполнения, что осталось, перенос в W+1.
**3c.** Не стартовавшие: причина, перенос или закрытие.
**3d.** Заблокированные: блокер, ETA снятия.

**3e. Ретро недели, свободный текст (WP-484, решение пилота 30.07 — рефлексия обязательна на всех тактах, CONCEPT-night-cycle.md §22).** [[gate]] Отдельно от статусов РП выше — спросить пилота:
- «Что на неделе сработало хорошо?»
- «Что не сработало? Какой был самый большой блокер недели?»

Записать в ledger (пустой ответ — писать «нет ответа», не пропускать):
```bash
WEEK=$(date +%Y-W%V)
RETRO_JSON="{\"subtype\": \"preclose_retro\", \"retro_worked\": <экранированный ответ 1>, \"retro_failed\": <экранированный ответ 2>}"
bash ~/IWE/DS-my-strategy/scripts/ledger-append.sh week "$WEEK" pilot_answer "$RETRO_JSON" week-close
```
`bash .claude/hooks/rule-engine.sh mark-gate week-close-g6` (WP-484, 30.07 — trace-satisfaction для Week Close читает гейты из `memory/protocol-close.md § Week Close`, не из этого файла; без mark-gate шаг помечен `[[gate]]` здесь, но не проверяется механически).

Формулировка и поля идентичны `scripts/week-preclose.sh` — тот же скрипт остаётся терминальным запасным путём.

### 4. Метрики недели

- Completion rate: X/Y РП (N%)
- Коммитов всего, активных дней
- WakaTime итог недели (физическое время)
- Бюджет закрыт (сумма done × бюджет + partial % × бюджет)
- Мультипликатор недели = Бюджет закрыт / WakaTime
- **Калибровка гипотез (WP-496, из шага 6a):** сверено N записей за неделю; из них с уверенностью ≥80% — доля подтвердившихся (порог: ≥0.9 от заявленной уверенности, иначе «уверенность завышена» — явно отметить в WeekReport). Если сверок не было на этой неделе — не считать, пропустить строку.

### 5. Carry-over → W+1

Незавершённые РП с pending/in_progress статусами → перенести в новый WeekPlan W{N+1} (создаст session-prep автоматически в Пн 04:00 либо вручную).

### 5b. Pending фазы внутри активных РП (B-005)

> **Зачем:** carry-over §5 работает на уровне РП (status: in_progress → перенос). Pending **фазы** внутри Ф-таблиц context-файлов могут потеряться: если родительский РП в `in_progress` — pending-фаза не выделяется автоматически; если родительский ушёл в `done` — фаза теряется вместе с context-файлом.

```bash
bash ${IWE_SCRIPTS}/pending-phases-sweep.sh
```

Скрипт обходит все `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/WP-*.md` со `status: in_progress` (или без явного status), извлекает строки Ф-таблицы со статусом `⏳ pending` / `pending`, выводит сводку формата:

```
WP-NNN: pending-фазы (M):
  Фx — <описание фазы>
  Фy — <описание фазы>
```

Для каждой pending-фазы решить: **(a)** делать на этой неделе → добавить в W{N+1} как явный пункт; **(b)** переоценить (блокер? устарела?); **(c)** оставить как есть (если ожидание внешнего события — записать ожидаемый триггер).

Если скрипта нет — fallback: `grep -l "status: in_progress" {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/WP-*.md` → для каждого `grep -E "⏳.*pending|Ф[0-9]+.*pending"`.

### 6. Captures и уроки

- Просмотреть `inbox/fleeting-notes.md` за неделю → маршрутизировать невыключенные.
- Уроки сессий → MEMORY.md + thematic `lessons_*.md` (если есть).
- Drift-scan недели: что в MEMORY.md устарело за 7 дней.
- **Проверка полноты переноса перед архивацией (WP-5, 2026-07-10):** `bash {{IWE_SCRIPTS}}/check-wp-transfer-completeness.sh --all {{IWE_ROOT}}` по `inbox/WP-N/` — выводит `results_not_captured`-флаги (проставленные при закрытии без заполненного `results_in`) и файлы в подпапках без учёта в основном контекст-файле. Для каждого warning — пилот решает: (a) действительно нужен перенос знания, найти куда; (b) файл технический/устарел, можно оставить; (c) `results_in` заполнить постфактум. Не блокирует Close.

### 6a. Сверка журнала гипотез (LPF, WP-496)

> Регламент: `memory/lpf-hypothesis-log.md`. Журнал: `{{GOVERNANCE_REPO}}/current/hypotheses-log.md`.

1. Прочитать `hypotheses-log.md` — отфильтровать записи со статусом «на сверке» И датой сверки ≤ сегодня. Записи со статусом «черновик» (не подтверждённые пилотом Note-Review) — пропустить, они не в цикле сверки.
2. Для каждой найденной записи: сверить критерий фальсификации с доступной фактурой (коммиты недели, `domain_event`, инфраструктурные логи, факты из ретро §3-4 этого протокола).
3. Предложить вердикт: подтверждена / опровергнута / частично подтверждена / неприменимо (если условие критерия физически не выполнено — например, зависимый артефакт не был доставлен — гипотеза не проверяема, не «опровергнута»).
4. Пилот утверждает или правит вердикт → записать **новой** записью в конец журнала со ссылкой на исходную (`Сверка H-NNN`). Исходную запись не редактировать.
5. Для каждого вердикта — явное действие (обновить уверенность на будущее / добавить шаг в чек-лист / завести РП / зафиксировать кандидат в паттерн — §6 Capture-to-Pack). Вердикт без действия = «повисший», не закрывать неделю с повисшими вердиктами.
6. Если сверенных записей нет — пометить явно «сверка гипотез: 0 записей с наступившей датой» в WeekReport (не пропускать шаг молча).

### 6b. R-вопросник (`memory/r-questionnaire.md`, [[gate]])

> **WP-484 Ф4c.** Раньше существовал только в чек-листе внизу файла (не в нумерованном алгоритме) — реальный Close его пропускал, пока `check-trace-satisfaction` не блокировал финализацию постфактум на шаге 12. Теперь явный шаг здесь.

Данные предзаготовлены §9 предзаготовки Ф4a (`week-close-scaffold.sh`), если файл фактов свежий — иначе прогнать `behaviour-report.sh --period YYYY-MM` и прочитать `PACK-agent-rules/incident-journal.md` вручную.

3 вопроса (полный текст, критерии и антипаттерны → `memory/r-questionnaire.md`):
1. Системный паттерн из Behaviour Report/incidents — разовое или регулярное?
2. Какой РП взял больше времени, чем планировалось — и почему одним словом?
3. Если бы мог отменить одно действие этой недели — что?

Ответы → раздел «R-ответы» в WeekReport. «Нечего ответить» — валидный ответ (3 недели подряд → вопрос кандидат на удаление, решение пилота).

`bash .claude/hooks/rule-engine.sh mark-gate week-close-g3` (WP-484 Ф4d — трассировка по ходу, не постфактум на шаге 12).

### 6c. Архивация done-WP (sweep, [[gate]])

> **WP-484 Ф4d.** Гейт "Архивация done-WP" уже проверяется на шаге 12 (`check-trace-satisfaction`), но раньше не имел собственного явного шага здесь — `archive-done-wp.sh` вызывается по одному WP за раз из Day Close сразу при закрытии; Week Close нужна sweep-проверка: не остался ли done-WP в `inbox/`, пропущенный предыдущими Close.

```bash
for d in {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/inbox/WP-*/; do
  n=$(basename "$d"); f="$d/$n.md"
  [ -f "$f" ] && grep -q "^status: done" "$f" && echo "$f"
done
```

> Шаблон намеренно узкий — только канонический `WP-N/WP-N.md` (конвенция WP-434), не любой файл внутри папки. Более широкий `WP-*/WP-*.md` ложно матчит суб-файлы (handoff-заметки, транскрипты занятий), у которых `status: done` относится к суб-артефакту, не к самому РП — проверено живьём при написании этого шага (WP-484 Ф4d): широкий шаблон дал 6 ложных совпадений из 7, только 1 реальный (`WP-486/WP-486.md`, done и не заархивирован).

Найден файл → архивировать: `bash {{IWE_SCRIPTS}}/archive-done-wp.sh <WP_NUM>`. Пусто — нечего архивировать, gate удовлетворён без действия.

`bash .claude/hooks/rule-engine.sh mark-gate week-close-g4`

### 7. Платформенные шаги

#### 7a. Проверка здоровья бэкапов

> Обязательный шаг перед бэкапом. Запускает `iwe-backup-check.sh` (WP-317 supplement).

```bash
bash ${IWE_SCRIPTS}/iwe-backup-check.sh
```

Если вернул ❌ (exit 2) — устранить критичные gaps ДО бэкапа (устаревший бэкап >14 дней, нет iCloud).  
Если вернул ⚠️ (exit 1) — зафиксировать warnings в WeekReport, продолжить.  
Если ✅ (exit 0) — бэкап в норме.

#### 7b. Бэкап IWE в iCloud

> Условный шаг: только macOS с iCloud Drive. Запускать ТОЛЬКО если 7a не вернул ❌.

```bash
${IWE_SCRIPTS}/backup-icloud.sh
```

Архив всех файлов IWE (без `.git`, `node_modules`, `.venv`) → iCloud Drive. Хранит 4 последних архива.

#### 7c. Скан незакоммиченных файлов

```bash
${IWE_SCRIPTS}/check-dirty-repos.sh
```

Если есть грязные репо → закоммитить и запушить ДО завершения Week Close.

`bash .claude/hooks/rule-engine.sh mark-gate week-close-g1` (покрывает 7a+7c — WP-484 Ф4d).

#### 7d. Memory Validate (T22b, WP-217 Ф10.2)

```bash
bash ${IWE_SCRIPTS}/memory-bleed.sh
```

**Нарушения** (HOT-лимит, orphans, superseded_by без ссылки) → исправить до коммита Week Close.
**Кандидаты на понижение горизонта** → информативно, пользователь решает при следующем Month Close.

`bash .claude/hooks/rule-engine.sh mark-gate week-close-g2` (WP-484 Ф4d).

#### 7e. ТО памяти (T, SC.024.3 §5)

> Проверка здоровья статической нагрузки контекста. Флаги — информативно, пользователь решает.

```bash
echo "=== distinctions.md ===" && wc -l {{WORKSPACE_DIR}}/.claude/rules/distinctions.md
echo "=== MEMORY.md ===" && wc -l {{MEMORY_DIR}}/MEMORY.md
echo "=== memory/ файлы (mtime >14д) ===" && find {{MEMORY_DIR}} -name "*.md" -mtime +14 -not -name "MEMORY.md" -not -path "*/archive/*" | sort
```

| Метрика | Порог | Действие |
|---------|-------|---------|
| distinctions.md строк | **> 80** | Drift-флаг: нарушено правило DP.KR.001 §6 (1-3 строки на различение). Зафиксировать в Week Report, добавить задачу в техдолг. |
| MEMORY.md строк | **> 200** | Флаг превышения лимита. Предложить архивацию старых feedback в `archive/`. |
| memory/*.md без обращения > 14д | **> 5 файлов** | Предложить понизить `horizon: warm` (пользователь решает при Month Close). |

#### 7f. Hindsight health check

> **WP-337:** L2-memory = always-on, но требует периодической проверки.

```bash
echo "=== Hindsight container ===" && docker ps --format "table {{.Names}}\t{{.Status}}" | grep iwe-hindsight || echo "❌ Container not running"
echo "=== Hindsight log (last 20) ===" && cat ~/.iwe/hindsight.log 2>/dev/null | tail -20 || echo "❌ No log file"
```

**Проверки:**
- Container `iwe-hindsight` → статус `Up` (если `Down` → `bash ~/IWE/FMT-exocortex-template/exocortex/hindsight/start.sh`)
- Лог без `FAIL` за неделю. Если есть FAIL → `docker logs iwe-hindsight` → диагностика (OpenAI key? network? disk?)
- Размер БД: `docker exec iwe-hindsight ls -lh /data/hindsight.db` — если >100MB → флаг ротации
- **Whitelist review:** нужно ли добавить новые скиллы в `RECALL_SKILLS` (созданные за неделю)?

### 8. Запись итогов в WeekReport (split, ОПТ-5)

> **Split (WP-297 ОПТ-5):** факты недели живут в `WeekReport W{N}`, не в WeekPlan. WeekPlan — только намерения.

1. Открой текущий `WeekReport W{N} YYYY-MM-DD.md` (если нет — создай при следующем session-prep, см. CLAUDE.md §9 правило split).
2. Дополни секцию «Итоги W{N}» (структура — см. `roles/strategist/prompts/week-review.md`).
3. Также дополни секцию **«Сверка РП↔НЭП»** в WeekPlan W{N}: для каждого закрытого РП — какая НЭП снята / какой R-результат продвинут? Это вход в Strategy Session W{N+1}.
4. Заполни секцию **«Рекомендации изменений в НЭП и Стратегию»** в WeekPlan W{N} — что узнали на этой неделе → что менять в `Dissatisfactions.md` / `Strategy.md`.

`bash .claude/hooks/rule-engine.sh mark-gate week-close-g5` (WP-484 Ф4d).

### 9. Extensions (after)

Загрузить: `bash .claude/scripts/load-extensions.sh week-close after`. Exit 0 → `Read` каждый файл из вывода (alphabetic) → выполнить. Exit 1 → пропустить. Поддерживает `extensions/week-close.after.md` И `extensions/week-close.after.<suffix>.md`.

### 10. Оценка качества недели (WP-310 Gap-А)

Спросить пользователя: **«Оцени качество недели 1-5:  
1 = механически (шёл по инерции, голова не работала)  
2 = поверхностно (что было, что сделано — без анализа паттернов)  
3 = норма (осознанно, видишь паттерны, без прорывов)  
4 = хорошо (конкретные решения, что-то понято по-новому)  
5 = прорывная (изменилось понимание системы, ключевые решения)»**

Ответ N → включить `q:N` в commit message следующего шага.  
Если пользователь пропускает → commit без `q:`.

### 11. Закоммитить governance-репо

> **Защита от гонки параллельных сессий (WP-484 Ф4b).** Week Close — долгая (~30 мин) ручная сессия; за это время параллельные агентские сессии (Kimi/другие) гарантированно продолжают коммитить в тот же репозиторий (найдено 19.07: финальный коммит пришлось перезапускать 3 раза вручную). `week-close-commit-guard.sh` оборачивает commit+push тем же принципом, что `git-dirty-guard.sh` уже даёт открытию дня: `pull --rebase --autostash` перед стейджингом, retry (до 3 попыток) при отклонённом push, коммитит и пушит ТОЛЬКО переданный pathspec — независимо от того, что успело прилететь на origin между попытками.

```bash
cd {{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}
git status --short
# НЕ git add -A/git add ./git add -u — AGENTS.md CRITICAL (может захватить работу других агентов)
# Файлы, изменённые в шагах 1-10 (в массив для pathspec):
WC_FILES=(<каждый файл явным путём: WeekPlan, WeekReport, WP-REGISTRY, inbox/WP-*.md и т.д.>)
bash {{IWE_SCRIPTS}}/week-close-commit-guard.sh "$(pwd)" "week-close: W{N} итоги q:{score}" "${WC_FILES[@]}"
```

Exit 0 — закоммичено и запушено (возможно после retry). Exit 1 — нечего коммитить (уже сделано на предыдущей попытке этого же шага). Exit 2 — реальный конфликт после исчерпанных попыток или ошибка окружения → разобраться вручную (`git status`, `git log --oneline -5`), не игнорировать.

### 12. Верификация (Haiku R23)

Перед запуском R23 — `bash .claude/hooks/rule-engine.sh check-trace-satisfaction --protocol memory/protocol-close.md --section "Week Close"` (WP-481 Ф5.1: 5 гейтов, размеченных в `protocol-close.md` §Week Close — Бэкап, Memory Validate, R-вопросник, Архивация done-WP, Обновить WeekPlan). **С WP-484 Ф4d** каждый `mark-gate week-close-gN` вызывается по ходу своего шага (6c, 7c/7a, 7d, 6b, 8 выше) — эта проверка теперь читает уже расставленные по ходу маркеры, а не собирает их одним блоком постфактум. Verdict block → вернуться на незакрытый gate, потом R23. JSON вердикта приложить к вводу R23.

Запустить sub-agent Haiku в роли R23 Верификатор (context isolation).
Передать: чеклист, итоги недели, список обновлённых файлов, JSON вердикта trace-satisfaction.

---

## Чеклист Week Close

- [ ] Все изменения закоммичены и запушены (по всем репо)
- [ ] Ретро 7 дней: closed/partial/not_started/blocked разобраны
- [ ] Ретро недели свободным текстом задано (шаг 3e, WP-484): оба вопроса заданы пилоту, ответ записан в ledger через `pilot_answer/preclose_retro`
- [ ] Метрики посчитаны (completion rate, мультипликатор)
- [ ] Carry-over → W+1 (или явно «нет»)
- [ ] Pending фазы активных РП обойдены (`pending-phases-sweep.sh` или fallback grep) — решения зафиксированы
- [ ] Backlog `docs/Backlog.md` обойдён в следующую Strategy Session (либо триггеры активированы, либо явно «B-NNN живёт без триггеров»)
- [ ] Captures маршрутизированы, уроки записаны
- [ ] R-вопросник (3 вопроса, шаг 6b) — ответы записаны в WeekReport
- [ ] Drift-scan недели: устаревшие факты обновлены
- [ ] Проверка бэкапов (iwe-backup-check.sh) выполнена
- [ ] iCloud backup выполнен (если macOS)
- [ ] Dirty repos: 0 (или явно проигнорированы)
- [ ] ТО памяти: distinctions.md/MEMORY.md/memory/*.md проверены, флаги зафиксированы (или «норма»)
- [ ] Итоги W{N} записаны в WeekPlan
- [ ] Extensions `.after.md` выполнены (если есть)
- [ ] Hindsight: container Up, лог без FAIL за неделю, размер БД <100MB
- [ ] Оценка качества недели q:N задана (1-5) и включена в commit message
- [ ] Governance-репо закоммичено
- [ ] Peer-сессии недели: WP Gate проверен (только сессии с 2026-06-09):
  ```bash
  find ~/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/sessions -type f -name "peer-prompt.md" \
    | awk -F/ '{d=$(NF-1); match(d,/^[0-9]{4}-[0-9]{2}-[0-9]{2}/); print substr(d,RSTART,RLENGTH) " " $0}' \
    | awk '$1 >= "2026-06-09" {print $2}' \
    | xargs -I{} sh -c 'grep -q "Открытие (WP Gate)" "{}" || echo "WP-GATE-MISS: {}"'
  # Пропуски фиксировать в inbox/bugs/bug-YYYY-MM-DD-wp-gate-miss.md или «нет пропусков»
  ```

Все ✅ → «Неделя закрыта.» Иначе — указать что осталось.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
