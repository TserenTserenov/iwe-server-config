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
| 500 | 🔄 | P2 | Аудит IWE: безопасность, токены, SOTA — разбор находок | утечка ключа OpenAI в git-истории устранена 23.07 (ротация подтверждена пилотом); разбор Ф1-Ф21 не начат, начать с Ф1 |
| 501 | 🔄 | P2 | Headless-канал автономного выполнения задач | 23.07: Ф2.1 п.1+п.2 закрыты (root cause CLI-в-режиме-прокси, healthcheck litellm — фантомный Railway-проект), 7/7 независимо верифицировано; next Ф2 остаток |
| 502 | 🔄 | P2 | Актуализация и продвижение портфеля РП | 23.07: карта этапов построена (hops-критерий, пир-сессия с Kimi), WP-452 Ф2 закрыт, WP-448 Батч 2 (PACK-MIM 35 карточек) полностью закрыт; next продолжить цикл по карте stages-map.md |
| 498 | 🔄 | P2 | Наставник ИИ: оперативная помощь в чате | собрать Ф4 (маршрутизация + grounding) в context-sufficiency gate |
| 183 | 🔄 | — | CRM как система | DROP БД directus (решение 24.07) |
| 467 | 🔄 | **P1** | Архитектура подписок через Ори | решение Д10 блокирует Ф3 |
| 151 | 🔄 | — | Характеристики и состояния деятеля | активных фаз нет, ждать триггеров Ф18/Ф19 |
| 468 | ⏳ | P3 | Инфраструктура разработки | изучить ветку python-gcp knowledge-mcp |
| 469 | 🔄 | P3 | Архитектура доступа к личным данным | WP-470 Ф4 передан 22.07 (наблюдение 5 дней завершено, ни один день не потерян) — начать разбор |
| 470 | 🔄 | P3 | Канал выгрузки Здоровья в iCloud | 27.07: Focus To-Do канал развёрнут целиком — 4 хука, экспорт, еженедельный launchd-таймер; Ф5/Ф6 родителя по-прежнему открыты |
| 471 | 🔄 | P2 | Карта целевых аудиторий экосистемы | публикация метафоры или волна-2 (WP-437) |
| 462 | ⚠️ | P2 | Конвейер оценки качества платформы и IWE | closure противоречив, решение за пилотом |
| 454 | 🔄 | P4 | Честный числитель параллелизма | сверка на Week Close |
| 446 | 🔄 | P4 | Меню оплат «Потратить бонусы» | пилот подтверждает на семинарах |
| 417 | 🔄 | P3 | Табло пользователя | 24.07: АрхГейт пройден для межхостового parallelism (Mac+tsekh-1), план фаз 1-5 в WP-417.md; next Ф-parallelism-1 (схема+B7.3) |
| 448 | 🔄 | P2 | Каталог паттернов процесса IWE | решение по Ф10 |
| 458 | 🔄 | **P2** | Сквозной аудит безопасности платформы и IWE | 2 архитектурных решения за пилотом |
| 442 | 🔄 | — | Личный бренд Церена | посты 26-07/27-07 ждут ready |
| 418 | 🔄 | — | Доставщик | Ф5.1 когорта |
| 482 | 🔄 | P2 | Конвейер процессов IWE (рефлекс/ИИ/пилот) | 25.07: Ф6 реализована (reflex-принуждение к раннеру), race condition параллельных сессий найден и починен независимой проверкой; попутно найден и починен свой сбой первого прогона раннера (repo как абсолютный путь давал ложный has_diff=false, коммит не проходил молча) — next живая проверка гейта в бою + Ф3/Ф4/Ф5 наблюдение |
| 427 | 🔄 | — | Учёт следов Ф6.3 | живая приёмка |
| 262 | 🔄 | — | Интерфейсы платформы (зонтичный) | 27.07 веч.: Ф2-training (llm-proxy атрибуция X-User-ID) закрыта без нового сервиса, задеплоена, независимо проверена; ждёт живой приёмки пилотом (/train) → next feed |
| 330 | 🔄 | **P1** | Марафон вторая волна | 25.07: заключительная встреча волны-2 расшифрована и разобрана (extraction-report 3 кандидата PACK-personal, C-074 topic-log); 3 решения пилота всё ещё не донесены (18.07→22.07); вопрос про Lifework-хаб повторился 2-й раз |
| 437 | 🔄 | **P1** | Вторая волна когорты дизайн | Ф2 запуск, параллель WP-330 |
| 251 | 🔄 | — | Системы службы продвижения | Ф4 живая сессия с Алёной (блокер) |
| 250 | 🔄 | — | План развития до конца 2026 (зонтичный) | Week Close (WIP-фильтр+калибровка) |
| 399 | ⏳ | P1 | Ротация секретов экосистемы | батч просрочен, ротация за пилотом |
| 429 | 🔄 | — | Детектор непротиворечивости базы | 24.07: контракт маршрутизации на 3/9 Pack (systems-art, verification, rhetoric×2), линтер прошёл независимое ревью+2 фикса; next — оставшиеся 6 Pack или git-хук |
| 5 | 🔄 | — | Платформа: развитие (зонтичный) | 27.07: живой прогон Ubuntu в контейнере done (scheduler/incident/date fallback подтверждены), баг PyYAML починен — детали `inbox/WP-5/WP-5.md` |
| 117 | 🔄 | — | Развитие nudge-системы | Ф-adapt ждёт 4 недели рантайма |
| 149 | 🔄 | **P1** | Персональные руководства | 2-3 ночи наблюдения 2.4/2.5, потом решение порога объёма |
| 438 | 🔄 | — | Агентный режим Гермеса | перенос после WP-149 |
| 170 | 🔄 | P1 | База знаний: обновление | 37 карточек записано, 110/225 обработано; Kimi недоступен (token guard) — продолжать соло |
| 415 | 🔄 | P2 | Конвейер орг-GitHub | Конвейер 1 |
| 285 | 🔄 | — | Международная инфраструктура Track B | тесты-спецификации у Андрея |
| 401 | 🔄 | **P1** | Разделение GitHub-организаций | Ф6.1 manifest.sh |
| 406 | 🔄 | **P1** | Онбордер | Ф20 приёмка в Telegram (за пилотом) |
| 456 | 🔄 | P3 | Онбордер англоязычной IWE (браузер) | EN-приёмка ожидает пилота |
| 405 | 🔄 | — | Англоязычная платформа IWE | Ф4 Language Policy FMT |
| 452 | 🔄 | P3 | Гайд разработчика IWE | Ф2 стиль кода |
| 453 | 🔄 | P4 | Конвейер обновления руководства IWE | ждёт WP-452 Ф2-Ф3 |
| 349 | 🔄 | — | Онбординг на MCP | Ф31 тексты, 3-4ч |
| 245 | 🔄 | P5 | Программа личного развития | пилот: правка роли в методичке; Ф-M7/M8 или Блок 3-4 |
| 364 | 🏭 | — | Фабрика руководств МИМ | Ф6b разметка wave-2 |
| 455 | 🔄 | P4 | Неизменяемость аудит-журнала событий | 24.07: панель 23.07 перепроверена лично — не аномалия, штатный день; свежесть клона tsekh-1 не гарантирована (заявление пир-сессии не подтвердилось) — нужен git pull hardening; остаток Ф11 хост-зависимый, ждёт пилота |
| 290 | 🔄 | **P1** | Следователь: каузальная аналитика | Ход 2 — решение стратсессии |
| 73 | 🔄 | P3 | Новая архитектура ИТ-платформы Aisystant | Ф5 proposed, дедлайн 25.07 |
| 7 | 🔄 | — | Платформа: техдолг (зонтичный) | 27.07 веч.: гейт запуска на пустой LITELLM_INTERNAL_KEY задеплоен и подтверждён живым тестом (200 OK); root cause сегодняшнего всплеска $22 на OpenRouter — 4 дня тихого простоя, деньги не пострадали (та же сумма, просто размазана); 5 однотипных незащищённых переменных в auth-gateway.py — пилот решил не чинить сейчас |
| 485 | 🔄 | P2 | Сверка дублирующихся скриптов root↔шаблон | 8 файлов Kimi Standalone (решения пилота) |
| 487 | 🔄 | P3 | Планировщик отложенного запуска РП | живой прогон через очередь |
| 472 | 🔄 | P3 | Конвейер личного бренда | 2-й человек за пилотом |
| 474 | 🔄 | P2 | Скиллы создания Pack по FPF | сверка fpf-sync-check.sh (Ф9 пункт 3) |
| 475 | 🔄 | P3 | Резидентность персональных данных IWE | отдельный РП или ждать |
| 476 | 🔄 | **P1** | Модель жизненного цикла данных | 22.07: R15 №5 закрыт (тип 2.4 переопределён, DP.KR.002 согласован, Lifework → 2.1); осталось Ф2 (нужен пилот) |
| 244 | 🔄 | P2 | Наблюдаемость платформы | Волна 1: решение из 3 вариантов |
| 481 | 🔄 | **P1** | Каталог применений FPF-семинара к IWE | триаж 3 кандидатов Ф16 пилотом; параллельно Ф9.1/Ф7/Ф13/Ф3 |
| 289 | 🔄 | P2 | Интеграция IWE с личными базами знаний | Приёмка MVP |
| 483 | 🔄 | P2 | Комплект структурирования данных (guide-kit) | Ф6-Ф8 ждут РП495 Ф4-Ф5 |
| 488 | 🔄 | P2 | Браузерное рабочее место на Hetzner | railway MCP заведён на цех-1, проверить в новой IDE-сессии; Ф2 скорость/команда |
| 484 | 🔄 | — | Автогенератор открытия/закрытия дня (зонтичный) | выбор пилота: порядок фаз Ф8-Ф14 |
| 493 | 🔄 | P2 | Лаборатория характеристик | Ф4 ждёт данных (конец августа — сентябрь) |
| 494 | 🔄 | P2 | Панель рабочих продуктов в VS Code | ручная F5-приёмка пилотом |
| 495 | 🔄 | **P1** | Концепция персонального развития | 23.07: Ф8 черновик РП1 собран (12/13, placeholder — ждёт живых данных пробной группы); P1-окно закрылось 4 дня назад, нужна переоценка приоритета пилотом |
| 496 | 🔄 | P3 | Журнал гипотез (LPF-регламент обратной связи) | сверка «Актуальных» агентом на Week Close |
| 167 | 🔄 | P5 | Публикации (зонтичный) | пилот утверждает порядок 28 постов; публикатор стартует с Ф-А3 |
| 497 | 🔄 | P5 | Материалы исследования AGI | Ф1 ready; Ф9 публикация на клубе — ручной шаг пилота |
| 391 | 🔄 | **P1** | Браузерный IWE — мультимодельный вход (Kimi) | 25.07: Ф7.1 done (смоук-тест PASS) + Ф7.2 архитектура done (АрхГейт: MCP-адаптер поверх gateway-mcp, DRR); блокирует WP-385 Ф5 — next реализация адаптера |

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
- [lessons_two_agent_consensus_still_needs_independent_review.md](lessons_two_agent_consensus_still_needs_independent_review.md) — расхождение выводов → проверить, с какого хоста/источника данные, не только внутреннюю логику
- [feedback_kimi_peer_quality_concern.md](feedback_kimi_peer_quality_concern.md) — Кими плохо работает в пир-сессиях — усиленно верифицировать его находки независимо
- [feedback_s33_scope_already_answered.md](feedback_s33_scope_already_answered.md) — scope S-33 уже разграничен пилотом в сессии → констатировать, не переспрашивать
- [routing-vocab.md](routing-vocab.md) — фраза → путь, читать ПЕРЕД Write
- [feedback_response_clarity_for_pilot.md](feedback_response_clarity_for_pilot.md) — A1-A11 правила ответа
- [feedback_explicit_approval_covers_hook_false_positive.md](feedback_explicit_approval_covers_hook_false_positive.md) — одобренная команда → ложняк хука не требует переспроса
- [feedback_post_draft_dedup_before_new.md](feedback_post_draft_dedup_before_new.md) — новый материал для постов → сначала обогатить черновик, новый только если нет подходящего
- [reference_no_invented_facts_hub.md](reference_no_invented_facts_hub.md) — не выдумывать опыт/имена
- [user_tseren_personal_life.md](user_tseren_personal_life.md) — Tseren (НЕ Дмитрий), Кипр
- [reference_day_protocol_gaps_hub.md](reference_day_protocol_gaps_hub.md) — Day Open/Close квирки (7)
- [reference_wp_gate_mechanics_hub.md](reference_wp_gate_mechanics_hub.md) — task_id, дочерний РП, имя через Артефактор (6)
- [reference_llm_bot_output_quirks_hub.md](reference_llm_bot_output_quirks_hub.md) — TG markdown/HTML квирки (6)
- [reference_diagnosis_technique_hub.md](reference_diagnosis_technique_hub.md) — root-cause, verify-before-trust (48)
- [reference_git_hygiene_hub.md](reference_git_hygiene_hub.md) — git-add scope, pathspec, rebase/reset квирки (32)
- [lessons_verify_branch_before_commit_pilot_first.md](lessons_verify_branch_before_commit_pilot_first.md) — Pilot-First репо: проверить ветку ДО commit, не только перед push
- [reference_agent_session_mechanics_hub.md](reference_agent_session_mechanics_hub.md) — рецидив 3× kimi-peer-adapter (11)
- [reference_macos_zsh_env_quirks_hub.md](reference_macos_zsh_env_quirks_hub.md) — квирки macOS/zsh/grep/git (15)
- [lessons_ontological_not_lexical_generation.md](lessons_ontological_not_lexical_generation.md) — Pack/руководства — «онтологически, не лексически»
- [reference_tsekh1_backup_infra_hub.md](reference_tsekh1_backup_infra_hub.md) — SSH-зависания, restic/B2 cap (2)
- [reference_railway_deploy_quirks_hub.md](reference_railway_deploy_quirks_hub.md) — секреты в чат, railpack (2)
- [reference_fmt_process_practices_hub.md](reference_fmt_process_practices_hub.md) — /skill-creator, issue-close, sync≠version-cut (3)
- [reference_process_runner_quirks_hub.md](reference_process_runner_quirks_hub.md) — креды в карточке, race с активной сессией, umbrella-архивация (3)
- [reference_secrets_credentials_hub.md](reference_secrets_credentials_hub.md) — .mcp.json wrapper, ротация-верификация, 403≠401 (3)
- [lessons_shared_registry_axis_needs_ownership_check.md](lessons_shared_registry_axis_needs_ownership_check.md) — новая ось в платформенном реестре: сначала «чья это ось», потом «дробить или нет»
- [lessons_session_guard_housekeeping_reason_path_injection.md](lessons_session_guard_housekeeping_reason_path_injection.md) — housekeeping-reason с пробелами/двоеточием ломает session-guard.sh; note-file падает при нескольких открытых семафорах; close ДО commit стирает scope
- [lessons_active_wp_sweep_scale_hang.md](lessons_active_wp_sweep_scale_hang.md) — active-wp-sweep.sh O(РП×репо) без параллелизма/кэша зависает при росте базы (118+×67)
- [lessons_gate_marker_granularity_mismatch.md](lessons_gate_marker_granularity_mismatch.md) — giving-up маркер должен писаться в тот же state-файл, что проверяет входной гейт цикла
- [lessons_new_sentinel_gate_must_test_parallel_sessions.md](lessons_new_sentinel_gate_must_test_parallel_sessions.md) — новый sentinel/marker-гейт без session_id в общем каталоге путает параллельные сессии
- [lessons_commit_push_repo_field_is_relative_path.md](lessons_commit_push_repo_field_is_relative_path.md) — раннер: repos[] абсолютный путь, commits[].repo относительный от IWE_ROOT — разный контракт похожих полей
