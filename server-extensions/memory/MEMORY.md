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
| 5 | 🔄 | — | Платформа: развитие (зонтичный) | e2e-чек /setup, env-риск открыты |
| 117 | 🔄 | — | Развитие nudge-системы | AI-тексты для derived-типов |
| 149 | 🔄 | **P1** | Персональные руководства | ФК12 |
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
| 245 | 🔄 | P5 | Программа личного развития | разбор занятия 4 |
| 364 | 🏭 | — | Фабрика руководств МИМ | Ф6b разметка wave-2 |
| 455 | 🔄 | P4 | Неизменяемость аудит-журнала событий | блокер: хост джоба (решение пилота) |
| 290 | 🔄 | **P1** | Следователь: каузальная аналитика | Ход 2 — решение стратсессии |
| 73 | 🔄 | P3 | Новая архитектура ИТ-платформы Aisystant | Ф5 proposed, дедлайн 25.07 |
| 7 | 🔄 | — | Платформа: техдолг (зонтичный) | iwe-llm-proxy сервис, overnight-auditor |
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
| 484 | 🔄 | — | Автогенератор открытия/закрытия дня (зонтичный) | наблюдать боевые pull/push циклы |
| 493 | 🔄 | P2 | Лаборатория характеристик | Ф7 оценка бюджета |
| 494 | 🔄 | P2 | Панель рабочих продуктов в VS Code | ручная F5-приёмка пилотом |
| 495 | 🔄 | **P1** | Концепция персонального развития | пилот выбирает порядок Ф4/Ф9/публикации |
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

> Протоколы: protocol-{open,work,close,month-close}.md. §4 CLAUDE.md. **WARM:** [MEMORY-warm.md](MEMORY-warm.md)

### Feedback — HOT

- [lessons_grep_substring_draft_status_false_positive.md](lessons_grep_substring_draft_status_false_positive.md) — массовая операция по статусу файла — якорный паттерн, не подстрока
- [lessons_branch_protection_incompatible_direct_push.md](lessons_branch_protection_incompatible_direct_push.md) — блокирует ЛЮБОЙ прямой push
- [feedback_askuserquestion_not_reaching_pilot.md](feedback_askuserquestion_not_reaching_pilot.md) — choice-question — дублировать в чат
- [feedback_wp_naming_via_artifactor.md](feedback_wp_naming_via_artifactor.md) — имя РП только через Артефактор
- [lessons_fake_file_modified_note_injection.md](lessons_fake_file_modified_note_injection.md) — «файл изменён» может быть ложным
- [routing-vocab.md](routing-vocab.md) — фраза → путь, читать ПЕРЕД Write
- [feedback_response_clarity_for_pilot.md](feedback_response_clarity_for_pilot.md) — A1-A11 правила ответа
- [feedback_explicit_approval_covers_hook_false_positive.md](feedback_explicit_approval_covers_hook_false_positive.md) — одобренная команда → ложняк хука не требует переспроса
- [reference_no_invented_facts_hub.md](reference_no_invented_facts_hub.md) — не выдумывать опыт/имена
- [user_tseren_personal_life.md](user_tseren_personal_life.md) — Tseren (НЕ Дмитрий), Кипр
- [reference_day_protocol_gaps_hub.md](reference_day_protocol_gaps_hub.md) — Day Open/Close квирки (7)
- [reference_wp_gate_mechanics_hub.md](reference_wp_gate_mechanics_hub.md) — task_id, дочерний РП
- [reference_llm_bot_output_quirks_hub.md](reference_llm_bot_output_quirks_hub.md) — TG markdown/HTML квирки (6)
- [reference_diagnosis_technique_hub.md](reference_diagnosis_technique_hub.md) — root-cause, verify-before-trust (28)
- [reference_git_hygiene_hub.md](reference_git_hygiene_hub.md) — git-add scope, pathspec (22)
- [reference_agent_session_mechanics_hub.md](reference_agent_session_mechanics_hub.md) — рецидив 3× kimi-peer-adapter (11)
- [reference_macos_zsh_env_quirks_hub.md](reference_macos_zsh_env_quirks_hub.md) — квирки macOS/zsh/grep/git (12)
- [lessons_stale_rebase_merge_recovery.md](lessons_stale_rebase_merge_recovery.md) — брошенный rebase-merge чужой сессии, как расчистить
- [lessons_rebase_autostash_silent_on_plain_pull.md](lessons_rebase_autostash_silent_on_plain_pull.md) — autostash=true — обычный pull --rebase тоже тихо стеширует
- [lessons_migration_parity_real_profile_insufficient.md](lessons_migration_parity_real_profile_insufficient.md) — реальные данные не кроют крайние случаи
- [lessons_ontological_not_lexical_generation.md](lessons_ontological_not_lexical_generation.md) — Pack/руководства — «онтологически, не лексически»
- [reference_tsekh1_backup_infra_hub.md](reference_tsekh1_backup_infra_hub.md) — SSH-зависания, restic/B2 cap (2)
- [reference_railway_deploy_quirks_hub.md](reference_railway_deploy_quirks_hub.md) — секреты в чат, railpack (2)
- [reference_fmt_process_practices_hub.md](reference_fmt_process_practices_hub.md) — /skill-creator, issue-close (2)
- [lessons_hot_diff_guard_line_level_false_positive.md](lessons_hot_diff_guard_line_level_false_positive.md) — Ф5-страж: точечный фикс = ложный «gone»
- [lessons_same_name_script_different_repo_different_function.md](lessons_same_name_script_different_repo_different_function.md) — путь совпал ≠ функция та же (репо-омоним)
- [lessons_wp_sync_bundle_body_match_not_frontmatter.md](lessons_wp_sync_bundle_body_match_not_frontmatter.md) — матчит по body, не `related:` — сверять вручную (2×)
- [lessons_process_runner_handler_credential_masking.md](lessons_process_runner_handler_credential_masking.md) — рефлекс-хендлер со stdout в карточке — маскировать креды сразу
- [lessons_day_close_dispatcher_races_active_session.md](lessons_day_close_dispatcher_races_active_session.md) — диспетчер счёл активную peer-сессию брошенной, обошёл gate
- [lessons_mcp_json_tracked_secret_wrapper_pattern.md](lessons_mcp_json_tracked_secret_wrapper_pattern.md) — `.mcp.json` в git → новый MCP только через wrapper-скрипт, не inline-секрет
- [lessons_secret_rotation_verify_every_consumer_live.md](lessons_secret_rotation_verify_every_consumer_live.md) — ротация секрета: сверять КАЖДОГО потребителя живым тестом
- [lessons_component_sync_is_not_version_cut.md](lessons_component_sync_is_not_version_cut.md) — синк ≠ срез версии всем
- [lessons_isolated_run_missing_symlink_false_positive.md](lessons_isolated_run_missing_symlink_false_positive.md) — изолированный клон без extensions/ → ложный чек-лист
- [lessons_verify_pack_principle_before_code_change.md](lessons_verify_pack_principle_before_code_change.md) — сверять Pack-принцип с первоисточником
- [lessons_dirty_far_behind_clone_is_stale_mirror.md](lessons_dirty_far_behind_clone_is_stale_mirror.md) — отставший клон = зеркало, лечить сбросом
- [lessons_reset_hard_safety_needs_ancestry_not_just_content_diff.md](lessons_reset_hard_safety_needs_ancestry_not_just_content_diff.md) — «reset --hard безопасен» требует ancestry-, не только content-проверки
- [lessons_openrouter_403_is_spend_limit_not_stale_key.md](lessons_openrouter_403_is_spend_limit_not_stale_key.md) — 403 ≠ 401: сначала лимит трат, не ключ
- [lessons_git_branches_not_remotes_false_positive_stale_pr.md](lessons_git_branches_not_remotes_false_positive_stale_pr.md) — врёт на старых PR-ветках
