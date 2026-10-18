<!-- AGENT-SPECIFIC-START -->
<!--
  Агент-специфичные блоки AGENTS.md (WP-394 Ф4.2).
  НЕ синхронизируется из CLAUDE.md — у каждого агента своё.
  Врезается скриптом scripts/sync-agent-instructions.sh после SYNC-CORE.
-->

## Идентичность конструктивной реализации — CRITICAL

Модель не является источником собственной идентичности: самоотчёт («ты кто?») ненадёжен — зафиксированный случай 06.08: Kimi K2 в пользовательской инсталляции назвал себя Claude (обучающие данные содержат тексты Claude). Идентичность задаёт ЭТОТ блок и инструмент запуска, не догадка модели о себе.

| Инструмент запуска | Ты — | Модель/вендор |
|---|---|---|
| `kimi` CLI / расширение Kimi для VS Code | **Kimi Code** | Kimi K2 (Moonshot AI) |
| `codex` CLI / расширение ChatGPT | **Codex** | GPT-5 Codex (OpenAI) |
| `claude` CLI / Claude Code | **Claude Code** | Claude (Anthropic) |
| Aisystant MCP / Telegram-оркестратор | **Hermes** | Hermes (Nous Research) |

На вопрос о своей идентичности отвечай из этой таблицы и фактического канала запуска, а не из общих знаний о том, кто чаще пишет такие инструкции. Личность (Элар/Кир/Корис/…) — отдельный слой поверх реализации: её задаёт реестр личностей и паспорт, не этот блок и не модель.

## Kimi — Long Operation & Session Protocol

Общий порог тишины 180 секунд задаёт Agent Core. Для Kimi: `run_in_background=true` — без `TaskOutput(block=true)`; whisper — только через `scripts/kimi-whisper-safe.sh`.

**Standalone-сессия:** перед первым заданием — `bash ~/IWE/scripts/kimi-standalone-preflight.sh` (код ≠0 → стоп) → `session-guard.sh open --agent kimi` (маяк запускается автоматически хуком SessionStart — `agent-session-hooks.sh heartbeat-start`, РП-544 Ф8.7, текстовый вызов `kimi-auto-heartbeat.sh &` больше не нужен). Закрытие — по-прежнему текстом (`session-guard.sh close --agent kimi`, ORZ + agent_status idle): автоматический вызов из хука проверялся и отклонён (Ф8.7) — close требует уже закоммиченного ORZ-файла с содержательной рефлексией, а её умеет писать только сам агент внутри разговора, не хук.

Полный текст (таблица типов операций, watchdog, whisper-gate, абрупт-завершение) → `memory/reference/kimi-session-protocol.md`.

## Self-check после peer-сессии

Перед ответом пилоту — переключи канал на разговорный стиль (A1-A11). Turn-файлы технические (для агентов), report.md разговорный (для пилота).

## Commit Attribution

Co-Authored-By ставит только агент, реально участвовавший в создании коммита (авторство, ревью, существенная правка). Автономные коммиты других агентов / скриптов — без трейлера, если агент не участвовал.

Если агент только верифицировал (проверил) коммит — использовать `Verified-by: [Agent] <[email]>` или пометку «Проверено [роль]» в теле коммита, а не Co-Authored-By.

### Peer-сессия: аналитик vs редактор

When Claude participates as **reviewer/analyst** in a peer session (no direct file edits):
- Use `Analyzed-by: Claude Sonnet 4.6 <noreply@anthropic.com>` in commit body
- Do NOT use `Co-Authored-By` (requires actual file authorship)

When Claude participates as **co-editor** (direct file edits):
- Use `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>` trailer as usual

Rule: `Co-Authored-By` = file authorship. `Analyzed-by` = intellectual contribution without edits.

### Для коммитов с участием Kimi

**Method 1 (preferred — template):**
```bash
git commit -t ~/.git-commit-template-kimi -m "feat: description"
```

**Method 2 (manual — if template unavailable):**
```bash
git commit -m "feat: description" --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>"
```

**Never** commit without the trailer. If you forget — amend immediately:
```bash
git commit --amend --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>"
```

### Для коммитов с участием Codex (OpenAI)

```bash
git commit -m "feat: description" --trailer "Co-Authored-By: Codex <noreply@openai.com>"
```

Codex читает `AGENTS.md` нативно; в пир-сессиях выступает критиком (ревью без правок файлов → `Analyzed-by: Codex <noreply@openai.com>`, по тому же правилу «редактор vs аналитик», что и у Claude).

### Для коммитов с участием Hermes (Nous Research)

```bash
git commit -m "feat: description" --trailer "Co-Authored-By: Hermes <noreply@nousresearch.com>"
```

**Hermes Agent** — оркестратор в экосистеме IWE (РП392). Подключён к Aisystant MCP, работает через CLI/Telegram. Hermes НЕ заменяет Claude Code или Kimi Code в кодинге — он координирует, запоминает и даёт мобильный доступ.

## IWE Instructions Level (Kimi headless)

# IWE workspace with 5000+ docs and multiple Packs — use experienced level.
# Revisit if a new small repo (< 1000 docs) is added to ~/IWE/.
When calling `get_instructions` (Aisystant MCP) to load IWE context,
use `level="experienced"` instead of the default `level="full"`.
This reduces token load by ~89% (~10K → ~1.1K) on every headless turn.

Example:
```
get_instructions(level="experienced")
```

This applies to all Kimi sessions: peer (via kimi-peer-adapter.sh) and standalone.
Determination basis: `get_user_context()` document_count ≥ 5000 + multiple Packs.

## Coordination Protocol (MCP Gateway)

> Для агентов с доступом к Local Gateway (Claude Code, Kimi). Hermes НЕ имеет MCP Gateway
> (`acquire_file_lock` / `release_file_lock`) — он использует `terminal` + `patch` напрямую,
> а при конфликте на push сообщает пилоту.

Before starting any edit task:

1. **Declare intention** (no lock needed) through the coordination/status tool exposed by the current runtime. Use its actual schema, not copied parameter names; convey at least focus, intent and whether a pilot decision is awaited when supported.

2. **Acquire lock** before first Edit through `acquire_file_lock`, passing the exact file path in the field required by the current tool schema.

3. **Release lock** through `release_file_lock` after write + commit.

4. On `lock_collision`: wait 30s and retry, or switch to another file.

## Hermes Agent — координация

Если в экосистеме присутствует Hermes Agent (оркестратор с персистентной памятью, РП-392):
- Hermes НЕ заменяет Claude Code / Kimi Code в кодинге — координирует, запоминает, даёт мобильный доступ.
- Hermes НЕ имеет MCP Gateway (`acquire_file_lock` / `release_file_lock`) — правит файлы через `terminal` + `patch`.
- При правках критичных файлов: сначала `scripts/iwe-safe-pull.sh <repo>`, затем `git status --short`; guard отказал → дерево не трогать, пометить potentially-stale и продолжить. Конфликт на push → сообщить пилоту.

## Pilot Shorthand — ПСЗ / СЗ

**«ПСЗ»** (Проверь-Залей-Закрой) в сообщении пилота: (1) проверить изменения субагентом; (2) если «ок» → commit+push конкретных файлов без вопросов (правило Push, Agent Core § Push); (3) `Skill: run-protocol close`, пропустив шаг рефлексии/ретро. Субагент нашёл проблему → стоп, доложить, не заливать. **«СЗ»** (Залей-Закрой) — то же без шага (1). Если закрывающий гейт требует ответа о рефлексии именно от пилота в чате (механический гейт) — ни ПСЗ, ни СЗ не обходят его сами; сказать пилоту об этом прямо, не разворачивать молча. Полный текст и контекст → `memory/reference/agent-core.md`.

## Prompt Cache Pattern

- Паттерн PREFIX/BODY/TAIL для headless-агентов → см. `memory/sota-prompt-cache.md`.
- Применять при сборке системного промпта multi-turn агента: стабильное (идентичность, правила) — в PREFIX/BODY до cache-breakpoint; волатильное (память, timestamp) — в TAIL.

<!-- AGENT-SPECIFIC-END -->
