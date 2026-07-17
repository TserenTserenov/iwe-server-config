# Расширение: Метрики качества платформы (WP-462 Ф3)

## Встройка в Day Open

После шага «Day Status Check», добавить шаг:

### Metrics — Фоновый снимок метрик качества

```bash
# Запуск в фоне (fire-and-forget) — не блокирует Day Open
# Если БД недоступна, Day Open не пострадает

METRICS_LOG="${HOME}/IWE/logs/day-open-metrics-$(date +%Y%m%d).log"
bash "${HOME}/IWE/DS-my-strategy/scripts/profile_metrics_snapshot.sh" >> "$METRICS_LOG" 2>&1 &

# Exit code Day Open остаётся 0 (снимок запущен, результат не проверяется)
echo "✓ Метрики качества: фоновый снимок запущен (лог: $METRICS_LOG)"
```

**Назначение:**
- Еженедельный снимок метрик П1 (покрытие пересчётов), П2 (траектории), П3 (переходы ступеней)
- Отправка диагностических приглашений для аккаунтов, у которых last_diagnostic_at > 30 дней
- Результаты вставляются в `causal.measurement_history` (таблица Neon)

**Инвариант:**
- Запуск в фоне (не ожидаем завершения)
- День не зависит от успеха/неудачи снимка
- Если данные не попали в БД — Week Close обнаружит и вставит заглушку

**Логирование:**
- Успех: `SUCCESS: Snapshot complete | P1=X% P2=Y% P3=Z Invites=N`
- Ошибка: логируется в `$METRICS_LOG`, но не влияет на Day Open exit code
