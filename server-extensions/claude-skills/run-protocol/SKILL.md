---
name: run-protocol
description: Выполнение протокола ОРЗ как набора ограничений (CGUS, WP-481 Ф5): [[gate]]-шаги обязательны и проверяются trace-satisfaction при Close, [[narrative]] — демонстрационный порядок (skippable). Предотвращает пропуск обязательных шагов (включая верификацию).
argument-hint: "[open|close] [day|session]"
version: 1.0.0
layer: L1
status: active
triggers:
  slash: [/run-protocol]
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

# Выполнение протокола

> **Принцип (WP-481 Ф5, CGUS):** Протокол = набор типизированных ограничений, не линейный скрипт. Шаги помечены `[[gate]]`/`[[gate:AR.NNN]]` (предусловие «без этого работы нет» — обязательны, блокируют) и `[[narrative]]` (демонстрационный порядок — skippable, переставимы). Линейный порядок в файле = порядок удержания внимания, НЕ порядок исполнения. К Close все `[[gate]]` обязаны быть удовлетворены; `[[narrative]]` можно пропускать без последствий. Вход «с середины» штатен, если пропущенные gate не нарушены (пример: сессия ≤15 мин без изменений файлов — исключения AR.001/AR.007, вход сразу на работу легален).
> **Проблема, которую решает:** Агент «забывает» финальные шаги (верификация, backup) из-за загрязнения контекста (SOTA.002) — а линейная форма раньше провоцировала либо «галочки ради галочек», либо тайный пропуск обязательного.

**Аргументы:** $ARGUMENTS

## When to use

Пошаговое выполнение протокола ОРЗ с обязательной отметкой каждого шага. Предотвращает пропуск шагов (включая верификацию).

## Algorithm

## Шаг 1. Определить протокол

| Аргумент | Файл гейтов (для check-trace-satisfaction) | Skill (полный алгоритм) |
|----------|------|------------------------|
| `day-open` / `open day` | `memory/protocol-open.md § День` | `.claude/skills/day-open/SKILL.md` |
| `open session` или задание | `memory/protocol-open.md § Сессия` | — |
| `day-close` / `close day` | `.claude/skills/day-close/SKILL.md` (гейты размечены прямо в Skill-файле, WP-481 Ф5.1 — `protocol-close.md` секции «§ День» не существует) | тот же файл |
| `close` (без уточнения) | — | `close session` по умолчанию |
| `close session` | `memory/protocol-close.md § Quick Close` (ЧАСТЬ А с пилотом / ЧАСТЬ Б без пилота, DP.D.288 — WP-484 31.07) | — |
| `week-close` | `memory/protocol-close.md § Week Close` | `.claude/skills/week-close/SKILL.md` |

Если есть Skill-файл → читай его (содержит полный алгоритм + шаблоны). Protocol-файл = краткий маршрутизатор — кроме Day Close, где гейты размечены прямо в Skill-файле (нет отдельного router-раздела в protocol-close.md).

## Шаг 1b. Загрузить extensions (БЛОКИРУЮЩЕЕ)

Определи имя протокола: `day-open`, `day-close`, `week-close`, `protocol-close`, `protocol-open`.

Для каждого hook вызови loader, который вернёт **все** matching extensions (как `<protocol>.<hook>.md`, так и `<protocol>.<hook>.<suffix>.md`) в alphabetic order:

1. `bash .claude/scripts/load-extensions.sh {protocol} before` — exit 0 → `Read` каждый файл из вывода → добавить как **первые** шаги в TodoWrite
2. `bash .claude/scripts/load-extensions.sh {protocol} after` — exit 0 → `Read` каждый файл → добавить **после** основного алгоритма, **перед** верификацией
3. `bash .claude/scripts/load-extensions.sh {protocol} checks` — exit 0 → `Read` каждый файл → добавить **перед git commit** (БЛОКИРУЮЩЕЕ: commit запрещён до прохождения checks)

Exit 1 (нет файлов) → пропустить молча. Несколько файлов на один hook → выполняются в порядке вывода loader'а (alphabetic).

## Шаг 2. Извлечь шаги

Из алгоритма протокола (Skill-файл или protocol-файл) и extensions извлеки пронумерованный список шагов. Запиши их как задачи (TodoWrite):

Порядок задач:
1. Extensions `.before.md` / `.before.<suffix>.md` (если есть, alphabetic)
2. Основные шаги из алгоритма
3. Extensions `.after.md` / `.after.<suffix>.md` (если есть, alphabetic)
4. Extensions `.checks.md` / `.checks.<suffix>.md` + git commit (если есть артефакт для коммита)
5. Верификация по чеклисту (`/verify`)

- Каждый основной шаг = отдельная задача
- Последняя задача ВСЕГДА = «Верификация по чеклисту (/verify)»
- Статус: pending

## Шаг 3. Удовлетворять ограничения (gate — обязательно, narrative — по вниманию)

Для каждого шага:
1. Отметь шаг как `in_progress`
2. Выполни его
3. Отметь как `completed`
4. Перейди к следующему

**БЛОКИРУЮЩЕЕ — только `[[gate]]`:** шаг с тегом `[[gate]]`/`[[gate:AR.NNN]]` нельзя пропустить. Gate невозможен → отметь blocked и спроси пользователя. Шаг `[[narrative]]` можно пропустить или переставить — без пометки blocked и без вопроса (порядок = внимание, не исполнение).

**Маркировка трассы (для trace-satisfaction при Close):** после выполнения gate-шага протокола Close — `bash .claude/hooks/rule-engine.sh mark-gate <key>` (ключи через `list-gates` с ТЕМ ЖЕ `--section`, что и в Шаге 4 — позиционные ключи g1,g2,... содержат префикс масштаба, quick-close-g1 ≠ week-close-g1). AR.005 (repo clean/push/ORZ) засчитывается автоматически, маркер не нужен.

## Шаг 4. Верификация (финальный шаг)

После выполнения всех шагов:
1. Для Close-протоколов — сначала `check-trace-satisfaction` со scope, соответствующим строке из таблицы Шага 1 (WP-481 Ф5.1 — один файл держит 3 масштаба, без scope гейты чужого масштаба попадают в проверку и блокируют гарантированно):
   - `close` / `close session` → `bash .claude/hooks/rule-engine.sh check-trace-satisfaction --section "Quick Close"`
   - `week-close` → `bash .claude/hooks/rule-engine.sh check-trace-satisfaction --section "Week Close"`
   - `day-close` / `close day` → `bash .claude/hooks/rule-engine.sh check-trace-satisfaction --protocol .claude/skills/day-close/SKILL.md` (18 гейтов размечены прямо в Skill-файле, WP-481 Ф5.1)

   block = есть незакрытый gate → вернуться и закрыть; ok → дальше. Narrative-пропуски вердикт не меняют.
2. Вызови `/verify` с указанием артефактов протокола
3. Верификатор (Haiku R23) пройдёт чеклист; JSON вердикта trace-satisfaction приложить к вводу
4. По ❌ — исправить ДО показа результата пользователю

## Правила

- Один шаг `in_progress` одновременно
- Не забегай вперёд по gate-зависимостям — контекст загрязняется (SOTA.002)
- Вход «с середины» легален: сессия ≤15 мин или вопрос без изменений файлов → исключения AR.001/AR.007 применяются, TodoWrite по полному списку не обязателен
- При PreCompact — запиши в `.claude/checkpoint.md` на каком шаге остановился
- Если протокол прерван пользователем — запиши оставшиеся шаги в checkpoint
