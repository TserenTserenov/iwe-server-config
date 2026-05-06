## Авторские проверки Week Close

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
