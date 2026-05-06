<!-- index-health: skip -->
<!-- Обоснование: серверный контекст-файл для автономного Day Open агента; dense prose-формат, не индекс-таблица. Длинные строки = намеренная упаковка контекста для LLM. -->
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

### Текущие РП (W18→W19, 3 май)

> **Source-of-truth статусов** — `DS-my-strategy/current/WeekPlan W19 2026-05-04.md`. Здесь — только горячая выжимка после Strategy Session W19 (4 мая, two-track разворот).

**Two-Track архитектура (Strategy Session W19, 4 май):** Россия = Track A (legacy LMS+бот, передача Ильшату); мир/YC = Track B (новая Neon+Aisystant MCP+EN-ready). Подробно — `DS-my-strategy/docs/Strategy.md` § «Стратегический разворот W19».

**Track B (Tseren) — критические W19:**
- **WP-150** Мультиагентность IWE — архитектура Ф0–Ф8 (28h). **Уточнено W18 (4 май):** Claude (Planner) + Kimikode (Executor) + Ollama (fallback). Ф6 CRITICAL = unified MCP Gateway в VS Code (все агенты через один слой). Offline = Ф5 local MCP server + workspace cache. Phases overview в `phases-wp150-overview.md`. **Ф0 ✅ complete** (decision doc: peer-agent model, offline graceful degradation, context isolation) — **Ф1** (context isolation spec, 2.5h) — следующая сессия.
- **WP-253** Реализованная архитектура Neon — Ф9.6 ✅ (5 мая): cron tsekh-1 04:30 МСК работает, F1.A активен (event-gateway 201); soak F2 до 2026-05-12 → убрать digital_twins fallback из twin.py
- **WP-245** Персональное руководство — D-блок ✅ done (4 мая, все 12 фаз: Ф31+Ф19+Ф20+Ф22+Ф16 + ранее); Ф28.3 (внешние пилоты) + B3 (week-close-pilot) + Ф9/Ф10 (dep WP-149) — следующая сессия
- **WP-151** Характеристики деятеля — Ф14.1+Ф14.2+Ф14.3 ✅ done; **Ф13 ✅ done** (dt_snapshot_rcs + rcs_history pipeline в orchestrator, 4 мая); **Блок B ✅ done 5 мая** (эмиттеры IWE → event-gateway → projection-worker → learning.daily_plan/weekly_hypothesis end-to-end). Уроки: feedback_asyncpg_type_coercion.md, feedback_upsert_vs_update_for_closed_events.md
- **R4 YC** — RFS-анализ + deck v0.5 + demo-сценарий ≤3 мин (~6h W19)

**Track A (передача Ильшату):**
- **WP-281** Передача Track A — план месяца, on-call с W21, bus factor ≥2 к 1 июня

**Поддержка:** WP-188 Ф3+Ф4.5; WP-250; WP-246 soak продлён → 12 мая (digital_twins fallback тоже до 12 мая, Ф9.x spec); WP-283; WP-121 Ф2; WP-196 Ф8+Ф12.3; WP-7; WP-170; WP-231; WP-276; **WP-284** Интервью-пайплайн Ф0-Ф5 ✅ done 5 мая; **WP-214** Ф7 ✅ done 5 мая (iwe-actions-catalog + emitter + orz-tracker + git-template) → Ф8 dep WP-121; **WP-285** Ф1-Ф2 ✅ done 5 мая (Neon-аудит + сценарии)

**WP-293 ✅ done 6 мая:** Контракт параметризации путей IWE — FMT 0.29.29 (commit `4f0277f`): фикс `dt-collect.sh:234`, `update.sh:609` `.claude/scripts/*`, smoke HOME isolation + 3 safeguards.

**WP-287** Руководство по использованию IWE — **Ф0 ✅ done 6 мая** (трёхканальная стратегия: холодный/тёплый/внутренний; Ф1 dep WP-188 Ф4.5; Ф2 blocked dep WP-222); context: `DS-my-strategy/inbox/WP-287-iwe-usage-guide.md`

**Новые pending (W20+):** WP-286 IWE в корп. среде; WP-288 Рекомендации наставникам резидентур; WP-289 Интеграция IWE с PKM/Notion/Obsidian; **WP-290 «Следователь»** — каузальная аналитика развития (C.28, Pearl Hierarchy; dep WP-151+WP-253; enables WP-149+WP-117; ~26h); **WP-292 Бренд IWE** (spawn 6 мая) — имя продукта (Ipsembra кандидат, ищем альтернативы) + Brand Compendium 8 секций + приёмка работ дизайнера; артефакт в `DS-ecosystem-development/C.IT-Platform/C2.IT-Platform/C2.1.Meaning/2.1.1. Brand/` (бренд продукта IWE — SoI ядра C, не B; различение «IWE-продукт ≠ Aisystant-экосистема»); ⚪ ~30h за W19-W22, поддерживает Track B / R4 YC

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
- [lessons_infra.md](lessons_infra.md) — launchd, Neon tz, asyncpg, alerter DB-backed cooldown, feature flag без gate check, NEON_PROD_BASE в ~/.secrets/neon, INSERT RETURNING atomic dedup, uuid4 external_id
- [lessons_tools.md](lessons_tools.md) — MCP, Linear

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

