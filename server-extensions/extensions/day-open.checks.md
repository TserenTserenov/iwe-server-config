## Верификация DayPlan перед коммитом (БЛОКИРУЮЩЕЕ)

> Аналог day-close.checks.md. Проходить ЯВНО после записи файла, ДО `git commit`.
> Каждый пункт = grep/проверка по файлу. Не по памяти.

> **BUGFIX (2026-07-11):** `FILE=$(ls ... | tail -1)`, не `head -1`. Архивация вчерашнего
> DayPlan происходит в day-open-pipeline.sh ПОСЛЕ проверок (шаг 6, после шага 5) — пока в
> `current/` лежат сразу вчерашний и сегодняшний план, `ls` сортирует их по алфавиту, и
> "10" стоит раньше "11". `head -1` брал самый старый файл — почти все блоки этого файла
> тихо проверяли вчерашний план вместо сегодняшнего каждую ночь, когда вчерашнее Закрытие
> дня не успевало заранее убрать файл в архив (найдено на ложном "Требует внимания -- ПРОПУЩЕНА").
> `tail -1` берёт самый свежий по дате файл — это всегда сегодняшний план.

### BLOCKING: Саморазвитие (шаг 3)

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
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

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: все РП из priorities.yaml в плане (bug-2026-07-01)

> **Источник:** 2026-07-01 WP-453 был в priorities.yaml `today:`, но выпал из таблицы плана.
> Корень: наивный parse_frontmatter путал вложенный `status:` → РП не попадал в JSON-факты,
> а промпт запрещал LLM добавлять РП вне JSON. Проверка ловит регресс независимо от причины.

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
PRIO="$HOME/IWE/DS-my-strategy/current/priorities.yaml"
echo "=== Проверка: все РП из priorities.yaml присутствуют в DayPlan ==="
if [ -f "$PRIO" ]; then
  WPS=$(python3 -c "
import yaml,sys
d=yaml.safe_load(open('$PRIO')) or {}
for w in (d.get('today') or []):
    print(str(w).strip())
" 2>/dev/null)
  # Scope to the plan table inside "План на сегодня", not the whole file: 2026-07-01
  # WP-453 was missing from the plan table but present in both the "Утренние приоритеты"
  # bullet list and the content-plan table, so a whole-file grep gave a false pass.
  PLAN_TABLE=$(awk '/<summary><b>План на сегодня<\/b><\/summary>/{f=1} f&&/^\|/{print} f&&/<\/details>/{exit}' "$FILE")
  MISSING=0
  # BUGFIX (2026-07-03): `for wp in $WPS` не разбивал многострочный $WPS на элементы под zsh
  # (Bash-инструмент агента фактически исполняет через /bin/zsh, где unquoted-expansion не
  # делает word-split как в bash), плюс BSD grep трактует многострочный паттерн как список
  # альтернатив (-e "WP-1" -e "WP-2" ...) — вместе это давало ВСЕГДА ✅ независимо от того,
  # сколько РП реально отсутствовало в таблице. `while read` работает одинаково в bash и zsh.
  # BUGFIX (2026-07-11): priorities.yaml хранит "WP-149", а колонка «#» таблицы плана
  # тогда была голым числом "149" — матчили по границе ячейки `| 149 |`.
  # BUGFIX (2026-07-14): колонка «#» с тех пор стала сквозным номером строки (1, 2, 3…),
  # а номер РП переехал внутрь ячейки «РП» жирным текстом (`**WP-483** — название`) —
  # прежняя проверка по границе ячейки перестала совпадать вообще для любого РП, каждую
  # ночь давая ложный ❌ на реально присутствующие РП (подтверждено на архиве 07-11: там
  # формат ещё был "| 149 |", сегодня — "| 1 | **WP-483** — …"). Матчим сам номер с
  # обязательным префиксом WP- где угодно в строке таблицы (не привязываясь к колонке) —
  # жирный markdown вокруг него не мешает, а требование префикса не даёт "47" ложно
  # совпасть внутри "471".
  # BUGFIX (2026-07-16): формат снова сменился — колонка «#» опять стала голым номером
  # РП («| 🔴 | В | 483 | **guide-kit** — …»), без префикса WP- нигде в строке. Проверка
  # по всей таблице разом (grep по $PLAN_TABLE целиком) на реальном плане 16.07 дала ДВЕ
  # ошибки сразу: ложный ❌ на WP-149/WP-481 (нет текста «WP-» в их строках — новый формат)
  # И скрытый ложный ✅ для WP-483 (совпало не по его собственной строке, а по случайной
  # ссылке «после решения WP-483 Ф1.5» внутри строки WP-149) — при таком формате проверка
  # не защищает вообще ни от чего. Теперь матчим ПОСТРОЧНО: колонка «#» (4-е поле по `|`)
  # равна голому номеру ИЛИ в этой же строке (не во всей таблице) есть WP-номер с префиксом —
  # так ловятся оба формата и не текут ссылки между чужими строками.
  while IFS= read -r wp; do
    [ -z "$wp" ] && continue
    num="${wp#WP-}"
    FOUND=0
    while IFS= read -r row; do
      case "$row" in \|*) ;; *) continue ;; esac
      col3=$(printf '%s' "$row" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')
      if [ "$col3" = "$num" ]; then FOUND=1; break; fi
      if printf '%s' "$row" | grep -qE "WP-${num}([^0-9]|\$)"; then FOUND=1; break; fi
    done <<< "$PLAN_TABLE"
    if [ "$FOUND" -eq 0 ]; then
      echo "  ❌ $wp из priorities.yaml отсутствует в таблице «План на сегодня» — COMMIT БЛОКИРОВАН"
      MISSING=$((MISSING+1))
    fi
  done <<< "$WPS"
  if [ "$MISSING" -eq 0 ]; then
    echo "  ✅ Все РП из priorities.yaml присутствуют в плане"
  else
    exit 1
  fi
else
  echo "  ⚠️ priorities.yaml не найден — проверка пропущена"
fi
```

- [ ] Каждый `WP-NNN` из `priorities.yaml → today:` присутствует в DayPlan. Если ❌ — commit заблокирован.

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: `<details>` без `<summary>` (баг «Details», bug-2026-07-01)

> **Источник:** 2026-07-01 в 7 секциях DayPlan стоял голый `<details>` без `<summary>` —
> браузер/VS Code рендерит его как слово "Details". Причина: LLM оборачивал ответ в
> лишний `<details>`. Инвариант: каждый `<details>` парен с одним `<summary>`.

<!-- GATE-B: always-on -->
```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
echo "=== Проверка: баланс <details>/<summary> ==="
# grep -c печатает "0" (не пусто) даже без совпадений, но выходит с кодом 1;
# под set -e (см. day-open-checks-runner.sh) голое присваивание с таким кодом
# молча обрывает блок ДО if — `|| true` обязателен, `:-0` после присваивания
# не спасает (до него уже не доходит). Тот же класс бага, что NA_COUNT ниже,
# WP-5 Ф2 09.07 — исходный `|| echo 0` вдобавок дублировал вывод ("0\n0").
OPENS=$(grep -cE '^<details' "$FILE" 2>/dev/null || true)
SUMMARIES=$(grep -cE '<summary>' "$FILE" 2>/dev/null || true)
if [ "$OPENS" -gt "$SUMMARIES" ]; then
  echo "  ❌ Голый <details> без <summary> ($OPENS открытий vs $SUMMARIES summary) — рендерится как 'Details'. COMMIT БЛОКИРОВАН"
  exit 1
else
  echo "  ✅ Все <details> имеют <summary> ($OPENS/$SUMMARIES)"
fi
```

- [ ] Число `<details>` ≤ числу `<summary>`. Если больше — голый блок рендерится как "Details", commit заблокирован.

### Секции DayPlan (полнота по шаблону)

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
echo "=== Проверка секций ==="
# BUGFIX (2026-07-03): голый `grep -q "$section"` даёт ложный ✅, если слово встречается
# где угодно в файле (напр. «Мир» совпадал со строкой из «Требует внимания», не с реальным
# заголовком раздела) — «Мир» и «Активные РП» отсутствовали 3-4 дня подряд (30 июня — 3 июля)
# незамеченными. Теперь для заголовочных секций ищем именно <summary><b>Название.
# УБРАНО (2026-07-04, WP-7 DOSCAF1): «Активные РП» удалена из шаблона (дублировала
# current/priorities.yaml + current/active-wp.md) — больше не входит в required-список.
for section in "План на сегодня" "Календарь" "Здоровье платформы" "Контент-план" "Разбор заметок" "Итоги вчера" "Мир" "Контекст недели" "Требует внимания"; do
  if grep -qE "<summary><b>$section" "$FILE"; then echo "  ✅ $section"; else echo "  ❌ $section -- ПРОПУЩЕНА"; fi
done
# Вложенные bold-текстовые метки внутри «Здоровье платформы» / «Наработки агентов» — не отдельный <details>
if grep -q "IWE за ночь" "$FILE"; then echo "  ✅ IWE за ночь"; else echo "  ❌ IWE за ночь -- ПРОПУЩЕНА"; fi
if grep -qE "<summary><b>Наработки агентов" "$FILE"; then echo "  ✅ Наработки агентов"; else echo "  ❌ Наработки агентов -- ПРОПУЩЕНА"; fi
```

- [ ] Все 11 секций присутствуют (нет ❌). Если данных нет -- секция с явным «нет данных», не пропуск.

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: «Требует внимания» присутствует (WP-484 Ф2, 2026-07-13)

> **Источник:** проверка секций выше (блок «Секции DayPlan») только печатает ❌, но не блокирует —
> ни одна из её 9 строк не вызывает `exit`. «Требует внимания» пропадала вместе с «Мир»/«Горлышко
> недели» в обоих известных случаях деградированного скаффолда (06-15 day-close-recovery,
> 07-10 fallback scaffold — оба целиком без секции), но проходила commit незамеченной. Это
> противоречит инварианту WP-484: «нет данных → явный маркер, никогда тихий пропуск». Эта секция
> — единственная из 9, для которой сделан отдельный блокирующий гейт: она агрегирует сигналы
> из 9 разных источников (carry-over, светофор, Scout, KE-SLA, орг-сигналы …), и её тихое
> исчезновение прячет все 9 сразу, а не один локальный факт, как для остальных 8 секций.

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
echo "=== Проверка: «Требует внимания» присутствует ==="
if grep -qE "<summary><b>Требует внимания" "$FILE"; then
  echo "  ✅ Требует внимания: секция присутствует"
else
  echo "  ❌ Требует внимания: секция ОТСУТСТВУЕТ — COMMIT БЛОКИРОВАН"
  echo "       Скорее всего DayPlan собран деградированным путём (fallback/recovery scaffold)."
  echo "       Проверь generated_by в frontmatter и inbox/bugs/ на связанный открытый баг."
  exit 1
fi
```

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
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
echo "=== Проверка: Разбор заметок — markdown-ссылки ==="
if grep -q "Разбор заметок" "$FILE"; then
  notes_section=$(sed -n '/Разбор заметок/,/<\/details>/p' "$FILE")
  # Пропускаем заголовок таблицы и строку-заглушку без данных.
  # `|| true` обязателен: без pipefail в этом суб-шелле статус пайпа = статус
  # последней команды (grep -c); 0 совпадений → grep вернёт 1 → под `set -e`
  # (снаружи, в day-open-checks-runner.sh) присвоение переменной с таким
  # статусом молча обрывает блок ДО if/else — ни ✅, ни ❌ не печатались,
  # просто тишина (найдено 2026-07-09, WP-5 Ф2, тот же класс "runner
  # никогда реально не исполнялся").
  data_rows=$(echo "$notes_section" | grep -vE '^\| ?Заметка |^\|[-:]+\|' | grep -cE '\[.+\]\(.+\)' || true)
  # BUGFIX (2026-07-11): когда inbox/fleeting-notes.md реально пуст (нет новых заметок
  # со времени последнего Note-Review), явная строка-заглушка «нет заметок» — корректный
  # ответ, а не пропуск (тот же принцип, что и для остальных секций — см. чеклист выше
  # «данных нет → явное "нет данных", не пропуск»). Без этой ветки проверка блокировала
  # commit каждый день без новых заметок, требуя выдумать несуществующую ссылку.
  if [ "$data_rows" -gt 0 ]; then
    echo "  ✅ Разбор заметок: markdown-ссылки присутствуют ($data_rows шт.)"
  elif echo "$notes_section" | grep -qE '\|[[:space:]]*нет заметок[[:space:]]*\|'; then
    echo "  ✅ Разбор заметок: заметок нет (явно указано, не пропуск)"
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
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
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
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
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
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
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
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
REPORTS_DIR="$HOME/IWE/DS-my-strategy/inbox/extraction-reports"
# `|| true`: под pipefail (наследуется от day-open-checks-runner.sh) статус пайпа —
# статус самой правой упавшей команды. При 0 pending-report'ов (штатный случай)
# grep -rl вернёт 1, и это молча оборвёт блок ДО echo/if под set -e — тот же
# класс бага, что NA_COUNT/OPENS/STALE выше (WP-5 Ф2 09.07).
PENDING=$(grep -rl "status: pending-review" "$REPORTS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ' || true)
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

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: KE-очередь — согласованность параллельных источников (bug-2026-07-12)

> **Источник:** `day-open-smoke.sh` и `ke-queue-stats.sh` считают одну и ту же метрику (KE-очередь: count + oldest_age_days) разными способами фильтрации. 12.07.26 расхождение (132/44д против 9/0д) попало в DayPlan и было замечено только пилотом при ручной сверке. Оба скрипта приведены к одной логике фильтрации, но проверка нужна на случай будущего дрейфа одного из них.

```bash
echo "=== Проверка: KE-очередь — согласованность day-open-smoke.sh vs ke-queue-stats.sh ==="
SMOKE_JSON=$(bash ~/IWE/DS-my-strategy/scripts/day-open-smoke.sh 2>/dev/null)
STATS_JSON=$(bash ~/IWE/DS-my-strategy/scripts/ke-queue-stats.sh 2>/dev/null)
SMOKE_COUNT=$(echo "$SMOKE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['ke_count'])" 2>/dev/null)
SMOKE_OLDEST=$(echo "$SMOKE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['ke_oldest_days'])" 2>/dev/null)
STATS_COUNT=$(echo "$STATS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['count'])" 2>/dev/null)
STATS_OLDEST=$(echo "$STATS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['oldest_age_days'])" 2>/dev/null)
if [ -z "$SMOKE_COUNT" ] || [ -z "$STATS_COUNT" ]; then
  echo "  ⚠️ KE-очередь: не удалось прочитать один из источников (smoke='$SMOKE_JSON', stats='$STATS_JSON') — пропуск, не блокирует"
elif [ "$SMOKE_COUNT" = "$STATS_COUNT" ] && [ "$SMOKE_OLDEST" = "$STATS_OLDEST" ]; then
  echo "  ✅ KE-очередь: источники согласованы ($STATS_COUNT отчётов, oldest ${STATS_OLDEST}д)"
else
  echo "  ❌ KE-очередь: расхождение — day-open-smoke.sh(count=$SMOKE_COUNT,oldest=$SMOKE_OLDEST) vs ke-queue-stats.sh(count=$STATS_COUNT,oldest=$STATS_OLDEST). COMMIT БЛОКИРОВАН — один из скриптов считает неверно, свериться перед записью в DayPlan."
  exit 1
fi
```

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
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
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
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
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
# grep -c печатает "0" (не пусто) даже без совпадений, но выходит с кодом 1.
# `|| echo 0` тогда дублировал вывод ("0\n0" → integer expression expected);
# просто убрать `|| echo 0` тоже не годится — под set -e (day-open-checks-
# runner.sh запускает каждый блок в `( set -e; eval ... )`) само присваивание
# `VAR=$(cmd_с_кодом_1)` молча обрывает блок ДО этой строки, даже если
# значение уже корректно легло в переменную. Только `|| true` даёт и верное
# значение, и не убивает блок (найдено 2026-07-09, WP-5 Ф2 — тот же класс
# "проверка никогда не запускалась", вскрылось только после починки runner'а
# от бага с NUL-разделителем; первая правка этой строки была неполной).
NA_COUNT=$(grep -c '\](n/a)' "$FILE" 2>/dev/null || true)
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
# `|| true`: без него, ноль зависших планов (штатный случай) даёт grep -v exit 1,
# и под set -e присвоение молча обрывает блок до if — тот же класс бага, что
# markdown-ссылки/OPENS-SUMMARIES выше (WP-5 Ф2 09.07).
STALE=$(ls "$HOME/IWE/DS-my-strategy/current/" 2>/dev/null | grep -E "^DayPlan [0-9]{4}-[0-9]{2}-[0-9]{2}\.md$" | grep -v "$TODAY" || true)
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
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
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
  # Честный fallback-маркер (day-open-bottleneck-patch.sh, WP-484 Ф2): headless-конвейер
  # не может вызвать LLM-скилл /bottleneck-pick сам, и вместо часового блока каждую ночь
  # (эмпирически: маркер BY-SCRIPT встретился только в 6 из 139 архивных DayPlan) честно
  # помечает секцию как отложенную. Никто не выдаёт чужую работу за свою — в отличие от
  # рукописного текста без обоих маркеров (ветка ниже), эту ветку не за что блокировать,
  # но и молчать про неё нельзя — 🟡 в «Требует внимания» видимый, не блокирующий.
  if grep -q "<!-- BOTTLENECK-PENDING:" "$FILE"; then
    echo "  🟡 Bottleneck: честный маркер BOTTLENECK-PENDING — требует ручного /bottleneck-pick, не блокирует"
  elif grep -q "Горлышко недели" "$FILE"; then
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
    # `|| true`: под pipefail отсутствие файла (ls вернёт 1 на нераскрытый glob)
    # молча оборвёт блок ДО if — тогда пропадает конкретный текст исправления,
    # остаётся только глухое "N block(s) failed" (тот же класс бага, WP-5 Ф2 09.07).
    YAML_FILE=$(ls "$RUNS_DIR/$TODAY-weekplan"*.yaml 2>/dev/null | head -1 || true)
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

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: Таблица плана — без шаблонных заглушек (bug Block DOF, 2026-07-09)

> **Источник:** WP-7 Block DOF. `fill_chunk()` в `day-open-llm-fill.py` сравнивал с тегом-обёрткой
> вместо содержимого куска, поэтому секция «План на сегодня» не заполнялась и уходила в коммит
> с примером-заглушкой из скаффолда (`day-open-scaffold.sh:1003`):
> `| 🔴 | С | NNN | **<!-- PENDING -->** | X | pending |`. Ни один существующий чек этого не
> ловил — баг нашёлся только потому, что пилот прямо спросил про полноту открытия дня.

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
PLAN_TABLE=$(awk '/<summary><b>План на сегодня<\/b><\/summary>/{f=1} f&&/^\|/{print} f&&/<\/details>/{exit}' "$FILE")
echo "=== Проверка: таблица плана без шаблонных заглушек (Block DOF) ==="
if printf '%s\n' "$PLAN_TABLE" | grep -qE '\| *NNN *\||<!-- PENDING -->|\| *X *\|'; then
  echo "  ❌ КРИТИЧЕСКИЙ: таблица «План на сегодня» содержит шаблонную заглушку (NNN/X/PENDING) вместо реальных данных — COMMIT БЛОКИРОВАН"
  echo "       Тот же дефект, что Block DOF: fill_chunk() не заполнил секцию, ушёл пример-заглушка."
  exit 2
else
  echo "  ✅ Таблица плана: заглушек не найдено"
fi
```

- [ ] Таблица «План на сегодня» не содержит `NNN`, `<!-- PENDING -->` или одиночный `X` вместо реального номера/часов. Если ❌ — commit заблокирован.

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: «физ» в бюджете дня — не fallback-заглушка (bug-2026-07-16)

> **Источник:** `day-open-budget-patch.py` при отсутствии `phys_hours` в `priorities.yaml`
> молча подставляет физ = сумма РП (`h_phys = read_phys_hours(...) or h_rp`) → «Плановый
> мультипликатор ~1.0x». Это не прогноз, а копия суммы: физически невозможное число
> (36h/36h) для одного дня. 2 из последних 10 открытий (15.07, 11.07) прошли с этой
> заглушкой, ни один существующий чек её не поймал — старая проверка бюджета (см. ниже)
> сверяет только формат строки, не содержание. Найдено пилотом напрямую вопросом
> про полноту открытия — тот же класс, что Block DOF (bug-2026-07-09).

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
PRIO="$HOME/IWE/DS-my-strategy/current/priorities.yaml"
echo "=== Проверка: «физ» в бюджете дня — не fallback-заглушка ==="
if ! grep -qE "^phys_hours:" "$PRIO" 2>/dev/null; then
  echo "  ❌ phys_hours не задан в priorities.yaml — budget-patch.py подставит физ = РП (fallback 1.0x). COMMIT БЛОКИРОВАН"
  echo "       Исправь: добавь 'phys_hours: N' (реалистичная оценка часов на сегодня, потолок пилота — 9ч) в priorities.yaml"
  exit 1
fi
H_PHYS=$(grep -oE '~[0-9.]+h физ' "$FILE" 2>/dev/null | grep -oE '[0-9.]+' | head -1)
if [ -n "$H_PHYS" ]; then
  OVER=$(awk -v h="$H_PHYS" 'BEGIN{print (h>14)?1:0}')
  if [ "$OVER" = "1" ]; then
    echo "  ❌ «физ» = ${H_PHYS}h — физически невозможно для одного дня (потолок пилота: 9ч). COMMIT БЛОКИРОВАН"
    exit 1
  fi
  echo "  ✅ «физ» = ${H_PHYS}h — в пределах разумного"
else
  echo "  ⚠️ Не удалось извлечь «физ» из строки бюджета — проверь вручную"
fi
```

- [ ] `priorities.yaml` содержит `phys_hours:` (не fallback-дефолт). «Физ» в DayPlan ≤14ч (потолок пилота — 9ч, выше — предупреждение). Если ❌ — commit заблокирован.

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: health-значений в DayPlan быть НЕ должно (резидентность WP-469, фаза WP-7 DayPlan-Health-Residency)

> **Источник:** retrofit-audit WP-469 (24.07.2026) — сон/пульс/плавание коммитились в
> `current/DayPlan {date}.md` и уходили на GitHub 09–19.07. Решение пилота 24.07:
> вариант (б) — health-срез пишется ТОЛЬКО локально
> (`~/Library/IWE/health-data/day-summaries/<date>.md`), в DayPlan не попадает ничего,
> хук `day-open.summary-extra.sh` держит stdout пустым.
> **Проверка инвертирована:** прежняя версия (bug-2026-07-17) ТРЕБОВАЛА строку здоровья
> в DayPlan — теперь её присутствие = нарушение резидентности и блокер коммита.
> Пропажу данных ловим не по DayPlan, а по логу хука (`logs/day-open-summary-extra.err.log`)
> и наличию локального файла-среза.

```bash
FILE="$(ls ~/IWE/DS-my-strategy/current/DayPlan\ *.md 2>/dev/null | sort | tail -1)"
echo "=== Проверка: health-значения в DayPlan запрещены (WP-469) ==="
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "  ⚠️ DayPlan-файл не найден — проверка резидентности пропущена (не блокирует)"
elif grep -qE '\*\*(Сон|Пульс покоя|Плавание):\*\*|Сон и пульс покоя: нет данных' "$FILE"; then
  echo "  ❌ Health-строка найдена в DayPlan — нарушение резидентности WP-469 — COMMIT БЛОКИРОВАН"
  echo "       Убрать ДО коммита; срез дня — ~/Library/IWE/health-data/day-summaries/"
  exit 2
else
  echo "  ✅ Health-значений в DayPlan нет (резидентность WP-469 соблюдена)"
fi
```

- [ ] В DayPlan нет строк вида `**Сон:** / **Пульс покоя:** / **Плавание:**`. Если ❌ — commit заблокирован, строку удалить (срез лежит в `~/Library/IWE/health-data/day-summaries/`).

### 🟡 ПРОВЕРКА: Доставка обязательных хуков Close-контура (WP-484 Ф74в, 2026-08-07)

> **Источник:** 4/4 случая `blocked-witness-unavailable` (Ф56 доп./Ф73) и обход Quick Close 07.08 — один корень: хук на диске есть, но в settings.json не подключён. SessionStart-хук не может обнаружить отсутствие собственной регистрации, поэтому аудит живёт вне хук-контура. Граница: canary доказывает работоспособность файла, не факт загрузки живой сессией.

```bash
echo "=== Проверка: доставка обязательных хуков (Ф74в) ==="
if [ -x "$IWE/scripts/check-hooks-delivery.sh" ]; then
  if ! bash "$IWE/scripts/check-hooks-delivery.sh"; then
    echo "  🟡 Расхождения доставки хуков — в «Требует внимания» (не блокирует commit)"
  fi
else
  echo "  🟡 check-hooks-delivery.sh не найден/не исполняем — аудит доставки хуков не выполнен"
fi
```

- [ ] `check-hooks-delivery.sh` зелёный. Если 🟡 — расхождение регистрации/версии хуков в «Требует внимания» (не блокирует commit, требует разбора: класс «хук есть, доставки нет»).

### Git

- [ ] `git push` -- СРАЗУ после коммита, ДО вывода compact dashboard в VS Code
