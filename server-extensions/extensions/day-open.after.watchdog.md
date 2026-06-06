# Day Open — date-watchdog hook (WP-357 Ф3)

<!-- AUTHOR-ONLY -->

### Date Pipeline Watchdog (in-band)

> Запускается из Day Open ПОСЛЕ scaffold, ПЕРЕД compact dashboard.
> Регенерирует ledger + проверяет пропущенные процессы.
> Out-of-band watchdog (launchd, каждый час) — отдельно через `com.iwe.date-watchdog.plist`.

```bash
# 1. Регенерация date-ledger (derived artifact)
bash "$HOME/IWE/DS-my-strategy/scripts/date-ledger-gen.sh" 2>&1 | tail -3

# 2. Watchdog in-band (без Telegram-дайджеста — он в out-of-band)
WATCHDOG_OUT=$(bash "$HOME/IWE/DS-my-strategy/scripts/date-watchdog.sh" --mode in-band 2>&1)
echo "$WATCHDOG_OUT" | tail -5

# 3. Извлечь alerts для DayPlan
ALERTS_FILE="$HOME/.claude/state/watchdog-alerts.json"
if [ -f "$ALERTS_FILE" ]; then
    ALERT_COUNT=$(python3 -c "import json; d=json.load(open('$ALERTS_FILE')); print(d.get('current_alert_count', 0))" 2>/dev/null || echo 0)
    if [ "$ALERT_COUNT" -gt 0 ]; then
        echo "⚠️  Watchdog: $ALERT_COUNT пропущенных процессов — см. секцию «Требует внимания»"
    fi
fi
```

**Если ALERT_COUNT > 0** → добавить в секцию «Требует внимания» DayPlan:

```markdown
### ⏰ Watchdog: пропущенные процессы

> N процессов не запустились в ожидаемое время.
> Подробности: `~/.claude/state/watchdog-alerts.json`

| Процесс | Ритм | Last run | Overdue |
|---------|------|----------|---------|
| [id] | [rhythm] | [last_run или never] | Xh |
```

**Если ALERT_COUNT = 0** → пропустить молча.

<!-- /AUTHOR-ONLY -->
