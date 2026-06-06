# Week Close Extension (after) — Weekly Digest для Strategy Session

<!-- AUTHOR-ONLY -->

> **Источник:** WP-364 Ф2.2 «Loop C scope» — peer-сессия [2026-05-30-03-loop-c-scope-decision](../DS-my-strategy/sessions/2026-05/2026-05-30-03-loop-c-scope-decision/report.md).
>
> **Принцип:** автоматический weekly Стратег — это не отдельный РП и не фаза WP-313. Это **glue layer** между Week Close и /strategy-session: Аналитик собирает факты прошлой недели → пилот в Стратегической сессии работает с готовой сводкой как входом, а не пустым листом.

## Шаг: Сборка Weekly Digest

Выполнить **в самом конце** Week Close — после всех ретро-шагов, carry-over, бэкапа и dirty-репо проверок.

### 1. Запуск Аналитика

```bash
bash "$HOME/IWE/DS-my-strategy/scripts/weekly-digest.sh"
```

Скрипт читает:
- git log за прошедшую неделю по всем репо в `~/IWE/`
- активные РП через `active-wp-sweep.sh`
- закрытые РП за неделю (status: done + closed в диапазоне)
- кандидаты bottleneck'а (эвристика: overdue target_close ИЛИ stale last_session)

Пишет в `DS-my-strategy/current/weekly-digest.md` с frontmatter (`generated_at`, `valid_until`, `week_iso`).

### 2. TTL и инвариант

- **TTL = 7 дней.** Каждый Week Close перезаписывает файл свежим срезом.
- **Stale digest не используется.** Если пилот не запустил `/strategy-session` в течение недели — следующий Week Close затирает прошлый digest. Это страховка от использования устаревших данных для нового планирования.
- **Носитель = Аналитик, не Стратег.** Скрипт собирает факты и кандидаты, но **не выбирает** bottleneck и **не пишет** WeekPlan. Это остаётся за пилотом в `/strategy-session`.

### 3. Связь с /strategy-session

Скилл `/strategy-session` (weekly flow) в шаге «Открытие сессии» читает `current/weekly-digest.md` как supplementary input (см. правку `roles/strategist/prompts/strategy-session.md`). Если digest есть и `valid_until ≥ today` — использовать как контекст. Если нет — работать как раньше.

## Что не входит

- **Полный `/bottleneck-pick`-цикл.** Digest использует lightweight-эвристику. Полная open-loop калибровка bottleneck остаётся ручным шагом в `/strategy-session`.
- **Решения по плану.** Digest предлагает кандидатов, но WeekPlan собирает пилот.
- **Cron независимо от Week Close.** Trigger строго через Week Close (замкнутый контур: закрыл неделю → подготовился digest → планируешь новую). Независимый расписной запуск ведёт к stale digest, если пилот пропустил closure.

## Откат

Если digest не приносит ценности (пилот регулярно начинает /strategy-session с нуля, игнорируя файл) — отключить расширение через `mv week-close.after.weekly-digest.md week-close.after.weekly-digest.md.disabled`. Файл `current/weekly-digest.md` можно оставить — он устареет через 7 дней.

<!-- /AUTHOR-ONLY -->
