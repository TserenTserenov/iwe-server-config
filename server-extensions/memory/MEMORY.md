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

### Feedback (правила поведения)

- [feedback_memory_index_discipline.md](feedback_memory_index_discipline.md) — шапки индексов (MEMORY/WP-REGISTRY/…) = hook-строки, не changelog и не статус (24 апр)
- [feedback_writing.md](feedback_writing.md) — стиль, публикации, Marp
- [feedback_governance.md](feedback_governance.md) — бюджет, множитель, WP-оценки
- [feedback_architecture.md](feedback_architecture.md) — код, DDD, MCP, Neon
- [feedback_behaviour.md](feedback_behaviour.md) — ОРЗ, снапшоты, верификация, автономность
- [feedback_note_review_routing.md](feedback_note_review_routing.md) — знание → DayPlan кандидатом, captures.md только при явном маркере
- [feedback_link_format.md](feedback_link_format.md) — файлы IWE → GitHub URL (VS Code ext не открывает URL-encoded кириллицу)
- [feedback_decision_gates.md](feedback_decision_gates.md) — gate = бинарный чеклист yes/no, без процентов/score
- [feedback_post_promote_sync.md](feedback_post_promote_sync.md) — L1↔L3 leak при промоции и init-time; тест «применимо пустому пользователю?»
- [feedback_world_section_links.md](feedback_world_section_links.md) — Мир-секция DayPlan: каждый пункт = markdown URL или исключается
- [feedback_scout_backlog_discipline.md](feedback_scout_backlog_discipline.md) — Scout backlog пуст по умолчанию; только явные заказы
- [feedback_protocol_full_checklist.md](feedback_protocol_full_checklist.md) — Day Close R23 передавать ПОЛНЫЙ чеклист, grep-верификация FAIL-ов
- [feedback_wp_context_tail_first.md](feedback_wp_context_tail_first.md) — WP-context читать снизу вверх; long-tail handoff в конце инвертирует фазы в середине (25 апр)
- [feedback_multiplier_carry_forward.md](feedback_multiplier_carry_forward.md) — мультипликатор DayPlan → WeekPlan при Day Close
- [feedback_template_sync_placeholders.md](feedback_template_sync_placeholders.md) — в шаблонных файлах (SKILL.md, scripts/*.sh) плейсхолдеры `$IWE_SCRIPTS`/`$IWE_TEMPLATE`/`$HOME`, не хардкод (валидатор роняет sync, 26 апр)
- [feedback_chat_replies_not_in_repo.md](feedback_chat_replies_not_in_repo.md) — ответы для отправки X (TG/email/Slack) даём в чате, не пишем `inbox/draft.md` (26 апр)
- [feedback_cutover_completeness.md](feedback_cutover_completeness.md) — `git branch --contains` для merge-verify, cut-over 3 слоя, FORBIDDEN_FIELDS PII tax; `development.engagement.user_uuid` ненадёжен post-cutover → UUID всегда из `persona.ory_identity` (28 апр)
- [feedback_rule_registry_pattern.md](feedback_rule_registry_pattern.md) — Pack/DS pattern для правил агента (WP-272); FPF A.7 (Object/Description/Carrier); +batch-uplift паттерн с audit-loop +weekly evolution scheduled agent (27 апр Ф4)
- [feedback_railway_new_project_pitfall.md](feedback_railway_new_project_pitfall.md) — Railway "+ New" с dashboard ROOT создаёт новый проект, не сервис; WP-270 worker → attractive-optimism вместо peaceful-vision (27 апр)
- [feedback_per_domain_cursor_self_init.md](feedback_per_domain_cursor_self_init.md) — worker идемпотентно создаёт cursors через INSERT ON CONFLICT, миграция cursor split → NOOP при первом deploy (27 апр)
- [feedback_sequential_worker_throughput_ceiling.md](feedback_sequential_worker_throughput_ceiling.md) — sequential projection-worker upper rate ~50-60 ev/min на Neon-pooled; trigger Ф3 scaling если incoming > ceiling (27 апр)
- [feedback_quantum_like_trigger.md](feedback_quantum_like_trigger.md) — при ArchGate / метриках / диагностике / observability проверять 5 симптомов QL → DP.METHOD.050 после исчерпания классики (FPF C.26*, WP-274, 27 апр)
- [feedback_neon_pooler_listen_notify.md](feedback_neon_pooler_listen_notify.md) — LISTEN/NOTIFY несовместимо с Neon `-pooler` endpoint (PgBouncer transaction-mode); receiver-DSN всегда direct (28 апр)
- [feedback_russian_clear.md](feedback_russian_clear.md) — только понятный русский в ответах, минимум английских слов, без сленга и жаргона (28 апр)
- [feedback_repo_hosting_principle.md](feedback_repo_hosting_principle.md) — инстанс ≠ шаблон (разные репо); лицензия Apache 2.0 + CLA с первого коммита; нейтральные имена; Foundation для шаблонов в Q3-Q4 (28 апр)
- [feedback_silent_projection_fail.md](feedback_silent_projection_fail.md) — projection-worker cursor advance + silent UPSERT fail (3 случая 28 апр); детектор alerter rule 4 cross-DB diff (28 апр)
- [feedback_silent_fail_log_to_stdout.md](feedback_silent_fail_log_to_stdout.md) — bash log() в stderr, иначе ломает $() pipelines с JSON (29 апр, dt-collect.sh)
- [feedback_post_cutover_doc_drift.md](feedback_post_cutover_doc_drift.md) — после cut-over runbook'и проверять grep'ом на dead-code flags / manual-шаги; не следовать слепо pre-cutover документации (29 апр)
- [feedback_release_gates.md](feedback_release_gates.md) — валидатор без интеграции в pre-commit/CI = в чужих руках (WP-279, 29 апр)
- [feedback_alerter_writer_sampling_drift.md](feedback_alerter_writer_sampling_drift.md) — alerter threshold ↔ writer sampling drift (lazy metric ≠ heartbeat); idle ≠ stuck без backlog-проверки (29 апр)

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
- [project_web_onboarding.md](project_web_onboarding.md) — лендинг, конверсия
- [project_inga_ux_designer.md](project_inga_ux_designer.md) — Инга, UX
- [project_karpathy_llm_knowledge_base.md](project_karpathy_llm_knowledge_base.md) — LLM-вики, автопилот
- [project_qualification_assessment.md](project_qualification_assessment.md) — квалификация, СМ, EQF
- [project_wp129_multichannel_publisher.md](project_wp129_multichannel_publisher.md) — S47

### Lessons (уроки, детали → тематические файлы)

- [lessons_day_rituals.md](lessons_day_rituals.md) — Day Open/Close, календарь
- [lessons_infra.md](lessons_infra.md) — launchd, Neon tz, asyncpg, alerter DB-backed cooldown, feature flag без gate check, NEON_PROD_BASE в ~/.secrets/neon
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
