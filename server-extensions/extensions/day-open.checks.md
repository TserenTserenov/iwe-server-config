## Верификация DayPlan перед коммитом (БЛОКИРУЮЩЕЕ)

> Аналог day-close.checks.md. Проходить ЯВНО после записи файла, ДО `git commit`.
> Каждый пункт = grep/проверка по файлу. Не по памяти.

### BLOCKING: Саморазвитие (шаг 3)

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | head -1)"
# Проверка 1: секция Саморазвитие есть в файле
if ! grep -q "Саморазвитие" "$FILE"; then
  echo "  ❌ КРИТИЧЕСКИЙ: секция Саморазвитие (шаг 3) НЕ НАЙДЕНА в DayPlan — COMMIT БЛОКИРОВАН"
  exit 2
fi
# Проверка 2: конкретный D-NNN есть (не только PENDING-плейсхолдер)
if ! grep -qE "D-[0-9]+" "$FILE"; then
  echo "  ❌ КРИТИЧЕСКИЙ: Саморазвитие без конкретного D-NNN (drafts/) — COMMIT БЛОКИРОВАН"
  echo "       Требуется: [D-NNN](drafts/D-NNN-тема.md) и «где остановился»"
  exit 2
fi
# Проверка 3: **Активный черновик:** заполнен (не содержит PENDING) — fix по вердикту Кими 22 мая
if grep -q "\*\*Активный черновик:\*\*" "$FILE"; then
  if grep "\*\*Активный черновик:\*\*" "$FILE" | grep -q "PENDING"; then
    echo "  ❌ Саморазвитие: **Активный черновик** не заполнен (содержит PENDING) — COMMIT БЛОКИРОВАН"
    exit 2
  fi
fi
echo "  ✅ Саморазвитие: D-NNN присутствует, PENDING не обнаружен"
```

- [ ] Саморазвитие: секция `<details>` ИЛИ явная строка в плане **с конкретным D-NNN** и «где остановился»
- [ ] Нет формулировки «саморазвитие X мин» без D-NNN или названия руководства + главы

### Секции DayPlan (полнота по шаблону)

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | head -1)"
echo "=== Проверка секций ==="
for section in "План на сегодня" "Календарь" "Здоровье платформы" "IWE за ночь" "Наработки Scout" "Контент-план" "Разбор заметок" "Итоги вчера" "Мир" "Контекст недели" "Требует внимания"; do
  if grep -q "$section" "$FILE"; then echo "  ✅ $section"; else echo "  ❌ $section -- ПРОПУЩЕНА"; fi
done
```

- [ ] Все 11 секций присутствуют (нет ❌). Если данных нет -- секция с явным «нет данных», не пропуск.

### Опциональные шаги алгоритма (проверка по config)

- [ ] **Помидорки (шаг 4b):** если `day-rhythm-config.yaml → pomodoro` задан — в DayPlan упомянуты work/break длительности (в «План на сегодня» или отдельной строкой). Иначе — отметить почему пропущено.
- [ ] **Видео (шаг 5a2):** если `day-rhythm-config.yaml → video.enabled: true` — в DayPlan явно сказано «N новых видеозаписей сегодня» (0 или >0). Пропуск = косяк, не молчание.
- [ ] **Саморазвитие (шаг 3):** секция/строка плана указывает КОНКРЕТНО где остановился (drafts/D-NNN, руководство X глава Y), не «саморазвитие 30 мин».

### Таблица плана (формат)

- [ ] Таблица: `| 🚦 | # | РП | h | Статус | Результат |` (6 колонок, не меньше)
- [ ] Бюджет дня: формат `~Xh РП всего / ~Yh физ / Плановый мультипликатор ~N.Nx`
- [ ] Mandatory check: WP-7 (техдолг) + контентный РП -- явно отмечены

### Бот QA (полнота)

- [ ] Дельта (сегодня vs вчера + 7д vs пред. 7д)
- [ ] Таблица замечаний (или «нет замечаний»)
- [ ] Lifecycle (new/classified/resolved)
- [ ] Кластеры (7д)

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: Разбор заметок — markdown-ссылки на источники

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | head -1)"
echo "=== Проверка: Разбор заметок — markdown-ссылки ==="
if grep -q "Разбор заметок" "$FILE"; then
  notes_section=$(sed -n '/Разбор заметок/,/<\/details>/p' "$FILE")
  # Пропускаем заголовок таблицы и строку-заглушку без данных
  data_rows=$(echo "$notes_section" | grep -vE '^\| ?Заметка |^\|[\-:]+\|' | grep -cE '\[.+\]\(.+\)')
  if [ "$data_rows" -gt 0 ]; then
    echo "  ✅ Разбор заметок: markdown-ссылки присутствуют ($data_rows шт.)"
  else
    echo "  ❌ Разбор заметок: нет markdown-ссылок в столбце 'Заметка' — COMMIT БЛОКИРОВАН"
    echo "       Требуется: [«текст заметки»](inbox/fleeting-notes.md) для каждой заметки"
    exit 2
  fi
else
  echo "  ⚠️ Разбор заметок: секция отсутствует"
fi
```

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: Контент-план — Стратегия заполнена (bug-2026-05-22)

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | head -1)"
echo "=== Проверка: Контент-план — Стратегия и TTL заполнены ==="
VIOLATIONS=0

if grep -q "\*\*Стратегия:\*\*" "$FILE"; then
  if grep "\*\*Стратегия:\*\*" "$FILE" | grep -q "PENDING"; then
    echo "  ❌ Контент-план: **Стратегия** не заполнена (PENDING) — COMMIT БЛОКИРОВАН"
    VIOLATIONS=$((VIOLATIONS+1))
  else
    echo "  ✅ Контент-план: Стратегия заполнена"
  fi
else
  echo "  ❌ Контент-план: строка **Стратегия** отсутствует — COMMIT БЛОКИРОВАН"
  VIOLATIONS=$((VIOLATIONS+1))
fi

if grep -q "\*\*TTL просрочены:\*\*" "$FILE"; then
  if grep "\*\*TTL просрочены:\*\*" "$FILE" | grep -q "PENDING"; then
    echo "  ❌ Контент-план: **TTL просрочены** не заполнен (PENDING) — COMMIT БЛОКИРОВАН"
    VIOLATIONS=$((VIOLATIONS+1))
  else
    echo "  ✅ Контент-план: TTL просрочены заполнен"
  fi
else
  echo "  ❌ Контент-план: строка **TTL просрочены** отсутствует — COMMIT БЛОКИРОВАН"
  VIOLATIONS=$((VIOLATIONS+1))
fi

[ "$VIOLATIONS" -gt 0 ] && exit 1 || true
```

- [ ] `**Стратегия:**` присутствует и не содержит `PENDING`. Если ❌ — commit заблокирован.
- [ ] `**TTL просрочены:**` присутствует и не содержит `PENDING`. Если ❌ — commit заблокирован.
- [ ] Draft-list (1-3 темы)

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: Мир — гиперссылки (WP-264 Ф6, bug-2026-05-01)

**Шаг 6 SKILL.md:** «Ссылки на источники обязательны (URL)». Это касается ВСЕХ открытий (авто + ручной).

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | head -1)"
echo "=== Проверка: Мир должен содержать минимум одну ссылку ==="

# Извлечь секцию Мир
MIR=$(awk '/<summary><b>Мир<\/b><\/summary>/{found=1; next} found && /<\/details>/{exit} found{print}' "$FILE")
# Нет данных — пропустить
if echo "$MIR" | grep -qiE "PENDING|нет новых материалов|RSS недоступны на сервере|RSS-фиды недоступны"; then
  echo "  ✅ Мир: нет данных (PENDING/нет материалов/RSS недоступны) — проверка пропущена"
elif echo "$MIR" | grep -q "\[.*\](http"; then
  echo "  ✅ Мир: найдены гиперссылки"
else
  echo "  ❌ Мир: есть контент без URL — COMMIT БЛОКИРОВАН"
  exit 1
fi
```

- [ ] Если раздел «Мир» содержит факты — минимум 1 гиперссылка. Если «нет данных» (PENDING/нет материалов/недоступен) — проверка пропускается. **Если ❌ — commit заблокирован.**

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: Запрет тихого пропуска шагов (bug-2026-05-12)

> **Принцип:** Стратег НЕ имеет права самостоятельно пропустить шаг SKILL.md, объявленный в `day-rhythm-config.yaml` как `enabled: true`. Пропуск разрешён только если конфиг явно говорит `enabled: false` ИЛИ пользователь дал прямое указание в этой сессии.
> **Триггер:** фразы «отложено», «отложена», «пропущено», «пропустим», «жёсткий ТОС», «не успел», «не запускался» в секциях Мир/Scout/Календарь/Видео БЕЗ соответствующего `enabled: false` в конфиге = НАРУШЕНИЕ.

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | head -1)"
CFG="$HOME/IWE/memory/day-rhythm-config.yaml"
echo "=== Проверка: запрещён тихий пропуск секций с enabled:true ==="

VIOLATIONS=0
check_section() {
  local section="$1" yaml_key="$2"
  local enabled
  enabled=$(awk -v k="$yaml_key" 'tolower($0) ~ "^"k":" {flag=1; next} flag && /enabled:/ {print $2; exit}' "$CFG")
  if [ "$enabled" = "true" ]; then
    if awk "/<summary><b>$section/,/<\/details>/" "$FILE" | grep -qiE "отложен|пропущен|пропустим|жёстк[иой] ТОС|не запускался|server-mode.*пропуск"; then
      echo "  ❌ $section: тихий пропуск при enabled=true (config: $yaml_key) — COMMIT БЛОКИРОВАН"
      VIOLATIONS=$((VIOLATIONS+1))
    else
      echo "  ✅ $section: пропуска не обнаружено"
    fi
  fi
}

check_section "Мир" "news"
check_section "Видео" "video"

[ "$VIOLATIONS" -gt 0 ] && exit 1 || true
```

- [ ] Нет тихих пропусков секций с `enabled: true` в `day-rhythm-config.yaml`. Если данные недоступны (headless/MCP) — секция помечается 🔴 в светофоре «IWE за ночь», а не вставляется фраза «отложено».

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: KE-кандидаты в DayPlan (bug-2026-05-17)

> **Источник:** 3 дня подряд (15-17 мая) пропускался шаг 5e extensions/day-open.after.md. При N>0 pending-review extraction-reports секция `📚 KE-кандидаты` ОБЯЗАНА присутствовать в DayPlan.

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | head -1)"
REPORTS_DIR="$HOME/IWE/DS-my-strategy/inbox/extraction-reports"
PENDING=$(grep -rl "status: pending-review" "$REPORTS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
echo "KE_PENDING=$PENDING"
if [ "$PENDING" -gt 0 ]; then
  if grep -q "KE-кандидаты" "$FILE" 2>/dev/null; then
    echo "  ✅ KE-кандидаты: секция присутствует ($PENDING pending)"
  else
    echo "  ❌ KE-кандидаты: $PENDING extraction-reports pending-review, но секция ОТСУТСТВУЕТ — COMMIT БЛОКИРОВАН"
    exit 1
  fi
else
  echo "  ✅ KE-кандидаты: N=0, секция не нужна"
fi
```

- [ ] Если `KE_PENDING > 0` — секция `### 📚 KE-кандидаты` есть в DayPlan. Если нет — вернуться к шагу 5e extensions/day-open.after.md и дописать.

### Carry-over заметок

- [ ] Неразобранные заметки из вчерашнего DayPlan перенесены (или «нет carry-over»)

### Свежесть данных

```bash
cd ~/IWE/DS-my-strategy && git log --oneline -5
```

- [ ] Нет коммитов из параллельных сессий, которые меняют DayPlan или статусы РП
- [ ] Если есть -- учтены в файле (статусы РП актуальны)

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: AR.009 — новые файлы в exocortex/ (bug-2026-05-19)

```bash
echo "=== Проверка: AR.009 Routing Gate ==="
NEW_FILES=$(cd ~/IWE/DS-my-strategy && git status --porcelain | awk '/^\?\? / {print $2}' | grep "exocortex/" | grep -v -E "(feedback_|lessons_|reference_|project_|routing-vocab|CLAUDE|MEMORY|STAGING|checklists|dry-run|protocol-close|navigation)" || true)
if [ -n "$NEW_FILES" ]; then
  echo "  ❌ AR.009: новые файлы в exocortex/ не соответствуют routing-vocab.md:"
  echo "$NEW_FILES"
  echo "  → Должны быть в inbox/bugs/, memory/, или другом месте по DP.KR.001 §5"
  exit 1
else
  echo "  ✅ AR.009: новых файлов в exocortex/ не обнаружено (или имена корректны)"
fi
```

- [ ] Нет новых файлов в `exocortex/` без префикса `feedback_` / `lessons_` / `reference_` / `project_` / `routing-vocab` и т.д. Если есть — commit БЛОКИРОВАН.

### 🟡 ПРОВЕРКА: Календарь — данные или явный PENDING (bug-2026-05-19)

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | head -1)"
echo "=== Проверка: календарь — данные или явный PENDING ==="
if grep -q "проверить вручную" "$FILE" && ! grep -qE '\| [0-9]{2}:[0-9]{2} \|' "$FILE"; then
  echo "  🟡 Календарь: содержит fallback без реальных данных — требует внимания"
else
  echo "  ✅ Календарь: данные присутствуют или явный PENDING"
fi
```

- [ ] Если в секции «Календарь» фраза «проверить вручную» при отсутствии событий с временем — 🟡 в «Требует внимания» (не блокирует commit, но требует проверки preflight).

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: LLM-шаги Day Open (peer-сессия 2026-05-24, feedback_day_open_checks_coverage_gap)

> **Источник косяка:** 24 мая Day Open пропустил 4 LLM/external-шага (Горлышко недели, News Lens вывод, smoke-тесты бота, URL для «Мир»). Эти шаги невидимы bash-скаффолду — проверка только по grep содержимого, не по названию секции.

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | head -1)"
CFG="$HOME/IWE/memory/day-rhythm-config.yaml"
echo "=== Проверка: LLM-шаги Day Open ==="
VIOLATIONS=0

# 1. Горлышко недели (bottleneck-pick output)
WEEK_CTX=$(awk '/<summary><b>Контекст недели/,/<\/details>/' "$FILE")
if echo "$WEEK_CTX" | grep -qE "Горлышко недели|bottleneck-pick"; then
  if echo "$WEEK_CTX" | grep "Горлышко недели" | grep -q "PENDING"; then
    echo "  ❌ Горлышко недели: PENDING не заполнен — COMMIT БЛОКИРОВАН"
    VIOLATIONS=$((VIOLATIONS+1))
  else
    echo "  ✅ Горлышко недели: заполнено"
  fi
else
  echo "  ❌ Горлышко недели: секция отсутствует в «Контекст недели» — COMMIT БЛОКИРОВАН"
  echo "       Требуется: /bottleneck-pick --target weekplan --layer intra --horizon week --depth 1"
  VIOLATIONS=$((VIOLATIONS+1))
fi

# 2. News Lens «Вывод:» (если news.enabled: true)
NEWS_ENABLED=$(awk '/^news:/{flag=1; next} flag && /enabled:/{print $2; exit}' "$CFG")
if [ "$NEWS_ENABLED" = "true" ]; then
  MIR=$(awk '/<summary><b>Мир<\/b>/,/<\/details>/' "$FILE")
  if echo "$MIR" | grep -q "\*\*Вывод:\*\*"; then
    if echo "$MIR" | grep "\*\*Вывод:\*\*" | grep -q "PENDING"; then
      echo "  ❌ News Lens: **Вывод:** PENDING — COMMIT БЛОКИРОВАН"
      VIOLATIONS=$((VIOLATIONS+1))
    else
      echo "  ✅ News Lens: **Вывод:** заполнен"
    fi
  else
    echo "  ❌ News Lens: **Вывод:** отсутствует в секции «Мир» — COMMIT БЛОКИРОВАН"
    echo "       Требуется: Haiku-субагент (SKILL.md:136-156 шаг 6a)"
    VIOLATIONS=$((VIOLATIONS+1))
  fi
fi

# 3. Smoke-тесты бота (если pytest есть)
HEALTH=$(awk '/<summary><b>Здоровье платформы/,/<\/details>/' "$FILE")
if echo "$HEALTH" | grep -qiE "Smoke-тесты|smoke tests"; then
  echo "  ✅ Smoke-тесты: упомянуты в «Здоровье платформы»"
else
  echo "  ⚠️ Smoke-тесты бота не упомянуты — WARN (не блокирует, может быть pytest не запущен)"
fi

# 4. Запрет (n/a) как валидного URL
NA_COUNT=$(grep -c '\](n/a)' "$FILE" 2>/dev/null || echo 0)
if [ "$NA_COUNT" -gt 0 ]; then
  echo "  ❌ Найдено $NA_COUNT ссылок [...](n/a) — заглушка не валидна, COMMIT БЛОКИРОВАН"
  echo "       Используй WebSearch fallback или удали ссылку с пометкой '⚠️ нет источника'"
  VIOLATIONS=$((VIOLATIONS+1))
fi

[ "$VIOLATIONS" -gt 0 ] && exit 1 || true
```

- [ ] «Горлышко недели» присутствует и заполнен (не PENDING). Source: `extensions/day-open.after.md:158-191`
- [ ] News Lens «**Вывод:**» присутствует и заполнен при `news.enabled: true`. Source: `SKILL.md:136-156`
- [ ] Smoke-тесты упомянуты в «Здоровье платформы» (WARN, не блок)
- [ ] Нет ссылок `[...](n/a)` — это заглушка, не URL. Используй WebSearch fallback

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: current/ без зависших DayPlan (feedback_dayplan_archive_silent_skip, 2026-05-24)

> **Источник:** 22-23-24 мая подряд вчерашний DayPlan оставался в `current/` после Day Close — Day Close протокол не имеет шага архивации DayPlan, Day Open checks этого не ловили.

```bash
TODAY=$(date +%Y-%m-%d)
STALE=$(ls "$HOME/IWE/DS-my-strategy/current/" 2>/dev/null | grep -E "^DayPlan [0-9]{4}-[0-9]{2}-[0-9]{2}\.md$" | grep -v "$TODAY")
if [ -n "$STALE" ]; then
  echo "  ❌ Зависшие DayPlan в current/:"
  while IFS= read -r f; do
    echo "       $f"
    echo "       → git mv \"current/$f\" archive/day-plans/"
  done <<< "$STALE"
  echo "  COMMIT БЛОКИРОВАН — архивировать вчерашние DayPlan перед commit"
  exit 1
else
  echo "  ✅ current/: только сегодняшний DayPlan"
fi
```

- [ ] В `current/` только один DayPlan — сегодняшний. Вчерашние/старее → `git mv archive/day-plans/`. Если ❌ — commit заблокирован.

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: Калибровка скилла /bottleneck-pick (peer-session 2026-05-28-04, повтор feedback_skill_manual_synthesis_bypass 24+28 мая)

> **Источник:** 24 мая — заявил запуск /bottleneck-pick, сделал интуитивную выжимку. 28 мая повтор. Дважды → повышение из 🟡 в 🔴.
> **Принцип:** «Горлышко недели» = производное от YAML. Любая ручная запись = bypass.
> **Markеr:** генератор `bottleneck-section-from-yaml.sh` вставляет `<!-- BY-SCRIPT: bottleneck-section-from-yaml.sh -->` в начало выжимки. Ручная запись маркера не имеет.

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | head -1)"
TODAY=$(date +%Y-%m-%d)
DOW=$(date +%u)  # 1=Mon ... 7=Sun
CFG="$HOME/IWE/memory/day-rhythm-config.yaml"
RUNS_DIR="$HOME/IWE/DS-my-strategy/inbox/bottleneck-pick-runs"
echo "=== Калибровка /bottleneck-pick (BLOCKING) ==="

# Условие пропуска: strategy_day (под секцией day_open: в day-rhythm-config.yaml) или выходной (Сб/Вс)
STRATEGY_DAY=$(awk '/^day_open:/{flag=1; next} flag && /^[^[:space:]]/{flag=0} flag && /strategy_day:/{print $2; exit}' "$CFG" 2>/dev/null | tr -d '"')
TODAY_DOW=$(date +%A | tr '[:upper:]' '[:lower:]')
SKIP=false
if [ "$DOW" -ge 6 ]; then
  echo "  ℹ️ Выходной ($DOW = $(date +%A)) — проверка пропущена"
  SKIP=true
elif [ -n "$STRATEGY_DAY" ] && [ "$STRATEGY_DAY" = "$TODAY_DOW" ]; then
  echo "  ℹ️ strategy_day ($STRATEGY_DAY) — проверка пропущена (план в WeekPlan, не DayPlan)"
  SKIP=true
fi

if [ "$SKIP" = "false" ]; then
  if grep -q "Горлышко недели" "$FILE"; then
    # Проверка 1: маркер BY-SCRIPT в выжимке
    if grep -q "<!-- BY-SCRIPT: bottleneck-section-from-yaml.sh -->" "$FILE"; then
      echo "  ✅ Bottleneck: выжимка содержит маркер BY-SCRIPT"
    else
      echo "  ❌ Bottleneck: «Горлышко недели» написано вручную (нет маркера BY-SCRIPT)"
      echo "       Исправь: запусти /bottleneck-pick → bash ~/IWE/DS-my-strategy/scripts/bottleneck-section-from-yaml.sh \\"
      echo "                ~/IWE/DS-my-strategy/inbox/bottleneck-pick-runs/$TODAY-weekplan.yaml"
      echo "       Скопируй вывод (включая маркер BY-SCRIPT) в DayPlan секцию «Контекст недели»."
      echo "  COMMIT БЛОКИРОВАН"
      exit 1
    fi
    # Проверка 2: weekplan-YAML за сегодня существует (workflow day-open.after.md использует именно weekplan)
    YAML_FILE=$(ls "$RUNS_DIR/$TODAY-weekplan"*.yaml 2>/dev/null | head -1)
    if [ -z "$YAML_FILE" ]; then
      echo "  ❌ Bottleneck: weekplan-YAML за $TODAY не найден в $RUNS_DIR/"
      echo "       Исправь: запусти /bottleneck-pick --target weekplan --layer intra --horizon week --depth 1"
      echo "  COMMIT БЛОКИРОВАН"
      exit 1
    fi
    echo "  ✅ Bottleneck: YAML $YAML_FILE существует"
    # Проверка 3: YAML парсится
    if ! python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$YAML_FILE" 2>/dev/null; then
      echo "  ❌ Bottleneck: YAML $YAML_FILE битый (yaml.safe_load fail)"
      echo "       Исправь: запусти /bottleneck-pick заново или почини YAML вручную"
      echo "  COMMIT БЛОКИРОВАН"
      exit 1
    fi
    echo "  ✅ Bottleneck: YAML валиден"
  else
    # Рабочий день, не strategy_day, нет секции — это тоже нарушение
    echo "  ❌ Bottleneck: рабочий день, секция «Горлышко недели» отсутствует в DayPlan"
    echo "       Исправь: запусти /bottleneck-pick и вставь выжимку в «Контекст недели»."
    echo "  COMMIT БЛОКИРОВАН"
    exit 1
  fi
fi
```

- [ ] В рабочий день (Пн-Пт, кроме strategy_day): секция «Горлышко недели» присутствует, содержит маркер `<!-- BY-SCRIPT -->`, YAML за сегодня существует и валиден. Если ❌ — commit заблокирован.
- [ ] Источник правила: peer-сессия 2026-05-28-04-day-open-checks-fix (DP.SC.154).

### INFO: WP-REGISTRY integrity (deep-check, non-blocking)

> **Cell:** sessions/2026-06/2026-06-01-21-wp-registry-drift-guard/report.md.
> **Цель:** L2 periodic reconciliation — orphan detection в реестре. Не блокирует commit;
> результат идёт в DayPlan «Требует внимания» через визуальный лог Day Open.

```bash
DEEP_OUT=$(python3 ~/IWE/DS-my-strategy/scripts/build-active-wp.py --deep-check 2>&1 || true)
ORPHAN_COUNT=$(echo "$DEEP_OUT" | grep -cE '^  - WP-' || true)
if [ "$ORPHAN_COUNT" -gt 0 ]; then
  echo "  ⚠️  WP-REGISTRY orphans: $ORPHAN_COUNT (deep-check). Подробности:"
  echo "$DEEP_OUT" | grep -E '^  - WP-' | head -10
  if [ "$ORPHAN_COUNT" -gt 10 ]; then
    echo "    (показано первые 10 из $ORPHAN_COUNT — полный отчёт: python3 scripts/build-active-wp.py --deep-check)"
  fi
  echo "  ℹ️  Не блокирует commit. Запланировать разбор orphans на Week Close."
else
  echo "  ✅ WP-REGISTRY: orphan-проверка пройдена (deep-check)."
fi
# Always exit 0 — informational only
exit 0
```

- [ ] WP-REGISTRY deep-check выполнен. При orphan_count > 0 — упомянуть в DayPlan «Требует внимания».

### Git

- [ ] `git push` -- СРАЗУ после коммита, ДО вывода compact dashboard в VS Code
