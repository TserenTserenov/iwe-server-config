---
name: week-close.after.focustodo
description: WP-470 — секция «Фокус (РП-470)» в WeekReport (недельное время в фокусе + тренд первая/вторая половина недели, Focus To-Do)
hook: after
protocol: week-close
valid_from: 2026-07-26
owner: user
---

# Week Close — секция фокуса (РП-470)

## Секция «Фокус (РП-470)» в WeekReport

**Когда выполнять:** тот же шаг, что `week-close.after.health.md` (шаг 9 Extensions after SKILL week-close) — после записи итогов в WeekReport, до коммита.

**Дизайн:** тот же принцип, что health-секция того же протокола — время в фокусе (Focus To-Do), обязательный маркер покрытия «N из D дней», честная заглушка при отсутствии экспорта вместо тихого пропуска. Источник — разовый ручной экспорт (решение пилота 26.07: без автосинхронизации), не непрерывный поток — покрытие обычно ниже, чем у health.

**Что сделать:**

```bash
# WEEK_START/WEEK_END — понедельник..воскресенье закрываемой недели (не текущей даты)
WEEK_START="YYYY-MM-DD"
WEEK_END="YYYY-MM-DD"
REPORT_FILE="$HOME/IWE/DS-my-strategy/current/WeekReport W{N} YYYY-MM-DD.md"

if grep -q "## Фокус (РП-470)" "$REPORT_FILE"; then
  echo "week-close.after.focustodo: секция уже присутствует — пропуск (idempotent)"
else
  bash "$HOME/IWE/extensions/week-close.focustodo-extra.sh" "$WEEK_START" "$WEEK_END" >> "$REPORT_FILE"
fi
```

**Инвариант:**
- Экспорта нет → скрипт сам пишет честную заглушку, секция всё равно присутствует.
- Вывод детерминированный (JSON-экспорт), LLM его не переписывает.
- Скрипт author-only (личные данные), в FMT-exocortex-template не поставляется.

**Проверка перед коммитом:** `grep -c "Фокус (РП-470)" "$REPORT_FILE"` → ровно 1.
