# Расширение: Синтез метрик качества за неделю (WP-462 Ф3)

## Встройка в Week Close

Во время синтеза Week Report, добавить шаг:

### Quality Metrics — Синтез данных за неделю

```bash
# Переменные (обеспечивает вызывающий протокол)
REPORT_FILE="${REPORT_FILE:-$HOME/IWE/current/WeekReport-$(date +%Y-W%V).md}"

WEEK="W$(date +%V)"  # текущая неделя
WEEK_START=$(date -v-$((($(date +%w) + 6) % 7))d +%Y-%m-%d)  # macOS-compatible (не GNU date -d)

# Проверить наличие снимка за эту неделю (детерминированная проверка COUNT)
COUNT=$(psql "${DATABASE_URL_INDICATORS}" --set ON_ERROR_STOP=on -t -c \
  "SELECT COUNT(*) FROM causal.measurement_history WHERE measurement_week = '$WEEK_START'::DATE" 2>/dev/null | tr -d ' ')

if [ "${COUNT:-0}" -eq 0 ]; then
  # Данных нет — вставить честную заглушку в Report
  cat >> "${REPORT_FILE}" <<STUB

## § Метрики качества платформы ($WEEK)

⚠️ **Снимок не выполнен на неделе** 
- Check: логи `profile_metrics_snapshot.sh` в `$HOME/IWE/logs/day-open-metrics-*.log`
- Возможные причины: БД недоступна, скрипт упал, или Day Open не запустился

Данные будут собраны в следующей неделе.

STUB
else
  # Есть данные — синтезировать полный отчёт
  bash "${HOME}/IWE/DS-my-strategy/scripts/generate_week_quality_report.sh" "$WEEK" >> "${REPORT_FILE}"
fi
```

**Назначение:**
- Синтез еженедельного снимка в markdown-секцию для WeekReport
- Отображение метрик П1, П2, П3 с трендами
- Честное уведомление если данных нет (не маскирование нулём)

**Инвариант:**
- Проверка COUNT (не grep) для детерминированности
- Заглушка информирует пилота об отсутствии данных, указывает на логи
- Не прерывает Week Close даже если скрипт упал

**Вывод:**
- Успех: markdown-секция с таблицей метрик + статусом валидации P3
- Отсутствие данных: заглушка с указанием как диагностировать
