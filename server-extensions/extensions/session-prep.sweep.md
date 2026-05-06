# Session-Prep Sweep Extension — Авторский

> Шаг 5.5 session-prep.md — Active-WP heartbeat sweep.
> Вызывается через `bash load-extensions.sh session-prep sweep`.
> Автор: Tseren (author_mode). Слой 3 (extensions).

## Шаг 5.5: Запустить heartbeat sweep активных РП

```bash
IWE_WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}"
SWEEP_OUT=$(bash "$IWE_WORKSPACE/scripts/active-wp-sweep.sh" \
  "$IWE_WORKSPACE/DS-my-strategy/inbox" \
  "$IWE_WORKSPACE" 2>/dev/null)
echo "$SWEEP_OUT"
```

Если sweep вернул таблицу с РП — включить её в черновик WeekPlan как секцию:

```markdown
## Активные РП — кандидаты на добавление в план (sweep)

> Найдены через heartbeat-sweep (git-активность ≥7д, status: active/in_progress в inbox).
> Не все попали в WORKPLAN.md или carry-over явно. Проверь на сессии стратегирования.

{{ SWEEP_TABLE }}
```

## Шаг 5.5b: Обновить MEMORY.md «РП текущей недели» (если скрипт есть)

```bash
UPDATER="$IWE_WORKSPACE/scripts/memory-active-wp-update.sh"
if [[ -x "$UPDATER" ]]; then
  bash "$UPDATER" "$IWE_WORKSPACE"
fi
```

## Регрессионный сценарий (4 мая 2026)

Инцидент: серверный session-prep сформировал WeekPlan W19, но WP-245 и WP-151 (оба с закрытыми фазами в тот же день) не попали в план — не были в WORKPLAN.md явно.

Sweep выявил бы их как активные (status: in_progress + git commit за 7д). После Ф7 — воспроизвести dry-run сценарий и убедиться что оба РП попадают в секцию «Кандидаты».

## Связь

- Скрипт: [scripts/active-wp-sweep.sh](../scripts/active-wp-sweep.sh)
- WP-283: [DS-my-strategy/inbox/WP-283-server-day-open-crossplatform.md](../DS-my-strategy/inbox/WP-283-server-day-open-crossplatform.md) Шаг E
- Инцидент: [DS-my-strategy/inbox/bugs/bug-2026-05-04-session-prep-missing-active-wps.md](../DS-my-strategy/inbox/bugs/bug-2026-05-04-session-prep-missing-active-wps.md)
