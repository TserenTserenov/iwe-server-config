---
# see DP.SC.160, DP.ROLE.058
name: artifactor
description: "Classifies raw pilot request → structured JSON {task_type, class, artifact, budget_estimate, confidence, routing_tag, resolution_path, schema_version, expected_result_kind, result_kind_resolution}. Keyword-fast (<200ms) or Haiku fallback (<60s). Does NOT create WP or call executor."
version: 1.0.0
layer: L1
status: active
triggers:
  slash: [/artifactor]
  phrases: []
owner_role: DP.ROLE.058
related:
  - DP.SC.160
  - DP.ROLE.058
  - DP.ROLE.059
routing:
  executor: sonnet
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# /artifactor — Артефактор-Постановщик

> **Роль:** DP.ROLE.058 Артефактор-Постановщик  
> **Триггер:** запрос без routing-tag (Маршрутизатор → Артефактор) или `/artifactor "текст"`  
> **Service Clause:** DP.SC.160

## When to use

Classifies raw pilot request → structured JSON {task_type, class, artifact, budget_estimate, confidence, routing_tag, resolution_path, schema_version, expected_result_kind, result_kind_resolution}. Keyword-fast (<200ms) or Haiku fallback (<60s). Does NOT create WP or call executor.

## Обещание (контракт)

**Вход:** сырой текст запроса пилота (любой длины, без routing-tag)  
**Выход:** JSON, schema_version 2 (WP-481 Ф7 шаги 3-4) → stdout:

```json
{
  "task_type": "string",
  "class": "trivial | closed-loop | open-loop | problem-framing",
  "artifact": "string (одна строка на русском — существительное-результат)",
  "budget_estimate": "~Xh | ?",
  "confidence": "high | low",
  "routing_tag": "string",
  "resolution_path": "keyword | llm",
  "schema_version": 2,
  "expected_result_kind": "kind_id из PACK-digital-platform/pack/digital-platform/result-kinds-registry.yaml | null",
  "result_kind_resolution": "static | deferred-to-session | unresolved"
}
```

**Инвариант:**
- НЕ создаёт РП, НЕ вызывает исполнителя, НЕ задаёт уточняющих вопросов
- `confidence=high` только при keyword-пути; `confidence=low` при LLM-пути
- При запросе <5 слов: вернуть `{"error": "INSUFFICIENT_INPUT"}`, стоп
- `budget_estimate: "?"` только при `problem-framing` или полной неопределённости
- `expected_result_kind` — дискриминатор ожидаемого kind-а результата (WP-481 Ф7, «не бывает общего результата»), НЕ показатель готовности проверки (`gate_ready` — забота `/verify`, не Артефактора)
- `result_kind_resolution: "unresolved"` — ни один kind реестра не подходит; классификатор НЕ подменяет ближайшим (анти-утечка в супертип)
- `result_kind_resolution: "deferred-to-session"` — мета-триггер (например `peer_session`), kind решается внутри самого процесса, не в момент классификации
- **stdout = CONFIG_ERROR** (exit 3) → реестр kind-ов не читается или устарел относительно `KEYWORD_MAP` (дрейф) — fail-closed, эскалировать пилоту, не игнорировать поле

## Algorithm

### Шаг 1. Keyword-lookup

Запустить скрипт (возвращает JSON или сигнал):

```bash
python3 "${IWE_SCRIPTS:-$HOME/IWE/scripts}/artifactor.py" "$ARGUMENTS"
```

Интерпретация результата:
- **stdout = JSON** (exit 0) → вернуть пилоту, стоп
- **stdout = INSUFFICIENT_INPUT** (exit 1) → вернуть `{"error": "INSUFFICIENT_INPUT"}`, стоп
- **stdout = NO_KEYWORD_MATCH** (exit 2) → перейти к Шагу 2
- **stderr содержит CONFIG_ERROR** (exit 3) → реестр kind-ов недоступен или устарел (дрейф) — эскалировать пилоту одной строкой, НЕ переходить к Шагу 2 (это не «нет keyword-совпадения», а поломка конфигурации)

### Шаг 2. LLM-классификация (fallback при NO_KEYWORD_MATCH)

Заполнить все 10 полей, используя правила ниже. Вернуть JSON с `resolution_path: "llm"`, `confidence: "low"`, `schema_version: 2`. Для `expected_result_kind`/`result_kind_resolution` — та же логика, что у keyword-пути: подобрать `kind_id` из `PACK-digital-platform/pack/digital-platform/result-kinds-registry.yaml` по смыслу запроса; если ни один явно не подходит — `expected_result_kind: null`, `result_kind_resolution: "unresolved"` (не подменять ближайшим).

**Правила `class`:**

| Класс | Критерий |
|-------|---------|
| `trivial` | Протокол без неопределённости (day-open, week-close, peer-сессия) |
| `closed-loop` | Чёткая спецификация + известный метод (баг-фикс, миграция, ревью, триаж) |
| `open-loop` | Нет спецификации, нужно генерировать (контент-план, диагностика, сценарии) |
| `problem-framing` | Расплывчато, метод неизвестен (идеи, концепции, «что-то придумать с X») |

При сомнении — выбирать более широкий класс (open-loop, не closed-loop).

**Правила `artifact`:** одна строка на русском, первое слово — существительное, обозначающее документ, систему или состояние системы (не процесс/действие над ним — «Разбор X», «Анализ X», «Проверка X» не годятся, даже когда сами по себе грамматически существительные).  
Примеры: «Список тем для трёх постов», «Диагностический отчёт латентности», «ТЗ сценариев».  
Не так: «Разбор 88 неразобранных коммитов» (описывает действие) → так: «Реестр неразобранных коммитов ветки X» (описывает артефакт-результат).

**Правила `budget_estimate`:**
- `trivial` → `~0.5h`
- `closed-loop` → `~2h` (если нет конкретного числа в запросе)
- `open-loop` → `~3h`
- `problem-framing` → `?`

**Поле `routing_tag`** = значение `task_type` (snake_case).

### Шаг 3. Вернуть результат

Вывести JSON в stdout. Без дополнительных пояснений.

## Режим отказа

| Сценарий | Поведение |
|---------|-----------|
| Запрос < 5 слов | `{"error": "INSUFFICIENT_INPUT"}` |
| Скрипт не найден / сбой | Перейти к Шагу 2 напрямую |
| Запрос на иностранном языке | Классифицировать как есть, `confidence: low` |
