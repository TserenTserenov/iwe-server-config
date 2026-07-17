# Расширение: Синтез метрик качества за месяц (WP-462 Ф3)

## Встройка в Month Close

Во время синтеза Month Report, добавить шаг:

### Quality Metrics — Синтез данных за месяц

```bash
# Переменные (обеспечивает вызывающий протокол)
REPORT_FILE="${REPORT_FILE:-$HOME/IWE/current/MonthReport-$(date +%Y-%m).md}"

MONTH=$(date +%Y-%m)  # текущий месяц

# Проверить наличие снимков за месяц (детерминированная проверка COUNT)
COUNT=$(psql "${DATABASE_URL_INDICATORS}" --set ON_ERROR_STOP=on -t -c \
  "SELECT COUNT(*) FROM causal.measurement_history WHERE TO_CHAR(measurement_week, 'YYYY-MM') = '$MONTH'" 2>/dev/null | tr -d ' ')

if [ "${COUNT:-0}" -eq 0 ]; then
  # Данных нет — вставить честную заглушку в Report
  cat >> "${REPORT_FILE}" <<STUB

## § Качество платформы за месяц ($MONTH)

⚠️ **Снимки не собирались весь месяц**
- Check: логи `profile_metrics_snapshot.sh` в `$HOME/IWE/logs/day-open-metrics-*.log`
- Action: убедиться что Day Open запускается каждый понедельник

Данные будут собраны в следующем месяце.

STUB
else
  # Есть данные — синтезировать месячный отчёт
  bash "${HOME}/IWE/DS-my-strategy/scripts/generate_month_quality_report.sh" --month "$MONTH" >> "${REPORT_FILE}"
fi
```

**Назначение:**
- Синтез месячного тренда метрик (П1, П2, П3)
- Агрегирование недельных снимков в средние/суммарные значения
- Определение рисков и рекомендаций на следующий месяц

**Инвариант:**
- Проверка COUNT (не grep) для детерминированности
- Заглушка информирует если данных нет за весь месяц
- Не прерывает Month Close

**Вывод:**
- Успех: markdown-секция с таблицей трендов, рисков, действий
- Отсутствие данных: заглушка с диагностикой
