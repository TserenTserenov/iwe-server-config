---
name: week-close.after.health
description: WP-470 Ф5 — value-free указатель на локальные health-данные в WeekReport (резидентность WP-469)
hook: after
protocol: week-close
valid_from: 2026-07-25
owner: user
---

# Week Close — локальные данные здоровья (РП-470)

## Указатель на локальные health-данные в WeekReport (БЛОКИРУЮЩЕЕ)

**Когда выполнять:** шаг 9 (Extensions after) SKILL week-close — после шага 8 (запись итогов в WeekReport), до шага 11 (коммит).

**Резидентность (WP-469, исправление 22.08):** WeekReport коммитится и пушится в Git. Поэтому числовые показатели сна, пульса и плавания в него не записываются. Источник остаётся в локальной `health.db`; недельный срез пересчитывается по запросу. В WeekReport допустима только строка-указатель без health-значений.

**Что сделать:**

```bash
# WEEK_START/WEEK_END — понедельник..воскресенье закрываемой недели (не текущей даты)
WEEK_START="YYYY-MM-DD"
WEEK_END="YYYY-MM-DD"
REPORT_FILE="$HOME/IWE/DS-my-strategy/current/WeekReport W{N} YYYY-MM-DD.md"

if grep -q "^_Здоровье (РП-470):" "$REPORT_FILE"; then
  echo "week-close.after.health: указатель уже присутствует — пропуск (idempotent)"
else
  bash "$HOME/IWE/extensions/week-close.summary-extra.sh" "$WEEK_START" "$WEEK_END" >> "$REPORT_FILE"
fi

if grep -Eq '^\|[[:space:]]*(Сон|Пульс покоя|Плавание)[[:space:]]*\|' "$REPORT_FILE"; then
  echo "week-close.after.health: ОШИБКА — health-значения обнаружены в git-tracked WeekReport" >&2
  exit 1
fi
```

**Инвариант:**
- В WeekReport — только строка-указатель без значений; таблица сна/пульса/плавания блокирует коммит.
- Данных нет → скрипт пишет честную value-free заглушку, тихий пропуск запрещён.
- Скрипт author-only, в FMT-exocortex-template не поставляется.

**Проверка перед коммитом:** указатель встречается ровно один раз, а проверка ниже возвращает ноль строк:

```bash
grep -c "^_Здоровье (РП-470):" "$REPORT_FILE"
grep -En '^\|[[:space:]]*(Сон|Пульс покоя|Плавание)[[:space:]]*\|' "$REPORT_FILE"
```

**Не встроено:** привязка к стоп-листу «перегрузка/выгорание». Если она понадобится, потребитель должен читать локальную базу, не Git-отчёт.
