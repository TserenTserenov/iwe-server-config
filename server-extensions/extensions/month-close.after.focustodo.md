---
name: month-close.after.focustodo
description: WP-470 — срез «Фокус (РП-470)» локально вне git + строка-указатель в MonthClose (Focus To-Do)
hook: after
protocol: month-close
valid_from: 2026-07-26
owner: user
---

# Month Close — срез фокуса (РП-470)

## Шаг. Срез «Фокус (РП-470)»: локальный файл + указатель в MonthClose

**Когда выполнять:** тот же шаг, что `month-close.after.health.md` — ПОСЛЕ записи `archive/MonthClose YYYY-MM.md`, ДО коммита.

**Резидентность:** та же логика, что у health-среза того же протокола — `archive/MonthClose YYYY-MM.md` коммитится и пушится на GitHub, персональные значения фокуса в него попадать не должны. Скрипт пишет полную секцию (недели + тренд + маркер покрытия) в локальный файл `~/Library/IWE/focustodo-data/month-summaries/YYYY-MM.md` (вне git), в stdout — только строка-указатель без значений.

**Дизайн:** те же метрики (время в фокусе, число помидоров), тот же принцип «недели + тренд». Источник — разовый ручной экспорт (решение пилота 26.07), не непрерывный поток — покрытие обычно ниже, чем у health.

**Что сделать:**

```bash
MONTH="YYYY-MM"  # закрываемый период, из шага 1a
REPORT_FILE="$HOME/IWE/DS-my-strategy/archive/MonthClose $MONTH.md"

if grep -q "Фокус (РП-470)" "$REPORT_FILE"; then
  echo "month-close.after.focustodo: строка-указатель уже присутствует — пропуск (idempotent)"
else
  bash "$HOME/IWE/extensions/month-close.focustodo-extra.sh" "$MONTH" >> "$REPORT_FILE"
fi
```

**Инвариант:**
- В MonthClose — ТОЛЬКО строка-указатель без значений; сами цифры — только в локальном файле вне git.
- Экспорта нет → скрипт пишет честную заглушку без значений, строка всё равно присутствует.
- Скрипт author-only (личные данные), в FMT-exocortex-template не поставляется.

**Проверка перед коммитом:** `grep -c "Фокус (РП-470)" "$REPORT_FILE"` → ровно 1, и в MonthClose нет строк вида `| W[0-9]* (...) | *ч |` из таблицы фокуса.
