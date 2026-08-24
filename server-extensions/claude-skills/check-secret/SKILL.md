---
name: check-secret
description: Проверка фрагмента текста на возможные секреты (API keys, tokens, passwords) ПЕРЕД отправкой в чат / коммитом / публикацией. Третий слой защиты поверх pre-commit hook (B7.7a) и PostToolUse redact (B7.7b). Manual gate — пользователь явно вызывает на потенциально чувствительный текст.
argument-hint: "<text-or-file-path>"
version: 1.2.0
layer: L3
status: active
triggers:
  slash: [/check-secret]
  phrases: []
routing:
  executor: script
  deterministic: true
  script_path: ".claude/skills/check-secret/check.sh"
  optimization_priority: 2
agents: none
interaction: one-shot
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# Check Secret — manual gate (B7.7c, WP-212)

> **Принцип:** B7.7a блокирует Bash-команды с секретами; B7.7b редактирует tool output; этот skill закрывает третий gap — **проверка произвольного текста** который пользователь готовится опубликовать (commit message, slack post, docs paragraph, чат-ответ).
>
> **Покрывает паттерны:** канонический корпус из `secret-bypass-lib.sh`: Neon, DATABASE_URL, Anthropic, OpenAI, Stripe, YooKassa, современные и прежние GitHub-токены, AWS, Google, Better Stack, Slack, заголовки приватных ключей, Bearer, JWT, Telegram, а также эвристики секретных env-присваиваний.
>
> **Архитектурное ограничение** (см. B7.7 в WP-212): отрицательный результат означает только отсутствие известных сигнатур. Он не доказывает, что текст безопасен, и не покрывает неизвестные форматы или преобразованные значения.

## When to use

Проверка фрагмента текста на возможные секреты (API keys, tokens, passwords) ПЕРЕД отправкой в чат / коммитом / публикацией. Третий слой защиты поверх pre-commit hook (B7.7a) и PostToolUse redact (B7.7b). Manual gate — пользователь явно вызывает на потенциально чувствительный текст.

## Algorithm

## Шаг 1. Получить вход

Аргумент `$ARGUMENTS` — это **либо**:
- (а) **путь к файлу** (если `$ARGUMENTS` существует как файл) — прочитать содержимое;
- (б) **сам текст** (inline) — взять как есть.

Если нет аргумента — попросить пользователя вставить текст.

## Шаг 2. Запустить проверку

```bash
bash "$IWE_SCRIPTS/route-task.sh" --skill check-secret --args "$ARGUMENTS"
```

Скрипт принимает либо путь либо текст. Возвращает:
- exit 0 + `OK: no secrets detected` — если ничего не найдено;
- exit 1 + классы, количества и номера строк — если найдены потенциальные секреты. Совпавшие строки и значения не выводятся.

## Шаг 3. Интерпретировать результат

**Если OK:** сообщить «известные сигнатуры секретов не найдены» и не представлять это как доказательство полной безопасности.

**Если найдены секреты:**
1. Перечислить найденные паттерны (с метками: Neon API key, GitHub token, и т.д.).
2. Для каждого — рекомендация:
   - Если плейсхолдер/тест/документация — заменить значение на `[REDACTED]` и повторить проверку.
   - Если реальный секрет — НЕ публиковать; запустить cascade rotation (см. `DP.RUNBOOK.003-cascade-secret-rotation.md`); см. правило 25 в `feedback_behaviour.md`.
3. После redaction — повторить проверку.

## Шаг 4. Лог

Каждое использование скилла логируется в `~/IWE/.claude/logs/check-secret.jsonl`. Журнал содержит только время и его часовой интервал, идентификатор сессии при наличии, решение, длину входа, классы и количество совпадений. Значения, строки и производные от содержимого хеши не записываются.

## Связи

- **Расширение:** B7.7a (`secret-leak-block.sh`) и B7.7b (`secret-leak-redact.sh`) — три-слойная защита.
- **Правило поведения:** Правило 25 в `memory/feedback_behaviour.md` — secrets никогда в чат как плейнтекст.
- **Runbook:** `DP.RUNBOOK.003-cascade-secret-rotation.md` для процедуры reactive ротации.
- **Канон паттернов:** `.claude/hooks/secret-bypass-lib.sh`; Bash guard, redactor, check-secret и pre-commit scanner используют один корпус.
