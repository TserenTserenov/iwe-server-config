# Week Close Extension (after) — Ревью 11 направлений Фабрики руководств МИМ

<!-- AUTHOR-ONLY -->

> **Источник:** WP-364 Ф4 ongoing coordination (peer-сессия [2026-05-30-33-wp364-systemic-order](../DS-my-strategy/sessions/2026-05/2026-05-30-33-wp364-systemic-order/report.md), CONSENSUS 30 мая).
>
> **Принцип:** зонтик WP-364 «Фабрика руководств МИМ» содержит 11 направлений (Source/Compiler/SSG/CI/Deploy/Env/Orchestration/Observability/QA/Community/ALE). Каждое — отдельный track развития с дочерними РП. Ф4 = еженедельный обзор статусов всех 11 направлений, чтобы зонтик не превратился в забытый roadmap.
>
> **SoT статусов 11 направлений:** [`inbox/WP-364-fabrika-rukovodstv-mim.md`](../DS-my-strategy/inbox/WP-364-fabrika-rukovodstv-mim.md) §«11 направлений Фабрики» (строки 70-84). Этот extension читает таблицу и формирует чеклист, не дублирует данные.

## Шаг: Ревью 11 направлений Фабрики

Выполнить **после** ретро и carry-over (основные шаги Week Close), **до** платформенных шагов (бэкап, dirty repos).

### 1. Открыть зонтик и пройти таблицу 11 направлений

Прочитать таблицу `## 11 направлений Фабрики` в `inbox/WP-364-fabrika-rukovodstv-mim.md`. Для каждой строки — отметить изменение статуса за неделю.

| # | Направление | Дочерние РП | Статус (прошлая неделя) | Изменения за неделю | Статус (текущая неделя) |
|---|------|-------------|--------------------------|---------------------|------------------------|
| 1 | Source & Version Control | Pack + CAT + FPF/SPF | — | (заполнить) | — |
| 2 | Semantic Compiler | WP-149, WP-371 | — | (заполнить) | — |
| 3 | Static Site Generator | WP-322, WP-321 | — | (заполнить) | — |
| 4 | CI/CD | WP-322, WP-321 | — | (заполнить) | — |
| 5 | Production Deploy | WP-355 | — | (заполнить) | — |
| 6 | Execution Environment | DP.D.052, WP-309 | — | (заполнить) | — |
| 7 | Distributed Orchestration | WP-310, WP-357, WP-350 | — | (заполнить) | — |
| 8 | Observability | WP-244, WP-353, WP-290 | — | (заполнить) | — |
| 9 | Quality Assurance | DP.SC.154, VR.R.001, WP-170 | — | (заполнить) | — |
| 10 | Community Interface | systemsworld.club, GitHub Issues, Linear | — | (заполнить) | — |
| 11 | Adaptive Learning Engine | WP-318, WP-353, reflection loop | — | (заполнить) | — |

### 2. Сигналы здоровья зонтика

- [ ] **Нет blocked-направлений без TTL-event.** Если направление blocked — обязательно зафиксированная дата/событие разморозки.
- [ ] **Нет drift'а между формулировкой зонтика и дочерним РП.** За день 30 мая — 3 случая (Развилки 3a, 4a, 1 d+e). Урок: [lessons_umbrella_child_threshold_drift.md](../.claude/projects/-Users-tserentserenov-IWE/memory/lessons_umbrella_child_threshold_drift.md). Митигация: при правке зонтика проверить bidirectional guards в дочерних.
- [ ] **Нет направлений без активности >2 недель** (без оформленного `status: blocked` или `defer-with-explicit-triggers`).

### 3. Carry-over на следующую неделю

Если за неделю появились новые дочерние РП или фазы — обновить таблицу 11 направлений (колонка «Дочерние РП»). Источник — `WP-REGISTRY.md` за неделю.

### 4. Сигнал ↔ дочерние РП

При обнаружении проблемы в направлении — обновить frontmatter:
- В зонтике (`WP-364`): добавить short note в раздел «11 направлений» с pointer на дочерний РП.
- В дочернем РП: если меняется status/scope — синхронизировать обратно в WP-364 через bidirectional guard.

## Связь с другими extensions

- **`week-close.after.lesson-application.md`** (Развилка 1 e WP-364 — отдельный checklist «применение lesson недели», не путать с этим).
- **`day-open.after.lesson-link.md`** (Развилка 1 d WP-364 — ссылка на сегодняшнюю lesson в DayPlan).

## Откат

Удалить файл из `extensions/` — следующий Week Close не выполнит этот шаг. SoT 11 направлений остаётся в `inbox/WP-364-fabrika-rukovodstv-mim.md`.

<!-- /AUTHOR-ONLY -->
