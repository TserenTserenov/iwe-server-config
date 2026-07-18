# Оперативная память

> **Инструкции:** `~/IWE/CLAUDE.md` | **Навигация:** `memory/navigation.md` | **Source-of-truth:** `DP.EXOCORTEX.001`
> **Слои:** L1 = платформа. L2 = staging. L3 = авторское.

## БЛОКИРУЮЩИЕ (проверяй ВСЕГДА)

1. **WP Gate:** ⛔ Первое действие на ЛЮБОЕ задание = `Read memory/protocol-open.md`. Без исключений.
2. **Close:** ⛔ «закрывай» / «всё» = `Вызвать Skill: run-protocol, аргумент: close`. Без исключений.
3. **ArchGate ≥8:** Архитектурное → СНАЧАЛА ЭМОГССБ → ПОТОМ решение.
4. **Repo-Touch Gate:** Первое действие в любом репо → прочитать `<repo>/CLAUDE.md`. Блок «ОБЯЗАТЕЛЬНО ЗАГРУЖАЙ» — загрузить ДО ответа.
5. **Routing Gate:** Перед Write нового файла → `memory/routing-vocab.md`. Miss → эскалация в `memory/repo-type-rules.md`. Аналогия запрещена. SC: DP.SC.036.

## ВАЖНЫЕ (на рубежах)

6. **Capture:** На рубеже → «Capture: X → Y»
7. **Процессы:** Без PROCESSES.md не реализовывать
8. **Гигиена inbox:** Close архивирует done-WP сразу. Session-Prep — широкая очистка.
9. **Модели:** Opus=open-loop. Sonnet=closed-loop. Haiku=trivial. Делегирование только вниз.
10. **Шапки индексов = индекс, не changelog.** → [feedback_memory_index_discipline.md](feedback_memory_index_discipline.md)
11. **Стратсессия → sessions/:** файл ДО commit+push (Claude и Kimi). → [feedback_sessions_missing.md](feedback_sessions_missing.md)
12. **Финиш > отлог.** Доп. задача → дефолт «делаю сейчас». → [feedback_finish_now_no_defer.md](feedback_finish_now_no_defer.md)
13. **Content cleanup backlog.** Содержательный вопрос → `current/content-cleanup-backlog.md`. Зонтик: WP-376.

---

## Текущая работа

> Источник: WeekPlan W{N} + WP-REGISTRY.md. Контекст каждого РП: `DS-my-strategy/inbox/WP-{N}/WP-{N}.md` (не повторяется ниже).
> **W29 (13-19.07):** ТОС — запуск персонального руководства. Пул: 149,289,417,406+476,469+401,415+481,482,483. План: `current/WeekPlan W29 2026-07-13.md`.
> **РП484 (зонтичный):** Ф1-Ф2 done; 17.07 вечер — server-primary git-lock для Day Close реализован и задеплоен (пир-сессия+2 раунда ревью+8 тестов). Ф3 ждёт первого боевого срабатывания 23:00 МСК. Контекст: `inbox/WP-484/WP-484.md`.

| WP | ст | P | Название | next (≤10 слов) |
|-----|----|----|----------|----------------|
| 183 | 🔄 | — | CRM как система | cron/Card 42 закрыты 17.07; next: DROP старой БД directus (решение 24.07) |
| 467 | 🔄 | **P1** | Архитектура подписок через Ори | решение Д10 блокирует Ф3 |
| 151 | 🔄 | — | Характеристики и состояния деятеля | ревью принято; Ф7б выделена в РП493 |
| 468 | ⏳ | P3 | Инфраструктура разработки | изучить ветку python-gcp knowledge-mcp |
| 469 | 🔄 | P3 | Архитектура доступа к личным данным | Ф1 закрыта (таксономия отказов, auth 2 слоя, логирование); ждёт WP-470 Ф4 (до 20.07) |
| 470 | 🔄 | P3 | Канал выгрузки данных Здоровья в iCloud Drive | Ф4 решение пилота: виджет |
| 471 | 🔄 | P2 | Карта целевых аудиторий экосистемы | Ф6 done 17.07 (автономный прогон): скелеты гипотез L/M/N1/N2 + реестр статусов сегментов; next: публикация валидации метафоры или волна-2 (WP-437) |
| 462 | ⚠️ | P2 | Конвейер оценки качества платформы и IWE | closure противоречив; решение за пилотом |
| 454 | 🔄 | P4 | Честный числитель параллелизма — одиночные сессии | 2 дня пересчитаны; сверка на Week Close |
| 446 | 🔄 | P4 | Меню оплат «Потратить бонусы» | пилот подтверждает на семинарах |
| 417 | 🔄 | P3 | Табло пользователя | тайлы в panel/{date}.md готовы; ждёт боевого рендера |
| 448 | 🔄 | P2 | Каталог паттернов процесса IWE | Ф9 done; next: решение по Ф10 |
| 458 | 🔄 | **P2** | Сквозной аудит безопасности платформы и IWE | Волна 4 закрыта на 7/9 (17.07); осталось 2 архитектурных (I8/ВЫ-9, ВЫ-8) — за пилотом; +ВЫ-13 (GitHub OAuth широкий scope) найдена и передана в WP-406 Ф22; +ВЫ-14 (ключ Grafana открытым текстом в `.mcp.json`) найдена и исправлена 18.07 — ротация ключа за пилотом |
| 442 | 🔄 | — | Личный бренд Церена | канон миссии принят 16.07; посты 26-07/27-07 draft ждут ready пилота |
| 418 | 🔄 | — | Доставщик | канарейка смержена (прод+пилот); next Ф5.1 когорта |
| 482 | 🔄 | P2 | Конвейер процессов IWE с типизированными шагами (рефлекс/ИИ/пилот) | Ф5 done (week/month-close.yaml, 2 бага починены проверкой); баги commit-push.sh (РП493) и session-index.sh (вставка не в начало таблицы, 17.07) починены; next: живой week-close 19-20.07 |
| 427 | 🔄 | — | Учёт следов Ф6.3 | задеплоено в прод; next: живая приёмка |
| 262 | 🔄 | — | Интерфейсы платформы — тонкие клиенты ядра (зонтичный) | В1: вынос engines/* из бота (strangler) |
| 330 | 🔄 | **P1** | Марафон вторая волна | 15.07 пропущена; 3 решения → 18.07 |
| 437 | 🔄 | **P1** | Вторая волна когорты дизайн | Ф2 запуск, параллель WP-330 |
| 251 | 🔄 | — | Системы службы продвижения | Ф2/Ф4-домашка done; next: Ф4 живая сессия с Алёной (блокер) |
| 250 | 🔄 | — | План развития до конца 2026 (зонтичный координатор) | актуализирован 17.07, месячный синтез выдан; очередь решений ~20-25; next: Week Close (WIP-фильтр+калибровка) |
| 399 | ⏳ | P1 | Ротация секретов экосистемы | Ф1 п.1 done (аудит-скрипт+баг починен); батч просрочен — ротация за пилотом |
| 429 | 🔄 | — | Детектор непротиворечивости базы | Ф6 дизайн done (пир+Кими); next: АрхГейт по Ф6.1+Ф6.2 |
| 5 | 🔄 | — | Платформа: развитие (зонтичный) | 18.07: «Быстрый фикс бота /setup» закрыт пир-сессией с Kimi — тир из встроенной проверки, задеплоено в pilot (84240b2) → прод (1143672, cherry-pick); попутно найден и оставлен нетронутым чужой незапушенный коммит РП117 на прод-ветке; хук предупредил про разрыв prod↔pilot (13 патчей); next: e2e-чек, env-риск USER_PROFILE_SERVICE_URL, напоминание 18.07 08:00 проверить прогон |
| 117 | 🔄 | — | Развитие nudge-системы | 18.07: залит зависший коммит registry wiring — обнаружился разрыв Pilot-First (реестр не доезжал до pilot), закрыт cherry-pick'ом на обе ветки, смок зелёный; next: AI-тексты для derived-типов или NudgeProducer |
| 149 | 🔄 | **P1** | Система генерации персональных руководств | 17.07: ФК5+ФК22 (Верификатор+провенанс данных) реализованы и задеплоены (пир-сессия с Кими, commit 617cc60) — 2 находки вынесены пилоту (mastery_by_area структурно недоступен; derived_snapshot.json не читается конвейером); ФК3 (модель Sonnet) оказалась уже done с 10.07, запись очереди была stale (пилот заметил); Ф-learning-history-bkt всё ещё ждёт АрхГейт; next: ФК12 |
| 438 | 🔄 | — | Агентный режим Гермеса | перенос после WP-149 |
| 170 | 🔄 | P1 | База знаний: обновление по разбору информации | очередь 13-16.07 записана (56 accept); next: 12 старых хвостов |
| 415 | 🔄 | P2 | Конвейер орг-GitHub | гейт кириллицы на публикации задеплоен+ревью; next: Конвейер 1 |
| 285 | 🔄 | — | Международная инфраструктура Track B | тесты-спецификации у Андрея |
| 401 | 🔄 | **P1** | Разделение GitHub-организаций | биллинг остановил конвейер; next: Ф6.1 manifest.sh |
| 406 | 🔄 | **P1** | Онбордер | next: приёмка Ф20 в Telegram (за пилотом); +Ф22 добавлена (сузить доступ GitHub заметок/Публикатора до выбранных репо, ArchGate пройден, реализация не начата) |
| 456 | 🔄 | P3 | Онбордер англоязычной IWE (браузер) | EN-приёмка ожидает пилота |
| 405 | 🔄 | — | Англоязычная платформа IWE | Ф4 Language Policy FMT |
| 452 | 🔄 | P3 | Гайд разработчика IWE | Ф2 стиль кода |
| 453 | 🔄 | P4 | Конвейер обновления руководства IWE | ждёт WP-452 Ф2-Ф3 |
| 349 | 🔄 | — | Онбординг на MCP | Ф31 тексты, 3-4ч |
| 245 | 🔄 | P5 | Программа личного развития | занятие 4 опубликовано; next: разбор |
| 364 | 🏭 | — | Фабрика руководств МИМ | Ф6b разметка wave-2 |
| 455 | 🔄 | P4 | Неизменяемость аудит-журнала событий | Ф10.1-Ф10.3 закрыты; Ф11 технически готова, блокер — решение пилота по хосту джоба (systemd-timer tsekh-1 vs launchd ноутбук) |
| 290 | 🔄 | **P1** | Следователь: система каузальной аналитики развития | Ход 3 подтверждён (прод-прогон rival_factors 13.07); Ход 2 — решение стратсессии |
| 73 | 🔄 | P3 | Новая архитектура и план развития ИТ-платформы Aisystant | 18.07: все 5 needs-decision закрыты (Ф4→РП5; ADR routing-gate 0.OPS задеплоен, branch protection несовместима с push-workflow — откачена; Ф5 proposed отправлен Андрею+Ильшату, дедлайн 25.07; #4/#5 placement исполнены — DP.D.253, WP-73 index-артефакт) |
| 7 | 🔄 | — | Платформа: техдолг (зонтичный) | 18.07: аудит трат Anthropic продолжен — ДЗ-чекер+сборщик руководств на OpenRouter, ротация PROXY_SHARED_SECRET (zero-downtime, auth-gateway), найден и закрыт живой инцидент прод-бота (~9ч без модели, два несинхронизированных Railway-сервиса); next: iwe-llm-proxy сервис (нет LITELLM_INTERNAL_KEY), overnight-auditor CLI-резолвер, render-pilot-guides.py |
| 485 | 🔄 | P2 | Сверка дублирующихся скриптов root↔шаблон | 17.07 поздний вечер: паразитный каталог DS-strategy — причина устранена (kimi-wp-run-scheduled.sh + extractor.sh резолвят репо через bootstrap, пилот дописал .exocortex.env), живое подтверждение прошло; next: 8 файлов кластера Kimi Standalone + WP-295 (решения пилота) |
| 486 | 🔄 | P3 | Роль и автозапуск процесса резервного копирования | Ф1-Ф2 закрыты; next: Ф3 systemd-таймер |
| 487 | 🔄 | P3 | Планировщик отложенного запуска РП | Ф1-Ф3 готовы; next: живой прогон через очередь |
| 472 | 🔄 | P3 | Конвейер личного бренда | шаблон опубликован (личный акк); 2-й человек за пилотом |
| 474 | 🔄 | P2 | Скиллы создания Pack по FPF | Ф8.6a done; next: Ф8.6b/Ф9/Ф10 автономны |
| 475 | 🔄 | P3 | Резидентность персональных данных IWE | Ф4 done; next: отдельный РП или ждать |
| 476 | 🔄 | **P1** | Модель жизненного цикла данных (конвейеры 2.1-2.4) | Ф7 заведена 17.07 вечер (3 расхождения: память/Lifework/транскрипты, план готов к промоции в шаблон); next: реализация Ф7, порядок пилот не выбрал |
| 478 | 🔄 | P3 | Терминология «развитие» в сообщениях IWE и бота | Ф3-Ф5 done; 2 пробела у Кими |
| 244 | 🔄 | P2 | Наблюдаемость платформы | целевое v4 принято; Волна 1 ждёт решения пилота из 3 вариантов (TG-алерты / +BetterStack free / +BetterStack paid+webhooks) — BS-аккаунт уже работает, узкая формулировка вводила в заблуждение 16.07 |
| 481 | 🔄 | **P1** | Каталог применений FPF-семинара к IWE | Ф5.1 закрыла 3 бага; next: Ф9.1/Ф7/Ф13/Ф3 |
| 289 | 🔄 | P2 | Интеграция IWE с личными базами знаний | боевой прогон Ф4 РП483 закрыт 17.07 (комплект доставлен в шаблон); связка с РП495 проставлена (related+таблица); next: Приёмка MVP |
| 483 | 🔄 | P2 | Комплект структурирования данных и руководств (guide-kit) | 18.07: Ф11 закрыта полностью — карта ролей + матрица по сценариям (`CONCEPT §13`), баг merge-приоритета в Ф5 пофикшен, поле степени квалификации добавлено (`guide-kit@61c8aa4`), документ прозрачности `HOW-IT-WORKS.md`; пилот поправил спутанные ступень/степень — различение `DP.D.252` заведено в Pack; next: решение пилота — тег релиза + `guide-kit-sync.sh` в шаблон, затем Ф6-Ф10 (прикладные темы/Исследователь-Просветитель/живой канал знаний/данные Здоровья) |
| 488 | 🔄 | P2 | Браузерное рабочее место разработчика на Hetzner | Ф1 принят; next: Ф2 скорость |
| 484 | 🔄 | — | Автогенератор открытия/закрытия дня/недели/месяца | 18.07: окно открытия дня на сервере сдвинуто на 4:30 (сужено до 6:59 по вопросу пилота); найден и обойдён новый баг — гейт закрытия дня доверяет отставшей локальной git-истории (грязная копия сервера, 50+ файлов, блокирует pull), план на 18.07 закрыт вручную в изолированном клоне (чек-лист 21/21 после дофикса РП470-раздела); открытие дня отдельно переключено на типовой раннер (другая сессия, первое боевое срабатывание завтра 09:15); next: срочно расчистить грязную копию сервера до 23:00 МСК — иначе повторно сорвётся боевая проверка git-lock закрытия дня |
| 493 | 🔄 | P2 | Лаборатория характеристик | 18.07: Ф6 дизайн когорты 3+ закрыта (пир-сессия claude-code/kimi, протокол — `cohort-protocol.md`); next: Ф7 оценка бюджета (характеристики прикладного мастерства) |
| 494 | 🔄 | P2 | Панель рабочих продуктов в VS Code | 17.07: Ф1-Ф5 реализованы (пир-сессия с Кими, 3 раунда review), GitHub-репо создан+запушен; осталась ручная F5-приёмка тайлов пилотом |
| 495 | 🔄 | **P1** | Концепция персонального развития как системной деятельности | 18.07: Ф1-Ф3 закрыты (стадии/словарь/DR-01, карта отстройки, модель руководства); Дополнение №6 из редакции поста (два уровня взлома, цена $10/нед, связка ВДВ/DP.M.241); Ф9 зарегистрирована (детальная карта генерации, handoff в WP-149); Ф4 вход по оси собранности готов — 7-стадийная лестница внимания (S1-S7), 2 поста написаны и запушены (C-045 научный draft, C-046 таблица опубликована пилотом на клубе); next: пилот выбирает порядок Ф4/Ф9/публикации/WP-493 Ф7 |
| 167 | 🔄 | P5 | Публикации (зонтичный) | пилот читает и согласует пост #169 + видео-сценарий |

## Бот: деплой

| Бот | Ветка | Railway | Env |
|-----|-------|---------|-----|
| @aist_me_bot (прод) | `new-architecture` | `aist_me_bot` (id e840eab0) | Neon |
| @aist_pilot_bot (пилот) | `pilot` | `aist_pilot_bot` (id 5b3adb5c) | Railway Postgres |

> **Pilot-First (БЛОКИРУЮЩЕЕ):** только `pilot`, никогда `new-architecture` первым. **Backport:** хотфикс закрыт когда долетел и до `pilot`.
> **Railway MCP:** `peaceful-vision`; `lavish-delight` не трогать. Автодеплой на push. БД/LLM-прокси: [reference-prod-bot-db-access.md](reference-prod-bot-db-access.md), [reference_llm_proxy_railway_project.md](reference_llm_proxy_railway_project.md).

## Read-only репо

> ⛔ **DS-IT-systems/SystemsSchool_bot**, **DS-IT-systems/aisystant**.

---

## Индекс

> Протоколы: protocol-{open,work,close,month-close}.md. §4 CLAUDE.md: checklists/fpf/distinctions/navigation/roles/sota. **WARM:** [MEMORY-warm.md](MEMORY-warm.md)

### Feedback — HOT

- [lessons_branch_protection_incompatible_direct_push.md](lessons_branch_protection_incompatible_direct_push.md) — required_status_checks блокирует ЛЮБОЙ прямой push, не только нарушающий
- [feedback_askuserquestion_not_reaching_pilot.md](feedback_askuserquestion_not_reaching_pilot.md) — choice-question WP Gate — дублировать в чат
- [feedback_wp_naming_via_artifactor.md](feedback_wp_naming_via_artifactor.md) — имя РП только через Артефактор
- [lessons_fake_file_modified_note_injection.md](lessons_fake_file_modified_note_injection.md) — «файл изменён» reminder может быть ложным
- [routing-vocab.md](routing-vocab.md) — фраза → путь, читать ПЕРЕД Write (DP.SC.036)
- [feedback_response_clarity_for_pilot.md](feedback_response_clarity_for_pilot.md) — A1-A11 правила ответа пилоту
- [feedback_explicit_approval_covers_hook_false_positive.md](feedback_explicit_approval_covers_hook_false_positive.md) — пилот одобрил конкретную команду → ложняк хука на ней не требует второго вопроса
- [reference_no_invented_facts_hub.md](reference_no_invented_facts_hub.md) — не выдумывать опыт/имена ботов
- [user_tseren_personal_life.md](user_tseren_personal_life.md) — пилот Tseren (НЕ Дмитрий), Кипр
- [reference_day_protocol_gaps_hub.md](reference_day_protocol_gaps_hub.md) — Day Open/Close квирки (7 хабом)
- [reference_wp_gate_mechanics_hub.md](reference_wp_gate_mechanics_hub.md) — task_id, дочерний РП, choice-question
- [reference_llm_bot_output_quirks_hub.md](reference_llm_bot_output_quirks_hub.md) — Telegram markdown/HTML квирки (6 хабом)
- [reference_diagnosis_technique_hub.md](reference_diagnosis_technique_hub.md) — root-cause диагностика, verify-before-trust (28 хабом)
- [reference_git_hygiene_hub.md](reference_git_hygiene_hub.md) — git-add scope, pathspec (22 хабом)
- [reference_agent_session_mechanics_hub.md](reference_agent_session_mechanics_hub.md) — **рецидив 3×** kimi-peer-adapter; Kimi-вызов, peer-фазы (11 хабом)
- [reference_macos_zsh_env_quirks_hub.md](reference_macos_zsh_env_quirks_hub.md) — квирки macOS/zsh/grep/git (12 хабом)
- [lessons_stale_rebase_merge_recovery.md](lessons_stale_rebase_merge_recovery.md) — брошенный rebase-merge чужой сессии — как расчистить
- [lessons_rebase_autostash_silent_on_plain_pull.md](lessons_rebase_autostash_silent_on_plain_pull.md) — `rebase.autostash=true` — обычный `git pull --rebase` тоже тихо стеширует
- [lessons_migration_parity_real_profile_insufficient.md](lessons_migration_parity_real_profile_insufficient.md) — **3 случая:** реальные данные не кроют крайние случаи, зелёные тесты не кроют реальность, «код готов» не значит «прогнан на реальных данных»
- [lessons_ontological_not_lexical_generation.md](lessons_ontological_not_lexical_generation.md) — генерация Pack/руководств: «онтологически, не лексически»
- [reference_tsekh1_backup_infra_hub.md](reference_tsekh1_backup_infra_hub.md) — SSH-зависания, гранты, restic/B2 cap (2 хабом)
- [reference_railway_deploy_quirks_hub.md](reference_railway_deploy_quirks_hub.md) — секреты в чат, railpack перебивает конфиг (2 хабом)
- [reference_fmt_process_practices_hub.md](reference_fmt_process_practices_hub.md) — скиллы через /skill-creator, issue-close этикет (2 хабом)
- [lessons_hot_diff_guard_line_level_false_positive.md](lessons_hot_diff_guard_line_level_false_positive.md) — Ф5-страж сравнивает строки целиком — точечный фикс пути = ложный «gone»
- [lessons_same_name_script_different_repo_different_function.md](lessons_same_name_script_different_repo_different_function.md) — файл существует по пути ≠ это нужная функция; тот же класс на уровне клона-омонима (WP-485, 17.07)
- [lessons_wp_sync_bundle_body_match_not_frontmatter.md](lessons_wp_sync_bundle_body_match_not_frontmatter.md) — wp-sync-bundle.sh матчит по body, не по `related:` — сверять вручную (2× повтор)
- [lessons_process_runner_handler_credential_masking.md](lessons_process_runner_handler_credential_masking.md) — **рецидив 2×:** reflex-хендлер, кладущий stdout в карточку, — маскировать креды сразу
- [lessons_day_close_dispatcher_races_active_session.md](lessons_day_close_dispatcher_races_active_session.md) — day-close диспетчер счёл активную peer-сессию брошенной, сам выполнил pilot-choice мимо gate (WP-483, 17.07)
- [lessons_mcp_json_tracked_secret_wrapper_pattern.md](lessons_mcp_json_tracked_secret_wrapper_pattern.md) — `.mcp.json` закоммичен в git — новый MCP-сервер только через wrapper-скрипт, не inline-секрет (18.07)
- [lessons_secret_rotation_verify_every_consumer_live.md](lessons_secret_rotation_verify_every_consumer_live.md) — ротация секрета: сверять КАЖДОГО потребителя живым тестом, похожие имена сервисов ≠ один сервис (прод-инцидент 9ч, 18.07)
- [lessons_isolated_run_missing_symlink_false_positive.md](lessons_isolated_run_missing_symlink_false_positive.md) — изолированный клон для обхода git-гонки: забытая директория (extensions/) → ложноположительный чек-лист «0 проверок, ок» (WP-484, 18.07)
- [lessons_verify_pack_principle_before_code_change.md](lessons_verify_pack_principle_before_code_change.md) — фраза Pack-принципа применена буквально без сверки с первоисточником целиком → неверный code-фикс, пир-напарник усилил ошибку вместо проверки (WP-483, 18.07)
- [lessons_dirty_far_behind_clone_is_stale_mirror.md](lessons_dirty_far_behind_clone_is_stale_mirror.md) — грязный сильно-отставший клон = устаревшее зеркало, а не потерянная работа; сверять blob-хешами против origin, лечить сбросом, не коммитом (WP-484, 18.07)
