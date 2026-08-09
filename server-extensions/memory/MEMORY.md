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

> Источник: WeekPlan W{N} + WP-REGISTRY.md. Полный контекст каждого РП только в `DS-my-strategy/inbox/WP-{N}/WP-{N}.md` — эта таблица только пойнтер (≤10 слов на `next`), детали сюда не дублировать. Текущий план недели: `current/WeekPlan W32*.md`.

| WP | ст | P | Название | next (≤10 слов) |
|-----|----|----|----------|----------------|
| 500 | 🔄 | P2 | Аудит IWE: безопасность, токены, SOTA — разбор находок | Ф1-Ф21 не начат — начать с Ф1 |
| 503 | 🔄 | P1 | Умный конвейер РП | АрхГейт ledger-sync решён (05.08, пир+Codex): lock+publisher; реализация+smoke-тест впереди; токен поллера всё ещё за пилотом |
| 502 | 🔄 | P2 | Актуализация и продвижение портфеля РП | next приёмка наставника + доступ к мониторингу (детали → WP-502.md) |
| 498 | 🔄 | P2 | Наставник ИИ: оперативная помощь в чате | собрать Ф4 (маршрутизация + grounding) в context-sufficiency gate |
| 183 | 🔄 | — | CRM как система | DROP БД directus (решение 24.07) |
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
| 442 | 🔄 | — | Личный бренд Церена | посты 26-07/27-07 ждут ready |
| 418 | 🔄 | — | Доставщик | Ф5.1 когорта |
| 482 | 🔄 | P2 | Конвейер процессов IWE (рефлекс/ИИ/пилот) | живая проверка гейта + Ф3/Ф4/Ф5 наблюдение |
| 427 | 🔄 | — | Учёт следов Ф6.3 | живая приёмка |
| 262 | 🔄 | — | Интерфейсы платформы (зонтичный) | ждёт приёмки пилотом (/train) → next feed |
| 330 | 🔄 | **P1** | Марафон вторая волна | волна-3 кикофф встречи-1 готов (05.08); 2 флага пилоту (состав команды, треки) |
| 251 | 🔄 | — | Системы службы продвижения | уточнить явное «да» по финансированию |
| 250 | 🔄 | — | План развития до конца 2026 (зонтичный) | R1-R6 августа утверждены → Strategy.md § август |
| 399 | ⏳ | P1 | Ротация секретов экосистемы | батч просрочен, ротация за пилотом |
| 509 | 🔄 | P2 | Пир-сессии 3+ агентов: роль-дискавери и общий рабочий продукт | S-51 закрыта 3/3; промоция на Week Close |
| 510 | 🔄 | P3→P1 | ИИ-личности | 2 пункта ждут пилота (текст фидбек-памяти, атрибуция коммита); РП-512 отдельно |
| 512 | 🔄 | P3 | Испытательный стенд непрерывности ИИ-личностей | spin-off РП-510 Ф8 (06.08); next Ф1 — мировой обзор continuity/adversarial/exit практик |
| 511 | ⏳ | P2 | Бизнес-модель продуктовой линейки | создан 06.08 (спин-офф поста №190-191); первая фаза декомпозиции |
| 5 | 🔄 | — | Платформа: развитие (зонтичный) | детали `inbox/WP-5/WP-5.md` |
| 117 | 🔄 | — | Развитие nudge-системы | переоткрыт 05.08 (ошибочно закрыт по одной фазе, 6 фаз открыты); приёмка stopgap до 30.08 |
| 149 | 🔄 | **P1** | Персональные руководства | 1.11 и порог доливки починены, задеплоены 08.08; 1.3 жёлтый |
| 438 | 🔄 | — | Агентный режим Гермеса | перенос после WP-149 |
| 170 | 🔄 | P1 | База знаний: обновление | партия #1-225 закрыта 03.08 полностью; 05.08 авторская очистка — 6/7 сигналов закрыты (CC-099 rejected) |
| 415 | 🔄 | P2 | Конвейер орг-GitHub | Конвейер 1 |
| 285 | 🔄 | — | Международная инфраструктура Track B | тесты-спецификации у Андрея |
| 401 | 🔄 | **P1** | Разделение GitHub-организаций | Ф6.1 manifest.sh |
| 406 | 🔄 | **P1** | Онбордер | блокирован: 3 пакета решений пилота (Ф20/Ф22/Ф24), 0 движения 03.08 |
| 456 | 🔄 | P3 | Онбордер англоязычной IWE (браузер) | EN-приёмка ожидает пилота |
| 452 | 🔄 | P3 | Гайд разработчика IWE | Ф2 стиль кода |
| 453 | 🔄 | P4 | Конвейер обновления руководства IWE | ждёт WP-452 Ф2-Ф3 |
| 245 | 🔄 | P5 | Программа личного развития | пилот: правка роли в методичке |
| 364 | 🏭 | — | Фабрика руководств МИМ | Ф6b разметка wave-2 |
| 455 | 🔄 | P4 | Неизменяемость аудит-журнала событий | урок про git pull записан, кода не выкатывал |
| 290 | 🔄 | **P1** | Следователь: каузальная аналитика | Ход 2 — решение стратсессии |
| 73 | 🔄 | P3 | Новая архитектура ИТ-платформы Aisystant | Ф5 proposed, дедлайн 25.07 |
| 7 | 🔄 | — | Платформа: техдолг (зонтичный) | 05.08: ORY-RT1 гейт сверен (2 пир-сессии), issues #351/#352 закрыты; next: QUICKCLOSE-GAPS1 разбор (детали → WP-7.md) |
| 485 | 🔄 | P2 | Сверка дублирующихся скриптов root↔шаблон | Ф7-Ф9 (сторож в ритм) |
| 472 | 🔄 | P3 | Конвейер личного бренда | 2-й человек за пилотом |
| 474 | 🔄 | P2 | Скиллы создания Pack по FPF | сверка fpf-sync-check.sh (Ф9 пункт 3) |
| 476 | 🔄 | **P1** | Модель жизненного цикла данных | прод-краш удаления закрыт, подтверждён; Ф2 ждёт пилота |
| 244 | 🔄 | P2 | Наблюдаемость платформы | Волна 1: решение из 3 вариантов |
| 481 | 🔄 | **P1** | Каталог применений FPF-семинара к IWE | аудит №2 (WP-149) закрыт; next аудит №3 WP-484/WP-503 |
| 496 | 🔄 | **P1** | Журнал гипотез (LPF-регламент обратной связи) | Ф5 done (fail-closed сверка починена); next Ф6 догоняющая сверка 39 записей |
| 289 | 🔄 | P3 | Интеграция IWE с личными базами знаний | 09.08: Ф11+WP-495 закрыты; SoT-рамка, активного next нет |
| 483 | 🔄 | P2 | Комплект структурирования данных (guide-kit) | Ф6 шаги 1-3 закрыты 03.08; шаг 4 (регистрация+код) — будущая сессия |
| 484 | 🔄 | **P1** | Автогенератор открытия/закрытия дня (зонтичный) | 08.08 Ф77 закрыта (Pull-on-Touch корневой фикс, задеплоен+подтверждён); next Ф75/Ф76 (реализация не начата) |
| 493 | 🔄 | P2 | Лаборатория характеристик | Ф4 ждёт данных (конец августа) |
| 494 | 🔄 | P2 | Панель рабочих продуктов в VS Code | дашборд готов и подтверждён; доставка в шаблон отложена до 30.08 |
| 167 | 🔄 | P5 | Публикации (зонтичный) | пилот утверждает порядок 28 постов |
| 497 | 🔄 | P5 | Материалы исследования AGI | Ф9 публикация на клубе — за пилотом |
| 304 | 🔄 | P3 | Сайты aisystant.com (мир) и МИМ (Россия): концепция и обновление | отстройка от образования, слоган, цена — за пилотом |
| 266 | 🔄 | P3 | Реферальные приглашения «Инженерии интеллекта» | P0-баг найден и исправлен 04.08 веч.; ждёт live-E2E |

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

- [project_iwe_local_config_is_pipeline_source.md](project_iwe_local_config_is_pipeline_source.md) — 09.08: `~/IWE` корень = рабочая копия `iwe-local-config`, источник конвейера → Мак scripts/ → rsync 2ч → `iwe-server-config` → сервер; коммит фикса напрямую в `iwe-server-config` затирается ближайшим тиком
- [project_memory_repo_has_no_remote.md](project_memory_repo_has_no_remote.md) — 09.08: `memory/` без git-remote с самого создания (03.08), резервной копии нет; пилот отложил решение, куда её класть — не переоткрывать как новую проблему
- [project_tsekh1_deploy_is_automated_not_manual.md](project_tsekh1_deploy_is_automated_not_manual.md) — 08.08: push в iwe-server-config деплоит на tsekh-1 сам (GitHub Actions deploy-rs), ручной nixos-rebuild не обязателен — проверять `gh run list` перед тем как писать «доставка не выполнена»
- [project_codex_peer_reliability_watch.md](project_codex_peer_reliability_watch.md) — 05.08: пилот отметил, что Codex-напарник игнорирует инструкции — открытое наблюдение, копить примеры до эскалации
- [project_tsekh1_chronic_git_sync_and_concurrent_agents.md](project_tsekh1_chronic_git_sync_and_concurrent_agents.md) — 08.08 РП484 Ф77: корневой фикс (raw --autostash → scripts/iwe-safe-pull.sh переиспользует git-dirty-guard.sh) задеплоен на tsekh-1 и подтверждён живым прогоном

### Feedback — HOT

- [lessons_git_conflict_marker_region_not_whole_story.md](lessons_git_conflict_marker_region_not_whole_story.md) — 09.08: git 3-way merge молча удаляет неконфликтующие строки за пределами `<<<<<<<`/`>>>>>>>` меток (одна сторона тронула, другая нет = auto-take) — сверять весь файл, не только помеченный блок
- [lessons_stale_uncommitted_work_is_rescuable_not_untouchable.md](lessons_stale_uncommitted_work_is_rescuable_not_untouchable.md) — 09.08: git-dirty-guard «real work present» ≠ живая сессия — mtime>1д + нет живого процесса + origin не трогал тот же путь → коммит (обратимо) безопасен, discard — нет
- [lessons_session_guard_semaphore_backlog_blocks_any_commit.md](lessons_session_guard_semaphore_backlog_blocks_any_commit.md) — 09.08: 46 стейл-семафоров (истёкшие права) в DS-my-strategy — push может упасть на СЛУЧАЙНОМ из них, не связанном с текущим коммитом; массовая чистка — кандидат РП-7, не попутный фикс
- [lessons_gitignored_artifacts_lost_on_reclone_check_reflog.md](lessons_gitignored_artifacts_lost_on_reclone_check_reflog.md) — «файл пропал из репо» → сначала `.gitignore` + `git reflog` (секунды), потом файловый поиск по диску; одинаковый mtime всего дерева = признак свежего клона (09.08, neon-migrations/tsekh-1)
- [lessons_git_checkout_shared_worktree_risk.md](lessons_git_checkout_shared_worktree_risk.md) — `git checkout -- .` в общей директории может отменить чужие незакоммиченные правки; status и discard — разными командами, не одной цепочкой (08.08)
- [lessons_sync_core_partial_rule_coverage.md](lessons_sync_core_partial_rule_coverage.md) — AGENTS.md (Kimi/Codex/Hermes) покрывает только 6 из 9 пронумерованных «Блокирующих правил» §2 CLAUDE.md — Push/Close/Чеклист-верификация/Hooks Gate/Автономность/Напоминания/Финиш>отлог физически не доходят (08.08)
- [lessons_run_card_frozen_after_force_no_reflection.md](lessons_run_card_frozen_after_force_no_reflection.md) — Quick Close карточка после `--force-no-reflection` навсегда виснет на blocked-witness-unavailable по дизайну; факт закрытия смотреть в ledger (session_closed_no_reflection), не в карточке (08.08)
- [feedback_no_repeated_ritual_prompts.md](feedback_no_repeated_ritual_prompts.md) — механические «скажи ок» поглощать самому: один пилотский слот на сессию, в сообщении с итогом; свою ошибку не превращать в просьбу к пилоту (07.08)
- [feedback_scope_full_fix_not_incremental_when_pattern_known.md](feedback_scope_full_fix_not_incremental_when_pattern_known.md) — найден системный класс бага (N похожих мест, причина одна) → чинить все N сразу, не оставлять «low priority» остаток; WP-476 07.08 стоило пилоту 4 живых попыток вместо 2
- [feedback_formal_close_never_silently_incomplete.md](feedback_formal_close_never_silently_incomplete.md) — содержание закрыто ≠ формальный ритуал закрыт (RUN-карточка/семафор до terminal) — говорить об этом в первом «готово», не ждать вопроса пилота; десятый раз одно и то же (07.08)
- [lessons_ssh_heredoc_backtick_local_expansion.md](lessons_ssh_heredoc_backtick_local_expansion.md) — markdown-бэктики в heredoc внутри `ssh host "..."` раскрываются ЛОКАЛЬНОЙ оболочкой как команды до отправки — писать во временный файл и передавать через stdin (07.08)
- [lessons_check_live_diff_before_parallel_infra_fix.md](lessons_check_live_diff_before_parallel_infra_fix.md) — сверить живой `git diff` перед правкой общего файла; контестирован файл → ждать/слить/обойти; контестирована ветка целиком → push через изолированный `git worktree` (04-09.08)
- [routing-vocab.md](routing-vocab.md) — фраза → путь, читать ПЕРЕД Write
- [feedback_response_clarity_for_pilot.md](feedback_response_clarity_for_pilot.md) — A1-A11 правила ответа
- [user_tseren_personal_life.md](user_tseren_personal_life.md) — Tseren (НЕ Дмитрий), Кипр
- Остальные уроки/hubs (73 шт., demoted 28.07+30.07+04.08+09.08) → [MEMORY-warm.md](MEMORY-warm.md)
