# Day Open — авторские расширения

<!-- AUTHOR-ONLY -->

### 5a-gate. Gate routing за ночь (WP-423 Ф6.4, информационно)

> Показать после overnight-auditor (04:45 UTC). Неблокирующее: если файл отсутствует — пропустить молча.
> Смысл метрики: какой процент задач прошёл без LLM. Рост % = зрелость реестра рефлексов.

```bash
GATE_LOG="$HOME/.iwe/gate-decisions.jsonl"
if [ -f "$GATE_LOG" ] && [ -s "$GATE_LOG" ]; then
  bash ~/IWE/DS-my-strategy/scripts/gate-metrics.sh "$GATE_LOG" 2>/dev/null \
    || echo "⚠️ gate-metrics.sh: ошибка — пропуск, неблокирующее"
else
  echo "ℹ️ Gate routing: нет данных пока (gate-decisions.jsonl пуст или отсутствует)"
fi
```

---

### 5a. Session Memory Injector: инжекция паттернов косяков (WP-316 Ф12, L2-hook)

> **Запускать ПЕРЕД остальными шагами Day Open.** Замыкает петлю обратной связи: агент видит свои паттерны ДО начала дня.
> Роль: TBD → WP-350. Выбирает 2-3 напоминания контекстно (session_type + текущий WP), не просто топ-3 по trust.
> Исполнитель по умолчанию: Claude Haiku. В будущем: любой LLM-агент (Hermes model, OpenClaw и др.)

```bash
# Session Memory Inject: контекстные напоминания (Haiku, ≤45s, $0.25)
# Fallback автоматический: если claude CLI недоступен → agent_fault_remind.py
bash ~/IWE/DS-autonomous-agents/scripts/session-memory-inject.sh day-open
```

**Вчерашние повторы (intra-session guard):**
```bash
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d)
DB="$HOME/IWE/DS-my-strategy/exocortex/agent-fault-profile/iwe_memory.db"
if [ -f "$DB" ]; then
  sqlite3 "$DB" "
    SELECT '🔴 [' || UPPER(COALESCE(severity,'major')) || '] ' || SUBSTR(content,1,80)
    FROM facts
    WHERE fact_type='agent_fault' AND record_date='$YESTERDAY'
    ORDER BY trust_score DESC LIMIT 5
  " 2>/dev/null | while read row; do echo "  $row"; done
fi
```

**Если есть вчерашние повторы** → добавить секцию в DayPlan «🔴 Вчерашние повторы (держать в уме)».
**Если нет** → пропустить молча.

> Fault decay запускается раз в неделю (Week Close). Запись нового косяка:
> `python3 ~/IWE/DS-my-strategy/scripts/iwe_checklist_memory.py record --fault "..." --severity major`

---

### 5a-stale-alarm. Алерт о зависшем DayPlan (WP-356, peer-сессия 2026-05-29-04)

> Если before.md заархивировал стейл-файлы — вставить 🔴 в DayPlan «Требует внимания».
> Это сигнал пилоту: Day Close был неполным.

```bash
TODAY=$(date +%Y-%m-%d)
FLAG="/tmp/iwe-stale-dayplan-$TODAY.flag"
DAYPLAN="$HOME/IWE/DS-my-strategy/current/DayPlan $TODAY.md"
if [ -f "$FLAG" ] && [ -f "$DAYPLAN" ]; then
  # basename + запятая — читаемо при 2+ файлах
  STALE_FILES=$(cat "$FLAG" | xargs -I{} basename {} | tr '\n' ',' | sed 's/,$//')
  # Вставить строку после заголовка «Требует внимания» через perl (macOS-совместимо)
  perl -i -pe "s|(## Требует внимания)|\\$1\n- 🔴 **Day Close не завершил архивацию** — $STALE_FILES автоархивирован при открытии дня. Проверить: был ли Day Close выполнен?|" "$DAYPLAN" 2>/dev/null || true
  rm -f "$FLAG"
  echo "🔴 Стейл-алерт добавлен в DayPlan (Day Close был неполным)"
fi
```

---

### Здоровье платформы (секция DayPlan — вставлять между «Календарь» и «IWE за ночь»)

> Агрегированная секция по всем сервисам платформы (бот, digital-twin, gateway, content-pipeline, knowledge-mcp). Внутри — подзаголовки по сервисам. Вставлять как отдельный `<details>`-блок при записи DayPlan.

```markdown
<details>
<summary><b>Здоровье платформы</b></summary>

### Бот @aist_me_bot (QA)

**Smoke-тесты:** 🟢 N passed (Xs) / 🔴 N failed

**Дельта:** Сегодня: N (↑↓X vs вчера) | Urgent: N (↑↓X) | За 7д: N (↑↓X vs пред. 7д)

**Lifecycle (30д):**

| Статус | Кол-во | Urgent |
|--------|--------|--------|
| new | N | N |
| classified | N | N |

**Статистика (за всё время):** N вопросов, N полезных (👍), N неудовлетворённых (🔍), N без оценки.

**Кластеры (7д)** — группы похожих жалоб, K = пробел в знаниях бота, U = UX/юзабилити:

| Кластер | Кол-во | Sev | Что значит |
|---------|--------|-----|-----------|
| [название] | N | low/medium/high | [краткое пояснение на русском] |

### Остальные MCP-сервисы

⬜ Нет AI quality отчётов / см. [WP-255](...).

### Operational health

⬜ Нет данных / ссылка на dashboard.

</details>
```

### 5b. Бот QA (расширение)

`DS-agent-workspace/scheduler/feedback-triage/YYYY-MM-DD.md` → дельта, urgent. Проверить дату отчёта. Фильтр 2 дня: только новые жалобы. Нет новых → «нет новых за 2 дня».

**Smoke-тесты (ежедневно):**
```bash
cd ~/IWE/DS-IT-systems/aist_bot_newarchitecture
if [ -d ".venv" ]; then .venv/bin/python -m pytest tests/smoke/ -q --tb=line 2>&1; fi
```
64 теста, <1s. Показать: `🟢 64 passed` или `🔴 N failed` (с именами упавших).

### 5b2. QA Тестировщик (S58, понедельник)

`DS-agent-workspace/tester/weekly-YYYY-MM-DD.md`. Только понедельник (или если файл новый). Показать: L1-L4 статус, failed метрики, red team findings. Нет файла → «QA cron не запускался».

### 5d. Scout + WP-170 (зонтичный)

`DS-agent-workspace/scout/results/YYYY/MM/DD/report.md`. Не проревьюен → «Требует внимания».

**WP-170 Gate:** Проверить накопленные captures:
1. Непроревьюенные report.md за последние 2 дня (⬜ не проверен)?
2. `DS-my-strategy/inbox/captures.md` — есть записи без `[processed]`?
3. `DS-agent-workspace/scout/backlog.yaml` — есть `status: pending` + `type: scan` старше 3 дней?

Если хотя бы одно «да» → добавить WP-170 в план дня (~30-60 мин).

### 5e. KE-кандидаты (Knowledge Extraction)

> Проверить: есть ли extraction-reports, ожидающих разбора R15 Валидатором.
> Молча пропустить если N = 0. Показать секцию если N > 0 — пользователь решит сам.

```bash
REPORTS_DIR="$HOME/IWE/DS-my-strategy/inbox/extraction-reports"
PENDING=$(grep -l "status: pending-review" "$REPORTS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
echo "KE_PENDING=$PENDING"
```

**Если KE_PENDING > 0** → добавить в DayPlan отдельную секцию перед «Требует внимания»:

```markdown
### 📚 KE-кандидаты (Knowledge Extraction)

> N extraction-report(ов) ожидают разбора R15 Валидатором.
> Запустить `/apply-captures` в отдельной сессии (~15 мин).

| Отчёт | Дата | Статус |
|-------|------|--------|
| [список файлов из grep выше] | [дата из frontmatter] | pending-review |

**SLA:** разобрать ≤24ч (DP.SC.004). Команда: `/apply-captures`
```

**Если KE_PENDING = 0** → ничего не выводить, пропустить молча.

**Как заполнить таблицу (bash):**
```bash
for f in "$REPORTS_DIR"/*.md; do
  st=$(grep "^status:" "$f" 2>/dev/null | awk '{print $2}')
  dt=$(grep "^date:" "$f" 2>/dev/null | awk '{print $2}')
  [ "$st" = "pending-review" ] && echo "$(basename $f) | $dt | pending-review"
done
```

### 6d. Авто-архивация устаревших WeekReport (bug-2026-05-12)

> WeekReport закрытой недели не должен оставаться в `current/`. Проверяем по week-номеру в имени файла vs текущая неделя ISO.

```bash
CURRENT_WEEK=$(date +%V)
CURRENT="$HOME/IWE/DS-my-strategy/current"
ARCHIVE="$HOME/IWE/DS-my-strategy/archive/week-reports"
mkdir -p "$ARCHIVE"
for f in "$CURRENT"/WeekReport\ W*.md; do
  [ -f "$f" ] || continue
  wnum=$(basename "$f" | sed -E 's/.*W([0-9]+).*/\1/')
  if [ "$wnum" -lt "$CURRENT_WEEK" ]; then
    echo "🗄️  Архивирую $(basename "$f") (W$wnum < W$CURRENT_WEEK)"
    git -C "$HOME/IWE/DS-my-strategy" mv "$f" "$ARCHIVE/" 2>/dev/null || mv "$f" "$ARCHIVE/"
  fi
done
```

### 7a. Незавершённые диалоговые сессии (DP.SC.154)

> Сканировать `sessions/conversations/*/meta.yaml` — `status: started` + нет `report.md` + `start_time > 6ч назад`.
> Если есть — вывести в «Требует внимания» (WARN, не BLOCK). Молча пропустить если N=0.

```bash
CONV_DIR="$HOME/IWE/DS-my-strategy/sessions/conversations"
SIX_HOURS_AGO=$(date -u -v-6H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-6 hours' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
STALE=()
for meta in "$CONV_DIR"/*/meta.yaml; do
  [ -f "$meta" ] || continue
  status=$(grep "^status:" "$meta" | sed 's/^status: *//; s/"//g')
  [ "$status" != "started" ] && continue
  session_dir="$(dirname "$meta")"
  [ -f "${session_dir}/report.md" ] && continue
  start=$(grep "^start_time:" "$meta" | sed 's/^start_time: *//; s/"//g')
  [ -n "$start" ] && [ "$start" \< "$SIX_HOURS_AGO" ] && STALE+=("$(basename "$session_dir")")
done
if [ ${#STALE[@]} -gt 0 ]; then
  echo "⚠️  Незавершённые диалоговые сессии (>6ч, нет report.md):"
  for s in "${STALE[@]}"; do
    echo "   - $s → bash scripts/peer-session-finalize.sh --finalize $s"
  done
fi
```

### 7c. Незакрытые external-сессии через бот (WP-358 Ф10)

> Сканировать `inbox/agent/sessions/SESSION-*.md` (Telegram-инициированные сессии через `/claude`).
> Незакрытая = status != "completed" ИЛИ (status: completed И возраст ≥24ч без перемещения в `sessions/external/`).
> Backfill 52 файлов pre-cutover не делаем — фильтр по mtime ≥ CUTOVER_DATE (см. скрипт).
> При N>0 — **вставить markdown-секцию в DayPlan** (между «Требует внимания» и «Контекст недели») + продублировать в stdout.
> Молча пропустить при N=0. Аналог 7a, но для external-канала (DP.SC.162), не peer (DP.SC.154).

```bash
SECTION=$(bash ~/IWE/DS-my-strategy/scripts/check-open-sessions.sh 2>/dev/null)
if [ -n "$SECTION" ]; then
  echo "$SECTION"
  FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | head -1)"
  if [ -f "$FILE" ] && ! grep -q "Незакрытые сессии" "$FILE"; then
    # Вставить перед секцией «Контекст недели» или в конец, если её нет
    if grep -q "<summary><b>Контекст недели" "$FILE"; then
      python3 -c "
import sys
file=sys.argv[1]; section=sys.argv[2]
with open(file) as f: lines=f.readlines()
out=[]
inserted=False
for line in lines:
    if not inserted and '<summary><b>Контекст недели' in line:
        out.append(section+'\n\n')
        inserted=True
    out.append(line)
with open(file,'w') as f: f.writelines(out)
" "$FILE" "$SECTION"
      echo "  ✅ Секция «Незакрытые сессии» вставлена в DayPlan"
    fi
  fi
fi
```

- [ ] Если есть `SESSION-*` post-cutover в `inbox/agent/sessions/` со status != completed или age≥24ч — секция вставлена в DayPlan со ссылками. Финализация — DP.SC.162 §close.

### 7b. Верификация DayPlan (БЛОКИРУЮЩЕЕ перед коммитом)

> Загрузить и выполнить `extensions/day-open.checks.md` ПОСЛЕ записи файла DayPlan, ДО `git commit`.
> Порядок шага 7: записать файл → пройти checks → `git commit` → `git push` → compact dashboard.

### Горлышко недели (секция DayPlan — вставлять в начало «Контекст недели»)

> Динамический bottleneck-анализ на основе текущего WeekPlan + активных РП + git за 7д. Заменяет статическое «фокус недели» — обновляется каждое Day Open.
> Вставляется как первая подсекция «Контекст недели», ПЕРЕД остальными элементами.

**Автоматическая инъекция (WP-356, peer-сессия 2026-05-29-04; переведено на общий скрипт — WP-484 Ф2, 2026-07-13):**

> Раньше эта инструкция инлайнила regex-вставку сама — её anchor (`**Контекст недели W`) разошёлся с фактической разметкой скаффолда (`<summary><b>Контекст недели`) и вставка молча no-op'илась почти всегда (эмпирически: маркер BY-SCRIPT встретился в 6 из 139 архивных DayPlan). Теперь и этот шаг, и headless-конвейер (`day-open-pipeline.sh` шаг 3.5) вызывают один и тот же исправленный скрипт — исправление в одном месте чинит оба пути.

```bash
TODAY=$(date +%Y-%m-%d)
DAYPLAN="$HOME/IWE/DS-my-strategy/current/DayPlan $TODAY.md"
bash "$HOME/IWE/DS-my-strategy/scripts/day-open-bottleneck-patch.sh" "$DAYPLAN"
```

Если YAML не найден, скрипт вставляет честный маркер `<!-- BOTTLENECK-PENDING -->` (не молчание) — `day-open.checks.md` показывает его как 🟡 в «Требует внимания», не блокирует commit.

**Запрещено:** писать «Горлышко недели» руками — checks заблокируют commit (см. `day-open.checks.md` блок «🔴 Калибровка скилла /bottleneck-pick»). Источник правила: peer-сессия 2026-05-28-04-day-open-checks-fix, фикс косяка 24 мая (feedback_skill_manual_synthesis_bypass).

**Если YAML не найден:** запустить `/bottleneck-pick --target weekplan --layer intra --horizon week --depth 1` вручную → скрипт выше подхватит при следующем прогоне after.md.

Структура выжимки (генерируется скриптом из YAML):

```markdown
<!-- BY-SCRIPT: bottleneck-section-from-yaml.sh -->
**Горлышко недели (SC-first, YYYY-MM-DD):**

- **SC-failing:** <DP.SC.NNN>
- **Bottleneck:** <блок / направление / фаза>
- **Class:** <Policy / Resource / Cognitive>
- **Этап 1:** <action_taken из YAML>
```

**Когда пропустить:**
- Понедельник до Strategy Session — нет актуального WeekPlan, дождаться сессии
- Бюджет вычисления >5 мин — отложить на отдельную сессию, оставить пометку «горлышко: см. /bottleneck-pick weekplan»
- WeekPlan не обновлялся ≥3 дней (стейл-сигнал) — флаг ⚠️ к выжимке

**Platform-уровень (раз в неделю, по понедельникам):**

Дополнительный запуск для cross-system анализа:
```
/bottleneck-pick --target b2:aisystant --layer platform --horizon week --depth 2
```
Результат сохраняется в `DS-my-strategy/inbox/bottleneck-pick-runs/` и сравнивается с прошлой неделей для bottleneck-shift detection (DP.M.061).

### 8. Emit day_plan_opened (WP-151 Блок B)

> После commit DayPlan (шаг 7, финал) → отправить событие в event-gateway.
> Идемпотентно: повторный запуск → 200 `{idempotent: true}`, не дублирует.

```bash
DATE=$(date +%Y-%m-%d)
ENV_FILE="$HOME/.config/aist/env"
ACCOUNT_ID=$(grep '^export DT_USER_ID=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
EVENT_GW="${EVENT_GATEWAY_URL:-https://event-gateway.aisystant.workers.dev}"
IS_STRATEGY=$([ "$(date +%u)" = "1" ] && echo "true" || echo "false")
EXT_ID="day-plan-opened-${DATE}-${ACCOUNT_ID:0:8}"

if [ -z "$ACCOUNT_ID" ]; then
  echo "⚠️ DT_USER_ID не задан в $ENV_FILE — пропуск emit day_plan_opened"
else
  RESP=$(curl -sf -X POST "$EVENT_GW/events" \
    -H "Content-Type: application/json" \
    -d "{\"source\":\"iwe\",\"event_type\":\"day_plan_opened\",\"schema_version\":\"v1\",\"external_id\":\"$EXT_ID\",\"account_id\":\"$ACCOUNT_ID\",\"payload\":{\"plan_date\":\"$DATE\",\"is_strategy_day\":$IS_STRATEGY}}" 2>&1)
  echo "$RESP" | grep -q '"inserted"' && echo "✅ day_plan_opened → learning.domain_event" || echo "⚠️ emit: $RESP (non-blocking)"
fi
```

### 9. Контент — тема дня (WP-442 Ф9, L3 авторское)

> Запускать в конце Day Open, после сборки DayPlan. Всегда: шаг встроен в LLM-сессию, не bash.
> Источник истины предложений: `DS-Tseren-Brand/content/topic-log.yaml`

**Шаг 9.1 — Проверить непринятые темы:**

Прочитай `DS-Tseren-Brand/content/topic-log.yaml`. Для каждой записи со статусом `proposed`:
- Вычисли возраст: сегодня − `proposed`
- Если 3-7 дней: добавь в DayPlan строку `⚠️ Тема C-NNN «[hook]» ожидает ответа (N дней). Принять / отклонить?`
- Если 7-14 дней: добавь строку `🔴 Тема C-NNN «[hook]» ожидает 7+ дней. Если неактуально — отклоняй (пишу rejected).`
- Если >14 дней: обнови статус на `archived` прямо в файле (Edit), добавь в DayPlan информационную строку.

**Шаг 9.2 — Сгенерировать тему дня:**

Прочитай (без дополнительных API-вызовов — всё уже в сессии):
1. `git log --oneline --since=7.days` для всех IWE-репо — что делал пилот
2. Последние 2 файла `DS-my-strategy/current/Day-*.md` — контекст, место, настроение
3. `DS-my-strategy/docs/Dissatisfactions.md` — стратегические неудовлетворённости
4. `DS-Tseren-Brand/content/topic-log.yaml` — что уже предлагали (не повторять в пределах 14 дней)
5. `DS-Tseren-Brand/08-content-themes.md` — таксономия O1-O6 для выравнивания

Эвристика выравнивания: посмотри на последние 3 предложенные темы в topic-log. Если все из одной области — предложи из другой.

Эвристика T3: если в topic-log нет записи `type: T3, status: accepted` за последние 14 дней → дополнительно предложи одну T3-тему (видео-скрипт) вместо резервной. Иначе — предлагай обе как T1.

Сформируй 1 основную тему + 1 резервную в формате:

```markdown
## Контент — тема дня
**Основная:** [O4/I3/T1] «Крючок-заголовок темы»
Почему сейчас: <1 строка — связь с текущим контекстом пилота>

**Резервная:** [O5/I5/T1] «Крючок-заголовок»
```

**Шаг 9.3 — Записать в трекер:**

Добавь новую запись в `DS-Tseren-Brand/content/topic-log.yaml` (в список `topics:`):
```yaml
- id: C-NNN  # следующий номер после последнего
  proposed: YYYY-MM-DD
  area: OX
  hypostasis: IX
  type: TX
  hook: "..."
  why_now: "..."
  status: proposed
  accepted: null
  published: null
  draft_path: null  # path to video/ideas/ or content/posts/ file; set when file is created, not at acceptance
  notes: ""
```

Вставь в конец DayPlan перед подписью блок в формате `<details>/<summary>` (совпадает со стилем всех секций DayPlan):
```markdown
<details>
<summary><b>Контент — тема дня</b></summary>

**Основная:** [O-код/I-код/T-код] «Крючок-заголовок темы»
Почему сейчас: <1 строка — связь с контекстом>

**Резервная:** [O-код/I-код/T-код] «Крючок-заголовок»

</details>
```

**Ручной запрос:** если пилот пишет «дай темы» или «предложи контент» → выполни шаг 9.2 с 5 вариантами вместо 2. Записать только принятые (статус accepted сразу при выборе).

<!-- /AUTHOR-ONLY -->
