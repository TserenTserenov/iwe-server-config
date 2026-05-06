---
name: run-protocol
description: Пошаговое выполнение протокола ОРЗ с обязательной отметкой каждого шага. Предотвращает пропуск шагов (включая верификацию).
argument-hint: "[open|close] [day|session]"
---

# Выполнение протокола

> **Принцип:** Протокол = последовательность шагов. Каждый шаг отмечается ДО перехода к следующему. Пропустить шаг нельзя.
> **Проблема, которую решает:** Агент «забывает» финальные шаги (верификация, backup) из-за загрязнения контекста (SOTA.002).

**Аргументы:** $ARGUMENTS

## Шаг 1. Определить протокол

| Аргумент | Файл | Skill (полный алгоритм) |
|----------|------|------------------------|
| `day-open` / `open day` | `memory/protocol-open.md § День` | `.claude/skills/day-open/SKILL.md` |
| `open session` или задание | `memory/protocol-open.md § Сессия` | — |
| `day-close` / `close day` | `memory/protocol-close.md § День` | `.claude/skills/day-close/SKILL.md` |
| `close` (без уточнения) | — | `close session` по умолчанию |
| `close session` | `memory/protocol-close.md § Сессия` | — |
| `week-close` | `memory/protocol-close.md § Неделя` | `.claude/skills/week-close/SKILL.md` |

Если есть Skill-файл → читай его (содержит полный алгоритм + шаблоны). Protocol-файл = краткий маршрутизатор.

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

## Шаг 3. Выполнять последовательно

Для каждого шага:
1. Отметь шаг как `in_progress`
2. Выполни его
3. Отметь как `completed`
4. Перейди к следующему

**БЛОКИРУЮЩЕЕ:** НЕ пропускай шаги. Если шаг невозможен — отметь как blocked и спроси пользователя.

## Шаг 4. Верификация (финальный шаг)

После выполнения всех шагов:
1. Вызови `/verify` с указанием артефактов протокола
2. Верификатор (Haiku R23) пройдёт чеклист
3. По ❌ — исправить ДО показа результата пользователю

## Правила

- Один шаг `in_progress` одновременно
- Не забегай вперёд — контекст загрязняется (SOTA.002)
- При PreCompact — запиши в `.claude/checkpoint.md` на каком шаге остановился
- Если протокол прерван пользователем — запиши оставшиеся шаги в checkpoint
