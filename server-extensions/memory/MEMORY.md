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

> Источник: WeekPlan W{N} + WP-REGISTRY.md. Полный контекст каждого РП только в `DS-my-strategy/inbox/WP-{N}/WP-{N}.md` — эта таблица только пойнтер (≤10 слов на `next`), детали сюда не дублировать. Текущий план недели: `current/WeekPlan W33*.md`.

| WP | ст | P | Название | next (≤10 слов) |
|-----|----|----|----------|----------------|
| 516 | 🔄 | P2 | Контур самоулучшения IWE | Ф2 закрыта 10.08 (6 кандидатов, 0 прошли); next Ф3 — АрхГейт с развилкой из РП481 |
| 500 | 🔄 | P2 | Аудит IWE: безопасность, токены, SOTA — разбор находок | Ф1-Ф21 не начат — начать с Ф1 |
| 503 | 🔄 | P1 | Умный конвейер РП | АрхГейт ledger-sync решён (05.08, пир+Codex): lock+publisher; реализация+smoke-тест впереди; токен поллера всё ещё за пилотом |
| 502 | 🔄 | P2 | Актуализация и продвижение портфеля РП | next приёмка наставника + доступ к мониторингу (детали → WP-502.md) |
| 498 | 🔄 | P2 | Наставник ИИ: оперативная помощь в чате | собрать Ф4 (маршрутизация + grounding) в context-sufficiency gate |
| 183 | 🔄 | — | CRM как система | DROP БД directus (решение 24.07); стратсессия 10.08 - отложен ещё на 2 недели, нет времени |
| 467 | 🔄 | **P1** | Архитектура подписок через Ори | решение Д10 блокирует Ф3 |
| 151 | 🔄 | — | Характеристики и состояния деятеля | ждать триггеров Ф18/Ф19 |
| 468 | 🔄 | P3 | Инфраструктура разработки | цех-1 MCP-вход починен 07.08; осталось Ф3 у коллеги |
| 469 | 🔄 | P3 | Архитектура доступа к личным данным | наблюдение завершено 22.07 — начать разбор |
| 470 | 🔄 | P3 | Канал выгрузки Здоровья в iCloud | 03.08: таймер+WeekReport+MonthClose починены; персруковод. → WP-149; Ф5/Ф6 открыты |
| 471 | 🔄 | P2 | Карта целевых аудиторий экосистемы | публикация метафоры или волна-2 (WP-437) |
| 446 | 🔄 | P4 | Меню оплат «Потратить бонусы» | пилот подтверждает на семинарах |
| 417 | 🔄 | P3 | Табло пользователя | Ф-parallelism-1 (схема+B7.3) |
| 448 | 🔄 | P2 | Каталог паттернов процесса IWE | суб-батч 6б done (24+12=36); решение accept/reject по DP.M.217 |
| 458 | 🔄 | **P2** | Сквозной аудит безопасности платформы и IWE | Ф5.1 в проде (оба источника); Ф5.2/5.3 реализованы, не задеплоены |
| 442 | 🔄 | — | Личный бренд Церена | посты 26-07/27-07 ждут ready; стратсессия 10.08 - остаётся, но не приоритет |
| 418 | 🔄 | — | Доставщик | Ф5.1 когорта |
| 482 | 🔄 | P2 | Конвейер процессов IWE (рефлекс/ИИ/пилот) | живая проверка гейта + Ф3/Ф4/Ф5 наблюдение |
| 427 | 🔄 | — | Учёт следов Ф6.3 | живая приёмка |
| 262 | 🔄 | — | Интерфейсы платформы (зонтичный) | ждёт приёмки пилотом (/train) → next feed |
| 330 | 🔄 | **P1** | Марафон вторая волна | волна-3 кикофф встречи-1 готов (05.08); 2 флага пилоту (состав команды, треки) |
| 251 | 🔄 | — | Системы службы продвижения | уточнить явное «да» по финансированию |
| 250 | 🔄 | — | План развития до конца 2026 (зонтичный) | R1-R6 августа утверждены → Strategy.md § август |
| 399 | ⏳ | P1 | Ротация секретов экосистемы | стратсессия 10.08 - не сейчас, привязан к переходу на GKE (после запуска персонального руководства) |
| 510 | 🔄 | P3→P1 | ИИ-личности | Гари: роль пересмотрена (менеджер флота, не онбордер) — дизайн роли не начат |
| 512 | 🔄 | P3 | Испытательный стенд непрерывности ИИ-личностей | spin-off РП-510 Ф8 (06.08); next Ф1 — мировой обзор continuity/adversarial/exit практик |
| 511 | ⏳ | P2 | Бизнес-модель продуктовой линейки | создан 06.08 (спин-офф поста №190-191); первая фаза декомпозиции |
| 5 | 🔄 | — | Платформа: развитие (зонтичный) | детали `inbox/WP-5/WP-5.md` |
| 117 | 🔄 | — | Развитие nudge-системы | переоткрыт 05.08 (ошибочно закрыт по одной фазе, 6 фаз открыты); приёмка stopgap до 30.08 |
| 149 | 🔄 | **P1** | Персональные руководства | 11.08: таймаут-инцидент ночного рендера устранён+задеплоен; 3 новые фазы записаны (параллелизм/пауза/WeekPlan-дрейф), старт не выбран |
| 515 | 🔄 | P3 | Нормализация RLS-конвенции защиты строк | 10.08: защита включена на всех 9 таблицах; единый ключ ждёт триггера/23.08 |
| 438 | 🔄 | — | Агентный режим Гермеса | перенос после WP-149 |
| 170 | 🔄 | P1 | База знаний: обновление | партия #1-225 закрыта 03.08 полностью; 05.08 авторская очистка — 6/7 сигналов закрыты (CC-099 rejected) |
| 415 | 🔄 | P2 | Конвейер орг-GitHub | Конвейер 1 |
| 285 | 🔄 | — | Международная инфраструктура Track B | тесты-спецификации у Андрея |
| 401 | 🔄 | **P1** | Разделение GitHub-организаций | Ф6.1 manifest.sh |
| 406 | 🔄 | **P1** | Онбордер | 10.08: живая работа продолжается (дизайн-сессия content_stage, фиксы в проде); блокеры Ф20/Ф22/Ф24 устарели - сверить заново |
| 456 | 🔄 | P3 | Онбордер англоязычной IWE (браузер) | EN-приёмка ожидает пилота |
| 452 | 🔄 | P3 | Гайд разработчика IWE | Ф2 стиль кода |
| 453 | 🔄 | P4 | Конвейер обновления руководства IWE | ждёт WP-452 Ф2-Ф3 |
| 245 | 🔄 | P5 | Программа личного развития | пилот: правка роли в методичке |
| 364 | 🏭 | — | Фабрика руководств МИМ | Ф6b разметка wave-2 |
| 455 | 🔄 | P4 | Неизменяемость аудит-журнала событий | урок про git pull записан, кода не выкатывал |
| 290 | 🔄 | **P1** | Следователь: каузальная аналитика | Ход 2 отменён 09.08; ждёт RLS-фикса (causal-rls.sql) и решения по новому РП сбора данных |
| 73 | 🔄 | P3 | Новая архитектура ИТ-платформы Aisystant | Ф5 proposed, дедлайн 25.07 (просрочен); стратсессия 10.08 - отложен на неделю, нет времени |
| 7 | 🔄 | — | Платформа: техдолг (зонтичный) | 10.08: Ф62 3/4 в проде (тесты в CI, троттлинг аудита, гейт CI→релиз — 2 бага пойманы пир-ревью); 4-е (классификация CHANGELOG) прошло АрхГейт, реализация отдельным заходом; Ф61 (backlog семафоров) остаётся open |
| 485 | 🔄 | P2 | Сверка дублирующихся скриптов root↔шаблон | Ф7-Ф9 (сторож в ритм) |
| 472 | 🔄 | P3 | Конвейер личного бренда | 2-й человек за пилотом |
| 474 | 🔄 | P2 | Скиллы создания Pack по FPF | сверка fpf-sync-check.sh (Ф9 пункт 3) |
| 476 | 🔄 | **P1** | Модель жизненного цикла данных | прод-краш удаления закрыт, подтверждён; Ф2 ждёт пилота |
| 244 | 🔄 | P2 | Наблюдаемость платформы | Волна 1: решение из 3 вариантов |
| 481 | 🔄 | **P1** | Каталог применений FPF-семинара к IWE | №7/№13 сделаны и задеплоены 10.08 (пир+Codex); Ф25.1 = 10 решений пилота (№12 добавлен) |
| 496 | 🔄 | **P1** | Журнал гипотез (LPF-регламент обратной связи) | Ф5 done (fail-closed сверка починена); next Ф6 догоняющая сверка 39 записей |
| 289 | 🔄 | P3 | Интеграция IWE с личными базами знаний | 09.08: Ф11+WP-495 закрыты; SoT-рамка, активного next нет |
| 483 | 🔄 | P2 | Комплект структурирования данных (guide-kit) | Ф6 шаги 1-3 закрыты 03.08; шаг 4 (регистрация+код) — будущая сессия |
| 484 | 🔄 | **P1** | Автогенератор открытия/закрытия дня (зонтичный) | 11.08: close-intent record + skip_reflection задеплоены, живой прогон подтверждён; next Ф3 — АрхГейт с развилкой из РП481 |
| 493 | 🔄 | P2 | Лаборатория характеристик | Ф4 ждёт данных (конец августа) |
| 494 | 🔄 | P2 | Панель рабочих продуктов в VS Code | дашборд готов и подтверждён; доставка в шаблон отложена до 30.08 |
| 167 | 🔄 | P5 | Публикации (зонтичный) | пилот утверждает порядок 28 постов |
| 497 | 🔄 | P5 | Материалы исследования AGI | Ф9 публикация на клубе — за пилотом |
| 304 | 🔄 | P3 | Сайты aisystant.com (мир) и МИМ (Россия): концепция и обновление | взят в неделю W33 (стратсессия 10.08) - возобновить концепцию, связь с гипотезой H-281 |
| 266 | 🔄 | P3 | Реферальные приглашения «Инженерии интеллекта» | P0-баг найден и исправлен 04.08 веч.; ждёт live-E2E |
| 284 | 🔄 | P2 | Регулярные интервью с пользователями (зонтичный) | взят в неделю W33 (стратсессия 10.08) - Ф6+Ф7, связан с РП511 (интервью о готовности платить) |

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

### Project — HOT

- [project_strategy_session_nep_hypothesis_tracing_gap.md](project_strategy_session_nep_hypothesis_tracing_gap.md) — 10.08: стратегирование не до конца учитывает неудовлетворённости+журнал гипотез при сборке WeekPlan — шаги 06a/06c кандидаты на доработку
- [project_ledger_day_file_recurring_stash_corruption.md](project_ledger_day_file_recurring_stash_corruption.md) — 10.08: дневной ledger-YAML закоммичен с литеральными конфликт-маркерами 3 раза за день — причина не найдена, кандидат в РП-7
- [project_feed_digest_timeout_vitaly_fixed.md](project_feed_digest_timeout_vitaly_fixed.md) — 10.08: тайм-аут дайджеста Ленты — найден, исправлен PR #301, задеплоен, пользователь разблокирован
- [project_wp484_chronic_weekplan_failure_pilot_dissatisfaction.md](project_wp484_chronic_weekplan_failure_pilot_dissatisfaction.md) — 10.08: пилот назвал РП484 «узким горлышком» — план недели не собирался автоматом весь месяц
- [project_iwe_local_config_is_pipeline_source.md](project_iwe_local_config_is_pipeline_source.md) — 09.08: `~/IWE` = iwe-local-config, конвейер → rsync 2ч → iwe-server-config → сервер; правка напрямую в сервер-репо затирается тиком
- [project_memory_repo_has_no_remote.md](project_memory_repo_has_no_remote.md) — 09.08: `memory/` без git-remote с создания, резервной копии нет — решение пилота отложено, не переоткрывать
- [project_tsekh1_deploy_is_automated_not_manual.md](project_tsekh1_deploy_is_automated_not_manual.md) — 08.08: push в iwe-server-config сам деплоит на tsekh-1 — проверять `gh run list`, не писать «доставка не выполнена» вслепую
- [project_codex_peer_reliability_watch.md](project_codex_peer_reliability_watch.md) — 05.08: пилот отметил, что Codex-напарник игнорирует инструкции — открытое наблюдение, копить примеры
- [project_day_open_blocked_since_20260809_staged_uncommitted.md](project_day_open_blocked_since_20260809_staged_uncommitted.md) — РЕШЕНО 11.08: regex+set-e/pipefail баг в проверке «физ» бюджета, фикс задеплоен, ретрай на tsekh-1 зелёный
- [project_tsekh1_chronic_git_sync_and_concurrent_agents.md](project_tsekh1_chronic_git_sync_and_concurrent_agents.md) — 08-10.08 РП484 Ф77/Ф79: корневой фикс autostash→git-dirty-guard задеплоен; живой рецидив «cannot cd» найден, не исправлен
- [project_ds_my_strategy_stash_pop_120_files_pending.md](project_ds_my_strategy_stash_pop_120_files_pending.md) — 09-10.08: ~84 файла вне WP-149 ещё расходятся с HEAD, не срочно; коммит тут — только explicit pathspec (живая гонка индекса)

### Feedback — HOT

- [lessons_check_prior_decisions_before_fresh_archgate.md](lessons_check_prior_decisions_before_fresh_archgate.md) — 11.08: пир-сессия+АрхГейт по гонке сессий (WP-484) одобрены пилотом, ПОТОМ нашёл — тот же вопрос уже отклонён 5 дней назад (Ф59) с двумя возражениями, не пересмотренными
- [lessons_quick_close_ai_contract_output_must_be_bare_enum.md](lessons_quick_close_ai_contract_output_must_be_bare_enum.md) — 10.08: R23-подобные шаги хотят голый литерал в output-поле, обоснование — отдельным сообщением
- [lessons_bash_cwd_drift_breaks_relative_cd_scripts.md](lessons_bash_cwd_drift_breaks_relative_cd_scripts.md) — 10.08: iwe-safe-pull.sh падает, если cwd уже внутри `<repo>` — cd ~/IWE и повторить
- [lessons_residency_gate_check_activation_auto_grants_from_blanket_pregrant.md](lessons_residency_gate_check_activation_auto_grants_from_blanket_pregrant.md) — 10.08: check_activation молча авто-грантит из blanket pre-grant — новый потребитель данных → check_lazy
- [lessons_close_runner_gate_override_needs_sentinel_rm_too.md](lessons_close_runner_gate_override_needs_sentinel_rm_too.md) — 10.08: close-override снимает obligation, но не sentinel-файл `/tmp/iwe-close-intent/` — чистить отдельно
- [lessons_verify_plan_against_live_portfolio_not_just_text.md](lessons_verify_plan_against_live_portfolio_not_just_text.md) — 10.08: сводный план сверять с живыми карточками РП, не перечитыванием своего текста
- [feedback_i_dont_know_do_it_systemically.md](feedback_i_dont_know_do_it_systemically.md) — 10.08: «не знаю, сделай системно» = делегирование с требованием качества, не индифферентность
- [lessons_git_conflict_marker_region_not_whole_story.md](lessons_git_conflict_marker_region_not_whole_story.md) — 09.08: 3-way merge молча удаляет строки за пределами конфликт-меток — сверять весь файл
- [lessons_stale_uncommitted_work_is_rescuable_not_untouchable.md](lessons_stale_uncommitted_work_is_rescuable_not_untouchable.md) — 09.08: старое незакоммиченное (mtime>1д+нет процесса+чужой origin не трогал) → коммит безопасен
- [lessons_session_guard_semaphore_backlog_blocks_any_commit.md](lessons_session_guard_semaphore_backlog_blocks_any_commit.md) — 09.08: стейл-семафоры могут ронять push на случайном файле — чистка кандидат в РП-7
- [lessons_gitignored_artifacts_lost_on_reclone_check_reflog.md](lessons_gitignored_artifacts_lost_on_reclone_check_reflog.md) — 09.08: «файл пропал» → сначала .gitignore+git reflog, не файловый поиск по диску
- [lessons_git_checkout_shared_worktree_risk.md](lessons_git_checkout_shared_worktree_risk.md) — 08.08: `git checkout -- .` в общей директории может стереть чужие правки — не в одной цепочке с discard
- [lessons_sync_core_partial_rule_coverage.md](lessons_sync_core_partial_rule_coverage.md) — 08.08: AGENTS.md покрывает только 6 из 9 блокирующих правил CLAUDE.md §2
- [lessons_run_card_frozen_after_force_no_reflection.md](lessons_run_card_frozen_after_force_no_reflection.md) — 08.08: карточка после --force-no-reflection зависает по дизайну — факт закрытия смотреть в ledger
- [feedback_no_repeated_ritual_prompts.md](feedback_no_repeated_ritual_prompts.md) — 07.08: механические «скажи ок» поглощать самому, свою ошибку не превращать в просьбу к пилоту
- [feedback_scope_full_fix_not_incremental_when_pattern_known.md](feedback_scope_full_fix_not_incremental_when_pattern_known.md) — 07.08: системный класс бага → чинить все места сразу, не оставлять остаток
- [feedback_formal_close_never_silently_incomplete.md](feedback_formal_close_never_silently_incomplete.md) — 07.08: содержание закрыто ≠ ритуал закрыт — говорить об этом в первом «готово»
- [lessons_ssh_heredoc_backtick_local_expansion.md](lessons_ssh_heredoc_backtick_local_expansion.md) — 07.08: бэктики в heredoc внутри ssh раскрываются ЛОКАЛЬНО — писать во временный файл
- [lessons_check_live_diff_before_parallel_infra_fix.md](lessons_check_live_diff_before_parallel_infra_fix.md) — 04-09.08: сверить живой git diff перед правкой общего файла; контестирована ветка → изолированный worktree
- [lessons_bare_git_commit_can_grab_concurrent_session_staged_file.md](lessons_bare_git_commit_can_grab_concurrent_session_staged_file.md) — 10.08: pathspec на commit не защищает git add — restore+add+commit одним вызовом
- [lessons_codex_exec_unreliable_citation_audits.md](lessons_codex_exec_unreliable_citation_audits.md) — 10.08: codex exec галлюцинирует цитаты в аудитах точного текста — верифицировать перед доверием
- [lessons_bash_set_e_pipefail_silent_death_on_empty_grep.md](lessons_bash_set_e_pipefail_silent_death_on_empty_grep.md) — 11.08: `VAR=$(pipeline)` под set-e+pipefail молча умирает на пустом grep — добавлять `\|\| true`
- [routing-vocab.md](routing-vocab.md) — фраза → путь, читать ПЕРЕД Write
- [feedback_response_clarity_for_pilot.md](feedback_response_clarity_for_pilot.md) — A1-A11 правила ответа
- [user_tseren_personal_life.md](user_tseren_personal_life.md) — Tseren (НЕ Дмитрий), Кипр
- Остальные уроки/hubs (73 шт., demoted 28.07+30.07+04.08+09.08) → [MEMORY-warm.md](MEMORY-warm.md)
