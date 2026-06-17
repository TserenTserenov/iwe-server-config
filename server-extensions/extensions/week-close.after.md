## Авторские проверки Week Close

### WP-REGISTRY integrity audit (peer-session 2026-06-01-21)

> **Цель:** L2 periodic reconciliation. Semantic check + аудит exemption-tag `[no-registry-touch]`.
> Не блокирует Week Close — генерирует список расхождений и счётчик обходов.

**Выполнить:**

```bash
# 1. Semantic check: status в реестре vs placement в inbox/archive
SEM_OUT=$(python3 ~/IWE/DS-my-strategy/scripts/build-active-wp.py --semantic-check 2>&1 || true)
SEM_COUNT=$(echo "$SEM_OUT" | grep -cE '^  - WP-' || true)
echo "=== WP-REGISTRY semantic check ==="
if [ "$SEM_COUNT" -gt 0 ]; then
  echo "⚠️  Расхождений: $SEM_COUNT"
  echo "$SEM_OUT" | grep -E '^  - WP-' | head -20
  if [ "$SEM_COUNT" -gt 20 ]; then
    echo "    (показано первые 20 из $SEM_COUNT)"
  fi
else
  echo "✅ Semantic OK — статус в реестре соответствует placement в inbox/archive."
fi

# 2. Counter exemption-tag [no-registry-touch] за последние 7 дней
# Scope: subject-only (--pretty='%s'). Иначе narrative-упоминания тега в body
# создают false positive (см. lessons_grep_counter_narrative_false_positive.md).
TAG_COUNT=$(cd ~/IWE/DS-my-strategy && git log --since="7 days ago" --pretty='%s' 2>/dev/null | grep -cF '[no-registry-touch]' || true)
echo ""
echo "=== Exemption tag [no-registry-touch] audit ==="
echo "Использовано за 7 дней: $TAG_COUNT"
if [ "$TAG_COUNT" -gt 2 ]; then
  echo "⚠️  ВЫШЕ ПОРОГА (>2/неделя). Проверь причины:"
  cd ~/IWE/DS-my-strategy && git log --since="7 days ago" --pretty='  %h %s' 2>/dev/null | grep -F '[no-registry-touch]'
  echo ""
  echo "    Если злоупотребление — обсудить в Strategy Session."
fi
```

**Чеклист Week Close:**

- [ ] Semantic-check выполнен. Расхождения (если >0) — добавить в Backlog или закрыть в Strategy Session.
- [ ] Exemption-tag счётчик ≤2/неделя ИЛИ ≥3 → проверены причины (legit vs abuse).

---

### WP-383 пост-закрытие: мониторинг routing + экономики (peer-session 2026-06-10-18)

> **Источник:** peer-консенсус 2026-06-10. Хранитель: Week Close. Не требует открытого РП.

**Выполнить:**

```bash
# 1. routing-drift.log — проверить наличие и содержимое
DRIFT_LOG="$HOME/IWE/DS-my-strategy/inbox/WP-383/routing-drift.log"
if [ -f "$DRIFT_LOG" ]; then
  DRIFT_COUNT=$(wc -l < "$DRIFT_LOG" | tr -d ' ')
  echo "=== routing-drift.log: $DRIFT_COUNT записей ==="
  tail -10 "$DRIFT_LOG"
  echo "Оцени актуальность routing-таблицы v2 (routing-design-v1.md §3)."
else
  echo "routing-drift.log не существует (нет отклонений от таблицы v2)."
fi

# 2. cost_usd batch check — посчитать report.md без поля
MONTH=$(date +%Y-%m)
MISSING=$(grep -rL "cost_usd:" "$HOME/IWE/DS-my-strategy/sessions/$MONTH/" --include="report.md" 2>/dev/null | wc -l | tr -d ' ')
echo ""
echo "=== cost_usd: отчётов без поля за текущий месяц: $MISSING ==="
if [ "$MISSING" -gt 3 ]; then
  echo "⚠️  Больше 3 отчётов без cost_usd — напомни заполнять поле."
fi

# 3. Валидация экономики — если накоплено ≥10 отчётов с cost_usd
FILLED=$(grep -rl "cost_usd:" "$HOME/IWE/DS-my-strategy/sessions/$MONTH/" --include="report.md" 2>/dev/null | wc -l | tr -d ' ')
if [ "$FILLED" -ge 10 ]; then
  echo "✅ Накоплено $FILLED отчётов с cost_usd — сверь суммарную экономию с routing-design-v1.md §6."
  echo "   Порог расхождения: 5%. При >5% — создать задачу на корректировку таблицы v2."
fi
```

**Чеклист:**

- [ ] routing-drift.log просмотрен (если существует); таблица v2 актуальна ИЛИ создана задача на корректировку.
- [ ] cost_usd: ≤3 отчётов без поля за месяц ИЛИ выдано напоминание.
- [ ] Если накоплено ≥10 отчётов с cost_usd — экономика сверена с routing-design-v1.md §6.

---

### Guard: канонический множитель (Ф8.3, WP-139)

> **Цель:** Week Close НЕ завершается при 0x/пустом множителе — силент-фейл парсера невидим.

**Выполнить ДО написания поста:**

```bash
# Запустить dry-run и проверить weekly_multiplier
MULT_JSON=$(bash ~/IWE/DS-IT-systems/DS-ai-systems/synchronizer/scripts/dt-collect.sh --dry-run 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
mult = data.get('weekly_multiplier', 0)
budget = data.get('weekly_budget_closed', 0)
print(f'weekly_multiplier={mult}, weekly_budget_closed={budget}')
")
echo "$MULT_JSON"
```

**Критерий блокировки:** `weekly_multiplier == 0` И `weekly_budget_closed == 0`
- Если оба 0 → **СТОП Week Close.** Парсер мультипликатора не нашёл данные.
  Диагностика: `bash ~/IWE/DS-IT-systems/DS-ai-systems/synchronizer/scripts/dt-collect.sh --dry-run`
  Проверить: DayPlan-ы за неделю существуют? Формат «Бюджет закрыт» совпадает?
  Зафиксировать вручную множитель в WeekPlan и только потом закрыть.
- Если `weekly_multiplier > 0` → продолжать.
- Если только `weekly_budget_closed > 0` но `weekly_multiplier == 0` → WakaTime недоступен, не блокер (записать ∞/N/A).

- [ ] **Guard выполнен** — `weekly_multiplier` не 0 (или задокументировано исключение)

---

### Linear sync — закрытие done-РП (Week Close)

> **Цель:** привести Linear в соответствие с REGISTRY.md — закрыть задачи для всех ✅-РП.
> **Не блокирует Close.** Ошибки Linear — предупреждение, не стоп.

**Алгоритм:**

1. Получить список done-РП из REGISTRY (номера WP-NNN)
2. Для каждого — проверить статус в Linear через `mcp__ext-linear__search_issues`
3. Закрыть те, что ещё `In Progress` / `Todo`, через `mcp__ext-linear__update_issue` (state → Done/Cancelled)

```bash
# Быстрая выборка done-РП из REGISTRY для передачи в Linear
grep '✅' ~/IWE/DS-my-strategy/docs/WP-REGISTRY.md | \
  grep -oP 'WP-\d+' | sort -t- -k2 -n | tail -30
```

**Чеклист:**

- [ ] **Список done-РП получен** из REGISTRY
- [ ] **Linear проверен** — найдены расхождения (или их нет)
- [ ] **Linear обновлён** (или зафиксировано «Linear недоступен» с причиной)

---

### Написание недельного поста из черновика (S-19, тестируется)

> **Источник:** `DS-Knowledge-Index-Tseren/docs/{YYYY}/{NN}-{месяц}/week-draft-w{NN}.md`
> **Цель:** финальный пост в `DS-Knowledge-Index-Tseren/docs/{YYYY}/{NN}-{месяц}/{YYYY-MM-DD}-week-review-w{NN}.md`
> **Правило:** писать пост НЕ с нуля — на основе накопленного черновика (4 уровня × 7 дней + метрики + инсайты).

**Алгоритм:**
1. Прочитать `week-draft-w{NN}.md` целиком
2. Выделить главный инсайт недели (что из 4 уровней повторялось или выделилось)
3. Предложить 3-5 вариантов заголовка → пользователь выбирает
4. Написать пост 400-700 слов: 4 уровня переплетены без явных заголовков (правило §3 `DS-Knowledge-Index-Tseren/CLAUDE.md`)
5. Встроить метрики в текст (не таблицей)
6. Финал: carry-over → W{N+1} из секции черновика
7. Итоговая строка-метрики (коммиты, репо, дни, задачи)
8. Frontmatter: `target: club`, `audience: community`, `tags: [итоги-недели, W{NN}]`, `status: ready`
9. Exit Protocol поста (§5 CLAUDE.md репо): обложка → README.md → commit/push

**После публикации:**
- Черновик не удаляется — остаётся в `docs/{YYYY}/{NN}-{месяц}/` как исходник
- На следующей неделе создаётся новый `week-draft-w{NN+1}.md` на Пн Day Close (первая запись дня)

- [ ] **Черновик прочитан** целиком
- [ ] **Главный инсайт выделен**
- [ ] **3-5 заголовков предложены** → выбран
- [ ] **Пост написан** (400-700 слов, 4 уровня переплетены)
- [ ] **Метрики недели посчитаны** и встроены в текст
- [ ] **Интегральный показатель** (прогресс месяца) записан
- [ ] **Exit Protocol поста** выполнен (обложка, README, commit, push)

---

### Emit weekly_hypothesis_set / weekly_hypothesis_closed (WP-151 Блок B)

> Выполнить **после** написания недельного поста, перед финальным commit.
> Заполнить поля из контекста стратегической сессии / WeekPlan W{N}.
>
> `target_lever`: W | M1 | M2 | M3 | M4 | resources
> `target_characteristic`: clarity | agency | composure | regularity | production_capacity | productivity | resourcefulness | stress_resilience
> `actual_idx_delta`: фактический прирост по шкале 0-2 (0=без изменений, 1=+1 пункт, 2=+2 пункта)

```bash
ENV_FILE="$HOME/.config/aist/env"
ACCOUNT_ID=$(grep '^export DT_USER_ID=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
EVENT_GW="${EVENT_GATEWAY_URL:-https://event-gateway.aisystant.workers.dev}"
WEEK_START=$(date -d "last Monday" +%Y-%m-%d 2>/dev/null || date -v-Mon +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
WEEK_ISO=$(date +%V | sed 's/^0//')
EXT_SET="weekly-hyp-set-W${WEEK_ISO}-${ACCOUNT_ID:0:8}"
EXT_CLOSED="weekly-hyp-closed-W${WEEK_ISO}-${ACCOUNT_ID:0:8}"

# Заполнить из контекста стратегической сессии / WeekPlan W{N}:
LEVER=<рычаг_недели: W|M1|M2|M3|M4|resources>
CHARACTERISTIC=<характеристика: composure|regularity|...>
HYPOTHESIS="<текст гипотезы>"
EXPECTED_DELTA=<0-2 или null>
ACTUAL_DELTA=<фактический прирост 0-2>

if [ -z "$ACCOUNT_ID" ]; then
  echo "⚠️ DT_USER_ID не задан — пропуск emit weekly_hypothesis"
else
  # 1. weekly_hypothesis_set (план)
  RESP=$(curl -sf -X POST "$EVENT_GW/events" \
    -H "Content-Type: application/json" \
    -d "{\"source\":\"iwe\",\"event_type\":\"weekly_hypothesis_set\",\"schema_version\":\"v1\",\"external_id\":\"$EXT_SET\",\"account_id\":\"$ACCOUNT_ID\",\"payload\":{\"week_start\":\"$WEEK_START\",\"week_iso\":$WEEK_ISO,\"target_lever\":\"$LEVER\",\"target_characteristic\":\"$CHARACTERISTIC\",\"hypothesis_text\":\"$HYPOTHESIS\",\"expected_idx_delta\":$EXPECTED_DELTA}}" 2>&1)
  echo "$RESP" | grep -q '"inserted"\|"idempotent"' && echo "✅ weekly_hypothesis_set emitted" || echo "⚠️ set emit: $RESP"

  # 2. weekly_hypothesis_closed (факт)
  RESP=$(curl -sf -X POST "$EVENT_GW/events" \
    -H "Content-Type: application/json" \
    -d "{\"source\":\"iwe\",\"event_type\":\"weekly_hypothesis_closed\",\"schema_version\":\"v1\",\"external_id\":\"$EXT_CLOSED\",\"account_id\":\"$ACCOUNT_ID\",\"payload\":{\"week_start\":\"$WEEK_START\",\"actual_idx_delta\":$ACTUAL_DELTA}}" 2>&1)
  echo "$RESP" | grep -q '"inserted"\|"idempotent"' && echo "✅ weekly_hypothesis_closed emitted" || echo "⚠️ closed emit: $RESP"
fi
```

---

### Audit Installation (WP-265 Ф10)

> **Цель:** еженедельный аудит инсталляции IWE — раннее обнаружение L1 drift, missing files, MCP failures. Соответствует SC.005 сценарий 3 («Week Close авторской инсталляции — Tseren еженедельно»).
>
> **Не блокирует Close.** Verdict ⚠️/❌ → информативный warning в Week Close report. Если хотите блокирующее поведение — перенесите блок в `extensions/week-close.checks.md`.

**Выполнить:**

```bash
AUDIT_SCRIPT="${IWE_ROOT:-$HOME/IWE}/scripts/iwe-audit.sh"
if [ ! -f "$AUDIT_SCRIPT" ]; then
    AUDIT_SCRIPT="${IWE_ROOT:-$HOME/IWE}/FMT-exocortex-template/scripts/iwe-audit.sh"
fi

if [ ! -f "$AUDIT_SCRIPT" ]; then
    echo "ℹ️ iwe-audit.sh не найден — аудит пропущен"
else
    AUDIT_OUT=$(bash "$AUDIT_SCRIPT" 2>&1)
    AUDIT_RC=$?
    case $AUDIT_RC in
        0) echo "✅ Аудит инсталляции: всё в порядке (exit 0)" ;;
        1) echo "⚠️ Аудит инсталляции: warnings (exit 1) — не блокирует Close, но рекомендуется проверить" ;;
        2) echo "❌ Аудит инсталляции: критичные gaps (exit 2) — рекомендуется починить" ;;
        *) echo "⚠️ Аудит инсталляции: неожиданный exit $AUDIT_RC" ;;
    esac
    # Показать первые 30 строк отчёта (Inventory + L1 drift summary)
    echo ""
    echo "$AUDIT_OUT" | head -30
fi
```

**Логика verdict:**
- exit 0 → ✅ всё в порядке
- exit 1 → ⚠️ warnings (отсутствует ≤2 опциональных файла)
- exit 2 → ❌ критичные gaps (≥1 обязательного файла нет)

**Что делать с verdict ❌:**
- L1 drift из-за устаревшей `update.sh` → запустить `cd FMT-exocortex-template && bash update.sh`
- Отсутствуют скрипты/protocols → перепроверить целостность шаблона, восстановить из FMT
- MCP unavailable → проверить настройки коннекторов claude.ai

**Чеклист:**

- [ ] **Аудит запущен** (или пропущен с причиной)
- [ ] **Verdict записан** в Week Close report
- [ ] **Если ❌** — план починки сформулирован (реализация на следующей сессии или сразу)

---

### Agent Fault L3 — эскалация повторяющихся косяков (WP-316 L3-hook)

> **Цель:** замкнуть петлю — косяки с ≥3 повторами предлагать пилоту записать в CLAUDE.md / distinctions.md.
> **Не блокирует Close.** Решение — за пилотом, агент предлагает, не пишет автономно.

**Шаг 1.** Запустить decay (убрать dormant записи без повтора >30д):
```bash
python3 ~/IWE/DS-my-strategy/scripts/iwe_checklist_memory.py decay
```

**Шаг 2.** Проверить кандидатов для эскалации (occurrences ≥ 3):
```bash
python3 ~/IWE/DS-my-strategy/scripts/iwe_checklist_memory.py escalation-check --threshold 3
```

**Правила эскалации:**
- `critical` → предложить добавить в `CLAUDE.md` или `.claude/rules/distinctions.md` **немедленно**
- `major` с n ≥ 3 → предложить добавить на **текущей неделе**
- `minor` → только SQLite, без эскалации

**Если пилот соглашается** — предложить формулировку правила; пилот добавляет в CLAUDE.md/distinctions.md сам (или явно говорит «добавь»). После добавления — обновить `context` записи в SQLite (добавить `"escalated_at": "YYYY-MM-DD"`).

**Если пилот откладывает** — записать `"defer_until": "W{N+1}"` в context записи.

**Dry-run scan старых feedback_*.md (необязательно, для метрики):**
```bash
python3 ~/IWE/DS-my-strategy/scripts/sync_feedback_to_memory.py 2>&1 | tail -1
```

**Чеклист:**

- [ ] **Decay запущен** (dormant записи помечены)
- [ ] **Escalation-check выполнен** (список критичных косяков показан пилоту)
- [ ] **Решение пилота зафиксировано** (эскалировать / отложить) для каждого critical/major

---

### Session Memory Injector: тренд-отчёт фолтов (WP-316 Ф12, pattern-report)

> **Цель:** один раз в неделю агент получает тренд-анализ своих паттернов косяков — не просто топ-3, а динамику: что растёт, что снижается, что новое.
> Исполнитель: Claude Sonnet ($0.50, ~30s). Fallback: пропустить молча если DB недоступна.

```bash
# Pattern-report: тренд-анализ фолтов за неделю (Sonnet, WP-316 Ф12)
bash ~/IWE/DS-autonomous-agents/scripts/session-memory-inject.sh week-close
```

**Если вывод содержит 🔴 паттерны с occurrences ≥ 3** → вынести в WeekReport отдельным пунктом «Паттерны косяков недели».

**Если DB недоступна** → пропустить молча (не блокирует Week Close).

- [ ] **Pattern-report получен** (или DB недоступна — задокументировать)

---

### Style Feedback Loop — доучивание агентов по стилю (WP-388 Ф10)

> **Цель:** проанализировать лог нарушений стиля за неделю, сгенерировать fault-reminders для агентов с повторяющимися нарушениями.
> **Не блокирует Close.** Генерирует HOT fault-reminder, который всплывёт у агента при следующем запуске.

**Выполнить:**

```bash
# Анализ нарушений за 7 дней, порог = 3 повтора
python3 ~/IWE/DS-my-strategy/scripts/style-feedback-loop.py --days 7 --threshold 3
```

**Логика:**
- count >= 3 по одному правилу у одного агента -> создаётся fault-reminder в `exocortex/fault-reminders/`
- Fault-reminder загружается агентом при старте сессии через `inject-fault-profile.sh`
- Если count не падает 2 недели -> переформулировать правило (не наращивать inline)
- Если count = 0 за 4 недели -> удалить fault-reminder

**Чеклист:**

- [ ] **Style feedback loop запущен** (или нет нарушений за неделю)
- [ ] **Новые fault-reminders** (если созданы) зафиксированы в Week Close report

---

### Обзор активности репозиториев за неделю (DOA2, WP-7 2026-06-12)

> **Цель:** пилот видит что сделано за неделю по каждому репо. Не блокирует Week Close.
> Диапазон: с понедельника 00:00 МСК текущей недели (детерминированно, без state).

**Выполнить:**

```bash
# Обзор коммитов с понедельника текущей недели по всем IWE-репо
# Понедельник 00:00 МСК = Monday 00:00 UTC+3
DAY_OF_WEEK=$(date +%u)  # 1=Пн, 7=Вс
DAYS_BACK=$((DAY_OF_WEEK - 1))
MONDAY=$(date -v-${DAYS_BACK}d +%Y-%m-%d 2>/dev/null || date -d "${DAYS_BACK} days ago" +%Y-%m-%d)
SINCE="${MONDAY} 00:00:00"

echo "=== Активность репозиториев с ${MONDAY} (Пн) ==="
echo ""
printf "| %-40s | %7s | %-55s |\n" "Репозиторий" "Коммитов" "Последний коммит"
printf "|%-42s|%9s|%-57s|\n" "$(printf '%.0s-' {1..42})" "$(printf '%.0s-' {1..9})" "$(printf '%.0s-' {1..57})"
any=0
for repo in ~/IWE/*/; do
  [ -d "${repo}.git" ] || continue
  slug=$(basename "$repo")
  n=$(git -C "$repo" log --since="$SINCE" --oneline 2>/dev/null | wc -l | tr -d ' ')
  [ "${n:-0}" -eq 0 ] && continue
  last=$(git -C "$repo" log -1 --format='%s (%ad)' --date=format:'%d %b' 2>/dev/null | cut -c1-55)
  printf "| %-40s | %7s | %-55s |\n" "$slug" "$n" "$last"
  any=1
done
[ "$any" = "0" ] && echo "Коммитов за неделю не найдено."
echo ""
echo "Итого репо с активностью: $(for repo in ~/IWE/*/; do [ -d "${repo}.git" ] || continue; n=$(git -C "$repo" log --since="$SINCE" --oneline 2>/dev/null | wc -l | tr -d ' '); [ "${n:-0}" -gt 0 ] && echo 1; done | wc -l | tr -d ' ')"
```

**Чеклист:**

- [ ] **Обзор репо получен** и вставлен в Week Report

---

### FMT source-of-truth — синхронизация install-hooks.sh (WP-7, 2026-06-17)

> **Цель:** убедиться, что изменения `install-hooks.sh` в авторском IWE отражены в FMT-exocortex-template.
> Появилось после peer-сессии WP-7/WP-313: Kimi добавил новые проверки в install-hooks.sh — нужно промотировать в шаблон.

**Выполнить:**

```bash
# Сравнить авторский скрипт с версией в FMT
diff ~/IWE/scripts/install-hooks.sh ~/IWE/FMT-exocortex-template/scripts/install-hooks.sh
```

Если есть расхождения — запустить промоцию:

```bash
bash ~/IWE/scripts/script-promote.sh install-hooks.sh [--dry-run]
```

**Чеклист:**

- [ ] **Diff проверен** (авторский vs FMT)
- [ ] **Если расхождение** — промоция выполнена через `script-promote.sh`

