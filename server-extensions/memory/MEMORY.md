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

> Источник: WeekPlan W{N} + WP-REGISTRY.md. Полный контекст каждого РП только в `DS-my-strategy/inbox/WP-{N}/WP-{N}.md` — эта таблица только пойнтер (≤10 слов на `next`), детали сюда не дублировать. Текущий план недели: `current/WeekPlan W31*.md`.

| WP | ст | P | Название | next (≤10 слов) |
|-----|----|----|----------|----------------|
| 500 | 🔄 | P2 | Аудит IWE: безопасность, токены, SOTA — разбор находок | Ф1-Ф21 не начат — начать с Ф1 |
| 503 | 🔄 | P1 | Умный конвейер РП | голод портфеля структурный; `wp-pool-phase-scan.sh` при честной фазе |
| 502 | 🔄 | P2 | Актуализация и продвижение портфеля РП | next приёмка наставника + доступ к мониторингу (детали → WP-502.md) |
| 498 | 🔄 | P2 | Наставник ИИ: оперативная помощь в чате | собрать Ф4 (маршрутизация + grounding) в context-sufficiency gate |
| 183 | 🔄 | — | CRM как система | DROP БД directus (решение 24.07) |
| 467 | 🔄 | **P1** | Архитектура подписок через Ори | решение Д10 блокирует Ф3 |
| 151 | 🔄 | — | Характеристики и состояния деятеля | ждать триггеров Ф18/Ф19 |
| 468 | ⏳ | P3 | Инфраструктура разработки | изучить ветку python-gcp knowledge-mcp |
| 469 | 🔄 | P3 | Архитектура доступа к личным данным | наблюдение завершено 22.07 — начать разбор |
| 470 | 🔄 | P3 | Канал выгрузки Здоровья в iCloud | 03.08: таймер+WeekReport+MonthClose починены; персруковод. → WP-149; Ф5/Ф6 открыты |
| 471 | 🔄 | P2 | Карта целевых аудиторий экосистемы | публикация метафоры или волна-2 (WP-437) |
| 462 | ⚠️ | P2 | Конвейер оценки качества платформы и IWE | closure противоречив, решение за пилотом |
| 454 | 🔄 | P4 | Честный числитель параллелизма | сверка на Week Close |
| 446 | 🔄 | P4 | Меню оплат «Потратить бонусы» | пилот подтверждает на семинарах |
| 417 | 🔄 | P3 | Табло пользователя | Ф-parallelism-1 (схема+B7.3) |
| 448 | 🔄 | P2 | Каталог паттернов процесса IWE | суб-батч 6б done (24+12=36); решение accept/reject по DP.M.217 |
| 458 | 🔄 | **P2** | Сквозной аудит безопасности платформы и IWE | Ф5 план КР-1/КР-2 согласован; решение пилота: порядок+АрхГейт |
| 442 | 🔄 | — | Личный бренд Церена | посты 26-07/27-07 ждут ready |
| 418 | 🔄 | — | Доставщик | Ф5.1 когорта |
| 482 | 🔄 | P2 | Конвейер процессов IWE (рефлекс/ИИ/пилот) | живая проверка гейта + Ф3/Ф4/Ф5 наблюдение |
| 427 | 🔄 | — | Учёт следов Ф6.3 | живая приёмка |
| 262 | 🔄 | — | Интерфейсы платформы (зонтичный) | ждёт приёмки пилотом (/train) → next feed |
| 330 | 🔄 | **P1** | Марафон вторая волна | 3 решения пилота не донесены; вопрос Lifework повторился |
| 437 | 🔄 | **P1** | Вторая волна когорты дизайн | Ф2 запуск, параллель WP-330 |
| 251 | 🔄 | — | Системы службы продвижения | уточнить явное «да» по финансированию |
| 250 | 🔄 | — | План развития до конца 2026 (зонтичный) | R1-R6 августа утверждены → Strategy.md § август |
| 399 | ⏳ | P1 | Ротация секретов экосистемы | батч просрочен, ротация за пилотом |
| 509 | 🔄 | P2 | Пир-сессии 3+ агентов: роль-дискавери и общий рабочий продукт | S-51 закрыта 3/3; промоция на Week Close |
| 510 | 🔄 | P3→P1 | ИИ-личности | 04.08: фазы актуализированы по 8 вопросам (Ф12, очерёдность, консенсус с Codex); next: Ф5-схема + dry-run Гари; 2 вопроса пилоту (№3/№4 шапки); цех-1 cherry-pick ждёт |
| 5 | 🔄 | — | Платформа: развитие (зонтичный) | детали `inbox/WP-5/WP-5.md` |
| 117 | 🔄 | — | Развитие nudge-системы | Ф-adapt ждёт 4 недели рантайма |
| 149 | 🔄 | **P1** | Персональные руководства | 2.3/1.9 починены и залиты; ждём ночного подтверждения |
| 438 | 🔄 | — | Агентный режим Гермеса | перенос после WP-149 |
| 170 | 🔄 | P1 | База знаний: обновление | партия #1-225 закрыта 03.08 полностью; ongoing, ждёт триаж-отчёта |
| 415 | 🔄 | P2 | Конвейер орг-GitHub | Конвейер 1 |
| 285 | 🔄 | — | Международная инфраструктура Track B | тесты-спецификации у Андрея |
| 401 | 🔄 | **P1** | Разделение GitHub-организаций | Ф6.1 manifest.sh |
| 406 | 🔄 | **P1** | Онбордер | блокирован: 3 пакета решений пилота (Ф20/Ф22/Ф24), 0 движения 03.08 |
| 456 | 🔄 | P3 | Онбордер англоязычной IWE (браузер) | EN-приёмка ожидает пилота |
| 405 | 🔄 | — | Англоязычная платформа IWE | Ф4 Language Policy FMT |
| 452 | 🔄 | P3 | Гайд разработчика IWE | Ф2 стиль кода |
| 453 | 🔄 | P4 | Конвейер обновления руководства IWE | ждёт WP-452 Ф2-Ф3 |
| 349 | 🔄 | — | Онбординг на MCP | Ф31 тексты, 3-4ч |
| 245 | 🔄 | P5 | Программа личного развития | пилот: правка роли в методичке |
| 364 | 🏭 | — | Фабрика руководств МИМ | Ф6b разметка wave-2 |
| 455 | 🔄 | P4 | Неизменяемость аудит-журнала событий | урок про git pull записан, кода не выкатывал |
| 290 | 🔄 | **P1** | Следователь: каузальная аналитика | Ход 2 — решение стратсессии |
| 73 | 🔄 | P3 | Новая архитектура ИТ-платформы Aisystant | Ф5 proposed, дедлайн 25.07 |
| 7 | 🔄 | — | Платформа: техдолг (зонтичный) | 03.08 веч.: Ф-MemoryBudget — S-53 введён (контракт записи, git памяти, замер), уборка таблицы ночью; 03.08: Ф-script-contract-gate закрыта (3 раунда фиксов); Ф39 (FMT #344-346) закрыта; +2 фазы сторожей (реестр, семафоры); детали `inbox/WP-7/WP-7.md`; решения пилота ждут |
| 485 | 🔄 | P2 | Сверка дублирующихся скриптов root↔шаблон | Ф7-Ф9 (сторож в ритм) |
| 487 | 🔄 | P3 | Планировщик отложенного запуска РП | живой прогон через очередь |
| 472 | 🔄 | P3 | Конвейер личного бренда | 2-й человек за пилотом |
| 474 | 🔄 | P2 | Скиллы создания Pack по FPF | сверка fpf-sync-check.sh (Ф9 пункт 3) |
| 475 | 🔄 | P3 | Резидентность персональных данных IWE | отдельный РП или ждать |
| 476 | 🔄 | **P1** | Модель жизненного цикла данных | осталось Ф2 (нужен пилот) |
| 244 | 🔄 | P2 | Наблюдаемость платформы | Волна 1: решение из 3 вариантов |
| 481 | 🔄 | **P1** | Каталог применений FPF-семинара к IWE | триаж 3 кандидатов Ф16 пилотом |
| 289 | 🔄 | P2 | Интеграция IWE с личными базами знаний | Приёмка MVP |
| 483 | 🔄 | P2 | Комплект структурирования данных (guide-kit) | Ф6 шаги 1-3 закрыты 03.08; шаг 4 (регистрация+код) — будущая сессия |
| 488 | 🔄 | P2 | Браузерное рабочее место на Hetzner | Ф2 скорость/команда |
| 484 | 🔄 | **P1** | Автогенератор открытия/закрытия дня (зонтичный) | Ф51: весь ночной цикл на Railway-шлюзе, секрет уже был доступен — закрыто без пилота |
| 493 | 🔄 | P2 | Лаборатория характеристик | Ф4 ждёт данных (конец августа) |
| 494 | 🔄 | P2 | Панель рабочих продуктов в VS Code | ручная F5-приёмка пилотом |
| 496 | 🔄 | P3 | Журнал гипотез (LPF-регламент обратной связи) | сверка «Актуальных» на Week Close |
| 167 | 🔄 | P5 | Публикации (зонтичный) | пилот утверждает порядок 28 постов |
| 497 | 🔄 | P5 | Материалы исследования AGI | Ф9 публикация на клубе — за пилотом |
| 304 | 🔄 | P3 | Сайты aisystant.com (мир) и МИМ (Россия): концепция и обновление | отстройка от образования, слоган, цена — за пилотом |
| 391 | 🔄 | **P1** | Браузерный IWE — стенд МИМ (mim-iwe), мультимодельный вход | блокирует WP-385 Ф5; next живой прогон сценария входа |

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

- [project_mcp_peer_session_delivery_status.md](project_mcp_peer_session_delivery_status.md) — снимок 30.07: облачный MCP и 2-агентные пир-сессии доставлены всем; DS-MCP-репо и 3+ агента — нет

### Feedback — HOT

- [feedback_codex_peer_code_diagnosis_quality.md](feedback_codex_peer_code_diagnosis_quality.md) — Codex в пир-сессиях хорошо держит код-уровневую верификацию, поймал 2 фактических промаха писателя по данным, не на слово (04.08)
- [lessons_close_fix_now_not_defer.md](lessons_close_fix_now_not_defer.md) — на Close чини сразу то, что ловит механический хук, не жди отдельной фазы; одобренный чек-лист = список открытого, не отчёт о решённом (03.08)
- [lessons_regression_test_must_verify_via_same_mechanism_bug_manifests.md](lessons_regression_test_must_verify_via_same_mechanism_bug_manifests.md) — тест сравнивал `$(cat file)` до/после — режет trailing `\n` на обеих сторонах одинаково, слеп к своему же классу бага (03.08)
- [feedback_check_sibling_bug_instances_and_verify_stale_docs.md](feedback_check_sibling_bug_instances_and_verify_stale_docs.md) — почини баг → проверь все точки того же класса, не только заявленную; WP-context может быть устаревшим — при сомнении проверять код напрямую (03.08, Codex дважды поймал на РП-470)
- [lessons_card_claims_need_live_artifact_check.md](lessons_card_claims_need_live_artifact_check.md) — карточка РП не доказывает факт: сверять с живым артефактом (02.08 — 7 фантомов)
- [feedback_no_closing_questions.md](feedback_no_closing_questions.md) — не спрашивай «Что дальше?» после выполнения, выполни → отчитайся
- [feedback_quick_close_means_fast_for_pilot.md](feedback_quick_close_means_fast_for_pilot.md) — «быстрое закрытие» = коротко для пилота (снять ретро), не агент сокращает работу
- [feedback_day_close_preliminary_vs_final_stats.md](feedback_day_close_preliminary_vs_final_stats.md) — ранний свод Day Close подписывать «предварительный», не «по факту» — итог только на позднем проходе
- [lessons_check_live_sessions_before_editing_shared_governance_files.md](lessons_check_live_sessions_before_editing_shared_governance_files.md) — соло-правка governance-файлов → проверить mtime `.iwe-runtime/sessions/*.open`, не только git-lock (31.07)
- [feedback_notes_pilot_only_review.md](feedback_notes_pilot_only_review.md) — заметки разбирает ТОЛЬКО пилот: агент предлагает, решение+дата → Notes-Archive, неразобранное повторяется в каждом Day Open; ночной авторазбор отключён 30.07
- [feedback_ship_artifact_fast_not_just_discuss.md](feedback_ship_artifact_fast_not_just_discuss.md) — сайт/лендинг → сразу кликабельный макет, не только план (подтверждено РП304)
- [feedback_subagent_reports_russian.md](feedback_subagent_reports_russian.md) — отчёты субагентов пилоту — на русском; брифовать deliverable RU
- [feedback_askuserquestion_not_reaching_pilot.md](feedback_askuserquestion_not_reaching_pilot.md) — choice-question — дублировать в чат
- [feedback_kimi_peer_quality_concern.md](feedback_kimi_peer_quality_concern.md) — Кими слаб в пир-сессиях — верифицировать находки независимо
- [lessons_guard_scope_mismatch.md](lessons_guard_scope_mismatch.md) — сторож, ловящий не то условие или только «своего» субъекта, обучает себя игнорировать
- [routing-vocab.md](routing-vocab.md) — фраза → путь, читать ПЕРЕД Write
- [feedback_response_clarity_for_pilot.md](feedback_response_clarity_for_pilot.md) — A1-A11 правила ответа
- [reference_no_invented_facts_hub.md](reference_no_invented_facts_hub.md) — не выдумывать опыт/имена
- [user_tseren_personal_life.md](user_tseren_personal_life.md) — Tseren (НЕ Дмитрий), Кипр
- [reference_day_protocol_gaps_hub.md](reference_day_protocol_gaps_hub.md) — Day Open/Close квирки (7)
- [reference_wp_gate_mechanics_hub.md](reference_wp_gate_mechanics_hub.md) — task_id, дочерний РП, имя через Артефактор (6)
- [reference_diagnosis_technique_hub.md](reference_diagnosis_technique_hub.md) — root-cause, verify-before-trust (49)
- [reference_git_hygiene_hub.md](reference_git_hygiene_hub.md) — git-add scope, pathspec, rebase/reset квирки (32)
- [reference_macos_zsh_env_quirks_hub.md](reference_macos_zsh_env_quirks_hub.md) — квирки macOS/zsh/grep/git (15)
- [reference_process_runner_quirks_hub.md](reference_process_runner_quirks_hub.md) — креды в карточке, race сессий, umbrella-архивация (3)
- [reference_secrets_credentials_hub.md](reference_secrets_credentials_hub.md) — .mcp.json wrapper, ротация-верификация, 403≠401 (3)
- [reference_day_cycle_tsekh1_fallback.md](reference_day_cycle_tsekh1_fallback.md) — день открывается вручную на Маке при падении Цех-1; нужна диагностика (ночь 31.07→01.08)
- [reference_tsekh1_claude_login_oauth_localhost.md](reference_tsekh1_claude_login_oauth_localhost.md) — вход в Клода на цехе бьёт в localhost Мака (OAuth): входить ручным кодом авторизации (21.07, 03.08)
- Остальные уроки/hubs (31 шт., demoted 28.07+30.07) → [MEMORY-warm.md](MEMORY-warm.md)
