# Оперативная память

> **Инструкции:** `~/IWE/CLAUDE.md` | **Навигация:** `memory/navigation.md` | **Source-of-truth:** `DP.EXOCORTEX.001`
> **Слои:** L1 = платформа. L2 = staging. L3 = авторское.

## БЛОКИРУЮЩИЕ (проверяй ВСЕГДА)

1. **WP Gate:** ⛔ Первое действие на ЛЮБОЕ задание = `Read memory/protocol-open.md`. Без исключений.
2. **Close:** ⛔ «закрывай» / «всё» = `Вызвать Skill: run-protocol, аргумент: close`. Без исключений.
3. **ArchGate ≥8:** Архитектурное → СНАЧАЛА ЭМОГССБ → ПОТОМ решение.
4. **Repo-Touch Gate:** Первое действие в любом репо → прочитать `<repo>/CLAUDE.md`. Если есть блок «ОБЯЗАТЕЛЬНО ЗАГРУЖАЙ» — загрузить указанные файлы ДО ответа.
5. **Routing Gate:** Перед Write нового файла → `memory/routing-vocab.md` (fast-path). Miss → `memory/repo-type-rules.md`. Аналогия с соседним файлом запрещена (P5). SC: DP.SC.036.

## ВАЖНЫЕ (на рубежах)

5. **Capture:** На рубеже → «Capture: X → Y»
6. **Процессы:** Без PROCESSES.md не реализовывать
7. **Гигиена inbox:** Close архивирует done-WP сразу. Session-Prep — широкая очистка.
8. **Модели:** Opus=open-loop. Sonnet=closed-loop. Haiku=trivial. Делегирование только вниз.
9. **Шапки индексов = индекс, не changelog.** MEMORY.md / WP-REGISTRY.md / прочие реестры — только hook-строки. Changelog → `*-changelog.md`. Детектор: `check-index-health.py` в Day Close § 4в. → [feedback_memory_index_discipline.md](feedback_memory_index_discipline.md)
10. **Стратсессия → sessions/:** DS-my-strategy стратсессия → создать `sessions/YYYY-MM-DD-<тема>.md` ДО commit+push. Касается Claude и Kimi. → [feedback_sessions_missing.md](feedback_sessions_missing.md)
11. **Финиш > отлог.** Доп. задача найдена в сессии → **дефолт «делаю сейчас»**, не «отдельный РП / технический долг». Choice question «сейчас или потом» — анти-паттерн. → [feedback_finish_now_no_defer.md](feedback_finish_now_no_defer.md)
12. **Content cleanup backlog.** Содержательный вопрос (расхождение в Pack, граф понятий, формулировки руководств), который НЕ решается в текущей сессии → запись в `DS-my-strategy/current/content-cleanup-backlog.md` ДО продолжения работы. Минимум полей: added/added_by/source/type/location/question. Анонс: «Capture: backlog CC-NNN — <one-line>». Зонтик: [WP-376](../../../IWE/DS-my-strategy/inbox/WP-376-content-cleanup-umbrella.md). Разбирает только пилот; агенты только регистрируют.

---

## Текущая работа

> **Источник статуса РП:** `DS-my-strategy/current/WeekPlan W{N}.md` + `DS-my-strategy/WP-REGISTRY.md` + `DS-my-strategy/current/inbox/WP-NNN-*.md`.
> В MEMORY.md статус РП НЕ хранится (дубликат). Открыть WeekPlan = точка старта сессии.

> 🚨 **Первая когорта (R1) — 50 волонтёров.** WP-330 Марафон: **6 июня cutover bug fix:** авто-миграция из старой системы + bottleneck NOT NULL fix (`2c47a83`, `008a8a0`) задеплоены на pilot и new-arch. Denis P (user_id=6795592) восстановлен на день 5. Утром 7 июня — проверить доставку. **Следующий шаг:** DOC3 (Google-токен tsekh-1) + наблюдение за 3 мигрированными пользователями. → [project_first_cohort_50_volunteers.md](project_first_cohort_50_volunteers.md)

> ✅ **WP-391 ЗАКРЫТ (4 июня).** Браузерный IWE: Ф1–Ф6 P0 done. `get_onboarding_context` задеплоен (T1 MVP). own-data-full-access в проде. Ф6.1–Ф6.3 в backlog-with-triggers. Архив: `archive/wp-contexts/WP-391-browser-iwe.md`.

> 🔄 **WP-397 Доступ оплатившим без Ory-identity.** **Peer-сессия 54 (4 июня):** контур был РАЗОМКНУТ — инкрементальный ETL по watermark + DLQ никогда не перечитывался → оплативший ДО регистрации навсегда застревал в DLQ. Фикс: плист → `--backfill` (полный пересмотр непровижиненных каждые 4ч) + DLQ guard `WHERE NOT EXISTS` + resolve при провижининге. Verify: guard доказан (rollback), backfill 9991→93 непровижиненных (все not_found_in_kratos), дубль DLQ 185→93 вычищен. Коммит `75b883a`. Доступ к Ory от Паши проверен — рабочий. **РП не закрыт:** ждёт первого реального провижининга (когда любой из 93 зарегистрируется → backfill подберёт ≤4ч). Spike C → backlog. Ротация креды Kratos → security-трек (owner Паша). Урок: [lessons_green_metric_masks_broken_loop.md](lessons_green_metric_masks_broken_loop.md).

> ✅ **WP-212 изоляция напоминаний по bot_id — ЗАКРЫТО на пилоте И проде (5 июня, peer-сессия 33 Claude+Kimi).** 3-слойный контракт: код (`4a17bd2`) пишет/фильтрует строго по bot_id + линтер pre-commit + БД (NOT NULL). **Layer 1 = миграция бота 024** (`db/migrations/024_reminder_bot_id_not_null.py`) — едет вместе с кодом, запускается ДО планировщика → порядок безопасен; backfill своим id (история+будущие) → DELETE просроченных NULL → SET NOT NULL, идемпотентно. Убраны 2 рантайм-костыля ADD COLUMN bot_id. **Прод (new-architecture, commit `c2b80d1`, изолированный cherry-pick только WP-212):** деплой SUCCESS, миграция 024 прошла (`bot_id=8584256260 backfilled=0 deleted=0` — 26 просроченных уже ушли сами к моменту миграции), запрет включён, планировщик после миграции, бот здоров. **Пилот (`79b06f2`):** миграция прошла (`8297564672`), запрет включён. Прод-backfill истории/будущих был сделан вручную в сессии (1817 строк, `24c2cab` в neon-migrations). Отчёт: `sessions/2026-06/2026-06-05-33-reminder-botid-backfill/report.md`.

> 🔒 **WP-212 B7.7c/d done + WP-399 создан (5 июня, peer-сессия 17 Claude+Kimi).** Prevention утечки секретов в контекст: новый PreToolUse(Read|Edit|Grep) DENY-хук `secret-file-read-block.sh` + MCP-guard `secret-mcp-dump-guard.sh` + затирание расширено на `mcp__*` + детектор массового вывода по содержимому + Bash read-эвристика (B7.7a). Корень повторной утечки — MCP-вывод (`list_variables`) не маскировался. Cold-review (5 Critical/High исправлены, включая регрессию sed), smoke прошёл. **WP-399 «Ротация секретов экосистемы»** (P1, owner=пилот) — spin-off на ротацию у провайдеров: 1897 вхождений в transcript. Карта: `inbox/WP-212/rotation-impact-map.md`. Урок: [lessons_secret_leak_mcp_vector.md](lessons_secret_leak_mcp_vector.md).

> 📖 **WP-362 Универсальные руководства ЛР — руководство 1-1 ЗАКРЫТО (6 июня).** Все 10 секций s1-s10 + s1-special пройдены C+B+A, cross-guide errors=0, AR.4 PASS=113, source:docs=0, S.12=0. Финальный коммит docs `d1328b3`. CC-102 (число стадий конвейера) перенесён в WP-364. **РП in_progress** (3 руководства): следующая — Ф4 (1-2 «Методы саморазвития»), ДО старта — решить CC-102 в WP-364. Точка входа: `inbox/WP-362/handoff-2026-06-06-1-1-complete.md`.

> 🔄 **WP-398 Многосессионный реестр статуса агентов (4 июня).** Ф1–Ф5 done. **Ф5 (peer-36):** командный дашборд `--repo`, pilot_name через getUserNames? лямбда (DI через DATABASE_URL), конфликты файлов + нормализация путей, 35 тестов. Deploy `b894604` (deep copy fix). **Ф4 pending:** Python mock test → CI (~0.5h). Handoff: `inbox/WP-398-*.md §Осталось`. Урок: [lessons_pk_change_all_write_paths.md](lessons_pk_change_all_write_paths.md).

> 🔄 **WP-392 Интеграция Hermes Agent (6 июня).** **✅ Б1 + Ф3.1b + HERMES_RUNTIME_TIMEOUT DONE.** Timeout 25→60с в gateway-mcp wrangler.toml (`3df53f3`, CF `81a8f997`) — сложные запросы (ASCII-арт, HTML) больше не обрываются. **Следующее:** Б2 (Settings-trap), hermes-specific timeout в коде, revert dual-write. Детали: `inbox/WP-392-hermes-agent-integration.md §Осталось`. Уроки: [lessons_router_precedence_shadowing.md](lessons_router_precedence_shadowing.md) · [lessons_mock_patch_package_reexport.md](lessons_mock_patch_package_reexport.md).

> ✅ **WP-378 ЗАКРЫТ (5 июня, peer-сессия -09 Claude+Kimi).** Распаковка R1 на Стратег (discovery, WHAT/WHY) + Плановик DP.ROLE.066 (планирование, HOW MUCH/WHEN). Ф1 governance: DP.SC.030 (discovery-стратегирование) + DP.SC.051 (совместный недельный ритуал) + переработка паспортов (убрана мёртвая Hub-and-Spoke/WORKPLAN) + онто-долг закрыт (DP.ONT.001). Ф2 локальное: навык `/discovery-session` (единый источник из DP.METHOD.053) + переносимый промпт для Анастасии (interim-мост, `docs/discovery-prompt-portable.md`). Deploy: PACK `dcd91a0`, FMT `e5c86a0`. **Follow-up (уточнение пилотом 5 июня):** серверный фиксатор = модель «два инструмента» (`run_strategist` сохраняется + добавляется `run_planner`, НЕ rename); DP.SC.011 переформулирован в зонтик «Стратегирование и Планирование» (декомпозируется на DP.SC.030+051, R17=роль пилота-участника, не конкурирующий агент). **Спин-офф (трекер B-006):** серверный многоходовой канал (гейт DP.SC.162) + `run_planner`. Архив: `archive/wp-contexts/WP-378-*.md` (при Close-уборке).

> 🔄 **WP-349 Онбординг на MCP — Ф29+Ф33 DONE (6 июня).** Ф29 BYOK: миграции применены (PERSONA_DIRECT/LEARNING_DIRECT), gateway задеплоен, BYOK_KEK в CF Secrets — всё верифицировано. Ф33 Проводник T0/T1: «Гермес,…» для tier<T3 → Haiku-помощник (DP.SC.169), DP.ROLE.013 расширен §9, bot pilot `408ac62`, new-arch `a34e113`, PACK `415f2c4`. Cold-review H1 исправлен. **Bug fix (6 июня):** parse_mode="Markdown" добавлен в message.answer() Проводника — SafeBot конвертирует `**` в HTML (`9acb9a2`, new-arch задеплоен). **Осталось:** Ф35 (докупка токенов ~9-12h), smoke Проводника, WP-392 Б2. Урок: [lessons_consent_or_logic_gdpr_gap.md](lessons_consent_or_logic_gdpr_gap.md).

> 🏭 **WP-364 Фабрика руководств МИМ — зонтичный РП.** 11 направлений с 18 дочерними. Все 4 развилки закрыты (29-30 мая). Ф1+Ф2+Ф6a ✅ done (peer-session 46); Ф3 → spin-off WP-374 (governance v4-lint, 10h, TSR-75); Ф5 → pointer-only WP-371 (sibling); Ф4 ongoing Week Close ревью; Ф6b разметка ЛР ~5-6h (Ф6c РР снят — нет контента). **Чистый бюджет WP-364: 21h** (было 53h до peer-session 46 + Ф6a 30 мая); из них done 9.5h, pending 12h. SoT направлений — `DS-my-strategy/inbox/WP-364-fabrika-rukovodstv-mim.md` §70-84.

## Ключевые различения (→ distinctions.md, hard-distinctions.md)

> **4 уровня: Проблема ≠ Задача ≠ ФР ≠ Работа** (HD #24, DP.D.053) — главный навык эпохи ИИ.
> **Персона / Память / Контекст** (HD #27, DP.D.052) — три слоя пользовательских данных, критерий = writer+owner.

## Бот: деплой

| Бот | Ветка | Railway | Env |
|-----|-------|---------|-----|
| @aist_me_bot (прод) | `new-architecture` | `aist_bot_newarchitecture` | Neon |
| @aist_pilot_bot (пилот) | `pilot` | `aist_bot_newarchitecture` | Railway Postgres |

> **Pilot-First (БЛОКИРУЮЩЕЕ):** Только на `pilot`. НИКОГДА на `new-architecture` первым. Pre-push hook.
> **Docs-only коммиты:** заливаются сразу на pilot и new-architecture (`FORCE_PROD=1`).
> **Railway MCP:** проект `peaceful-vision`. `lavish-delight` — не трогать.

## Read-only репо

> **DS-IT-systems/SystemsSchool_bot** — ⛔ READ-ONLY.
> **DS-IT-systems/aisystant** — ⛔ READ-ONLY.

---

## Индекс

> §4 CLAUDE.md покрывает: checklists, fpf-reference, hard-distinctions, navigation, repo-type-rules, roles, sota-reference.
> Протоколы: protocol-{open,work,close,month-close}.md. Операционные: t-checklist, r-questionnaire, sync-manifest.yaml, templates-dayplan.
> Спецификации: [memory-lifecycle-spec.md](memory-lifecycle-spec.md) — онтология памяти v1 (4 оси, frontmatter-схема, HOT/WARM/COLD).

### 🔄 Активные РП

> Таблица удалена (ОПТ-4, WP-297 Ф6.3) — была источником Type C/D drift.
> **Перечень активных РП:** открыть `DS-my-strategy/current/WeekPlan W{N}.md` или выполнить `bash $IWE_SCRIPTS/active-wp-sweep.sh`.
> Создание РП: `bash $IWE_SCRIPTS/create-wp.sh --title "..." --budget Xh` (регистрирует в REGISTRY + WeekPlan + inbox + Linear). `$IWE_SCRIPTS` = `~/IWE/FMT-exocortex-template/scripts/`.

### Feedback — HOT

> Архивы WARM: [feedback-april-2026.md](archive/feedback-april-2026.md) (17-26 апр) | [feedback-apr-may-2026.md](archive/feedback-apr-may-2026.md) (27 апр — 18 мая).

- [feedback_response_clarity_for_pilot.md](feedback_response_clarity_for_pilot.md) — **HOT:** 12 паттернов + 11 правил A1-A11 + детектор канала — как отвечать пилоту без путей-подлежащих и англицизмов (1 июня, peer-27)
- [feedback_no_invented_personal_history.md](feedback_no_invented_personal_history.md) — **HOT:** speaker notes / контент за пользователя — не выдумывать его личный опыт; шаблон `{СОБСТВЕННЫЙ ПРИМЕР: ...}` (31 мая, WP-351)
- [feedback_week_close_security_not_deferred.md](feedback_week_close_security_not_deferred.md) — **HOT:** Week Close: `open_critical_count > 0` → добавить WP-212 в WeekPlan СЕЙЧАС, не "при Session Prep" (25 мая)
- [feedback_day_of_week_verification.md](feedback_day_of_week_verification.md) — **HOT:** не называть день недели по памяти; вычислять из даты (`date +%A`) или читать из DayPlan (31 мая, назвал воскресенье понедельником)
- [feedback_week_close_todo_conditional_steps.md](feedback_week_close_todo_conditional_steps.md) — условные шаги протокола включать в TodoWrite со статусом completed+reason (24 мая, W21 close)
- [feedback_dt_collect_test_methodology.md](feedback_dt_collect_test_methodology.md) — dt-collect.sh: тест с 2>/dev/null + json.load() даёт 0/0 ложно; использовать grep по ключам (24 мая)
- [feedback_dayplan_archive_silent_skip.md](feedback_dayplan_archive_silent_skip.md) — **HOT:** вчерашний DayPlan застревает в current/ — Day Close не архивирует, Day Open checks не ловит; повторилось 22-23-24 мая
- [feedback_skill_manual_synthesis_bypass.md](feedback_skill_manual_synthesis_bypass.md) — **HOT:** обещал /bottleneck-pick (5-фазный ВДВ + calibration YAML), сделал интуитивную 5-строку — P5 микро-обход (24 мая)
- [feedback_day_open_strategy_day_skip.md](feedback_day_open_strategy_day_skip.md) — **HOT:** strategy_day (Пн) ≠ освобождение от шагов 1-6 и compact dashboard; session-prep ≠ Day Open (1 июня)
- [feedback_wp_gate_wrong_task_id.md](feedback_wp_gate_wrong_task_id.md) — **HOT:** task_id в meta.yaml сессии = archived WP-382 вместо WP-329; grep WP-REGISTRY ДО создания meta.yaml (1 июня)
- [feedback_day_open_checks_coverage_gap.md](feedback_day_open_checks_coverage_gap.md) — **HOT:** Day Open checks дырявые (нет проверок bottleneck/News Lens/smoke) + false-negative regex (24 мая)
- [feedback_marathon_newcomer_intern_sync.md](feedback_marathon_newcomer_intern_sync.md) — **HOT:** WP-330 marathon_newcomer не вызывал update_intern → /profile ломался (23 мая)
- [lessons_managed_pilot_tg_lookup.md](lessons_managed_pilot_tg_lookup.md) — managed-пилот в process_queue fallback: tg_chat_id подтягивать из persona.ory_identity, не оставлять "" (25 мая)
- [lessons_consent_or_logic_gdpr_gap.md](lessons_consent_or_logic_gdpr_gap.md) — **WARM:** OR-логика для consent при двух таблицах молчаливо игнорирует revoked_at (GDPR-дыра); правильно — migration + switch чтения (5 июня, WP-349 Ф32)
- [lessons_marathon_queue_no_bot_id.md](lessons_marathon_queue_no_bot_id.md) — **WARM:** marathon_queue без bot_id — пилот и прод пишут в одну Neon, пилот-доставка блокирует прод через has_recent_lesson_practice_sent; Fix A: проверять имена колонок grep'ом ДО UPDATE (6 июня, WP-330)
- [lessons_double_knowledge_search_tool_use.md](lessons_double_knowledge_search_tool_use.md) — **WARM:** pre-search + Claude tool_use оба зовут knowledge_search — 14с дубля подтверждено трейсами; фикс: передать pre-search результаты Клоду явно (5 июня, WP-330 latency)
- [lessons_telegram_markdown_underscore_silent_fail.md](lessons_telegram_markdown_underscore_silent_fail.md) — **HOT:** `_` в chatLink/URL ломает Telegram Markdown v1 — edit_text и answer оба падают молча; fix: `.replace("_", "\\_")` (5 июня, WP-330 S2)
- [lessons_bot_content_source_priority.md](lessons_bot_content_source_priority.md) — **WARM:** бот читает data/marathon-content.json из своей копии (приоритет 1), не авторский репо; синхронизировать через sync-marathon-content.sh перед коммитом (5 июня, WP-330)
- [lessons_bot_faq_keyword_ratio.md](lessons_bot_faq_keyword_ratio.md) — ≤6 ключевых слов на FAQ-запись; больше → ratio снижается (23 мая)
- [lessons_llm_audit_hallucinated_scale.md](lessons_llm_audit_hallucinated_scale.md) — **WARM:** LLM-аудит галлюцинирует шкалу ступеней (1-7 вместо 1-5) — grep STAGE_NAMES_RU перед исправлением знаменателя (5 июня)
- [lessons_bash_pipeline_fallback.md](lessons_bash_pipeline_fallback.md) — `head -1 || echo default` не работает при пустом пайплайне; нужна явная `[[ -z ]]` проверка (23 мая)
- [feedback_root_cause_verify_in_code.md](feedback_root_cause_verify_in_code.md) — **HOT:** root cause гипотеза → верификация в коде (grep + line-number) ДО публикации (22 мая)
- [feedback_solo_smoke_blind_spots.md](feedback_solo_smoke_blind_spots.md) — **HOT:** solo-smoke N/N PASS — слабый сигнал; +Pattern Guard (21 мая)
- [feedback_direction_files_staleness.md](feedback_direction_files_staleness.md) — **HOT:** direction-файлы WP-250 stale ≥48ч; перед анализом — git log (18 мая)
- [feedback_verify_bot_identity.md](feedback_verify_bot_identity.md) — **HOT:** имена ботов верифицировать через первичный источник (BotFather, Railway env, код) (20 мая)
- [feedback_registry_no_phases.md](feedback_registry_no_phases.md) — **HOT:** REGISTRY-ячейка = только имя артефакта (≤80 символов) (20 мая)
- [feedback_wp_naming_verbs.md](feedback_wp_naming_verbs.md) — **HOT:** имя РП = существительное-артефакт; запрет глагольных «производство/издание/выпуск/доставка/реализация» (29 мая)
- [feedback_behaviour.md](feedback_behaviour.md) — ОРЗ, снапшоты, верификация, автономность (29 апр)
- [feedback_bot_ux_user_facing_text.md](feedback_bot_ux_user_facing_text.md) — команды в TG без `<code>`; убирать служебные метки из user-facing строк (12 мая)
- [feedback_writing.md](feedback_writing.md) — стиль, публикации, Marp (28 апр)
- [feedback_post_style_reference.md](feedback_post_style_reference.md) — **HOT:** эталон стиля постов — «Сделать за человека?» (25 мая, клуб, post #151). Читать перед написанием нового поста
- [feedback_architecture.md](feedback_architecture.md) — код, DDD, MCP, Neon (28 апр)
- [feedback_russian_clear.md](feedback_russian_clear.md) — только понятный русский в ответах (28 апр)
- [feedback_close_push_all_repos.md](feedback_close_push_all_repos.md) — **HOT:** «закрывай» = git status по ВСЕМ репо сессии + push незалитого ДО шага 2 (18 мая)
- [feedback_wp_scope_vs_done_check.md](feedback_wp_scope_vs_done_check.md) — **HOT:** перед `status: done` РП — сверка scope из context-файла vs выполненное (18 мая)
- [feedback_explanations_no_codes.md](feedback_explanations_no_codes.md) — **HOT:** цифры правил — только в скобки; основная фраза = понятное объяснение (17 мая)
- [feedback_rule_carrier_confusion.md](feedback_rule_carrier_confusion.md) — **HOT:** правила про «как писать инструменты агента» — носитель = агент, не пилот (17 мая)
- [feedback_role_family_completeness.md](feedback_role_family_completeness.md) — **HOT:** перед фразой «N близких ролей» — grep Pack-source (20 мая)
- [feedback_day_open_gaps_2026-05-02.md](feedback_day_open_gaps_2026-05-02.md) — **КРИТИЧЕСКИЙ: шаг 3 Саморазвитие отсутствует в Day Open** + 4 косяка (3 май)
- [feedback_create_wp_via_script.md](feedback_create_wp_via_script.md) — **HOT:** новый РП = только `create-wp.sh`, не Write напрямую (16 мая)
- [feedback_wp_gate_ritual_for_child_wp.md](feedback_wp_gate_ritual_for_child_wp.md) — **HOT:** дочерний РП в рамках родительского требует **отдельного** WP Gate Ритуала; scope cut в моём предложении ≠ согласие; default — фаза в родительском, не дочерний РП (27 мая)
- [feedback_user_name_tseren_not_dmitry.md](feedback_user_name_tseren_not_dmitry.md) — **HOT:** пилот = Tseren, НЕ Дмитрий. «Дмитрий» в WP-327 / WP-261 context — ошибка файла, не имя пилота (27 мая)
- [feedback_choice_no_permission_token.md](feedback_choice_no_permission_token.md) — **HOT:** после блокировки хуком — не писать «(явное разрешение от тебя)» как маркер варианта в choice list; quasi-вопрос (30 мая, WP-364 peer-session 52, P5)
- [feedback_no_invented_authors.md](feedback_no_invented_authors.md) — **HOT:** не выдумывать авторов методологии «по памяти» (галлюцинация «Дмитрий Винник» как источник R28) — grep'ом проверять Pack ДО атрибуции (29 мая)
- [feedback_promote_script_clean_env.md](feedback_promote_script_clean_env.md) — **HOT:** promote-скрипты для FMT тестировать в `env -i` (20 мая)
- [feedback_git_add_dash_u.md](feedback_git_add_dash_u.md) — **HOT:** `git add -u` захватывает чужие unstaged-файлы peer-агентов → только `git add <specific-paths>` (17 мая)
- [feedback_git_revert_sha.md](feedback_git_revert_sha.md) — **HOT:** `git revert HEAD` опасен при peer-агентах; всегда `git revert <SHA>` (19 мая)
- [feedback_peer_agent_fetch_before_status.md](feedback_peer_agent_fetch_before_status.md) — **HOT:** peer-agent верификация → `git fetch origin` обязателен перед `git status` (19 мая)
- [feedback_peer_agent_wrong_repo_push.md](feedback_peer_agent_wrong_repo_push.md) — **HOT:** peer-агент копирует SSH URL из соседнего репо → верифицировать через `git ls-remote` (21 мая)
- [lessons_mock_patch_package_reexport.md](lessons_mock_patch_package_reexport.md) — **WARM:** `patch("pkg.submod.name")` падает если `pkg/__init__.py` реэкспортирует name как instance; нужен `importlib.import_module` + `patch.object` (6 июня, WP-392 Ф3.1b)
- [lessons_kimi_id_collision_resolution.md](lessons_kimi_id_collision_resolution.md) — **WARM:** Кими при rename ID (коллизия) оставляет orphan (unstaged deletion) + не правит заголовок `# DP.D.NNN`; проверять `git status --short | grep "^ D"` + grep frontmatter vs heading (6 июня)
- [lessons_tg_answer_vs_edit_text.md](lessons_tg_answer_vs_edit_text.md) — **WARM:** в callback-цепочке answer() создаёт новое сообщение → кнопки исходного stale; edit_text() обновляет на месте — использовать edit_text для многошаговых флоу (6 июня, github-баг)
- [lessons_i18n_batch_rebase_overwrite.md](lessons_i18n_batch_rebase_overwrite.md) — **WARM:** после pull --rebase в общей ветке i18n-файлы могут откатиться (другой агент пушил тот же файл); верифицировать grep ключевых строк ПОСЛЕ rebase (6 июня)
- [lessons_kimi_adapter_adddir_token_limit.md](lessons_kimi_adapter_adddir_token_limit.md) — **WARM:** kimi-peer-adapter `--add-dir` на крупную папку (>~500K) → Кими читает целиком → лимит токенов; давать узкие папки / файлы путями (5 июня, WP-362 s6)
- [feedback_peer_agent_spec_claims.md](feedback_peer_agent_spec_claims.md) — **HOT:** «ближе к спеке» без цитаты раздела = требует независимой проверки (20 мая)
- [feedback_peer_agent_workflow_smoke_test.md](feedback_peer_agent_workflow_smoke_test.md) — **HOT:** peer-агент, коммитя CI-workflow, обязан smoke-test через `gh workflow run` ДО отчёта done (20 мая)
- [feedback_required_check_paths_pitfall.md](feedback_required_check_paths_pitfall.md) — **HOT:** required_status_checks на workflow с `paths:` фильтром = PR навсегда «expected» (20 мая)
- [feedback_peer_agent_partial_edit.md](feedback_peer_agent_partial_edit.md) — **HOT:** peer-агент после терминологической замены обязан grep всего файла; +YAML PyYAML smoke-test (20 мая)
- [lessons_agents_md_derived_not_editable.md](lessons_agents_md_derived_not_editable.md) — **HOT:** AGENTS.md derived (sync-agent-instructions.sh); ручные вставки не выживают при --force; агент-специфика → agent-blocks (3 июня, WP-394)
- [lessons_peer_adapter_stdout_constraint.md](lessons_peer_adapter_stdout_constraint.md) — **HOT:** claude-peer-adapter синтез/review: «Напиши file.md» → Write tool вместо stdout; нужен явный stdout-only constraint (3 июня)
- [lessons_peer_yaml_validation.md](lessons_peer_yaml_validation.md) — v4-lint porter использует regex-парсер не PyYAML; при правках YAML — yaml.safe_load() smoke-test (20 мая)
- [lessons_terminology_verify_loop.md](lessons_terminology_verify_loop.md) — terminology-замена требует 2-3 проходов verify→fix; первый проход оставляет inconsistency (22 мая)
- [lessons_subagent_review_for_validators.md](lessons_subagent_review_for_validators.md) — **HOT:** independent cold-context Agent review обязателен после реализации (валидатор/линтер/любой свежий код); generalized 27 мая через 3.6.2 peer-pipeline (16 + 27 мая)
- [lessons_subagent_review_peer_complement.md](lessons_subagent_review_peer_complement.md) — **HOT:** субагент после peer-сессии ловит то что peer пропустил (D10 constraint crash, D11 отсутствие таблицы) — разные слои проверки (4 июня, WP-368)
- [lessons_mandatory_slots_mismatch.md](lessons_mandatory_slots_mismatch.md) — **WARM:** параллельные копии скрипта с разными MANDATORY_SLOTS дают разные ступени — diff ключевых констант при аудите (4 июня, WP-368)
- [feedback_pack_refs_source_entity_vs_method.md](feedback_pack_refs_source_entity_vs_method.md) — **HOT:** pack_refs source: DP.IWE.NNN для сущностей, DP.M.NNN для методов (21 мая)
- [lessons_pack_first_introduces_ontology.md](lessons_pack_first_introduces_ontology.md) — **HOT:** v4-lint A.8: introduces только если понятие в ontology.md — сначала Pack, потом guide (4 июня, WP-362)
- [lessons_canon_three_layer_verify.md](lessons_canon_three_layer_verify.md) — **WARM:** сверка модели в guide — 3 слоя (формализация FORM.080 + глоссарий ontology.md + структура-оутлайн), они расходятся; не доверять «понятий нет» (grep сам); git-провенанс отвечает «потеря или ошибка с рождения» (4 июня, WP-362 s4)
- [lessons_uniform_linter_warn_is_tooling_drift.md](lessons_uniform_linter_warn_is_tooling_drift.md) — **WARM:** линтер флагует идентичный набор WARN у ВСЕХ файлов → рассогласование эталона инструмента, не дефекты данных; grep распределения ДО массовой правки контента (5 июня, WP-362 ФАЗА D)
- [reference_aisystant_universal_guides.md](reference_aisystant_universal_guides.md) — **WARM:** ссылки на универсальные руководства 3 программ (ЛР/РР/ИР) в aisystant/docs + каталог квалификаций system-school.ru/qualification (30 мая, WP-371 брифинг)
- [lessons_railway_learning_schema_isolation.md](lessons_railway_learning_schema_isolation.md) — **WARM:** pilot-БД изоляция через Railway reference var `${{Postgres.DATABASE_URL}}` + startup migration — паттерн переносим на любой `*_URL` (6 июня, WP-7)
- [routing-vocab.md](routing-vocab.md) — **L0 fast-path словарь**: фраза → канонический путь (30+ типов). Читать ПЕРЕД Write. SC: DP.SC.036 (12 мая)
- [feedback_routing_gate_always.md](feedback_routing_gate_always.md) — **HOT:** перед КАЖДЫМ Write нового файла открывать routing-vocab.md (12 мая)
- [feedback_archgate_independent_review.md](feedback_archgate_independent_review.md) — **HOT:** после ~2h работы по новому архитектурному решению — independent cold-context review (Opus subagent) (12 мая)
- [feedback_day_open_captures_skipped.md](feedback_day_open_captures_skipped.md) — **HOT, главный косяк Day Open:** шаг 5e (KE-кандидаты) пропущен 3 дня подряд 15-17 мая
- [feedback_dayopen_missing_ke_section.md](feedback_dayopen_missing_ke_section.md) — **HOT:** scaffold не имел PENDING-маркера для 5e → секция молча пропускалась; исправлено 21 мая
- [feedback_dayopen_incomplete_sections.md](feedback_dayopen_incomplete_sections.md) — **HOT:** 4 систематических пропуска: Календарь, светофор, Мир, KE; корень — Day Open без TodoWrite пошагово
- [feedback_lean_mvp_after_full_archgate.md](feedback_lean_mvp_after_full_archgate.md) — **HOT:** после ArchGate с N≥10h + зонтичный РП → предложить MVP-subset как фазу (18 мая)
- [feedback_kimi_direct_call.md](feedback_kimi_direct_call.md) — **HOT:** Кими вызывать через `kimi-peer-adapter.sh` напрямую (22 мая)
- [feedback_peer_adapter_role_overreach.md](feedback_peer_adapter_role_overreach.md) — **HOT:** `claude-peer-adapter.sh` для peer-реплики обязан содержать negative scope «не редактировать файлы / не commit»; иначе Claude self-execute весь turn-loop (1 июня, WP-380 fixup-session)
- [lessons_smoke_import_off_by_one.md](lessons_smoke_import_off_by_one.md) — Python smoke-import не ловит off-by-one в data tables; verify = `diff <(grep key sim) <(grep key src)` (1 июня, WP-380 повтор drift'а)
- [lessons_extraction_report_id_conflict.md](lessons_extraction_report_id_conflict.md) — extraction-report резервирует ID по устаревшему max; перед write — `ls | tail -1` по реальному Pack (2 июня)
- [lessons_registry_row_ordering.md](lessons_registry_row_ordering.md) — **WARM:** spin-off WP вставляется рядом с родителем, не вверху; order-guard добавлен в commit-msg хук (4 июня)
- [lessons_proxy_gate_enforcement.md](lessons_proxy_gate_enforcement.md) — **WARM:** прокси-gate валидирует тот же ключ, что читает backend; webhook 200-on-error прячет тихий сбой; кэш инвалидировать на мутирующем пути (4 июня, WP-391 Ф6)
- [lessons_lms_suser_schema.md](lessons_lms_suser_schema.md) — **WARM:** LMS suser: нет created_at (инкремент по id), ory_id почти всегда NULL, Kratos Admin API = Basic auth через nginx (4 июня, WP-397)
- [lessons_green_metric_masks_broken_loop.md](lessons_green_metric_masks_broken_loop.md) — **WARM:** расписание+exit 0+counter=0 может маскировать разомкнутый контур; проверять путь данных в коде/контролируемым тестом, не выводить «работает» из «запускается» (4 июня, WP-397 peer-54)
- [lessons_secret_leak_mcp_vector.md](lessons_secret_leak_mcp_vector.md) — **WARM:** утечка секретов идёт через вывод MCP-инструментов (не только Read/Bash); ловить по содержимому, не по имени/фразе; PostToolUse-редакция не спасает transcript; `${var}` обязателен рядом с не-ASCII под set -u (5 июня, WP-212 B7.7c/d)
- [lessons_constraint_migration_after_code.md](lessons_constraint_migration_after_code.md) — **WARM:** миграция-ужесточение (NOT NULL/строгий фильтр) только ПОСЛЕ выката кода; read прод-данных ДО мутации; публичный id сервиса из логов, не из токена; бэкап + .gitignore дампа (5 июня, WP-212 Layer 1 peer-33)
- [lessons_fmt_author_script_divergence.md](lessons_fmt_author_script_divergence.md) — **WARM:** FMT-скрипты могут разойтись с авторскими; перед promote --force диффать, не затирать генерализацию FMT (4 июня, WP-7 Block FMT)
- [lessons_betterstack_verify_before_act.md](lessons_betterstack_verify_before_act.md) — **WARM:** перед «ручным действием BetterStack» — проверить реальное состояние через API; session report может описывать уже выполненное (4 июня, hw-checker fast-path)
- [lessons_ffmpeg_x265_brew_version_conflict.md](lessons_ffmpeg_x265_brew_version_conflict.md) — **WARM:** ffmpeg падает с dyld после `brew upgrade x265` — симлинк переключается, старая lib пропадает; лечение: `ln -sfn ../Cellar/x265/4.1 /opt/homebrew/opt/x265` или `brew reinstall ffmpeg` (5 июня)
- [lessons_pk_change_all_write_paths.md](lessons_pk_change_all_write_paths.md) — **WARM:** смена PK миграцией → grep ВСЕ write-path (ORM + raw-psql fail-safe), иначе `ON CONFLICT` молча падает (42P10); fail-safe маскирует поломку (4 июня, WP-398 Ф2)
- [lessons_create_table_if_not_exists_noop_constraint.md](lessons_create_table_if_not_exists_noop_constraint.md) — **WARM:** `CREATE TABLE IF NOT EXISTS` молча no-op'ит на предсуществующей таблице без constraint → `ON CONFLICT` падает 42P10; миграция должна гарантировать unique-index идемпотентно + логировать `had_target_before` (5 июня, peer-session 2026-06-05-02 consent_grant)
- [lessons_router_precedence_shadowing.md](lessons_router_precedence_shadowing.md) — **WARM:** catch-all/active-session handler раньше по цепочке затеняет intent-роутер → фича «не работает», хотя сообщение съел приоритетный handler; intent-роутеры регистрировать ДО catch-all (5 июня, WP-392)
- [lessons_stop_hook_transcript_path.md](lessons_stop_hook_transcript_path.md) — **WARM:** Stop-хук Claude Code даёт `transcript_path` (JSONL), не `assistant_response`; детектор должен сканировать стенограмму (4 июня, WP-388)
- [lessons_migration_immutable_and_hash_dedup.md](lessons_migration_immutable_and_hash_dedup.md) — **WARM:** закоммиченную миграцию не перезаписывать (новый файл + DEPRECATED); partial-unique dedup только при provenance_hash IS NOT NULL (NULL = нет ключа идемпотентности → история допустима) (4 июня, WP-368 Ф4/Ф5)
- [lessons_schema_dependent_filter_verify.md](lessons_schema_dependent_filter_verify.md) — **WARM:** фильтр, зависящий от колонки → прямая проверка information_schema ДО деплоя; косвенное «миграция применена» ненадёжно если query-путь обходится; push ≠ deploy для agent-runner (4 июня, WP-373)
- [lessons_kimi_adddir_pii_block.md](lessons_kimi_adddir_pii_block.md) — **WARM:** kimi-peer-adapter `--add-dir` с исходником auth/JWT → exit 3 (PII); node_modules → exit 4; давать Кими папку сессии/дизайн, не код (4 июня, WP-392)
- [lessons_swarm_check_before_blocked.md](lessons_swarm_check_before_blocked.md) — **WARM:** в параллельном swarm перед «фаза заблокирована» — `git log --since=6am` по всем репо; соседняя сессия могла закрыть (5 июня, WP-349: дважды отчитался «Б1/Ф26 блок», пока их закрывали)
- [lessons_kimi_content_filter.md](lessons_kimi_content_filter.md) — **HOT:** Kimi headless блокирует промпты со словами `private key/PEM/secret/token` (HTTP 400 high risk). **WP-394 Ф3.2: guard автоматизирован в kimi-peer-adapter.sh** — переформулировать вручную больше не нужно (3 июня)
- [lessons_hermes_artifact_search.md](lessons_hermes_artifact_search.md) — **WARM:** артефакты Гермеса в `~/.hermes/`, а не `~/IWE` — поиск по IWE даёт ложное «не найдено» (3 июня, WP-394 верификация)
- [lessons_railway_list_variables_secret_dump.md](lessons_railway_list_variables_secret_dump.md) — **WARM:** Railway list_variables высыпает ВСЕ секреты в лог — не звать ради одной переменной; прод-чтение через RO-кред вне репо; удаление логов ≠ ротация (5 июня, WP-330)
- [lessons_bolid_two_components_canon.md](lessons_bolid_two_components_canon.md) — **WARM:** Болид = Пилот + Машина (2 компонента), Мастерство ∈ Пилот; «+ Мастерство» был дрейфом (Pack 18 мая, гайды 4 июня) — не доверять «X переписан на N компонентов» как канону, сверять с PD.FORM + git-провенанс + внутренние противоречия (5 июня, WP-362)
- [lessons_hermes_aisystant_oauth_refresh.md](lessons_hermes_aisystant_oauth_refresh.md) — **WARM:** Hermes↔Aisystant: браузер-петля OAuth = client.json `client_secret_basic` vs сервер `none` (фикс → `none`; `hermes mcp login`/`update` откатывают); запросы разрешений = 3 канала (approvals.mode off + ACP edit-mode патч server.py + VS Code `chat.tools.global.autoApprove`+`.optIn`) (4 июня)
- [lessons_gateway_mcp_auto_deploy.md](lessons_gateway_mcp_auto_deploy.md) — **HOT:** push в main репо `gateway-mcp` автоматически деплоит на боевой mcp.aisystant.com (`deploy.yml`). Всегда пушить на ветку, merge в main — только по явному слову пилота (3 июня, WP-394 Ф4.1)
- [feedback_kimi_agents_md.md](feedback_kimi_agents_md.md) — **HOT:** Kimi читает `AGENTS.md`, не `CLAUDE.md` (22 мая)
- [feedback_kimi_gateway_vs_adapter.md](feedback_kimi_gateway_vs_adapter.md) — **HOT:** отсутствие Claude в `list_peer_statuses` ≠ нельзя вызвать; использовать `claude-peer-adapter.sh` (26 мая)
- [feedback_kimi_writer_stdout_only.md](feedback_kimi_writer_stdout_only.md) — Kimi-writer через `kimi-peer-adapter.sh` обязан получить «НЕ используй Write/Edit, выводи markdown в stdout» в промпте; иначе пишет резюме вместо реплики (1 июня, WP-330 peer-session 22)
- [feedback_response_language_russian.md](feedback_response_language_russian.md) — **HOT:** итоговые сводки, «что сделано/далее» — только русский; EN лишь в коде и именах файлов (27 мая)
- [feedback_code_review_fix_imperative.md](feedback_code_review_fix_imperative.md) — **HOT:** fix-рекомендации в code review — только императив («убрать», «заменить»), не «должна/следует» (28 мая)
- [lessons_systemd_env_override.md](lessons_systemd_env_override.md) — environment.d/*.conf перехватывает ВСЕ systemd user сервисы; EnvironmentFile в unit переопределяет (27 мая, WP-358 Ф8)
- [lessons_n8n_railway_ops.md](lessons_n8n_railway_ops.md) — **HOT:** n8n Railway: CORS обязателен явно + внешний монитор + BetterStack 2 шага + webhook registry только при старте (API activate ≠ reload) (29 мая)
- [lessons_n8n_volume_bloat.md](lessons_n8n_volume_bloat.md) — **HOT:** n8n execution_data bloat: EXECUTIONS_DATA_SAVE_ON_SUCCESS=none обязателен; volume > max_wal_size (1GB); диагностика через pg_database_size + pg_total_relation_size (28 мая)
- [lessons_bash_vs_python_counting.md](lessons_bash_vs_python_counting.md) — **HOT:** bash-pipeline для подсчётов в отчёте → верифицировать `text.count()` в Python; в file-output только Python-числа (28 мая, WP-362 Ф1)
- [lessons_branch_check_before_audit.md](lessons_branch_check_before_audit.md) — **HOT:** перед аудитом репо — `git branch -a` + `git log --all -- <file>`; main часто отстаёт от feature-веток (`staging-v4`), деплой собирает оттуда (28 мая, WP-362 Ф1)
- [lessons_python39_heredoc_utf8.md](lessons_python39_heredoc_utf8.md) — Apple Python 3.9.6 не применяет UTF-8 по умолчанию для stdin heredoc → добавить `# -*- coding: utf-8 -*-` первой строкой (29 мая, server-calendar.sh)
- [lessons_python39_pipe_union_type.md](lessons_python39_pipe_union_type.md) — `X | None` (PEP 604) требует Python 3.10+; fix — `from __future__ import annotations`; stub не покрывает `| None` в самом модуле (1 июня, WP-379 Ф6)
- [lessons_bash32_empty_array_setu.md](lessons_bash32_empty_array_setu.md) — macOS bash 3.2 `${VAR[1]:-}` падает с `set -u` при пустом массиве; guard `${#VAR[@]} -ge N` (29 мая, WP-365 Ф2)
- [lessons_defer_with_explicit_triggers.md](lessons_defer_with_explicit_triggers.md) — governance-паттерн `deferred-with-explicit-triggers`: 6 триггеров + auto-revisit предотвращают masked cancel; terminal для close umbrella-РП (29 мая, WP-150 Ф5/Ф8)
- [lessons_bash_macos_compat.md](lessons_bash_macos_compat.md) — macOS bash: find -printf→stat -f, sed \n→perl -i -pe, for f in $VAR→while IFS= read -r для путей с пробелами (29 мая, WP-356)
- [lessons_anthropic_usage_limit.md](lessons_anthropic_usage_limit.md) — **HOT:** HTTP 400 "usage limits"/"regain access" → AnthropicUsageLimitError, bail-out без retry, dead_letter в queue, log body (29 мая, WP-7)
- [lessons_rsync_flatten_footgun.md](lessons_rsync_flatten_footgun.md) — **HOT:** rsync с multi-file аргументами в директорию-назначение НЕ сохраняет подпапки источника → файлы кладутся плоско в корень; md5-verify обязателен после deploy шаблонов/статики (30 мая, WP-149)
- [lessons_git_add_pipe_exit_masking.md](lessons_git_add_pipe_exit_masking.md) — **HOT:** `git add ... 2>&1 | tail` маскирует exit 128 при несуществующих путях → `&&` идёт дальше → `git commit` захватывает чужие staged-файлы параллельных peer-сессий. Использовать `set -o pipefail` ИЛИ `git status --short` перед commit ИЛИ `git commit -- path1 path2 ...` (30 мая, WP-371 close, commit `12cec1b01` с чужими файлами)
- [lessons_content_verification_type_homogeneity.md](lessons_content_verification_type_homogeneity.md) — **WARM:** ФАЗА C: сверка содержания ≠ чистка прозы; проверять однородность типов в составе понятия (носитель ≠ функция ≠ условие, FPF A.7) + чинить Pack, не только производное; не выдавать форму за содержание (4 июня, WP-362)
- [lessons_deploy_target_verification.md](lessons_deploy_target_verification.md) — **HOT:** перед deploy проверять реальный target через `curl -D - <prod-url>` (заголовок `server`, `x-railway-*`, `x-vercel-*`); локальный systemd unit ≠ прод-канал; `railway.json` в репо = первый сигнал (30 мая, WP-149)
- [lessons_post_migration_pool_target_drift.md](lessons_post_migration_pool_target_drift.md) — **WARM:** после миграции БД на N пулов — verify/keep-alive/create/query на ПРАВИЛЬНОМ пуле (verify-пул==read-пул); бил 3× в @aist_me_bot (crash-loop деплоя, keep-alive не той БД, missing tables). + deploy-FAILED слепое пятно (вотчдог), keep-alive compute≠connections, laptop→Neon непредставителен (4 июня, WP-330)
- [lessons_jinja2_dict_items_collision.md](lessons_jinja2_dict_items_collision.md) — **HOT:** в Jinja2 `dict['items']` при отсутствии ключа `items` falls back в `getattr` → bound `dict.items` метод, `TypeError` при итерации; always-init ключей или `.get('items', [])` (30 мая, WP-149)
- [lessons_google_drive_mcp_oauth.md](lessons_google_drive_mcp_oauth.md) — mcp__ext-google-drive__ и mcp__claude_ai_Google_Drive__ — разные OAuth-сессии; файл одного недоступен другому (29 мая, WP-330)
- [lessons_bot_oauth_native_path.md](lessons_bot_oauth_native_path.md) — перед ручной сборкой OAuth URL — найти нативный путь в бот-меню/Настройки, не только /connect callback chain (30 мая, WP-200 Ф10B)
- [lessons_stage_aware_premature_opt.md](lessons_stage_aware_premature_opt.md) — Stage-зависимые параметры при wave-1 = premature optimization; flat + backward-compat через `mode` параметр чище (31 мая, WP-149 Ф-gap-detector-a)
- [lessons_fmt_skill_needs_active_copy.md](lessons_fmt_skill_needs_active_copy.md) — **WARM:** навык только в FMT-шаблоне ≠ активен для пилота; нужна копия в `~/IWE/.claude/skills/`; sibling [[lessons_fmt_author_script_divergence]] (5 июня, WP-378)
- [lessons_local_maximum_trap_personal_vs_work.md](lessons_local_maximum_trap_personal_vs_work.md) — личное развитие не даёт материала для Паков: нет сигнала «ценно только тебе»; нужно рабочее развитие чтобы видеть чужую деятельность (29 мая, пир-сессия Айлев)
- [lessons_metabase_spike_diagnosis.md](lessons_metabase_spike_diagnosis.md) — Spike в Metabase: backfill = все события за одну секунду + один rule_id; фикс — WHERE activity_domain != 'other' (29 мая)
- [lessons_metabase_app_db_data_placement.md](lessons_metabase_app_db_data_placement.md) — таблицы данных НЕ в app-DB Metabase (MB_DB_DBNAME); мигрировать через \COPY pipe (18 мая, WP-183)
- [lessons_python_vs_bash_literal_expansion.md](lessons_python_vs_bash_literal_expansion.md) — Python не раскрывает `${...}` — литерал; при поиске источника артефактов с именем env-переменной проверять *.py/*.js/*.go, не только bash (29 мая, peer-session cleanup)
- [lessons_macos_timeout_fallback.md](lessons_macos_timeout_fallback.md) — `timeout` не на macOS; hook'и/L1 скрипты требуют fallback `gtimeout` или без timeout, иначе silent failure через `|| echo ""` (30 мая, WP-356 inject-fault-profile.sh)
- [lessons_promote_pipeline_dynamic_verify.md](lessons_promote_pipeline_dynamic_verify.md) — promote-конвейер L3→FMT ловил только static-checks; перед commit в шаблон обязателен dynamic verify (env -i + smoke + JSON validation) — реализация `verify-before-promote.sh` (30 мая, WP-356 подэтап 9)
- [lessons_personal_knowledge_mcp_two_contexts.md](lessons_personal_knowledge_mcp_two_contexts.md) — **HOT:** personal-knowledge-mcp (DS-MCP, Ory) и IWE platform MCP имеют разные user_sources; memorySearch LIMIT 30 не находит файлы в большом репо — фикс через path SQL (3 июня, WP-391)
- [lessons_n8n_api_drops_langchain_connections.md](lessons_n8n_api_drops_langchain_connections.md) — **HOT:** n8n public API GET не отдаёт `ai_languageModel` связи → GET→PUT round-trip молча рвёт LLM-граф (webhook 200 + 0 байт); PUT слать полный connections с langchain-типами, verify по webhook не по readback (4 июня, hw-checker fast-path)
- [lessons_python_triple_quote_sql_trap.md](lessons_python_triple_quote_sql_trap.md) — **HOT:** Python `'''SELECT ... != '''''` парсер пожирает empty-string literal `''` как часть закрытия → SQL обрывается на `!= ` без значения → PostgresSyntaxError; AST passed но runtime crashed. Fix: `length(col) > 0` вместо `!= ''`. Verification: AST inspect string value (не синтаксис кода). Bot crash 1 июня в Block GTW (1 июня, WP-7 GTW hotfix `a5e5662`)
- [lessons_umbrella_child_threshold_drift.md](lessons_umbrella_child_threshold_drift.md) — **HOT:** зонтик описывает старый порог gate, дочерний РП передвинул за день-два → формулировка устаревает в часах. Митигация: split (pointer-only + conditional-on) + bidirectional guard + sync в 3 местах (summary/таблица/closing). 2 случая подряд 30 мая (WP-364 Развилки 3a, 4a)
- [lessons_inbox_actualization_anchor.md](lessons_inbox_actualization_anchor.md) — актуализация >5 связанных Inbox-файлов = сначала найти якорный документ (свежий master-РП); статусы зависимых = derived (29 мая, peer-сессия 12)
- [lessons_parallel_session_staged_capture.md](lessons_parallel_session_staged_capture.md) — **WARM:** параллельная сессия захватывает staged git rm/mv через `git add -u`; обнаружить по `git show HEAD --name-status` (4 июня, audit current/)
- [lessons_kimi_adapter_tmp_collision.md](lessons_kimi_adapter_tmp_collision.md) — **HOT:** `/tmp/kimi-prompt-turn*.txt` без сессионного суффикса = коллизия; Kimi ответит чужой репликой; имя файла обязано содержать SESSION_ID (30 мая, peer-сессия 11)
- [lessons_parallel_peer_sessions_same_file.md](lessons_parallel_peer_sessions_same_file.md) — параллельные peer-сессии в одном файле: `git add <file>` захватывает чужие unstaged функции; coordinate через комментарии-маркеры или `git stash --keep-index` (30 мая, WP-318 + WP-370)
- [lessons_gateway_mcp_timeout_circuit_breaker.md](lessons_gateway_mcp_timeout_circuit_breaker.md) — **WARM:** `GATEWAY_MCP_TIMEOUT=3` + Railway cold start (Hermes ~10-25s) = circuit breaker за 6с блокирует все MCP-вызовы; нужен per-tool timeout (5 июня, WP-392)
- [lessons_content_session_velocity.md](lessons_content_session_velocity.md) — контент-peer-сессия 28 текстов = 20-30 мин фактически, не 3h план; фикс шаблон + cold-review subagent даёт 6-10× оборот (30 мая, С7/С8)
- [lessons_routing_connect_all_callsites.md](lessons_routing_connect_all_callsites.md) — **HOT:** routing-функция должна быть подключена ко ВСЕМ prod-callsites; 35 PASS unit-тестов не покрывают integration; cold-review критичен ДО deploy (31 мая, WP-330 С9a Critical #1)
- [lessons_factual_db_check_before_migration.md](lessons_factual_db_check_before_migration.md) — **HOT:** ДО migration script — factual SELECT в реальную БД; handoff mapping plan может быть полностью no-op; Railway PG external через `DATABASE_PUBLIC_URL` proxy (31 мая, WP-330 С9b escalation-00)
- [lessons_marp_visual_iteration_timebox.md](lessons_marp_visual_iteration_timebox.md) — Marp PDF: 3+ итерации redesign без видимого эффекта = drastically change layout или удалить слайд; subtle tweaks под порогом восприятия в Chromium PDF (31 мая, WP-351 v3.3→v3.6)
- [lessons_scope_arg_schema_mismatch.md](lessons_scope_arg_schema_mismatch.md) — scope guard должен проверять arg-schema каждого tool: `personal_propose_capture` использует `suggested_source`/`suggested_path`, не `source`/`path`; catch-блок "fail-open" требует `available` флага (1 июня, WP-381)
- [lessons_gh_label_query_and_or.md](lessons_gh_label_query_and_or.md) — **HOT:** `gh issue list --label "X,Y"` = AND, не OR (то же у REST API `?labels=`); для OR — отдельные запросы + Python merge с dedup (1 июня, WP-386 hardening)
- [lessons_composite_trigger_human_in_loop.md](lessons_composite_trigger_human_in_loop.md) — composite-триггер «когда подключать человека к LLM-автоматике» = engagement drop + task-stuck + bh-trend (AND, не OR) + escalation chain self-booking 24ч → auto-booking 48ч с pre-read + obligatory opt-in (1 июня, WP-385/WP-330)
- [lessons_pre_textcontent_strips_html.md](lessons_pre_textcontent_strips_html.md) — **HOT:** `<pre>{{content|safe}}</pre>` + `marked.parse(textContent)` несовместим с HTML-контентом; теги стрипаются → стена текста на проде. Перед approve «return HTML» — читать JS-pipeline ПОЛНОСТЬЮ + visual smoke в браузере, не только curl (1 июня, WP-329 регрессия + revert)
- [lessons_grep_counter_narrative_false_positive.md](lessons_grep_counter_narrative_false_positive.md) — **HOT:** counter exemption-тегов по `git log --grep` ловит narrative-упоминания в body; subject-only через `--pretty='%s'` + `grep -cF` (1 июня, WP-7 guard counter)
- [lessons_headless_bridge_empty_output_guard.md](lessons_headless_bridge_empty_output_guard.md) — headless-bridge (adapter/MCP-proxy/CLI-wrapper) должен fail-loud при empty output: silent exit 0 = false-green в N-step pipeline (1 июня, peer-session 2026-06-01-20)
- [lessons_script_promote_changelog_flush_ordering.md](lessons_script_promote_changelog_flush_ordering.md) — release-flow: все promote → правки → flush. Promote после flush регенерирует [Unreleased] с теми же коммитами (1 июня)
- [lessons_git_stash_parallel_peer_recovery.md](lessons_git_stash_parallel_peer_recovery.md) — stash как safe net для параллельной peer-работы при чужом merge; перед `reset --hard` всегда `stash list` (1 июня, Kimi work recovery)
- [lessons_pre_commit_grep_catches_comments.md](lessons_pre_commit_grep_catches_comments.md) — pre-commit grep ловит хардкоды и в комментариях; валидатор должен исключать `#`-строки, иначе документация ломает commit (1 июня)

### Lessons — HOT (17-25 мая)

> Архив уроков 12-20 мая: [lessons-may-2026.md](archive/lessons-may-2026.md).

- [lessons_postgres_date_at_time_zone_footgun.md](lessons_postgres_date_at_time_zone_footgun.md) — **HOT:** `(...)::date AT TIME ZONE 'zone'` = двойная конвертация → сдвиг границы суток (+6ч); фикс `date_trunc('day',...)`. Причина DAU=0 в pulse-отчёте (не event-gateway). Не сравнивать календарный счётчик vs скользящее окно (4 июня, peer-session bot-dau-zero)
- [lessons_chrome_insecure_valid_cert.md](lessons_chrome_insecure_valid_cert.md) — Chrome «Не защищено» + «✅ Действительный сертификат» одновременно = local browser state (расширение/Google sync/антивирус), не сервер; incognito test разводит (30 мая, WP-355 Ф18.7)
- [lessons_ory_issuer_trailing_slash.md](lessons_ory_issuer_trailing_slash.md) — **HOT:** Ory Hydra iss=...hydra/ со слешем, JWT verify exact-match; сервис должен принимать оба варианта (30 мая, WP-201 Ф3.5)
- [lessons_llm_prompt_scope_injection.md](lessons_llm_prompt_scope_injection.md) — **HOT:** инжектить allowed_repos/allowed_paths в LLM-промпт, иначе LLM галлюцинирует owner; enforce_scope = вторая линия защиты (30 мая, WP-201 Ф3.5)
- [lessons_idempotency_hash_fallback.md](lessons_idempotency_hash_fallback.md) — idempotency_key default = SHA-256(fingerprint), не random UUID; иначе retry создаёт N runs (30 мая, WP-201 Ф3.5)
- [lessons_webhook_auto_provision.md](lessons_webhook_auto_provision.md) — webhook installation_repositories.added → fan-out на ВСЕ per-repo сервисы через fire-and-forget; manual SQL для пилота = блокер масштабирования (30 мая, WP-201 Ф4)
- [lessons_anthropic_prompt_caching_pattern.md](lessons_anthropic_prompt_caching_pattern.md) — **HOT:** prompt caching = PREFIX/BODY/TAIL разделение + cache_control:ephemeral; `${var}` вместо `{var}` для prompts с литеральным JSON; маркеры НЕ-format-friendly (===CACHE_BOUNDARY===, не `{{}}`) (30 мая, WP-375)
- [lessons_strategist_prompt_gaps.md](lessons_strategist_prompt_gaps.md) — **HOT:** 2 пробела промпта Стратега agent-runner — (1) destructive rewrite Strategy.md вместо append (теряет H1 + старые записи), (2) галлюцинированная дата (нет инжекции `${today_iso}`). Без фикса каждый пилот теряет историю Strategy.md после 2 запусков (31 мая, WP-375 verification fallout)
- [lessons_preexisting_fails_dont_defer_blindly.md](lessons_preexisting_fails_dont_defer_blindly.md) — **HOT:** «pre-existing fails» в репо ≠ автоматически TD; 5 мин root-cause diagnose ДО defer; 3 fails gateway-mcp оказались 1-line PEM header mismatch (30 мая, WP-201 post-review)
- [lessons_fdw_hidden_dependency.md](lessons_fdw_hidden_dependency.md) — **HOT:** cross-schema SQL (learning.*) через Railway Postgres пул = зависимость от FDW; фикс — app-side join через get_learning_pool() (31 мая, WP-330)
- [lessons_marp_image_svg.md](lessons_marp_image_svg.md) — Marp: `<img max-height>` в CSS grid игнорируется → `![bg ...]` директивы; SVG/inline-style без `html: true` рендерятся как plain text (29 мая, WP-351)
- [lessons_layered_guard_masks_missing_fix.md](lessons_layered_guard_masks_missing_fix.md) — **HOT:** фикс применён к N-1 из N однотипных call-site, пропущенный named-пункт «работал» только из-за второго защитного слоя (permission default) → false-green; verify каждый call-site (grep весь файл) и каждый слой отдельно (3 июня, WP-393 ревью синтеза 4.2)
- [lessons_wp327_v44_apply.md](lessons_wp327_v44_apply.md) — **HOT:** flag активация ≠ обновление функции; config без эмиттера = invisible bug; FDW-схема; projection_rules обязателен (reward_rules недостаточно); is_marker=true → v_base=1.0 баг (28 мая)
- [lessons_wp327_qual_mult_level1.md](lessons_wp327_qual_mult_level1.md) — **HOT:** qualification_levels_v4 level=1 → qual_mult=0; constraint `> 0` блокирует level 1 users → DLQ (28 мая)
- [lessons_multiplier_peer_sessions_uncounted.md](lessons_multiplier_peer_sessions_uncounted.md) — **HOT:** Day Close мультипликатор — перечислить ВСЕ peer-сессии из `sessions/00-index.md`; не использовать 0.25h как заглушку для ad-hoc с 14-ю ходами; 3 метода расчёта показать пилоту (27 мая)
- [lessons_idle_stall_layered_defense.md](lessons_idle_stall_layered_defense.md) — **HOT:** эшелонированная защита asyncio listener'ов от idle-stall — 5 слоёв (driver timeout + heartbeat + per-event wait_for + periodic replay + idempotency contract); один слой ≠ защита (27 мая, peer-session mdpw)
- [lessons_asyncio_shield_vs_command_timeout.md](lessons_asyncio_shield_vs_command_timeout.md) — asyncio.shield не нужен при command_timeout + periodic replay; shield добавляет конкурентность cursor_cache без пользы (28 мая)
- [lessons_marathon_stop_partial_cleanup.md](lessons_marathon_stop_partial_cleanup.md) — **HOT:** /stop команды должны чистить ВСЁ состояние объекта, не только часть; иначе наследство при перезапуске блокирует counters (27 мая, WP-330 Ф8.2)
- [lessons_marathon_state_vs_delivery.md](lessons_marathon_state_vs_delivery.md) — marathon_state = журнал откликов пользователя (нажатие кнопки), НЕ доставки; доставка = marathon_queue.status (2 июня, WP-330)
- [lessons_infra_fix_coverage_smoke.md](lessons_infra_fix_coverage_smoke.md) — **HOT:** перед коммитом в auto-commit/watchdog/sync — smoke на coverage всех writer'ов (git log --name-only --since=14d + git status --porcelain); concurrent writers должны учитываться в threshold-логике (30 мая, WP-7 WD). **Third level (30 мая, WP-7 RP):** VOLATILE-функция в VALUES UPSERT + AFTER trigger cascade → PG-21000 «cannot affect row a second time»; runtime gate в loader projection rules (RPA1)
- [lessons_iterative_production_diagnosis.md](lessons_iterative_production_diagnosis.md) — **WARM:** infra fix «навсегда» может быть полу-решением; short smoke-loop (2-3 мин логов после deploy); cascade bug exposed только когда первая блокада снята (30 мая, WP-7 RP, 5 deploys)
- [lessons_spin_off_secondary_index_sync.md](lessons_spin_off_secondary_index_sync.md) — **WARM:** spin-off РП через create-wp.sh регистрирует child в 4 первичных местах; ещё 5 вторичных индексов sync вручную (parent's direction-таблица, «Связки с РП», бюджет недели, reverse-pointer source-РП, linear_id в frontmatter). 4/5 пропущены в WP-374, найдено cold-context аудитом (30 мая, peer-session 46)
- [lessons_pilot_first_violation_detection.md](lessons_pilot_first_violation_detection.md) — **HOT:** перед runtime-проверкой fix-а на pilot-боте — `git branch --contains <fix-sha>` (27 мая, WP-330)
- [lessons_dry_run_skip_side_effects.md](lessons_dry_run_skip_side_effects.md) — `--dry-run` пропускает existence-checks внешних артефактов; иначе pre-commit гейт ловит false-positive (29 мая, WP-347 PD-2 follow-up)
- [lessons_migration_owner_pattern.md](lessons_migration_owner_pattern.md) — **HOT:** bot_admin не owner таблиц development.*; ALTER TABLE падает; fix: OWNER TO bot_admin + current_user паттерн (25 мая)
- [lessons_calendar_pipeline_design.md](lessons_calendar_pipeline_design.md) — WP-357: 7 паттернов конвейера дат (generated ledger, A/B-класс, dual-mode watchdog, no Claude-headless, digest, +stdin против injection, +календарь через MCP)
- [lessons_ory_scope_config.md](lessons_ory_scope_config.md) — ORY client: scope'ы фиксированы при создании; `email` может быть не разрешён; sub-based lookup достаточен (26 мая, WP-355)
- [lessons_ory_redirect_uri.md](lessons_ory_redirect_uri.md) — ORY OAuth: redirect_uri = фиксированный GUIDE_PUBLIC_URL, не request base URL — иначе token exchange mismatch (28 мая, WP-355)
- [lessons_discourse_user_actions_endpoint.md](lessons_discourse_user_actions_endpoint.md) — Discourse: `posts.json?username=X` игнорирует фильтр; правильный — `user_actions?filter=5` (25 мая, WP-353)
- [lessons_classifier_pattern_coverage.md](lessons_classifier_pattern_coverage.md) — pattern rule в classifier → сначала grep всех callback_data, иначе nav-колбэки маскируются как heavy (25 мая)
- [lessons_multiplier_missing_days.md](lessons_multiplier_missing_days.md) — **HOT:** dt-collect пропускает дни без «Бюджет закрыт»; Week Close: проверить 7 дней вручную ДО dt-collect (25 мая)
- [lessons_cf_worker_jwt_pkcs8.md](lessons_cf_worker_jwt_pkcs8.md) — `wrangler secret put` с PKCS#8 ключом при коде под PKCS#1 regex → silent write-path breakage 18ч (22 мая)
- [lessons_dormant_bug_adjacent_fix.md](lessons_dormant_bug_adjacent_fix.md) — adjacent-fix оживляет дремлющий баг; после CI-fix re-run full smoke, prior-green не валиден (22 мая)
- [lessons_subagent_timeout_pack_extraction.md](lessons_subagent_timeout_pack_extraction.md) — **HOT:** background-субагенты падают на 10-мин timeout при >5 файлов; дробить ≤3 файла за раз (18 мая)
- [lessons_peer_agent_optimistic_reports.md](lessons_peer_agent_optimistic_reports.md) — **HOT:** peer-агент даёт оптимистичные отчёты с расхождениями; главный агент верифицирует механически (19 мая)
- [lessons_peer_session_read_wp_first.md](lessons_peer_session_read_wp_first.md) — **HOT:** перед peer-сессией по родительскому РП — читать `inbox/WP-N-*.md` ДО составления гипотез (27 мая)
- [lessons_rule_propagation_check.md](lessons_rule_propagation_check.md) — блокирующее правило → 4 точки propagation (Pack/чек-лист/design doc/AR-правило); migration pattern (17 мая)
- [lessons_mass_migration_overrides_choice.md](lessons_mass_migration_overrides_choice.md) — mass-migration без pre-check на пользовательский выбор (sovereign-привязка) = silent overwrite; класс «derived writers ломают user choice» (30 мая, WP-7 OPCH)
- [lessons_event_gateway_owner_integrity.md](lessons_event_gateway_owner_integrity.md) — learning.domain_event = single writer (DP.ROLE.032); эмиттеры через `helpers/dual_write.post_event()`, НЕ direct INSERT (17 мая)
- [lessons_ccr_git_push_credentials.md](lessons_ccr_git_push_credentials.md) — CCR-агент не имеет git credentials по умолчанию; fix: `gh auth setup-git` + fallback `GH_TOKEN` (17 мая)
- [lessons_temporal_fallback_routing.md](lessons_temporal_fallback_routing.md) — **HOT:** Карта-derived routing = temporal fallback; легитимация через 4 условия; на малых масштабах — явный result_location (17 мая)
- [lessons_honcho_scope_creep.md](lessons_honcho_scope_creep.md) — memory-провайдер (Honcho) нельзя расширять на детерминированные системы; только cp.wld/agt/awr (17 мая)
- [lessons_event_gateway_writer_gotchas.md](lessons_event_gateway_writer_gotchas.md) — **HOT:** 4 грабли writer-pipeline event-gateway→projection (jq falsy, git log newline, cursor out-of-order, PII bypass) (17 мая)
- [feedback_agent_inbox_chat_pattern.md](feedback_agent_inbox_chat_pattern.md) — **HOT:** Agent Inbox через чат — sync в сессии / async через dispatcher. НЕ заставлять заполнять YAML (17 мая)
- [lessons_static_sql_path_casts.md](lessons_static_sql_path_casts.md) — **HOT:** в static SQL cast по семантике path ($.account_id→::uuid); PG не auto-cast'ит text→typed (17 мая)
- [lessons_listener_idle_heartbeat.md](lessons_listener_idle_heartbeat.md) — **HOT:** lag-метрика молчит в idle; нужна unconditional alive-heartbeat в poll-loop (17 мая)
- [lessons_close_protocol_spec_pack_drift.md](lessons_close_protocol_spec_pack_drift.md) — Quick Close с PASS не гарантирует реализацию артефакта; явная сверка `git log --stat` по target (17 мая)
- [lessons_peer_adapter_session_diff.md](lessons_peer_adapter_session_diff.md) — **WARM:** kimi-peer-adapter always-on передаёт Kimi git-diff сессии (WP-383); opt-in для агентских фич = хрупко (4 июня)
- [feedback_checklist_validator_drift.md](feedback_checklist_validator_drift.md) — **HOT:** новое 🔴-правило ОБЯЗАНО иметь парный код-FAIL в валидаторе в том же коммите (17 мая)
- [lessons_memory_six_slots_outdated.md](lessons_memory_six_slots_outdated.md) — **HOT:** «6 mandatory-слотов cp.*» — упрощение; актуально: 13 cp-срезов + 7 bh + 8 характеристик выпускника (17 мая)
- [lessons_two_cursors_two_workers.md](lessons_two_cursors_two_workers.md) — **HOT:** при N воркерах cursor живёт в N разных БД; decommission без проверки downstream = false-green (17 мая)
- [lessons_test_dont_assume_permissions.md](lessons_test_dont_assume_permissions.md) — **HOT:** перед «не могу X» делать smoke-test (gh auth status / curl POST); эскалация после ошибки 4xx/5xx (17 мая)
- [feedback_finish_now_no_defer.md](feedback_finish_now_no_defer.md) — **HOT:** дефолт = довести до конца в текущей сессии; choice question «сейчас или потом» — анти-паттерн (17 мая)
- [lessons_spec_impl_completeness_gap.md](lessons_spec_impl_completeness_gap.md) — два линтера (spec + impl) не дают cross-check «объявлено vs реализовано»; нужна третья команда completeness (19 мая)
- [lessons_hook_relative_paths_vscode_freeze.md](lessons_hook_relative_paths_vscode_freeze.md) — хуки с относительными путями в settings.json → Unhandled case + зависание сессии (20 мая)
- [lessons_kimi_extraction_audit.md](lessons_kimi_extraction_audit.md) — **HOT:** 5 паттернов косяков bulk-extraction Kimi + системный фикс M-RM-промпта (5 pre-checks в DP.SC.150) (20 мая)
- [lessons_kimi_model_ids.md](lessons_kimi_model_ids.md) — Кими путает model ID Claude 4-серии с форматом Claude 3 (date-based); верифицировать через system-reminder (27 мая)
- [lessons_apply_to_contract_drift.md](lessons_apply_to_contract_drift.md) — **HOT:** новое поле выхода Портного должно одновременно меняться в 3 точках (prompt.md контракт + live build_system_prompt + output parser); иначе non-functional (29 мая, WP-364 Развилка 1)
- [lessons_scheduler_retry_contract.md](lessons_scheduler_retry_contract.md) — retry-aware функции должны возвращать `True` (deferred), не вызывать `_schedule_retry()` внутри → infinite loop (24 мая)
- [lessons_pg_drop_column_view_deps.md](lessons_pg_drop_column_view_deps.md) — DROP COLUMN на проде → проверка pg_depend ДО миграции; если есть view — bundle DROP VIEW + DROP COLUMN + CREATE VIEW в одной транзакции (29 мая)

### User (личный профиль)

- [user_background.md](user_background.md) — мех-мат МГУ, математик+методолог+экзоскелет (не физик, не МФТИ)
- [user_mission_core.md](user_mission_core.md) — корневой мотив: познание Вселенной через развитие интеллекта
- [user_identifiers.md](user_identifiers.md) — Telegram ID, Ory UUID, ИП/ООО

- **WP-200 + WP-201 закрыты** (30 мая, peer-session 2026-05-30-44): observability gap fix (user_source enum + request_id + fire-and-forget INSERT в proxy_calls), bridge VS Code↔Aisystant MCP с refresh-flow, live OAuth + ЦД smoke 21:30 МСК (integral_index 96.2, stage 4 Проактивный). Контекст-файлы → archive/wp-contexts/. WP-373 (scope-контроль personal_write) заведён как follow-up.
- [lessons_railway_proxy_streaming.md](lessons_railway_proxy_streaming.md) — Railway: stream=True несовместим с sync proxy; startCommand не интерполирует $PORT (19 мая)
- [lessons_railway_custom_domain_dns.md](lessons_railway_custom_domain_dns.md) — Railway SSL stuck VALIDATING_OWNERSHIP: fix = customDomainDelete+customDomainCreate при уже настроенных DNS; DNS не трогать (29 мая)
- [lessons_railway_guide_public_url.md](lessons_railway_guide_public_url.md) — «Не защищено» при валидном SSL = mixed content из-за отсутствия GUIDE_PUBLIC_URL (http:// ссылки в HTML) (29 мая)

### Project (контекст инициатив)

- [project_team_roles.md](project_team_roles.md) — Андрей/Паша/Дима/Ильшат/Олег
- [project_domain_name.md](project_domain_name.md) — «Системное созидательство» (v0.1, 21 апр)
- [project_iwe_tiers.md](project_iwe_tiers.md) — T1 Наблюдатель / T2 Практикующий / T3 Ведомый / T4 Деятель; T3a тайный гит / T3b явный гит (WP-342, 22 мая)
- [project_iwe_arch_strategy.md](project_iwe_arch_strategy.md) — новая арх (платформа+IWE, 12 Neon БД) vs старая (LMS монолит)
- [project_iwe_systems_map.md](project_iwe_systems_map.md) — карта систем Aisystant (3 уровня S2R + 12 C2 + 15 Q2 + 4 оси WP-250); опора для `/bottleneck-pick` (WP-313)
- [project_persona_memory_context.md](project_persona_memory_context.md) — Персона/Память/Контекст (3 слоя)
- [project_iwe_positioning.md](project_iwe_positioning.md) — 5 компонент, слоган
- [project_community_iwe.md](project_community_iwe.md) — сообщество, воронка
- [project_ilshat_handover.md](project_ilshat_handover.md) — WP-281: передача менеджмент+поддержка → Ильшат (3 фазы, →1 сент)
- [project_inga_ux_designer.md](project_inga_ux_designer.md) — Инга, UX
- [project_peer_agents.md](project_peer_agents.md) — Kimi подключён 12 мая: config, разделение задач, git attribution (WP-150)
- [project_managed_personal_guide.md](project_managed_personal_guide.md) — managed-канал доставки руководств
- [project_iwe_business_models.md](project_iwe_business_models.md) — топ-3 модели (Pro-tier SaaS / сертификация / marketplace); класс ≈ Obsidian + Anki + Red Hat (22 мая)
- [project_wp316_text_sources.md](project_wp316_text_sources.md) — WP-316: источники текста (LMS ДЗ > клуб > репо); ArchGate 18 мая вариант B (18 мая)
- [project_wp121_phase2_state.md](project_wp121_phase2_state.md) — WP-121 Ф2 после сноса: карта Neon БД (learning/reference/rewards), gap в rewards-projection-worker

### Reference (внешние системы)

- [reference_ory_hydra_gateway.md](reference_ory_hydra_gateway.md) — OAuth/JWT/Ory
- [reference_neon_connections.md](reference_neon_connections.md) — pooled/unpooled, pg_dump
- [reference_github_repos.md](reference_github_repos.md) — URLs
- [reference_lms_db.md](reference_lms_db.md) — LMS таблицы
- [reference_alexey_code.md](reference_alexey_code.md) — код-ревью
- [reference_ds_ecosystem_operations.md](reference_ds_ecosystem_operations.md) — runbooks
- [reference_cloudflare_workers.md](reference_cloudflare_workers.md) — CF Workers, wrangler
- [reference_railway_token.md](reference_railway_token.md) — Railway API
- [reference_gcp_oauth_audience.md](reference_gcp_oauth_audience.md) — GCP OAuth
- [reference_video_locations.md](reference_video_locations.md) — видео
- [reference_post_drafts.md](reference_post_drafts.md) — `~/IWE/DS-my-strategy/drafts/` D-NNN драфты постов
- [reference_fpf_quint_code.md](reference_fpf_quint_code.md) — agentic RAG, FPF-паттерны, CodeAlive
- [reference_railway_postgres_after_cutover.md](reference_railway_postgres_after_cutover.md) — Railway-local Postgres `bot_data` (ory_tokens, dt_tokens) post-WP-268
- [distinctions-warm.md](distinctions-warm.md) — авторские различения warm: MCP/Gateway, БД/архитектура, PII, CF, ЛР/РР, Pack
- [reference_gdrive_sync.md](reference_gdrive_sync.md) — **ПЕРВЫМ при Upload/Drive**: `DS-MCP/google-drive-mcp/gdrive-sync.py` + `sync-config.json`; OAuth, не сервисный аккаунт
- [reference_club_api.md](reference_club_api.md) — Discourse API клуба systemsworld.club; токен `~/.secrets/club_api_token`
- [reference_dp_d053.md](reference_dp_d053.md) — DP.D.053 (4-уровневое различение Problem→Task→Form→Work) с примерами (WP-282)
- [reference_betterstack_api.md](reference_betterstack_api.md) — BetterStack API endpoints, токены, мониторы + статус-страница (14 мая)
- [reference_token_registry.md](reference_token_registry.md) — реестр GitHub Secrets по репо: даты обновления, TTL, reminder IDs (20 мая)
- [reference_kimi_config.md](reference_kimi_config.md) — `~/.kimi/config.toml`: extra_skill_dirs + merge_all_available_skills (22 мая)
- [agent-architecture-framework.md](agent-architecture-framework.md) — Трёхслойная архитектура IWE: LLM / Агент / Роль; Универсальный vs Специализированный; Два каталога (25 мая)
- [lessons_n8n_chainllm_vs_agent.md](lessons_n8n_chainllm_vs_agent.md) — n8n chainLlm vs ReAct agent: для JSON-ответа LLM нужен chainLlm, не agent (WP-354, 25 мая)
- [lessons_rule_needs_detector_not_just_checklist.md](lessons_rule_needs_detector_not_just_checklist.md) — **WARM:** декларативное правило не исполняется само; нужен детектор (сильнее) или чек-пункт; тест «забудут — узнают?» (4 июня, WP-387 peer-28)
- [project_lms_homework_checker_status.md](project_lms_homework_checker_status.md) — LMS Проверяльщик ДЗ не задеплоен; два сервера: LMS=213.139.211.118, IWE=95.216.75.148; Railway endpoint готов (25 мая)
- [lessons_wp_phase_list_verify_before_impl.md](lessons_wp_phase_list_verify_before_impl.md) — **WARM:** пункты Ф-фаз карточки РП проверять против кода/прода до реализации (WP-368 Ф6: 3/5 оказались no-op/мисатрибуция); learning.X в комментах = таблица в learning-БД, схема public (4 июня)
