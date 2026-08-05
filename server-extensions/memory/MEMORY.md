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
| 503 | 🔄 | P1 | Умный конвейер РП | АрхГейт ledger-sync решён (05.08, пир+Codex): lock+publisher; реализация+smoke-тест впереди; токен поллера всё ещё за пилотом |
| 502 | 🔄 | P2 | Актуализация и продвижение портфеля РП | next приёмка наставника + доступ к мониторингу (детали → WP-502.md) |
| 498 | 🔄 | P2 | Наставник ИИ: оперативная помощь в чате | собрать Ф4 (маршрутизация + grounding) в context-sufficiency gate |
| 183 | 🔄 | — | CRM как система | DROP БД directus (решение 24.07) |
| 467 | 🔄 | **P1** | Архитектура подписок через Ори | решение Д10 блокирует Ф3 |
| 151 | 🔄 | — | Характеристики и состояния деятеля | ждать триггеров Ф18/Ф19 |
| 468 | ⏳ | P3 | Инфраструктура разработки | изучить ветку python-gcp knowledge-mcp |
| 469 | 🔄 | P3 | Архитектура доступа к личным данным | наблюдение завершено 22.07 — начать разбор |
| 470 | 🔄 | P3 | Канал выгрузки Здоровья в iCloud | 03.08: таймер+WeekReport+MonthClose починены; персруковод. → WP-149; Ф5/Ф6 открыты |
| 471 | 🔄 | P2 | Карта целевых аудиторий экосистемы | публикация метафоры или волна-2 (WP-437) |
| 454 | 🔄 | P4 | Честный числитель параллелизма | сверка на Week Close |
| 446 | 🔄 | P4 | Меню оплат «Потратить бонусы» | пилот подтверждает на семинарах |
| 417 | 🔄 | P3 | Табло пользователя | Ф-parallelism-1 (схема+B7.3) |
| 448 | 🔄 | P2 | Каталог паттернов процесса IWE | суб-батч 6б done (24+12=36); решение accept/reject по DP.M.217 |
| 458 | 🔄 | **P2** | Сквозной аудит безопасности платформы и IWE | B26 закрыт, Ф5.1 в проде; Ф5.2/5.3 — новая сессия |
| 442 | 🔄 | — | Личный бренд Церена | посты 26-07/27-07 ждут ready |
| 418 | 🔄 | — | Доставщик | Ф5.1 когорта |
| 482 | 🔄 | P2 | Конвейер процессов IWE (рефлекс/ИИ/пилот) | живая проверка гейта + Ф3/Ф4/Ф5 наблюдение |
| 427 | 🔄 | — | Учёт следов Ф6.3 | живая приёмка |
| 262 | 🔄 | — | Интерфейсы платформы (зонтичный) | ждёт приёмки пилотом (/train) → next feed |
| 330 | 🔄 | **P1** | Марафон вторая волна | волна-3 кикофф встречи-1 готов (05.08); 2 флага пилоту (состав команды, треки) |
| 437 | 🔄 | **P1** | Вторая волна когорты дизайн | Ф2 запуск, параллель WP-330 |
| 251 | 🔄 | — | Системы службы продвижения | уточнить явное «да» по финансированию |
| 250 | 🔄 | — | План развития до конца 2026 (зонтичный) | R1-R6 августа утверждены → Strategy.md § август |
| 399 | ⏳ | P1 | Ротация секретов экосистемы | батч просрочен, ротация за пилотом |
| 509 | 🔄 | P2 | Пир-сессии 3+ агентов: роль-дискавери и общий рабочий продукт | S-51 закрыта 3/3; промоция на Week Close |
| 510 | 🔄 | P3→P1 | ИИ-личности | Патч 3b MCP-доставка закрыт с Codex; next: контракт РП-406/B7.3 |
| 5 | 🔄 | — | Платформа: развитие (зонтичный) | детали `inbox/WP-5/WP-5.md` |
| 117 | 🔄 | — | Развитие nudge-системы | Ф-stopgap запушен, приёмка до 30.08; next Ф-milestone-once/narrative |
| 149 | 🔄 | **P1** | Персональные руководства | А0/А0b/В+4 находки ревью закрыты; ждём ночь 05→06.08 |
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
| 7 | 🔄 | — | Платформа: техдолг (зонтичный) | 04.08 ночь: Ф48 часть 1 закрыта (пир-сессия Codex) — гонка счётчика активных дней бота, deploy pilot@0302ba02; часть 2 (протокол доставки) открыта, нужен АрхГейт; попутно 2 находки в session-guard.sh (не чинил, защищённый файл). 04.08 веч.: +фаза QUICKCLOSE-GAPS1 (4 разрыва конвейера Close — no-remote-путаница commit-push, слепой к terminal-файлам session-guard, дубль session-index-write, repo-wide has_diff вместо diff агента — найдены живьём при закрытии этой же сессии, не чинил); CI зелёный на 15a38b9 (был красным только в C.UTF-8-локали раннера — тест поймал реальный баг). Ф42/QCRUN1 закрыта (095462ee62) — раннер quick-close больше не ломается на «---» в тексте коммита (не тире, как думали); fail-open политика выбрана пилотом. next: ORY-RT1; история фаз → `inbox/WP-7/WP-7.md` |
| 485 | 🔄 | P2 | Сверка дублирующихся скриптов root↔шаблон | Ф7-Ф9 (сторож в ритм) |
| 487 | 🔄 | P3 | Планировщик отложенного запуска РП | живой прогон через очередь |
| 472 | 🔄 | P3 | Конвейер личного бренда | 2-й человек за пилотом |
| 474 | 🔄 | P2 | Скиллы создания Pack по FPF | сверка fpf-sync-check.sh (Ф9 пункт 3) |
| 475 | 🔄 | P3 | Резидентность персональных данных IWE | отдельный РП или ждать |
| 476 | 🔄 | **P1** | Модель жизненного цикла данных | осталось Ф2 (нужен пилот) |
| 244 | 🔄 | P2 | Наблюдаемость платформы | Волна 1: решение из 3 вариантов |
| 481 | 🔄 | **P1** | Каталог применений FPF-семинара к IWE | аудит №1 (WP-510) закрыт; next аудит №2 WP-149 |
| 289 | 🔄 | P2 | Интеграция IWE с личными базами знаний | Приёмка MVP |
| 483 | 🔄 | P2 | Комплект структурирования данных (guide-kit) | Ф6 шаги 1-3 закрыты 03.08; шаг 4 (регистрация+код) — будущая сессия |
| 488 | ✅ | P2 | Браузерное рабочее место на Hetzner | done |
| 484 | 🔄 | **P1** | Автогенератор открытия/закрытия дня (зонтичный) | Ф61: пустой commit-push больше не роняет закрытие сессий (живой баг в фиксе тоже закрыт) |
| 493 | 🔄 | P2 | Лаборатория характеристик | Ф4 ждёт данных (конец августа) |
| 494 | 🔄 | P2 | Панель рабочих продуктов в VS Code | ручная F5-приёмка пилотом |
| 496 | 🔄 | P3 | Журнал гипотез (LPF-регламент обратной связи) | сверка «Актуальных» на Week Close |
| 167 | 🔄 | P5 | Публикации (зонтичный) | пилот утверждает порядок 28 постов |
| 497 | 🔄 | P5 | Материалы исследования AGI | Ф9 публикация на клубе — за пилотом |
| 304 | 🔄 | P3 | Сайты aisystant.com (мир) и МИМ (Россия): концепция и обновление | отстройка от образования, слоган, цена — за пилотом |
| 391 | 🔄 | **P1** | Браузерный IWE — стенд МИМ (mim-iwe), мультимодельный вход | блокирует WP-385 Ф5; next живой прогон сценария входа |
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

- [project_mcp_peer_session_delivery_status.md](project_mcp_peer_session_delivery_status.md) — снимок 30.07: облачный MCP и 2-агентные пир-сессии доставлены всем; DS-MCP-репо и 3+ агента — нет
- [project_codex_peer_reliability_watch.md](project_codex_peer_reliability_watch.md) — 05.08: пилот отметил, что Codex-напарник игнорирует инструкции — открытое наблюдение, копить примеры до эскалации

### Feedback — HOT

- [feedback_two_layer_review_catches_different_bugs.md](feedback_two_layer_review_catches_different_bugs.md) — пир-диалог с Codex до кода и холодное код-ревью после кода ловят разные классы дефектов, не взаимозаменяемы (04.08)
- [lessons_process_runner_root_repo_path_is_dot.md](lessons_process_runner_root_repo_path_is_dot.md) — process-runner.py commit-push: корневой репозиторий IWE = `"repo": "."`, не имя git-remote (04.08)
- [lessons_check_live_diff_before_parallel_infra_fix.md](lessons_check_live_diff_before_parallel_infra_fix.md) — сверить живой `git diff` перед правкой общего файла; если чужой diff МЕНЯЕТСЯ прямо сейчас — ждать тишины (polling), не разовая проверка (04-05.08)
- [lessons_test_isolation_needs_env_unset_not_just_path_override.md](lessons_test_isolation_needs_env_unset_not_just_path_override.md) — изоляция теста подменой пути к секрет-файлу недостаточна, если процесс наследует реальные credentials из окружения — нужен явный `env -u` (05.08, живой инцидент: 2 тестовых сообщения ушли в боевой Telegram)
- [lessons_guard_behind_failing_step_never_runs.md](lessons_guard_behind_failing_step_never_runs.md) — корректный сторож не исполняется, если стоит в конвейере за падающим шагом; красный CI отключает всё после точки падения (04.08)
- [feedback_long_autonomous_work_needs_visibility.md](feedback_long_autonomous_work_needs_visibility.md) — долгий автономный участок (>15-20 мин без апдейта) ощущается пилотом как темнота даже при хорошем итоге — апдейты по вехам, не только в начале (04.08); подтверждено 04.08: апдейты по вехам + один consolidated-вопрос = «отработал полностью сам»
- [feedback_close_summary_structure_over_density.md](feedback_close_summary_structure_over_density.md) — A1-A11 (лексика) не гарантируют понятность итога; финал долгой сессии вести «что теперь есть → что это даёт», не «как дошли» (04.08)
- [feedback_codex_peer_code_diagnosis_quality.md](feedback_codex_peer_code_diagnosis_quality.md) — Codex в пир-сессиях хорошо держит код-уровневую верификацию, поймал 2 фактических промаха писателя по данным, не на слово (04.08)
- [feedback_no_closing_questions.md](feedback_no_closing_questions.md) / [feedback_askuserquestion_not_reaching_pilot.md](feedback_askuserquestion_not_reaching_pilot.md) — не спрашивай «Что дальше?» после выполнения; choice-question — дублировать в чат, не полагаться только на инструмент
- [feedback_quick_close_means_fast_for_pilot.md](feedback_quick_close_means_fast_for_pilot.md) — «быстрое закрытие» = коротко для пилота (снять ретро), не агент сокращает работу
- [lessons_cloudflare_railway_cross_system_secrets.md](lessons_cloudflare_railway_cross_system_secrets.md) — Cloudflare secrets пишутся вслепую (добавление источника в keyring = ротация всех записей); `railway deployment redeploy`, не `railway redeploy` (05.08)
- [lessons_marp_visual_verification_required.md](lessons_marp_visual_verification_required.md) — презентацию проверять по рендеру (Read PDF), не по исходнику — список съезжал и текст обрезался незаметно в markdown (05.08)
- [feedback_git_add_specific_file_not_enough.md](feedback_git_add_specific_file_not_enough.md) — даже именной `git add <file>` не гарантирует чистый коммит в общей рабочей копии — чужие файлы могут быть уже застейджены; `git diff --cached --name-only` обязателен перед commit каждый раз (05.08, живой инцидент)
- [routing-vocab.md](routing-vocab.md) — фраза → путь, читать ПЕРЕД Write
- [feedback_response_clarity_for_pilot.md](feedback_response_clarity_for_pilot.md) — A1-A11 правила ответа
- [user_tseren_personal_life.md](user_tseren_personal_life.md) — Tseren (НЕ Дмитрий), Кипр
- Остальные уроки/hubs (52 шт., demoted 28.07+30.07+04.08) → [MEMORY-warm.md](MEMORY-warm.md)
