# Оперативная память

> **Инструкции:** `~/IWE/CLAUDE.md` | **Навигация:** `memory/navigation.md` | **Source-of-truth:** `DP.EXOCORTEX.001`
> **Слои:** L1 = платформа. L2 = staging. L3 = авторское.

## БЛОКИРУЮЩИЕ (проверяй ВСЕГДА)

1. **WP Gate:** ⛔ Первое действие на ЛЮБОЕ задание = `Read memory/protocol-open.md`. Без исключений.
2. **Close:** ⛔ «закрывай» / «всё» = `Вызвать Skill: run-protocol, аргумент: close`. Без исключений.
3. **ArchGate ≥8:** Архитектурное → СНАЧАЛА ЭМОГССБ → ПОТОМ решение.
4. **Repo-Touch Gate:** Первое действие в любом репо → прочитать `<repo>/CLAUDE.md`. Если есть блок «ОБЯЗАТЕЛЬНО ЗАГРУЖАЙ» — загрузить указанные файлы ДО ответа.

## ВАЖНЫЕ (на рубежах)

5. **Capture:** На рубеже → «Capture: X → Y»
6. **Процессы:** Без PROCESSES.md не реализовывать
7. **Гигиена inbox:** Close архивирует done-WP сразу. Session-Prep — широкая очистка.
8. **Модели:** Opus=open-loop. Sonnet=closed-loop. Haiku=trivial. Делегирование только вниз.
9. **Шапки индексов = индекс, не changelog.** MEMORY.md / WP-REGISTRY.md / прочие реестры — только hook-строки. Changelog → `*-changelog.md`. Статус РП → WeekPlan + inbox. Детектор: `check-index-health.py` в Day Close § 4в. → [feedback_memory_index_discipline.md](feedback_memory_index_discipline.md)

---

## Текущая работа

> **Источник статуса РП:** `DS-my-strategy/current/WeekPlan W{N}.md` + `DS-my-strategy/WP-REGISTRY.md` + `DS-my-strategy/current/inbox/WP-NNN-*.md`.
> В MEMORY.md статус РП НЕ хранится (дубликат). Открыть WeekPlan = точка старта сессии.

## 4-уровневое различение: Проблема ≠ Задача ≠ ФР ≠ Работа (→ HD #24, DP.D.053, WP-282 ✅ 1 май)

> **Главный навык эпохи ИИ:** конвертировать Проблему в Задачу через системное моделирование.
> Проблема = ступор (метод неясен) → Задача = метод известен → Формулировка работы = спецификация → Работа = физ.реальность.
> ИИ-автопилот ускоряет Задача→Работа. ИИ-экзоскелет помогает Проблема→Задача (DP.D.046). Дополнительно: `hard-distinctions.md § HD #24`.

## Модель пользовательских данных: Персона / Память / Контекст (→ HD #27, DP.D.052)

> Заменяет «ЦД» как монолитную сущность. Критерий слоя = **writer + owner**.
> **Персона** (writer = пользователь, owner = его Git): PACK-personal, DS-my-strategy, captures, preferences.
> **Память** (writer = платформа, owner = Neon): события (activity-hub #3), платежи (#4), расчёты/baseline/indicators (#5 — бывший узкий ЦД), подписки-контракты (#1). Под-уровни: Observed (события) + Derived (агрегаты).
> **Контекст** (runtime, не хранится): промпт-сборка под LLM-вызов.
> **Правило замены ЦД:** расчётный профиль → Память.Derived (85%); декларация о себе → Персона (10%); окно LLM → Контекст (5%).

## Бот: деплой

| Бот | Ветка | Railway | Env |
|-----|-------|---------|-----|
| @aist_me_bot (прод) | `new-architecture` | `aist_bot_newarchitecture` | Neon |
| @aist_pilot_me (пилот) | `pilot` | `aist_bot_newarchitecture` | Railway Postgres |

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

<!-- ACTIVE-WP-START -->

### 🔄 Активные РП (sweep по inbox/WP-*.md)

| РП | Последний коммит (7д) |
|----|---------------------------------|
| **WP-114** Claude Partner — исследование партнёрской программы Anthropi | нет (7д) |
| **WP-117** Развитие nudge-системы — расширение правил, все тиры, ЦД-пер | dcb445c2 feat: WP-290 Следователь — система каузальной  |
| **WP-121** Правила начисления баллов за активность — правила + реализац | b437c6c6 day-plan: 6 мая 2026 — расширенный план + WP-2 |
| **WP-132** WP-132-autonomous-night-agents | нет (7д) |
| **WP-140** Windows-совместимость IWE | нет (7д) |
| **WP-144** Управление заданиями агентов (research-tasks) | нет (7д) |
| **WP-149** Система генерации персональных руководств | dcb445c2 feat: WP-290 Следователь — система каузальной  |
| **WP-151** Характеристики и состояния деятеля — от модели к измерению | dcb445c2 feat: WP-290 Следователь — система каузальной  |
| **WP-155** Конвейер публикаций ContentPipeline | 04412926 docs: WP-155 Editorial Ф + S-37 Редактор конте |
| **WP-164** Персональное руководство по ZP для семьи (Денис) | нет (7д) |
| **WP-167** Публикации — зонтичный РП контент-конвейера | 1e911e06 close(WP-167): Quick Close — сессия 4 мая, пос |
| **WP-171** WP-171-hw-checker-v2-async | 36686a9b docs(WP-171): обновить Осталось — handoff посл |
| **WP-183** CRM как система | нет (7д) |
| **WP-185** Google Drive MCP + DocSend — экспорт документов и аналитика  | нет (7д) |
| **WP-188** Первая когорта + IWE лендинг (Ф15a system-school.ru/iwe — завтра) | d4ef79ac docs(WP-188): Ф15a структура лендинга из исследования |
| **WP-190** Анализ прецессионных центрифуг — SOTA, стартап, коммерциализ | нет (7д) |
| **WP-199** UX бота и пользовательских интерфейсов платформы | 1947dda fix: маршрутизация задач T001-T049 — исправлени |
| **WP-202** Зрелость IWE-шаблона для внешнего мира | нет (7д) |
| **WP-203** Оркестратор SC.020 -- управление циклом развития | 9cf5740d docs: связки между незакрытыми РП (10 пар) |
| **WP-206** Исследование многозадачности | нет (7д) |
| **WP-207** Гарантированный handoff между сессиями | 9cf5740d docs: связки между незакрытыми РП (10 пар) |
| **WP-211** Стилистический эталон письма автора | нет (7д) |
| **WP-212** Программа безопасности продуктов | 0e37b77a WP-212: Quick Close handoff — «Осталось» 29 ап |
| **WP-214** Концепция учёта персональных данных в IWE | 0fc1e2e6 docs(WP-214): Ф10 сессия 2 — MULT_JSON fix    |
| **WP-215** Концепция разделения инфраструктуры Россия и мир | 934552b2 feat: WP-285 Международная инфраструктура Trac |
| **WP-231** Реестр подписок | 9cf5740d docs: связки между незакрытыми РП (10 пар) |
| **WP-232** Консолидация баз Neon → platform | нет (7д) |
| **WP-237** Audit trail для финансовых таблиц (compliance 7 лет) | нет (7д) |
| **WP-292** Бренд IWE: имя продукта и Brand Compendium | a8afcfc WP-292 Ф1: 01-foundations.md — Brand Foundations |
| **WP-244** Наблюдаемость платформы (Platform Observability) | 209854c2 docs(WP-73): актуализация контекст-файла — 30  |
| **WP-245** Анализ падения ступени: механика M1/M4, раннее предупреждени | 097922ac WP-196 Ф14: трекер lifework-рекомендаций + WP- |
| **WP-245** Программа личного развития | 097922ac WP-196 Ф14: трекер lifework-рекомендаций + WP- |
| **WP-246** Архитектура прямых платежей (все каналы → Neon) | нет (7д) |
| **WP-250** План развития до конца 2026 | b437c6c6 day-plan: 6 мая 2026 — расширенный план + WP-2 |
| **WP-253** WP-253 Legacy `platform` БД audit — что осталось, чтобы DROP | dcb445c2 feat: WP-290 Следователь — система каузальной  |
| **WP-253** Master Roadmap — DROP `platform` БД (от 28 апр до Q3) | dcb445c2 feat: WP-290 Следователь — система каузальной  |
| **WP-253** Реализованная новая архитектура Neon | dcb445c2 feat: WP-290 Следователь — система каузальной  |
| **WP-265** Аудит инсталляции IWE — SC + скрипт + скилл | d61cd212 WP-265 Quick Close: Ф6.1+Ф9 done + Opus review |
| **WP-276** Двухуровневая карта внешних провайдеров (Pack: принципы + DS | нет (7д) |
| **WP-281** Трекер передачи: менеджмент + поддержка → Ильшат | 1e08d377 strategy-session W19: two-track architecture + |
| **WP-283** Автономный Day Open на сервере — кросс-платформенные скрипты | 964ead6c docs(WP-283): Ф7+Ф8 done — session-prep sweep  |
| **WP-284** Регулярные интервью с пользователями → обратная связь → РП ( | 9868b996 upd(WP-284): контекст Ф0-Ф5 done — журнал, сек |
| **WP-284** WP-284-participants | 9868b996 upd(WP-284): контекст Ф0-Ф5 done — журнал, сек |
| **WP-285** Международная инфраструктура Track B | abcb05a WP-285: командный план + Ф2 выбор GKE Standard 7 мая |
| **WP-287** Руководство по использованию IWE | bc733374 docs: зарегистрировать сессию WP-287 в open-sessions.log |
| **WP-294** WP-294-wp-mention-sync-actualization | 2841ecee WP-294 ✅ Ф1-Ф5 done — Ф6 blocked (env-bug) → Ф7 resilience + Ф8 observability applied 13 мая — 🧪 passive testing до Week Close |
| **WP-295** Журнал решений, повтор и параллельные пути для ИИ-агентов IWE | spawn 2026-05-06 |
| **WP-45** Бот: observability + auto-fix | нет (7д) |
| **WP-5** Платформа: развитие (зонтичный) | a99d5595 chore: add WP-5 1h to итоги, мультипликатор 1. |
| **WP-55** DS-principles-curriculum: разработка ячеек и программ | 9cf5740d docs: связки между незакрытыми РП (10 пар) |
| **WP-7** Платформа: техдолг (зонтичный) | b437c6c6 day-plan: 6 мая 2026 — расширенный план + WP-2 |
| **WP-73** Новая архитектура и план развития ИТ-платформы Aisystant | ce56769f docs(WP-73): актуализация встреча 14, GKE Standard 7 мая |
| **WP-??** WP-INCIDENT-2026-04-30-bot-diagnostics-runbook | нет (7д) |
> _Обновлено: 2026-05-07 (quick-close WP-285/WP-73)_
<!-- ACTIVE-WP-END -->

### Feedback — HOT (27-30 апр, 1-3 май)

> Горячие файлы, читаемые регулярно. Архивные WARM (17-26 апр) → [`archive/feedback-april-2026.md`](archive/feedback-april-2026.md).

- [feedback_monthclose_strategy_session_input.md](feedback_monthclose_strategy_session_input.md) — MonthClose YYYY-MM.md = вход стадии 2 первой сессии месяца (WP-196 Ф13, 4 май)
- [feedback_r_questionnaire_month.md](feedback_r_questionnaire_month.md) — M1-M3/M6 заполнять из данных автоматически; только M4-M5 спрашивать у пользователя; нет английских слов (4 май)
- [feedback_day_open_gaps_2026-05-02.md](feedback_day_open_gaps_2026-05-02.md) — **КРИТИЧЕСКИЙ: шаг 3 Саморазвитие отсутствует в Day Open**; + 4 косяка, рекомендации по SKILL.md и scaffold (3 май)
- [feedback_calendar_query_day_open.md](feedback_calendar_query_day_open.md) — шаг 4c: запрашивать ВСЕ calendar IDs из config; пропускать событие как private только при явном `visibility: "private"` в API-ответе (3 май)
- [feedback_behaviour.md](feedback_behaviour.md) — ОРЗ, снапшоты, верификация, автономность (29 апр)
- [feedback_writing.md](feedback_writing.md) — стиль, публикации, Marp (28 апр)
- [feedback_architecture.md](feedback_architecture.md) — код, DDD, MCP, Neon (28 апр)
- [feedback_cutover_completeness.md](feedback_cutover_completeness.md) — `git branch --contains` для merge-verify, cut-over 3 слоя, FORBIDDEN_FIELDS PII tax; `development.engagement.user_uuid` ненадёжен post-cutover → UUID всегда из `persona.ory_identity` (28 апр)
- [feedback_neon_pooler_listen_notify.md](feedback_neon_pooler_listen_notify.md) — LISTEN/NOTIFY несовместимо с Neon `-pooler` endpoint (PgBouncer transaction-mode); receiver-DSN всегда direct (28 апр)
- [feedback_silent_projection_fail.md](feedback_silent_projection_fail.md) — projection-worker cursor advance + silent UPSERT fail (3 случая 28 апр); детектор alerter rule 4 cross-DB diff (28 апр)
- [feedback_sequential_worker_throughput_ceiling.md](feedback_sequential_worker_throughput_ceiling.md) — sequential projection-worker upper rate ~50-60 ev/min на Neon-pooled; trigger Ф3 scaling если incoming > ceiling (28 апр)
- [feedback_russian_clear.md](feedback_russian_clear.md) — только понятный русский в ответах, минимум английских слов, без сленга и жаргона (28 апр)
- [feedback_repo_hosting_principle.md](feedback_repo_hosting_principle.md) — инстанс ≠ шаблон (разные репо); лицензия Apache 2.0 + CLA с первого коммита; нейтральные имена; Foundation для шаблонов в Q3-Q4 (28 апр)
- [feedback_rule_registry_pattern.md](feedback_rule_registry_pattern.md) — Pack/DS pattern для правил агента (WP-272); FPF A.7 (Object/Description/Carrier); +batch-uplift паттерн с audit-loop +weekly evolution scheduled agent (27 апр Ф4)
- **[archive ↓]** feedback_railway_new_project_pitfall / feedback_quantum_like_trigger / feedback_per_domain_cursor_self_init — [feedback-april-2026.md](archive/feedback-april-2026.md) (WP-270, WP-274 done)
- [feedback_silent_fail_log_to_stdout.md](feedback_silent_fail_log_to_stdout.md) — bash log() в stderr, иначе ломает $() pipelines с JSON (29 апр, dt-collect.sh)
- [feedback_post_cutover_doc_drift.md](feedback_post_cutover_doc_drift.md) — после cut-over runbook'и проверять grep'ом на dead-code flags / manual-шаги; не следовать слепо pre-cutover документации (29 апр)
- [feedback_release_gates.md](feedback_release_gates.md) — валидатор без интеграции в pre-commit/CI = в чужих руках (WP-279, 29 апр)
- [feedback_alerter_writer_sampling_drift.md](feedback_alerter_writer_sampling_drift.md) — alerter threshold ↔ writer sampling drift (lazy metric ≠ heartbeat); idle ≠ stuck без backlog-проверки (29 апр)
- [feedback_context_isolation_day_open.md](feedback_context_isolation_day_open.md) — двойное открытие (автономное + ручное) наследует результаты без переаттестации БЛОКИРУЮЩИХ шагов; решение: BLOCKING validation перед commit (1 май)
- [feedback_asyncpg_type_coercion.md](feedback_asyncpg_type_coercion.md) — asyncpg валидирует Python-тип ДО отправки в PG; SQL `::cast` не помогает для параметров — нужен Python-coerce (str→date, str→datetime). WP-151 Блок B 5 май
- [feedback_upsert_vs_update_for_closed_events.md](feedback_upsert_vs_update_for_closed_events.md) — closed-события с бедным payload должны быть `op: UPDATE`, не UPSERT; PG проверяет NOT NULL на INSERT clause ДО conflict resolution. WP-151 Блок B 5 май
- [feedback_server_sync_patterns.md](feedback_server_sync_patterns.md) — pre-tick git pull через ExecStartPre+`-`-префикс, deployment ≠ artifact-generation location, DIRTY как сигнал, FORCE_PROD-projection правило, master↔main divergence (WP-7 S-A/S-B 7 мая)
- [lessons_architecture_audit_before_implementation.md](lessons_architecture_audit_before_implementation.md) — WP-121 Ф2 fail 5 мая: реализовал на Railway вместо Neon из-за пропуска архитектурного аудита. Правило: до кода — DP.ARCH + WP-context + grep на existing implementations
- [project_wp121_phase2_state.md](project_wp121_phase2_state.md) — WP-121 Ф2 после сноса: точная карта Neon БД (learning/reference/rewards), gap в существующем rewards-projection-worker, план v2 (6-8h)

### User (личный профиль)

- [user_background.md](user_background.md) — мех-мат МГУ, математик+методолог+экзоскелет (не физик, не МФТИ)
- [user_mission_core.md](user_mission_core.md) — корневой мотив: познание Вселенной через развитие интеллекта
- [user_identifiers.md](user_identifiers.md) — Telegram ID, Ory UUID, ИП/ООО

### Project (контекст инициатив)

- [project_team_roles.md](project_team_roles.md) — Андрей/Паша/Дима/Ильшат/Олег
- [project_domain_name.md](project_domain_name.md) — «Системное созидательство» (v0.1, 21 апр)
- [project_iwe_arch_strategy.md](project_iwe_arch_strategy.md) — новая арх (платформа+IWE, 12 Neon БД) vs старая (LMS монолит)
- [project_metabase_state.md](project_metabase_state.md) — Metabase config + planned restructure после legacy cleanup (27 апр)
- [project_persona_memory_context.md](project_persona_memory_context.md) — Персона/Память/Контекст (3 слоя)
- [project_iwe_positioning.md](project_iwe_positioning.md) — 5 компонент, слоган
- [project_community_iwe.md](project_community_iwe.md) — сообщество, воронка
- [project_lifetime_subscription_vision.md](project_lifetime_subscription_vision.md) — подписка, LTV
- [project_ilshat_handover.md](project_ilshat_handover.md) — WP-281: передача менеджмент+поддержка → Ильшат (3 фазы, →1 сент)
- [project_web_onboarding.md](project_web_onboarding.md) — лендинг, конверсия
- [project_inga_ux_designer.md](project_inga_ux_designer.md) — Инга, UX
- [project_karpathy_llm_knowledge_base.md](project_karpathy_llm_knowledge_base.md) — LLM-вики, автопилот
- [project_qualification_assessment.md](project_qualification_assessment.md) — квалификация, СМ, EQF
- [project_wp129_multichannel_publisher.md](project_wp129_multichannel_publisher.md) — S47

### Lessons (уроки, детали → тематические файлы)

- [lessons_day_rituals.md](lessons_day_rituals.md) — Day Open/Close, календарь
- [lessons_infra.md](lessons_infra.md) — launchd, Neon tz, asyncpg, alerter DB-backed cooldown, feature flag без gate check, NEON_PROD_BASE в ~/.secrets/neon, INSERT RETURNING atomic dedup, uuid4 external_id, knowledge-mcp≠iwe-knowledge
- [lessons_tools.md](lessons_tools.md) — MCP, Linear
- [lessons_hook_json_safety.md](lessons_hook_json_safety.md) — Claude Code hooks: JSON только через `jq -n --arg`, не `cat <<EOF` (silent failure при кавычках в reason). WP-265 Ф6.1 + Opus review (6 мая)

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
- [reference_gdrive_sync.md](reference_gdrive_sync.md) — **ПЕРВЫМ при Upload/Drive**: `DS-MCP/google-drive-mcp/gdrive-sync.py` + `sync-config.json`; OAuth, не сервисный аккаунт
- [reference_dp_d053.md](reference_dp_d053.md) — DP.D.053 (4-уровневое различение Problem→Task→Form→Work) с примерами (WP-282, 1 май)

## ✅ INCIDENT-2026-04-30 (RESOLVED, 30 апр 23:50)

**FINAL STATUS:** SESSION 2 COMPLETE — все исправления выполнены

Контекст РП: `DS-my-strategy/inbox/WP-INCIDENT-2026-04-30-bot-diagnostics-runbook.md`

**SESSION 2 результаты:**
- ✅ **Ф2a OAuth (CRITICAL)** — ory_tokens expired в Railway-local Postgres; DELETE 1 row; OAuth recovery triggered
- ✅ **Ф2b GitHub (HIGH)** — logger.error → logger.debug в github_content.py:65
- ✅ **Ф3 Feed latency (MEDIUM)** — Claude API timeout pattern; not a bug
- ✅ **Ф4 Close** — все документы обновлены, инцидент закрыт

