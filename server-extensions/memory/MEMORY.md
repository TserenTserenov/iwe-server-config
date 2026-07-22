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
| 498 | 🔄 | P2 | Наставник ИИ: оперативная помощь в чате | 20.07: Ф4 маршрутизация (единый диспетчер-промпт) + grounding (RAG по PACK-personal до генерации) решены пилотом; next: собрать в context-sufficiency gate |
| 183 | 🔄 | — | CRM как система | DROP БД directus (решение 24.07) |
| 467 | 🔄 | **P1** | Архитектура подписок через Ори | решение Д10 блокирует Ф3 |
| 151 | 🔄 | — | Характеристики и состояния деятеля | 19.07: Ф18/Ф19 триггеры проверены, оба не сработали; активных фаз нет |
| 468 | ⏳ | P3 | Инфраструктура разработки | изучить ветку python-gcp knowledge-mcp |
| 469 | 🔄 | P3 | Архитектура доступа к личным данным | ждёт WP-470 Ф4 (до 20.07) |
| 470 | 🔄 | P3 | Канал выгрузки Здоровья в iCloud | 22.07: REST-канал жив (пуш только при открытии приложения, порог сторожа 48ч), iCloud-канал мёртв с 06.07 — решение пилота: настроить выгрузку файлов или снять поток; 20.07: разведка Focus To-Do — экспорта/API нет, путь закрыт |
| 471 | 🔄 | P2 | Карта целевых аудиторий экосистемы | публикация метафоры или волна-2 (WP-437) |
| 462 | ⚠️ | P2 | Конвейер оценки качества платформы и IWE | closure противоречив, решение за пилотом |
| 454 | 🔄 | P4 | Честный числитель параллелизма | сверка на Week Close |
| 446 | 🔄 | P4 | Меню оплат «Потратить бонусы» | пилот подтверждает на семинарах |
| 417 | 🔄 | P3 | Табло пользователя | ждёт боевого рендера |
| 448 | 🔄 | P2 | Каталог паттернов процесса IWE | решение по Ф10 |
| 458 | 🔄 | **P2** | Сквозной аудит безопасности платформы и IWE | 2 архитектурных решения за пилотом |
| 442 | 🔄 | — | Личный бренд Церена | посты 26-07/27-07 ждут ready; Ф14 дневник реализована (шаг в day-close.after.md) |
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
| 5 | 🔄 | — | Платформа: развитие (зонтичный) | 22.07: фаза «Ubuntu-переносимость и упрощение скриптов шаблона» создана по внешнему аудиту (4/4 претензии подтверждены); next: П0 решение пилота (объём/порядок П1-П7, ответ пользователю). Также: живая проверка weekly-release.yml → перенос oauth_server.py в prod; MCP discovery E2E за пилотом |
| 117 | 🔄 | — | Развитие nudge-системы | 20.07: Ф-roles закрыта полностью (7/7) — правило онбордер задеплоено pilot+prod; next: Ф-adapt ждёт 4 недели рантайма |
| 149 | 🔄 | **P1** | Персональные руководства | 22.07: пир-сессия с Кими — 5 фиксов рендера задеплоены+3 живых прогона (корень: стратконтракт месяц не читался, путь current/→machine/; запрет глаголов в обеих ветках; section_floors sum==floor; SET LOCAL для Neon-табло; формат-страж после живого регресса H2); 📏 streak=2 алерт подтверждён пилотом; drift G6/Ученик закрыт тем же днём (108771e); next: 2-3 ночи наблюдения 2.4/2.5 («наблюдаем» — решение пилота), потом решение по порогу объёма (модель насыщается 1200-1400 при 1474); минорный хвост: same-day повтор 📏 |
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
| 245 | 🔄 | P5 | Программа личного развития | 21.07: занятие 5 резидентуры (20.07, мышление проговариванием) транскрибировано и разобрано — формат упражнения, уточнение роли (название объекта в контексте, не поведение), различение состояние≠метод; материал для постов уже разнесён (D-049/D-071 обогащены, D-076/D-077 новые); методичка серии ждёт правки роли за пилотом. 19.07: Блок 1 (Ф-M1…M5) + Ф-M6 метода изменения себя реализованы и верифицированы; next: пилот решает — начинать Ф-M7/M8 или продолжать Блок 3-4 |
| 364 | 🏭 | — | Фабрика руководств МИМ | Ф6b разметка wave-2 |
| 455 | 🔄 | P4 | Неизменяемость аудит-журнала событий | блокер: хост джоба (решение пилота) |
| 290 | 🔄 | **P1** | Следователь: каузальная аналитика | Ход 2 — решение стратсессии |
| 73 | 🔄 | P3 | Новая архитектура ИТ-платформы Aisystant | Ф5 proposed, дедлайн 25.07 |
| 7 | 🔄 | — | Платформа: техдолг (зонтичный) | 22.07 веч.: пир-сессия с Kimi закрыла 5 issue шаблона FMT (#293,#294,#287,#290 закрыты, #291 частично) — governance-путь + плоская доставка memory/ + ZP-клон, 4 коммита, независимая проверка чисто; ранее 22.07: WakeSystem-гонка DNS закрыта полностью (Block WAKE-DNS) — network-wait.sh (активная проба getaddrinfo) подключён к telegram.sh (5 напоминаний+дайджест), iwe-tg, панели (хост из DSN), приёмнику здоровья; sleep 20 из deps-check убран; панели 20-21.07 досчитаны (чекер 42 дня чисто); next: живая проверка завтра 08:00 (напоминание дня); 21.07: новый сбой overnight-auditor.service на цехе-1 (04:45) разобран и закрыт — НЕ рецидив вчерашнего AUD-KEY, отдельная причина: свежий Claude CLI резолвит алиас модели sonnet в claude-sonnet-5, которого нет в шлюзе auth-gateway (Invalid model name). Закреплены точные имена моделей (claude-sonnet-4-6, claude-haiku-4-5-20251001) в overnight-auditor.sh, коммит bedc198 залит и задеплоен на цех-1, подтверждено живым прогоном (прямой запуск + systemd) и независимой проверкой субагентом; блок AUD-MODEL закрыт в WP-7.md. found: TG-алерты 12factor-reaudit не долетают (нет токена/chat-id в systemd env) — не чинил, за пилотом. 20.07: жалоба участницы марафона на инверсию чекин/занятие после сброса разобрана — фаза Ф-Marathon-Reset-Order-Bug закрыта, cutoff-фикс задеплоен pilot+prod (a0432878), код-ревью+smoke 343/343 чисто; ранее 20.07 ночь: попутная находка Block AUD-KEY доделана — diagnostic-probe overnight-auditor.sh переведён на ANTHROPIC_BASE_URL, не маскирует причину сбоя больше; ранее 20.07 ночь: оставшиеся 5 issue шаблона (#269,#270,#274,#283,#284) разобраны и закрыты — cd776e3: sentinel-drift доки (dry-run-gate #237 vs SKILL.md), memory/reference/agent-core.md восстановлен из git-истории M2-слима+в манифест, priorities.yaml writer восстановлен в day-close (осиротел в PR #209), update.sh 3-way merge CLAUDE.md теперь подставляет плейсхолдеры (was: сырой upstream в base), /iwe-bug-report распознаёt --help; открытых issue в FMT 0; ранее 20.07 веч.: сбой overnight-auditor.service на цехе-1 (invalid x-api-key) разобран и закрыт — рецидив инцидента 18.07, поправлен ключ .proxy-env; фаза Block AUD-KEY закрыта в WP-7.md; ранее 20.07: deps-check reminder пофикшен (sleep 20, b16b91b9b); 7 issue шаблона (#275-282) закрыты — fbcb42e, код-ревью нашло+пофикшено 1 критическая+3 высоких; found: та же WakeSystem-гонка в remind-day-open.sh — 5 скриптов ещё уязвимы, за пилотом |
| 485 | 🔄 | P2 | Сверка дублирующихся скриптов root↔шаблон | 8 файлов Kimi Standalone (решения пилота) |
| 487 | 🔄 | P3 | Планировщик отложенного запуска РП | живой прогон через очередь |
| 472 | 🔄 | P3 | Конвейер личного бренда | 2-й человек за пилотом |
| 474 | 🔄 | P2 | Скиллы создания Pack по FPF | 20.07: Ф9 первые 2 пункта done (сверка E.11.PUA/A.22.CGUS + fpf-reference.md пополнен); next: сверка fpf-sync-check.sh (пункт 3) |
| 475 | 🔄 | P3 | Резидентность персональных данных IWE | отдельный РП или ждать |
| 476 | 🔄 | **P1** | Модель жизненного цикла данных | 19.07: Ф5/Ф6 закрыты + хвост Ф7 (R15 №6, retention 180д); осталось Ф2 (нужен пилот) + R15 №5 отложен |
| 478 | 🔄 | P3 | Терминология «развитие» | 2 пробела у Кими |
| 244 | 🔄 | P2 | Наблюдаемость платформы | Волна 1: решение из 3 вариантов |
| 481 | 🔄 | **P1** | Каталог применений FPF-семинара к IWE | 20.07: Ф16 (семинар 2) done — 20 идей, 3 кандидата на триаж пилота, распределены заметками в РП448/458/438/7; параллельно Ф9.1/Ф7/Ф13/Ф3 |
| 289 | 🔄 | P2 | Интеграция IWE с личными базами знаний | Приёмка MVP |
| 483 | 🔄 | P2 | Комплект структурирования данных (guide-kit) | 20.07: Ф5b закрыта полностью — LLM-генерация applied_note (прикладная мини-секция), независимая проверка нашла и закрыла 1 находку (нестроковый LLM-ответ ронял прогон), 316/316 тестов, guide-kit@47741c0; Ф6-Ф8 по-прежнему ждут РП495 Ф4-Ф5 |
| 488 | 🔄 | P2 | Браузерное рабочее место на Hetzner | 21.07: вход через расширение Claude Code в браузере починен (ручной код авторизации), CLI-автообновление + bypassPermissions расширения задеплоены декларативно; next: Ф2 скорость/команда |
| 484 | 🔄 | — | Автогенератор открытия/закрытия дня (зонтичный) | 22.07: все открытые хвосты 17-21.07 (диагностика причин сбоя открытия недели, Ф-Sweep-Perf) разложены в 7 явных фаз Ф8-Ф14 (производительность active-wp-sweep.sh, гонка git session-prep, streaming auth-gateway, синхронизация FMT, гипотезы в Week Close, Telegram-алерт, мелкие хвосты) — независимо проверено субагентом, реализация не начата, ждёт выбора пилота |
| 493 | 🔄 | P2 | Лаборатория характеристик | 20.07: сверка — открытых действий нет, всё закрыто (README организации iwesys подтверждено вживую). Ф4 по-прежнему ждёт данных (не раньше конца августа/сентября) |
| 494 | 🔄 | P2 | Панель рабочих продуктов в VS Code | ручная F5-приёмка пилотом |
| 495 | 🔄 | **P1** | Концепция персонального развития | 20.07: Ф9 черновик карты навигации DP.M.241 написан как предложение (не владелец Pack, ждёт решения владельца метода — РП149); Ф7 прогон идёт (5-8 человек, критерий день1 vs день7-10), блокер прогона — качество генерации в РП149 |
| 496 | 🔄 | P3 | Журнал гипотез (LPF-регламент обратной связи) | 21.07: инвентаризация 281 гипотезы + первая сверка 95 (45 явных вердиктов, 50 спорных); журнал разделён на «Основные» (4, пилот сам) vs «Актуальные» (агент, Week Close); контекст в РП484 |
| 167 | 🔄 | P5 | Публикации (зонтичный) | 20.07 веч.: порядок публикации 28 постов выстроен по 4 направлениям (артефакт), 4 слабых черновика удалены; пилот утверждает порядок, публикатор стартует с Ф-А3 |
| 497 | 🔄 | P5 | Материалы исследования AGI | план пересобран на 8 течений (АрхГейт); Ф1 ready, Ф9 контент готов (публикация правки на клубе — ручной шаг за пилотом) |

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

- [lessons_claude_permissions_cli_vs_vscode_extension.md](lessons_claude_permissions_cli_vs_vscode_extension.md) — bypassPermissions CLI ≠ claudeCode.* расширения VS Code, два независимых уровня
- [lessons_nixos_rebuild_from_mac_needs_nix_run.md](lessons_nixos_rebuild_from_mac_needs_nix_run.md) — nixos-rebuild нет на Маке — `nix run nixpkgs#nixos-rebuild`, проверять лог, не только exit-код `| tail`
- [lessons_systemd_environmentfile_unset_and_sops_nested_key.md](lessons_systemd_environmentfile_unset_and_sops_nested_key.md) — UnsetEnvironment вместо Environment="" для systemd; sops-секрет требует вложенный YAML-ключ
- [lessons_gate_marker_granularity_mismatch.md](lessons_gate_marker_granularity_mismatch.md) — giving-up маркер должен писаться в тот же state-файл, что проверяет входной гейт цикла
- [feedback_askuserquestion_not_reaching_pilot.md](feedback_askuserquestion_not_reaching_pilot.md) — choice-question — дублировать в чат
- [feedback_s33_scope_already_answered.md](feedback_s33_scope_already_answered.md) — scope S-33 уже разграничен пилотом в сессии → констатировать, не переспрашивать
- [routing-vocab.md](routing-vocab.md) — фраза → путь, читать ПЕРЕД Write
- [feedback_response_clarity_for_pilot.md](feedback_response_clarity_for_pilot.md) — A1-A11 правила ответа
- [feedback_explicit_approval_covers_hook_false_positive.md](feedback_explicit_approval_covers_hook_false_positive.md) — одобренная команда → ложняк хука не требует переспроса
- [feedback_post_draft_dedup_before_new.md](feedback_post_draft_dedup_before_new.md) — новый материал для постов → сначала обогатить черновик, новый только если нет подходящего
- [lessons_zsh_read_secret_releak.md](lessons_zsh_read_secret_releak.md) — секрет-гейт B7.7c блокирует по пути в команде; Write+Bash-по-скрипту как легитимный обход
- [reference_no_invented_facts_hub.md](reference_no_invented_facts_hub.md) — не выдумывать опыт/имена
- [user_tseren_personal_life.md](user_tseren_personal_life.md) — Tseren (НЕ Дмитрий), Кипр
- [reference_day_protocol_gaps_hub.md](reference_day_protocol_gaps_hub.md) — Day Open/Close квирки (7)
- [reference_wp_gate_mechanics_hub.md](reference_wp_gate_mechanics_hub.md) — task_id, дочерний РП, имя через Артефактор (6)
- [reference_llm_bot_output_quirks_hub.md](reference_llm_bot_output_quirks_hub.md) — TG markdown/HTML квирки (6)
- [reference_diagnosis_technique_hub.md](reference_diagnosis_technique_hub.md) — root-cause, verify-before-trust (37)
- [reference_git_hygiene_hub.md](reference_git_hygiene_hub.md) — git-add scope, pathspec, rebase/reset квирки (29)
- [lessons_verify_branch_before_commit_pilot_first.md](lessons_verify_branch_before_commit_pilot_first.md) — Pilot-First репо: проверить ветку ДО commit, не только перед push
- [reference_agent_session_mechanics_hub.md](reference_agent_session_mechanics_hub.md) — рецидив 3× kimi-peer-adapter (11)
- [reference_macos_zsh_env_quirks_hub.md](reference_macos_zsh_env_quirks_hub.md) — квирки macOS/zsh/grep/git (12)
- [lessons_ontological_not_lexical_generation.md](lessons_ontological_not_lexical_generation.md) — Pack/руководства — «онтологически, не лексически»
- [reference_tsekh1_backup_infra_hub.md](reference_tsekh1_backup_infra_hub.md) — SSH-зависания, restic/B2 cap (2)
- [reference_railway_deploy_quirks_hub.md](reference_railway_deploy_quirks_hub.md) — секреты в чат, railpack (2)
- [reference_fmt_process_practices_hub.md](reference_fmt_process_practices_hub.md) — /skill-creator, issue-close, sync≠version-cut (3)
- [reference_process_runner_quirks_hub.md](reference_process_runner_quirks_hub.md) — креды в карточке, race с активной сессией, umbrella-архивация (3)
- [reference_secrets_credentials_hub.md](reference_secrets_credentials_hub.md) — .mcp.json wrapper, ротация-верификация, 403≠401 (3)
- [lessons_shared_registry_axis_needs_ownership_check.md](lessons_shared_registry_axis_needs_ownership_check.md) — новая ось в платформенном реестре: сначала «чья это ось», потом «дробить или нет»
- [lessons_ci_diff_base_empty_tree_fallback.md](lessons_ci_diff_base_empty_tree_fallback.md) — diff-гейт в CI: fallback на empty-tree hash, не HEAD~1; тестировать гейт против его же policy-текста
- [lessons_manual_commit_bypasses_runner_merges_with_parallel_agent.md](lessons_manual_commit_bypasses_runner_merges_with_parallel_agent.md) — обход раннера git commit -- path может слить правку с параллельным чужим коммитом
- [lessons_mock_accepts_any_argv_misses_cli_regressions.md](lessons_mock_accepts_any_argv_misses_cli_regressions.md) — мок subprocess.run, принимающий любые argv, не ловит регрессию несуществующего CLI-флага — нужен ассерт на реальную команду или живой прогон
- [lessons_checklist_done_artifact_missing_from_disk.md](lessons_checklist_done_artifact_missing_from_disk.md) — чек-лист «закрыто» ≠ файл реально на диске — `ls`/`find` перед тем как проектировать код поверх артефакта
- [lessons_git_cherry_patch_id_not_content.md](lessons_git_cherry_patch_id_not_content.md) — git cherry сравнивает по patch-id, не по содержимому — большой список разрыва может быть шумом
- [lessons_stale_checkbox_after_parallel_phase_closed_it.md](lessons_stale_checkbox_after_parallel_phase_closed_it.md) — открытый чек-бокс needs-decision может быть уже исполнен соседней фазой того же дня — сверять факт (`gh repo view`/`ls`), не только маркер
- [lessons_llm_probe_http000_diagnose_edge_not_app.md](lessons_llm_probe_http000_diagnose_edge_not_app.md) — LLM probe HTTP 000 через Railway-прокси: пустые deploy-логи в окне сбоя = обрыв на edge/сети, не в коде прокси
- [lessons_session_guard_housekeeping_reason_path_injection.md](lessons_session_guard_housekeeping_reason_path_injection.md) — housekeeping-reason с пробелами/двоеточием ломает session-guard.sh; note-file падает при нескольких открытых семафорах; close ДО commit стирает scope
- [lessons_active_wp_sweep_scale_hang.md](lessons_active_wp_sweep_scale_hang.md) — active-wp-sweep.sh O(РП×репо) без параллелизма/кэша зависает при росте базы (118+×67)
