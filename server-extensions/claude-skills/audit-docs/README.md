---
wp: 217
phase: Ф5
created: 2026-04-10
title: "SC.024.∞ — Дизайн агентского auto-update docs/ (MVP на aist_bot)"
---

# Auto-update docs/ — дизайн MVP

> **Контекст:** Ф7 (10 апр) ручной аудит `aist_bot_newarchitecture/docs/` нашёл долг ~8h при 40 коммитах за 2 недели. MVP — на `aist_bot_newarchitecture` (единственный активный DS-instrument репо с docs/ на 10 апр: `activity-hub/docs` ещё не существует, `aisystant` read-only и docs/ отсутствует).
>
> **Аналоги:** Mintlify (коммерческий CI-агент), Swimm (auto-sync code↔docs), GitHub Copilot Workspace. **Ключевое отличие SC.024.∞:** owner-версия, субагент в Claude Code harness владельца, без отдельного backend-сервиса.

## 1. Триггер

**Вариант A (рекомендую для MVP): post-merge GitHub webhook.**
- GitHub Action в `aist_bot_newarchitecture` при push в `pilot` или merge PR → webhook на личный Cloudflare Worker владельца.
- Worker проверяет: были ли в PR изменения в `handlers/`, `db/`, `core/`, `services/` (пути, связанные с docs/ через sync-manifest).
- Если да → создаёт issue/comment «docs drift candidate» в этом же PR с diff'ом.
- Владелец на машине локально запускает `claude /auto-docs <PR>` → агент выполняет анализ.

**Вариант B (проще, но хуже UX): cron.**
- `0 8 * * *` локально запускает `iwe-drift.sh` → если `aist-bot-docs-to-code` в warn/critical, agent собирает diff за период и предлагает правки.
- Минус: batch — потеря привязки к конкретному PR, больше merge-конфликтов.

**Вариант C (самый простой, для первой обкатки): manual.**
- Пользователь при Week Close запускает `/audit-docs aist_bot_newarchitecture`.
- Агент делает то же, что владелец делал вручную 10 апр в Ф7.
- Минус: не решает проблему темпа, но даёт baseline для калибровки Вариантов A/B.

**Рекомендация:** C → A (после обкатки 2 недель).

## 2. Как субагент получает контекст

1. **Diff:**
   - Вариант A: `gh api repos/{owner}/{repo}/pulls/{N}/files` → JSON с изменёнными файлами и патчами.
   - Вариант B/C: `cd <repo> && git diff <last_audit_tag>..HEAD -- <non-docs paths>`.
2. **Mapping «код → docs»:**
   - Читает `.claude/sync-manifest.yaml` → находит пары `aist-bot-docs-to-code` и производные.
   - Доп. правило: каждый путь в diff сверяется с таблицей соответствия (явной или эвристической). Для MVP — эвристика:
     - `handlers/*.py` → `docs/scenarios/*.md`
     - `db/queries/*.py`, `db/models.py` → `docs/data/tables.md` + `docs/processes/*.md`
     - `services/*.py` → `docs/processes/*.md`
     - `core/*.py` → `docs/processes/*.md` или `docs/architecture/*.md`
3. **Существующие docs:** читает все связанные `.md` целиком (не > 20 файлов за раз).

## 3. Что генерирует агент

**Формат вывода — markdown-документ с предложениями**, НЕ прямой patch (PR hygiene: владелец должен ревьюить текст, не diff).

Структура:
```markdown
# docs/ drift report для PR #<N> (<date>)

## Sentinel: изменения в <file.py>
**что изменилось:** <summary из diff>
**затронутые docs:** <list>

### Предложение 1: обновить docs/processes/process-04-stats-collection.md
> Секция «Error metrics» устарела. Добавить:
> <черновик markdown, 10-30 строк>

### Предложение 2: создать docs/scenarios/scenario-new-connect.md
> Новая команда /connect в handlers/connect.py. Сценарий не покрыт.
> <шаблон + первые разделы>

## Кандидаты на archive
<list устаревших файлов>

## Неочевидности (§10-ловушки из CLAUDE.md)
<если в diff задет файл, упомянутый в CLAUDE.md § 10>
```

**Выход:** один markdown-файл `docs/_drafts/drift-<date>-<PR>.md` в том же репо, коммитится отдельной PR-веткой `docs-drift/PR-<N>`. Владелец ревьюит → применяет руками или через `/auto-apply` (следующий шаг, не в MVP).

## 4. Как человек ревьюит

1. Агент создаёт PR в `pilot` ветку с одним файлом `docs/_drafts/drift-<date>.md`.
2. Владелец читает в GitHub UI.
3. Принимает решения:
   - **apply-all:** `claude /auto-apply docs/_drafts/drift-<date>.md` → агент применяет все предложения к целевым docs, коммитит в ту же ветку.
   - **apply-partial:** владелец вручную правит draft, оставляя нужные секции, запускает `/auto-apply`.
   - **reject:** закрывает PR без применения.
4. После apply → владелец ревьюит финальные правки → merge.

**Итог:** человек видит предложения как черновик текста, не diff. Решения принимает батчем, не построчно.

## 5. Оценка стоимости

**Темп:** 40 коммитов / 2 недели = ~20/неделю → ~3/день. Допустим, 30% из них трогают пути, связанные с docs → 1 PR/день (усреднённо).

**Токены на PR:**
- Чтение diff: ~2k tokens (средний PR).
- Чтение связанных docs: 5 файлов × 2k = 10k.
- Чтение sync-manifest: 1k.
- Генерация draft: 3-5k output.
- **Итого:** ~15k input + 5k output = ~20k tokens/PR.

**Месяц (20 рабочих дней):**
- ~20 PR/месяц → ~400k tokens/месяц на одно репо (MVP scope — только `aist_bot_newarchitecture`).

**Стоимость (Sonnet 4.5):** ~$3/M input + $15/M output. ~20k in × 20 PR = 400k in, ~35k out. **~$2/месяц** на MVP (одно репо).

**Альтернатива (ручная работа):** Ф7 показал 8h на одно репо за 2 недели. 1 репо × 2 × 8 = 16h/месяц × $20/h (альтернативная ценность) = **$320/месяц**.

**ROI:** 320/2 ≈ 160x. Даже если реальная стоимость в 5 раз выше оценки — 30x ROI остаётся.

## 6. Сравнение с ручным Ф7 (10 апр)

| Метрика | Ручной Ф7 | Агентский |
|---------|-----------|-----------|
| Время на обнаружение расхождений | 30 мин | 0 (агент вывалил список) |
| Время на черновик правок | не делалось, выведено в WP-7 | автомат |
| Охват | выборочный (глаз скользит) | 100% связанных docs |
| Риск пропуска | высокий | низкий |
| Качество предложений | высокое (человек думал) | среднее → высокое после 2 недель fine-tuning инструкций |
| Триггер | инициатива владельца | автомат по PR |

**Главная разница:** агент работает постоянно при низкой стоимости, ручной аудит работает раз в месяц при высокой стоимости и низком охвате.

## 7. Граница ответственности (Human Gate)

**Что агент решает сам:**
- Что положить в draft.
- Какие файлы docs «кандидаты на обновление».
- Какие файлы считать устаревшими (отдельным списком).

**Что решает только человек:**
- Применять ли правки.
- Переформулировки, затрагивающие решения.
- Archived vs rewritten.
- Добавление новых ловушек в CLAUDE.md § 10.
- Новые категории docs (сейчас: Сценарий / Процесс / Данные — новая категория = архитектурное решение).

**Экзоскелет, не автопилот.** Без human gate SC.024.∞ превращается в автопилот и попадает под DP.SC.006 — но там уже есть S18 Code Scan, и он не справляется с этой задачей. SC.024.∞ ≠ S18 именно human gate'ом.

## 8. MVP-план (1.5h)

1. Ручной прогон (Вариант C): написать prompt для субагента, который выполняет шаги 2-4 для одного PR. Проверить на 3 реальных PR в `aist_bot_newarchitecture`. — 45 мин.
2. Скрипт `scripts/auto-docs.sh <repo> <pr_number>`: вызывает `gh api` + стартует subagent через `claude --prompt`. — 30 мин.
3. Первый прогон на текущем PR, фиксация качества (precision/recall предложений). — 15 мин.

**После MVP:** если precision > 70% — Вариант A (GitHub Action). Если ниже — calibration prompt, ещё 2-3 ручных прогона.

## 9. Открытые вопросы — РЕШЕНО 10 апр

### 9.1 Где живёт prompt (гибрид)

- **Ядро роли** — в `.claude/skills/audit-docs/SKILL.md` (новый скилл в авторском IWE).
- **Репо-специфичный контекст + mapping** — в `<repo>/docs/.audit-context.yaml` (отдельный файл в каждом репо).
- Скилл `/audit-docs` грузит роль **R24 Аудитор** как primary из `PACK-digital-platform/pack/digital-platform/02-domain-entities/DP.ROLE.001-platform-roles.md` — строка R24 в таблице верификационных ролей: «R24 | Аудитор | Все Pack'и + DS | VR.M.002, VR.M.004 (кросс-контекст, полнота) | Индекс + целевое множество | Отчёт аудита (coverage %)». Маппинг: R24 = VR.R.002.
- **Метод:** R24 coverage + R23 pair-diff (детекция drift'а между парами файлов). R8 Синхронизатор НЕ используется как метод — R8 это оператор (делает sync через операторные скрипты), а `/audit-docs` только детектирует и отчитывается.
- **Получатель (категория 3 — внешняя проектная роль):** владелец репо в другой временной позиции (U3a «я-будущий»), следующий агент (U3b), пользователи FMT-template.
- **TODO-миграция:** после создания **WP-224** («развёртывание R24: принципы, сценарии, границы + триада учёт-доступ-аудит») обновить SKILL.md — заменить прямую ссылку на строку R24 в DP.ROLE.001 на ссылку на полноценный `DP.ROLE.024-auditor.md`, когда тот появится.

### 9.2 Mapping code↔docs — в `<repo>/docs/.audit-context.yaml`

Зафиксировано в разделе 2: каждый репо содержит собственный context-файл с mapping'ом и репо-специфичным контекстом. Пример структуры:

```yaml
# docs/.audit-context.yaml
categories:
  scenarios:
    path: docs/scenarios/
    source_patterns: [handlers/*.py]
    file_naming: scenario-{NN}-{slug}.md
  processes:
    path: docs/processes/
    source_patterns: [services/*.py, core/*.py]
  data:
    path: docs/data/tables.md
    source_patterns: [db/models.py, db/queries/*.py]
traps_source: CLAUDE.md  # §10 — известные ловушки/инварианты
```

Скилл `/audit-docs` читает этот файл при старте, скрещивает с `sync-manifest.yaml` из авторского IWE.

### 9.3 Ловушки § 10 CLAUDE.md — агент читает CLAUDE.md репо

Решено: агент при старте читает `<repo>/CLAUDE.md` целиком, как любой агент в репо по протоколу. Никакой отдельной выжимки «context pack» не создаётся. Правило единообразия — все агенты читают CLAUDE.md репо при старте, audit-docs не исключение.

### 9.4 Read-only репо — снято

aisystant удалён из scope решением 2c (пара `aisystant-docs-to-code` удалена из `sync-manifest.yaml`). `docs/` там отсутствует, репо read-only — drift не actionable.

### 9.5 Автотриггер vs warning — warning на MVP

Решено: **warning** на MVP. `iwe-drift.sh` показывает top-3 critical в `/day-open`, владелец сам решает, запускать ли `/audit-docs` вручную. Автотриггер per-id добавлять только если за 2 недели обкатки обнаружится паттерн «всегда запускаю на конкретном drift id».
