---
name: strategy-session.after.focustodo
description: WP-470 — секция «Фокус (РП-470)» в discovery-контекст Strategy Session (30-дневное время в фокусе + тренд, Focus To-Do)
hook: after
protocol: strategy-session
valid_from: 2026-07-26
owner: user
---

# Strategy Session — секция фокуса (РП-470)

## Секция «Фокус (РП-470)» в discovery-контекст

**Когда выполнять:** тот же шаг, что `strategy-session.after.health.md` (шаг 3.2, режим discovery) — как один из входных фактов о состоянии пилота.

**Автовызов не подключён (тот же Extensions Gate, что у health-версии):** `SKILL.md` `strategy-session` не читает `load-extensions.sh strategy-session after` вообще — это платформенный (L1) файл, правится только через `update.sh`/автора. До промоции — Стратег читает этот файл вручную на шаге 3.2 и выполняет команду ниже сам, вместе с health-секцией.

**Дизайн:** те же метрики, что в Day Open/Week Close/Month Close (время в фокусе, число помидоров), окно — последние 30 дней от даты сессии. Источник — разовый ручной экспорт (решение пилота 26.07), не непрерывный поток.

**Что сделать:**

```bash
PERIOD_END=$(date +%Y-%m-%d)
PERIOD_START=$(date -v-30d +%Y-%m-%d)  # macOS date; 30 дней назад
bash "$HOME/IWE/extensions/strategy-session.focustodo-extra.sh" "$PERIOD_START" "$PERIOD_END"
```

Вывести результат прямо в контекст обсуждения (не файл-артефакт), рядом с health-секцией.

**Инвариант:**
- Экспорта нет → скрипт сам пишет честную заглушку.
- Скрипт author-only (личные данные), в FMT-exocortex-template не поставляется.
