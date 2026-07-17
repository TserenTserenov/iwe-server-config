---
name: rival-factors-extension
description: Ход 3 РП-290 — guardrail для честного рунга 2. Пилот записывает смешанные переменные (rival_factors) при Week Close.
triggers:
  - week-close
applies_to:
  - run-protocol
integration_type: subprocess
layer: L3
status: testing
---

# Extension: rival-factors (РП-290 Ход 3)

## Когда срабатывает

При выполнении `/run-protocol close` с аргументом `week` — после основного чек-листа Week Close.

## Что делает

Вызывает интерактивный скрипт `scripts/record-rival-factors.sh`, где пилот отвечает на вопрос:

> Какие факторы кроме целевого действия повлияли на эту неделю?

Ответы записываются в `causal.rival_factors_log`. Сразу после — `scripts/merge-rival-factors.sh` переносит накопленные ответы в `hypothesis_evaluation.rival_factors` для всех оценок гипотез, чей период наблюдения покрывает записанную неделю (объединение без дублей, безопасно при повторном запуске).

## Интеграция

Добавить в `run-protocol.sh` после выполнения основного чек-листа Week Close (перед синтезом отчёта):

```bash
if [ "$PROTOCOL" = "close" ] && [ "${CLOSE_TYPE:-}" = "week" ]; then
  PILOT_ACCOUNT_ID="${PILOT_ACCOUNT_ID:-}"
  if [ -z "$PILOT_ACCOUNT_ID" ] && [ -f "$HOME/.secrets/neon" ]; then
    PILOT_ACCOUNT_ID=$(grep 'PANEL_ACCOUNT_ID=' "$HOME/.secrets/neon" | head -1 | sed 's/.*=//' | tr -d '"')
  fi
  if [ -z "$PILOT_ACCOUNT_ID" ]; then
    echo "⚠ \$PILOT_ACCOUNT_ID не установлена и не найдена в ~/.secrets/neon — запись rival_factors пропущена"
  else
    echo ""
    echo "=== Guardrail для честной оценки гипотез (РП-290) ==="
    NEON_BASE=$(grep 'NEON_PROD_BASE=' "$HOME/.secrets/neon" | head -1 | sed 's/.*=//' | tr -d '"')
    NEON_DATABASE_URL="${NEON_BASE}/learning?sslmode=require" \
    bash ~/IWE/DS-my-strategy/scripts/record-rival-factors.sh \
      "$PILOT_ACCOUNT_ID" \
      || { echo "⚠ запись rival_factors прервана: exit $?"; true; }

    NEON_DATABASE_URL="${NEON_BASE}/learning?sslmode=require" \
    bash ~/IWE/DS-my-strategy/scripts/merge-rival-factors.sh \
      || { echo "⚠ перенос rival_factors в оценки гипотез прервана: exit $?"; true; }
  fi
fi
```

## Требования

- `scripts/record-rival-factors.sh` и `scripts/merge-rival-factors.sh` существуют и исполняются
- Таблицы `causal.rival_factors_log` и `causal.hypothesis_evaluation` созданы и развёрнуты на prod (2026-07-04, БД `learning`)
- `PILOT_ACCOUNT_ID` — если не задана явно env-переменной, берётся из `PANEL_ACCOUNT_ID` в `~/.secrets/neon` (подтверждён как account_id пилота: присутствует в потоке `domain_event`, используется в WP-417 panel-worker)

## Тестирование

```bash
# Mock-запуск (без интеракции)
echo "1 2 4" | NEON_DATABASE_URL="..." \
  ./scripts/record-rival-factors.sh \
  "550e8400-e29b-41d4-a716-446655440000" "2026-07-07"
```

## Граница

Это extension (`.claude/rules/` не трогается) → safe. Встроится в Week Close опционально (нет ошибки если отсутствует).
