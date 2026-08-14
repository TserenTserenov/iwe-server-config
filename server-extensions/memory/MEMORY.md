# Оперативная память

> **Инструкции:** `~/IWE/CLAUDE.md` | **Навигация:** `memory/navigation.md` | **SoT:** `DP.EXOCORTEX.001` | Слои: L1 платформа · L2 staging · L3 авторское.

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
| 525 | 🔄 | P2 | Конвейер обновления IWE из FPF | 13.08: Ф2 частично — SKILL.md правка задеплоена (полный поиск); Ф4 находка — раннер не коммитит корневой IWE; next Ф1 правило отбора паттернов |
| 520 | 🔄 | P2 | Новая версия конвейера закрытия сессии | 14.08 (PR#82-85): handoff коммитится ДО release; stash+W09 закрыты; Ф12 — агент сам пропустил рефлексию, зафиксировано; validate_orz canonical-path баг найден |
| 523 | 🔄 | P3 | Концепция использования MCP2.0 | вердикт C утверждён 11.08 (DRR); остаток Ф2: клиентская матрица + метрики |
| 521 | 🔄 | P1 | Конвейер генерации руководств и методических материалов | Ф0 done 11.08 (карта DP.MAP.003, пир Kimi); next спайк Ф1 с пилотом |
| 522 | 🔄 | P2 | Чек-лист участника экосистемы | Д-к добавлен 12.08: Разметчик подсказывает структуру базы — решается на Ф2 |
| 524 | 🔄 | P2 | Скилл многоагентных пир-сессий в разных интерфейсах | 14.08: скоуп расширен Ф5 (пилот) — сбор статистики ручного выбора координационного паттерна → кристаллизация в рефлекс; АрхГейт заблокировал немедленную автоматизацию; next сбор статистики из sessions/ |
| 516 | 🔄 | P2 | Контур самоулучшения IWE | Ф2 закрыта 10.08 (6 кандидатов, 0 прошли); next Ф3 — АрхГейт с развилкой из РП481 |
| 500 | 🔄 | P2 | Аудит IWE: безопасность, токены, SOTA — разбор находок | Ф1-Ф21 не начат — начать с Ф1 |
| 503 | 🔄 | P1 | Умный конвейер РП | 14.08 пир Codex: repair ledger day-14 done (гонка tsekh-1+Mac, union 97 событий, commit f596b9444); дизайн-пробел ledger-append.sh кандидат ArchGate; токен поллера всё ещё за пилотом |
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
| 510 | 🔄 | P3→P1 | ИИ-личности | 13.08: Ф25 конвенция активации Элара закреплена (3 живых пробела закрыты); Гари: роль пересмотрена, дизайн не начат |
| 512 | 🔄 | P3 | Испытательный стенд непрерывности ИИ-личностей | spin-off РП-510 Ф8 (06.08); next Ф1 — мировой обзор continuity/adversarial/exit практик |
| 511 | ⏳ | P2 | Бизнес-модель продуктовой линейки | создан 06.08 (спин-офф поста №190-191); первая фаза декомпозиции |
| 5 | 🔄 | — | Платформа: развитие (зонтичный) | детали `inbox/WP-5/WP-5.md` |
| 117 | 🔄 | — | Развитие nudge-системы | переоткрыт 05.08 (ошибочно закрыт по одной фазе, 6 фаз открыты); приёмка stopgap до 30.08 |
| ~~149~~ | ✅ | — | ~~Персональные руководства~~ | done 11.08: обещание выполнено (зелёная генерация+Портной); хвосты в РП-7 (RPP/RPE/RPW); наследник — новый РП «Портной: методический материал под запрос» |
| 515 | 🔄 | P3 | Нормализация RLS-конвенции защиты строк | 10.08: защита включена на всех 9 таблицах; единый ключ ждёт триггера/23.08 |
| 438 | 🔄 | — | Агентный режим Гермеса | перенос после WP-149 |
| 170 | 🔄 | P1 | База знаний: обновление | партия #1-225 закрыта 03.08 полностью; 05.08 авторская очистка — 6/7 сигналов закрыты (CC-099 rejected) |
| 415 | 🔄 | P2 | Конвейер орг-GitHub | Конвейер 1 |
| 285 | 🔄 | — | Международная инфраструктура Track B | тесты-спецификации у Андрея |
| 401 | 🔄 | **P1** | Разделение GitHub-организаций | Ф6.1 manifest.sh |
| 406 | 🔄 | **P1** | Онбордер | 12.08: прогон Б Ф-Ж техчасть подтверждена, поведенческая нет (нужен чистый аккаунт); секрет §4 уже заведён; чек-лист Ф20 и баг раннера reflection-detection (не заведён в bug-inbox) — за пилотом |
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
| 289 | 🔄 | P3 | Интеграция IWE с личными базами знаний | 11.08: Разметчик (structurer/) явно связан с РП149; SoT-рамка, активного next нет |
| 483 | 🔄 | P2 | Комплект структурирования данных (guide-kit) | 12.08: Ф6 шаг 4 закрыт (3 паралл. сессии) — Pack DP.ROLE.093/DP.SC.065 + код + H3.6; next живой прогон на реальном topic.yaml |
| 484 | 🔄 | **P1** | Автогенератор открытия/закрытия дня (зонтичный) | 11.08: Ф88 — 3 текстовых false-positive в гейтах закрытия/коммита исправлены |
| 493 | 🔄 | P2 | Лаборатория характеристик | Ф4 ждёт данных (конец августа) |
| 494 | 🔄 | P2 | Панель рабочих продуктов в VS Code | дашборд готов и подтверждён; доставка в шаблон отложена до 30.08 |
| 167 | 🔄 | P5 | Публикации (зонтичный) | пост «4 уровня ИИ» готов во всех 3 каналах, ready |
| 497 | 🔄 | P5 | Материалы исследования AGI | Ф9 публикация на клубе — за пилотом |
| 304 | 🔄 | P3 | Сайты aisystant.com (мир) и МИМ (Россия): концепция и обновление | взят в неделю W33 (стратсессия 10.08) - возобновить концепцию, связь с гипотезой H-281 |
| 266 | 🔄 | P3 | Реферальные приглашения «Инженерии интеллекта» | P0-баг найден и исправлен 04.08 веч.; ждёт live-E2E |
| 284 | 🔄 | P2 | Регулярные интервью с пользователями (зонтичный) | взят в неделю W33 (стратсессия 10.08) - Ф6+Ф7, связан с РП511 (интервью о готовности платить) |
| 519 | ⏳ | P2 | Инфраструктура непрерывной проверки кода | 11.08 создан (поручение пилота, тема доверия к агентному коду с ИТ-оперативки); next Ф1 — контракт качества и границы |

## Бот: деплой

| Бот | Ветка | Railway | Env |
|-----|-------|---------|-----|
| @aist_me_bot (прод) | `new-architecture` | `aist_me_bot` (id e840eab0) | Neon |
| @aist_pilot_bot (пилот) | `pilot` | `aist_pilot_bot` (id 5b3adb5c) | Railway Postgres |

> **Pilot-First:** только `pilot`, никогда `new-architecture` первым. Backport = долетело и до `pilot`.
> **Railway MCP:** `peaceful-vision`; `lavish-delight` не трогать. Автодеплой на push. БД/LLM-прокси: [reference-prod-bot-db-access.md](reference-prod-bot-db-access.md), [reference_llm_proxy_railway_project.md](reference_llm_proxy_railway_project.md)
> ⛔ **Read-only репо:** DS-IT-systems/SystemsSchool_bot, DS-IT-systems/aisystant.

---

## Индекс

> Протоколы: protocol-{open,work,close,month-close}.md, [lpf-hypothesis-log.md](lpf-hypothesis-log.md) (журнал гипотез, РП-496). §4 CLAUDE.md. **WARM:** [MEMORY-warm.md](MEMORY-warm.md)

### Project — HOT

- [project_ds_my_strategy_repo_divergence_carryover.md](project_ds_my_strategy_repo_divergence_carryover.md) — 12.08 вечер: DS-my-strategy на чужой ветке, +53/-185 от origin/main, 527 незакоммиченных файлов — пилот явно перенёс разбор в новую сессию, начинать оттуда
- [project_wp520_dashboard_clone_unpushed_fmt_duplicate.md](project_wp520_dashboard_clone_unpushed_fmt_duplicate.md) — 12.08: клон DS-my-strategy-dashboard хранит незапушенный дубль записи FMT delivery failure (2f7335f83) + основной WP-520.md пропускает 12-й живой случай (commit-push.sh)
- [project_ledger_day_file_recurring_stash_corruption.md](project_ledger_day_file_recurring_stash_corruption.md) — 10.08: дневной ledger-YAML закоммичен с литеральными конфликт-маркерами 3 раза за день — причина не найдена, кандидат в РП-7; 11.08 союз-мердж двух хвостов прошёл чисто (python union + полная валидация)
- [project_iwe_local_config_is_pipeline_source.md](project_iwe_local_config_is_pipeline_source.md) — 09.08: `~/IWE` = iwe-local-config, конвейер → rsync 2ч → iwe-server-config → сервер; правка напрямую в сервер-репо затирается тиком
- [project_memory_repo_has_no_remote.md](project_memory_repo_has_no_remote.md) — 09.08: `memory/` без git-remote с создания, резервной копии нет — решение пилота отложено, не переоткрывать
- [project_tsekh1_chronic_git_sync_and_concurrent_agents.md](project_tsekh1_chronic_git_sync_and_concurrent_agents.md) — 08-10.08 РП484 Ф77/Ф79: корневой фикс autostash→git-dirty-guard задеплоен; живой рецидив «cannot cd» найден, не исправлен
- [project_ds_my_strategy_stash_pop_120_files_pending.md](project_ds_my_strategy_stash_pop_120_files_pending.md) — 09-11.08: чекаут DS-my-strategy живёт на чужих ветках/с чужим staged — коммит только explicit pathspec, в main через worktree+cherry-pick; ~84 файла расходятся с HEAD

### Feedback — HOT

- [lessons_runner_commit_push_repo_wide_not_path_scoped.md](lessons_runner_commit_push_repo_wide_not_path_scoped.md) — 14.08: commit-push раннера проверяет push-чистоту всей ветки, не путей задачи — ложный отказ, когда чекаут на чужой ветке впереди upstream по несвязанным коммитам; multiline message с тегом [no-registry-touch] искажается при проходе через раннер (живой git-хук принял тот же текст напрямую)
- [lessons_causal_signal_beats_diff_recompute_for_gate.md](lessons_causal_signal_beats_diff_recompute_for_gate.md) — 14.08: устаревший gate после перестановки шагов → искать простой причинный сигнал (session_file_exists), не пересчитывать сложную diff-логику; не дробить инкапсулированный 382-строчный модуль ради одного нового потребителя
- [lessons_parallel_classification_stale_before_transfer.md](lessons_parallel_classification_stale_before_transfer.md) — 13.08: параллельная классификация субагентами устаревает к моменту переноса, если main продолжает расти во время их работы (7 из 34 находок протухли за минуты в РП520 Ф11 batch7) — обязательна перепроверка непосредственно перед переносом
- [lessons_quick_close_runner_root_repo_and_pilot_step_input.md](lessons_quick_close_runner_root_repo_and_pilot_step_input.md) — 13.08: commit-push.sh не адресует корневой репо IWE (любое имя переполняет путь); pilot-шаг (blocked-push-failed) теряет --input, переданный тем же вызовом, что его обнаружил — нужен раздельный повторный next
- [lessons_stale_draft_may_hide_unpublished_content_dont_discard_wholesale.md](lessons_stale_draft_may_hide_unpublished_content_dont_discard_wholesale.md) — 13.08: застывший diff не всегда гонка/зависание — может быть черновик поверх устаревшего среза, origin ушёл вперёд; сверять origin/main, переносить уникальную часть вручную, не отбрасывать и не коммитить целиком
- [feedback_verify_close_claims_against_ledger.md](feedback_verify_close_claims_against_ledger.md) — 13.08: не доверять тексту WP-карточки о закрытии («снято вручную») — сверять с дневным ledger по session_id, Codex поймал трижды за одну пир-сессию
- [project_close_gate_cannot_recognize_worktree_delivery.md](project_close_gate_cannot_recognize_worktree_delivery.md) — 13.08: 3 раза за день session-guard close не признал доставку через worktree; force-no-reflection покрывает только witness-гонку, не этот класс — карантинировать напрямую, не тратить циклы на обход
- [lessons_live_run_requires_clean_account.md](lessons_live_run_requires_clean_account.md) — 12.08: живой прогон проактивности модели невалиден на аккаунте с историей IWE — нужен чистый аккаунт (РП406, прогон Б Ф-Ж)
- [lessons_pull_refused_check_origin_before_wp_start.md](lessons_pull_refused_check_origin_before_wp_start.md) — 11.08: pull-guard отказал → сверить origin через git fetch ДО старта РП, иначе проектируешь уже отгруженное (РП406: бот-половина сделана параллельно за 20 мин до старта)
- [lessons_quick_close_witness_blocks_autonomous_vscode.md](lessons_quick_close_witness_blocks_autonomous_vscode.md) — 11.08: blocked-witness = штатное «жду живого ответа пилота» (не сбой); двухтактное закрытие автономной сессии, адресное снятие семафора, переоткрытие слага для пост-коммита; кейс №8 → РП-520
- [lessons_smoke_fixture_bypassing_pipeline_masks_nonpassthrough.md](lessons_smoke_fixture_bypassing_pipeline_masks_nonpassthrough.md) — 11.08: смоук с фикстурой в середину конвейера маскирует непроброс поля — сквозной смоук от входа обязателен (Critical Ф6 пойман ревью)
- [lessons_peer_session_found_same_day_earlier_fix_only_half_deployed.md](lessons_peer_session_found_same_day_earlier_fix_only_half_deployed.md) — 11.08: перед разбором хронической жалобы пилота — проверить журнал сессий за день, не решалась ли она уже (утренняя сессия решила гонку закрытия только на Claude-стороне)
- [lessons_peer_review_catches_event_vs_time_reap_conflation.md](lessons_peer_review_catches_event_vs_time_reap_conflation.md) — 11.08: «X уже покрывает Y» — проверять построчно, что реально триггерит X, не полагаться на имя/впечатление
- [lessons_check_prior_decisions_before_fresh_archgate.md](lessons_check_prior_decisions_before_fresh_archgate.md) — 11.08: перед новым АрхГейтом проверить, не отклонялся ли тот же вопрос раньше (Ф59-прецедент)
- [lessons_bash_set_e_pipefail_silent_death_on_empty_grep.md](lessons_bash_set_e_pipefail_silent_death_on_empty_grep.md) — 11.08: `VAR=$(pipeline)` под set-e+pipefail молча умирает на пустом grep — добавлять `\|\| true`
- [lessons_session_guard_notefile_ambiguous_multi_semaphore.md](lessons_session_guard_notefile_ambiguous_multi_semaphore.md) — 11.08: note-file при 2+ семафорах агента отказывает fail-closed, `\|\| true` глушит отказ — файлы вне scope, гейт валит коммит без имён; регистрация напрямую в свой семафор
- [lessons_bare_git_commit_can_grab_concurrent_session_staged_file.md](lessons_bare_git_commit_can_grab_concurrent_session_staged_file.md) — 10.08: pathspec на commit не защищает git add — restore+add+commit одним вызовом
- [lessons_codex_exec_unreliable_citation_audits.md](lessons_codex_exec_unreliable_citation_audits.md) — 10.08: codex exec галлюцинирует цитаты в аудитах точного текста — верифицировать перед доверием
- [lessons_check_live_diff_before_parallel_infra_fix.md](lessons_check_live_diff_before_parallel_infra_fix.md) — 04-11.08: сверить живой git diff И ТЕКУЩУЮ ВЕТКУ перед правкой общего файла; контестирована ветка → изолированный worktree (11.08: коммит сел на чужую ветку — cherry-pick в main + CAS-возврат ветки)
- [feedback_scope_full_fix_not_incremental_when_pattern_known.md](feedback_scope_full_fix_not_incremental_when_pattern_known.md) — 07.08: системный класс бага → чинить все места сразу, не оставлять остаток
- [feedback_formal_close_never_silently_incomplete.md](feedback_formal_close_never_silently_incomplete.md) — 07.08: содержание закрыто ≠ ритуал закрыт — говорить об этом в первом «готово»
- [routing-vocab.md](routing-vocab.md) — фраза → путь, читать ПЕРЕД Write
- [feedback_response_clarity_for_pilot.md](feedback_response_clarity_for_pilot.md) — A1-A11 правила ответа
- [user_tseren_personal_life.md](user_tseren_personal_life.md) — Tseren (НЕ Дмитрий), Кипр
- Остальные уроки/hubs (94 шт., demoted 28.07+30.07+04.08+09.08+11.08) → [MEMORY-warm.md](MEMORY-warm.md)
