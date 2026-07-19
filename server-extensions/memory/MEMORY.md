# Оперативная память

> **Инструкции:** `~/IWE/CLAUDE.md` | **Навигация:** `memory/navigation.md` | **Source-of-truth:** `DP.EXOCORTEX.001`
> **Слои:** L1 = платформа. L2 = staging. L3 = авторское.

## БЛОКИРУЮЩИЕ (проверяй ВСЕГДА)

1. **WP Gate:** ⛔ Первое действие на ЛЮБОЕ задание = `Read memory/protocol-open.md`. Без исключений.
2. **Close:** ⛔ «закрывай» / «всё» = `Вызвать Skill: run-protocol, аргумент: close`. Без исключений.
3. **ArchGate ≥8:** Архитектурное → СНАЧАЛА ЭМОГССБ → ПОТОМ решение.
4. **Repo-Touch Gate:** Первое действие в любом репо → прочитать `<repo>/CLAUDE.md`. Блок «ОБЯЗАТЕЛЬНО ЗАГРУЖАЙ» — загрузить ДО ответа.
5. **Routing Gate:** Перед Write нового файла → `memory/routing-vocab.md`. Miss → эскалация в `memory/repo-type-rules.md`. Аналогия запрещена.

## ВАЖНЫЕ (на рубежах)

6. **Capture:** На рубеже → «Capture: X → Y»
7. **Процессы:** Без PROCESSES.md не реализовывать
8. **Гигиена inbox:** Close архивирует done-WP сразу. Session-Prep — широкая очистка.
9. **Модели:** Opus=open-loop. Sonnet=closed-loop. Haiku=trivial. Делегирование только вниз.
10. **Шапки индексов = индекс, не changelog.** → [feedback_memory_index_discipline.md](feedback_memory_index_discipline.md)
11. **Стратсессия → sessions/:** файл ДО commit+push. → [feedback_sessions_missing.md](feedback_sessions_missing.md)
12. **Финиш > отлог.** Доп. задача → дефолт «делаю сейчас». → [feedback_finish_now_no_defer.md](feedback_finish_now_no_defer.md)
13. **Content cleanup backlog** → `current/content-cleanup-backlog.md` (зонтик WP-376).

---

## Текущая работа

> Источник: WeekPlan W{N} + WP-REGISTRY.md. Полный контекст каждого РП только в `DS-my-strategy/inbox/WP-{N}/WP-{N}.md` — эта таблица только пойнтер (≤10 слов на `next`), детали сюда не дублировать.
> **W29 (13-19.07):** ТОС — запуск персонального руководства. Пул: 149,289,417,406+476,469+401,415+481,482,483. План: `current/WeekPlan W29 2026-07-13.md`.

| WP | ст | P | Название | next (≤10 слов) |
|-----|----|----|----------|----------------|
| 183 | 🔄 | — | CRM как система | DROP БД directus (решение 24.07) |
| 467 | 🔄 | **P1** | Архитектура подписок через Ори | решение Д10 блокирует Ф3 |
| 151 | 🔄 | — | Характеристики и состояния деятеля | Ф7б выделена в РП493 |
| 468 | ⏳ | P3 | Инфраструктура разработки | изучить ветку python-gcp knowledge-mcp |
| 469 | 🔄 | P3 | Архитектура доступа к личным данным | ждёт WP-470 Ф4 (до 20.07) |
| 470 | 🔄 | P3 | Канал выгрузки Здоровья в iCloud | Ф4 решение пилота: виджет |
| 471 | 🔄 | P2 | Карта целевых аудиторий экосистемы | публикация метафоры или волна-2 (WP-437) |
| 462 | ⚠️ | P2 | Конвейер оценки качества платформы и IWE | closure противоречив, решение за пилотом |
| 454 | 🔄 | P4 | Честный числитель параллелизма | сверка на Week Close |
| 446 | 🔄 | P4 | Меню оплат «Потратить бонусы» | пилот подтверждает на семинарах |
| 417 | 🔄 | P3 | Табло пользователя | ждёт боевого рендера |
| 448 | 🔄 | P2 | Каталог паттернов процесса IWE | решение по Ф10 |
| 458 | 🔄 | **P2** | Сквозной аудит безопасности платформы и IWE | 2 архитектурных решения за пилотом |
| 442 | 🔄 | — | Личный бренд Церена | посты 26-07/27-07 ждут ready |
| 418 | 🔄 | — | Доставщик | Ф5.1 когорта |
| 482 | 🔄 | P2 | Конвейер процессов IWE (рефлекс/ИИ/пилот) | живой week-close 19-20.07 |
| 427 | 🔄 | — | Учёт следов Ф6.3 | живая приёмка |
| 262 | 🔄 | — | Интерфейсы платформы (зонтичный) | В1: вынос engines/* из бота |
| 330 | 🔄 | **P1** | Марафон вторая волна | 3 решения пилота перенесены на 22.07 |
| 437 | 🔄 | **P1** | Вторая волна когорты дизайн | Ф2 запуск, параллель WP-330 |
| 251 | 🔄 | — | Системы службы продвижения | Ф4 живая сессия с Алёной (блокер) |
| 250 | 🔄 | — | План развития до конца 2026 (зонтичный) | Week Close (WIP-фильтр+калибровка) |
| 399 | ⏳ | P1 | Ротация секретов экосистемы | батч просрочен, ротация за пилотом |
| 429 | 🔄 | — | Детектор непротиворечивости базы | АрхГейт по Ф6.1+Ф6.2 |
| 5 | 🔄 | — | Платформа: развитие (зонтичный) | 19.07: L1/L3-разделение в скиллах done (skill-promote.sh+гейт, живой прогон); MCP discovery живой E2E за пилотом |
| 117 | 🔄 | — | Развитие nudge-системы | AI-тексты для derived-типов |
| 149 | 🔄 | **P1** | Персональные руководства | 19.07: ФК5+ФК22 живая приёмка нашла баг судьи, пофикшено+независимо проверено (1a32ae7, 80dcccd); next: рендер 20.07 подтверждает, потом Стоп (следующий разбор — ФК12 с Kimi) |
| 438 | 🔄 | — | Агентный режим Гермеса | перенос после WP-149 |
| 170 | 🔄 | P1 | База знаний: обновление | миграция 119 секций 01B — не срочно |
| 415 | 🔄 | P2 | Конвейер орг-GitHub | Конвейер 1 |
| 285 | 🔄 | — | Международная инфраструктура Track B | тесты-спецификации у Андрея |
| 401 | 🔄 | **P1** | Разделение GitHub-организаций | Ф6.1 manifest.sh |
| 406 | 🔄 | **P1** | Онбордер | Ф20 приёмка в Telegram (за пилотом) |
| 456 | 🔄 | P3 | Онбордер англоязычной IWE (браузер) | EN-приёмка ожидает пилота |
| 405 | 🔄 | — | Англоязычная платформа IWE | Ф4 Language Policy FMT |
| 452 | 🔄 | P3 | Гайд разработчика IWE | Ф2 стиль кода |
| 453 | 🔄 | P4 | Конвейер обновления руководства IWE | ждёт WP-452 Ф2-Ф3 |
| 349 | 🔄 | — | Онбординг на MCP | Ф31 тексты, 3-4ч |
| 245 | 🔄 | P5 | Программа личного развития | 19.07: Блок 1 (Ф-M1…M5) + Ф-M6 метода изменения себя реализованы и верифицированы (2 прохода субагента, 1 задвоение найдено и закрыто); Ф-M7/M8 блокированы РП495 Ф4/Ф5 (не начаты) — доложено, не обойдено; next: пилот решает — ждать РП495 или взяться за Ф4/Ф5 |
| 364 | 🏭 | — | Фабрика руководств МИМ | Ф6b разметка wave-2 |
| 455 | 🔄 | P4 | Неизменяемость аудит-журнала событий | блокер: хост джоба (решение пилота) |
| 290 | 🔄 | **P1** | Следователь: каузальная аналитика | Ход 2 — решение стратсессии |
| 73 | 🔄 | P3 | Новая архитектура ИТ-платформы Aisystant | Ф5 proposed, дедлайн 25.07 |
| 7 | 🔄 | — | Платформа: техдолг (зонтичный) | 19.07: Ф-Guides-VectorScan-Crash дрейф сводки поправлен (закрыта 13.07); Ф-Repo-Cleanup п.7 разобран (decisions/README не видел июльский лог) → фаза DecisionLog-Split заведена; п.11 git-layer сверки сделан (14 tracked-but-ignored файлов сняты с учёта); next: iwe-llm-proxy сервис, overnight-auditor |
| 485 | 🔄 | P2 | Сверка дублирующихся скриптов root↔шаблон | 8 файлов Kimi Standalone (решения пилота) |
| 486 | 🔄 | P3 | Роль автозапуска резервного копирования | Ф3 systemd-таймер |
| 487 | 🔄 | P3 | Планировщик отложенного запуска РП | живой прогон через очередь |
| 472 | 🔄 | P3 | Конвейер личного бренда | 2-й человек за пилотом |
| 474 | 🔄 | P2 | Скиллы создания Pack по FPF | Ф8.6b/Ф9/Ф10 автономны |
| 475 | 🔄 | P3 | Резидентность персональных данных IWE | отдельный РП или ждать |
| 476 | 🔄 | **P1** | Модель жизненного цикла данных | реализация Ф7, порядок не выбран |
| 478 | 🔄 | P3 | Терминология «развитие» | 2 пробела у Кими |
| 244 | 🔄 | P2 | Наблюдаемость платформы | Волна 1: решение из 3 вариантов |
| 481 | 🔄 | **P1** | Каталог применений FPF-семинара к IWE | Ф9.1/Ф7/Ф13/Ф3 |
| 289 | 🔄 | P2 | Интеграция IWE с личными базами знаний | Приёмка MVP |
| 483 | 🔄 | P2 | Комплект структурирования данных (guide-kit) | решение пилота по Ф9 (транспорт/серверная часть) |
| 488 | 🔄 | P2 | Браузерное рабочее место на Hetzner | Ф2 скорость |
| 484 | 🔄 | — | Автогенератор открытия/закрытия дня (зонтичный) | 19.07 веч.: закрыт последний непрокрытый git pull (шаг 4.6 day-open-pipeline.sh, git-dirty-guard.sh) - оба места защищены; разовая проверка гонки сервер/Мак запланирована на 20.07 09:20 |
| 493 | 🔄 | P2 | Лаборатория характеристик | 19.07: Ф7+Ф5 закрыты (шов с WP-471 — маппинг этажей, конфликта нет); next: Ф8/Ф9 репо (решение пилота по таймингу) |
| 494 | 🔄 | P2 | Панель рабочих продуктов в VS Code | ручная F5-приёмка пилотом |
| 495 | 🔄 | **P1** | Концепция персонального развития | пилот выбирает порядок Ф4/Ф9/публикации |
| 496 | 🔄 | P3 | Журнал гипотез (LPF-регламент обратной связи) | 19.07: Ф0-Ф4 done — журнал+regламент+skill+АрхГейт роли; ждёт сверки H-001 (не раньше 01.09) |
| 167 | 🔄 | P5 | Публикации (зонтичный) | пилот согласует пост #169 + видео |

## Бот: деплой

| Бот | Ветка | Railway | Env |
|-----|-------|---------|-----|
| @aist_me_bot (прод) | `new-architecture` | `aist_me_bot` (id e840eab0) | Neon |
| @aist_pilot_bot (пилот) | `pilot` | `aist_pilot_bot` (id 5b3adb5c) | Railway Postgres |

> **Pilot-First:** только `pilot`, никогда `new-architecture` первым. Backport = долетело и до `pilot`.
> **Railway MCP:** `peaceful-vision`; `lavish-delight` не трогать. Автодеплой на push. БД/LLM-прокси: [reference-prod-bot-db-access.md](reference-prod-bot-db-access.md), [reference_llm_proxy_railway_project.md](reference_llm_proxy_railway_project.md)

## Read-only репо

> ⛔ **DS-IT-systems/SystemsSchool_bot**, **DS-IT-systems/aisystant**.

---

## Индекс

> Протоколы: protocol-{open,work,close,month-close}.md, [lpf-hypothesis-log.md](lpf-hypothesis-log.md) (журнал гипотез, РП-496). §4 CLAUDE.md. **WARM:** [MEMORY-warm.md](MEMORY-warm.md)

### Feedback — HOT

- [feedback_askuserquestion_not_reaching_pilot.md](feedback_askuserquestion_not_reaching_pilot.md) — choice-question — дублировать в чат
- [routing-vocab.md](routing-vocab.md) — фраза → путь, читать ПЕРЕД Write
- [feedback_response_clarity_for_pilot.md](feedback_response_clarity_for_pilot.md) — A1-A11 правила ответа
- [feedback_explicit_approval_covers_hook_false_positive.md](feedback_explicit_approval_covers_hook_false_positive.md) — одобренная команда → ложняк хука не требует переспроса
- [reference_no_invented_facts_hub.md](reference_no_invented_facts_hub.md) — не выдумывать опыт/имена
- [user_tseren_personal_life.md](user_tseren_personal_life.md) — Tseren (НЕ Дмитрий), Кипр
- [reference_day_protocol_gaps_hub.md](reference_day_protocol_gaps_hub.md) — Day Open/Close квирки (7)
- [reference_wp_gate_mechanics_hub.md](reference_wp_gate_mechanics_hub.md) — task_id, дочерний РП, имя через Артефактор (6)
- [reference_llm_bot_output_quirks_hub.md](reference_llm_bot_output_quirks_hub.md) — TG markdown/HTML квирки (6)
- [reference_diagnosis_technique_hub.md](reference_diagnosis_technique_hub.md) — root-cause, verify-before-trust (36)
- [reference_git_hygiene_hub.md](reference_git_hygiene_hub.md) — git-add scope, pathspec, rebase/reset квирки (29)
- [reference_agent_session_mechanics_hub.md](reference_agent_session_mechanics_hub.md) — рецидив 3× kimi-peer-adapter (11)
- [reference_macos_zsh_env_quirks_hub.md](reference_macos_zsh_env_quirks_hub.md) — квирки macOS/zsh/grep/git (12)
- [lessons_ontological_not_lexical_generation.md](lessons_ontological_not_lexical_generation.md) — Pack/руководства — «онтологически, не лексически»
- [reference_tsekh1_backup_infra_hub.md](reference_tsekh1_backup_infra_hub.md) — SSH-зависания, restic/B2 cap (2)
- [reference_railway_deploy_quirks_hub.md](reference_railway_deploy_quirks_hub.md) — секреты в чат, railpack (2)
- [reference_fmt_process_practices_hub.md](reference_fmt_process_practices_hub.md) — /skill-creator, issue-close, sync≠version-cut (3)
- [reference_process_runner_quirks_hub.md](reference_process_runner_quirks_hub.md) — креды в карточке, race с активной сессией, umbrella-архивация (3)
- [reference_secrets_credentials_hub.md](reference_secrets_credentials_hub.md) — .mcp.json wrapper, ротация-верификация, 403≠401 (3)
- [lessons_shared_registry_axis_needs_ownership_check.md](lessons_shared_registry_axis_needs_ownership_check.md) — новая ось в платформенном реестре: сначала «чья это ось», потом «дробить или нет»
