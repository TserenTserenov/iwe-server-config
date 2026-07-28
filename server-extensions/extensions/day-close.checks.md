## Авторские проверки Day Close

### 🔴 БЛОКИРУЮЩАЯ ПРОВЕРКА: Архивация DayPlan (WP-356, peer-сессия 2026-05-29-04)

> **Источник:** DayPlan регулярно зависает в current/ (22-24 мая, 29 мая — 5 раз за 2 недели).
> Архивация DayPlan ОБЯЗАТЕЛЬНА перед финальным коммитом Day Close.
> Без неё следующий Day Open получит стейл-файл, и day-open.checks.md заблокирует commit.

```bash
TODAY=$(date +%Y-%m-%d)
cd "$HOME/IWE/DS-my-strategy"
# Проверить: DayPlan сегодняшнего дня заархивирован (находится в archive/day-plans/, НЕ в current/)
ARCHIVED=$(git ls-files archive/day-plans/ 2>/dev/null | grep "DayPlan $TODAY\.md" || true)
STILL_IN_CURRENT=$(git ls-files current/ 2>/dev/null | grep "DayPlan $TODAY\.md" || true)
if [ -n "$STILL_IN_CURRENT" ]; then
  echo "❌ DayPlan $TODAY ещё в current/ — архивировать ДО финального коммита:"
  echo "   git mv 'current/DayPlan $TODAY.md' archive/day-plans/"
  echo "   Затем повторить коммит."
  exit 1
elif [ -n "$ARCHIVED" ]; then
  echo "✅ DayPlan $TODAY в archive/day-plans/"
else
  echo "⚠️ DayPlan $TODAY не найден ни в current/ ни в archive/ — создан сегодня? Проверить вручную."
fi
# Также проверить: нет ли ДРУГИХ стейл-DayPlan в current/ (накопленный мусор)
OTHER_STALE=$(git ls-files current/ 2>/dev/null | grep -E "^current/DayPlan [0-9]{4}-[0-9]{2}-[0-9]{2}\.md$" | grep -v "DayPlan $TODAY\.md" || true)
if [ -n "$OTHER_STALE" ]; then
  echo "❌ Найдены старые DayPlan в current/ (мусор):"
  echo "$OTHER_STALE"
  echo "   Архивировать: git mv 'current/DayPlan *.md' archive/day-plans/"
  exit 1
fi
```

- [ ] **DayPlan сегодняшнего дня** → `archive/day-plans/` (проверено bash выше). Если ❌ — коммит заблокирован.

### Сбор данных (шаг 1) — коммиты ПЕРВИЧНЫ

> **Правило (S-12):** идти от коммитов к РП, не от DayPlan к коммитам.
> DayPlan = план, коммиты = факт. Незапланированные РП и ad-hoc появляются только в коммитах.

**Алгоритм сбора (заменяет стандартный шаг 1):**
1. Получить все коммиты за день по всем репо (с временем: `--format="%ai %s"`)
2. Сгруппировать по сессиям (временные кластеры)
3. Для каждой сессии: какой РП? Есть ли коммиты без РП? → ad-hoc
4. ТОЛЬКО ПОСЛЕ — сопоставить с DayPlan (план vs факт)

- [ ] **Коммит-аудит:** все коммиты разобраны по РП/сессиям (не только из DayPlan)
- [ ] **ad-hoc без РП:** выявлены → записаны в итоги → предложить `/wp-new` если >0.5h

### CHANGELOG FMT
~~Перенесён в Quick Close (шаг 1b).~~ На Day Close — только проверить, что не пропущен.

- [ ] **CHANGELOG FMT:** проверить, что обновлён в Quick Close (не пропущен)

### Синхронизация веток бота (pilot vs new-architecture)

```bash
cd ~/IWE/DS-IT-systems/aist_bot_newarchitecture
git fetch origin
DIFF_STAT=$(git diff origin/pilot origin/new-architecture --stat -- ':!.DS_Store')
if [ -z "$DIFF_STAT" ]; then
  echo "pilot и new-architecture: содержимое идентично ✅"
else
  echo "pilot и new-architecture: РАСХОДЯТСЯ по содержимому ⚠️"
  echo "$DIFF_STAT"
fi
```

Сигнализировать ТОЛЬКО если `git diff` показывает разницу в содержимом.

### Smoke-тесты бота (S59, WP-179)

```bash
cd ~/IWE/DS-IT-systems/aist_bot_newarchitecture
if [ -d ".venv" ]; then
  .venv/bin/python -m pytest tests/smoke/ -q --tb=line 2>&1
fi
```

64 теста, <1s. Если FAIL → сигнализировать.

### DS-agent-workspace: коммит автоматический (WP-5 #14b)

> Артефакты агентов (scheduler/reports, feedback-triage, scout, tester, extractor) коммитятся автоматически ночью — см. `DS-ai-systems/synchronizer/scripts/agent-workspace-commit` в scheduler (config.yaml `hour: 5`). Ручной коммит в Day Close — **аварийный режим**, сигнал сбоя auto-commit.

```bash
cd ~/IWE/DS-agent-workspace
if [ -n "$(git status --porcelain)" ]; then
    echo "⚠️  DS-agent-workspace грязный — auto-commit не сработал. Проверь ~/logs/synchronizer/agent-workspace-commit-$(date +%F).log"
    # Аварийный ручной коммит (если auto-commit сбойнул):
    # git add -A && git commit -m "chore: manual sync $(date +%F) — auto-commit fail" && git push
fi
```

- [ ] **DS-agent-workspace чистый:** если грязный — разобрать лог auto-commit, не коммитить вручную по привычке

### 🟡 ПРОВЕРКА: Незакрытые external-сессии (WP-358 Ф10)

> Финализация sessions через `/claude` бот — DP.SC.162 §close.
> Warning, не block: если есть незакрытые SESSION-* post-cutover — напомнить, но коммит проходит.

```bash
SECTION=$(bash "$HOME/IWE/DS-my-strategy/scripts/check-open-sessions.sh" 2>/dev/null)
if [ -n "$SECTION" ]; then
  COUNT=$(printf '%s\n' "$SECTION" | grep -c '^| \[SESSION-' || true)
  echo "  🟡 $COUNT незакрытых external-сессии в inbox/agent/sessions/ — рассмотри финализацию (DP.SC.162 §close)"
  printf '%s\n' "$SECTION" | grep '^| \[SESSION-' | head -5
else
  echo "  ✅ Незакрытых external-сессий нет"
fi
```

- [ ] Если ⚠️ — оценить, нужна ли финализация прямо сейчас (создать `sessions/external/2026-05/SESSION-<id>/report.md` + `git mv`). Если не сегодня — закоммитить как есть, продолжит висеть до Day Open завтра.

### Запись в черновик недельного поста (S-19, тестируется)

> **Где живёт черновик:** `DS-Knowledge-Index-Tseren/docs/{YYYY}/{NN}-{месяц}/week-draft-w{NN}.md`
> **Когда:** вместе со спросом «Обещания кому-то?» в шаге 7г (Не забыто?).
> **Зачем:** накопительный сбор материала для недельного поста — чтобы на Week Close писать не с нуля.

**4 вопроса автору (на шаге 7г):**
1. **Мир:** что из сегодняшнего — универсальный принцип/идея для поста?
2. **Сообщество:** что поможет участникам клуба?
3. **Человек:** что один читатель может попробовать прямо сейчас?
4. **Личное:** что я сам понял / что изменилось?

Допустимые ответы: пропустить день, одна-две строки, одна общая мысль на все 4 уровня. Пустое поле = прочерк остаётся.

**Строка метрик (автозаполнение):**

```bash
~/IWE/scripts/week-draft-append.sh
```

Скрипт собирает: WakaTime (`~/.wakatime/wakatime-cli --today`), коммиты за день по всем репо, закрытые РП (по коммитам `close/done WP-NNN`). Обновляет строку текущего дня в таблице черновика. Поля «Бюджет закрыт» и «Прогресс месяца» пока заполняются вручную (счёт сложен, после 2 недель решим, автоматизировать ли).

**На Пн Day Close — сначала инициализация недели:**

```bash
~/IWE/scripts/week-draft-init.sh
```

Создаёт пустой черновик `week-draft-w{NN}.md` (если ещё не существует). Идемпотентен.

- [ ] **Пн:** запущен `week-draft-init.sh` (новая неделя)
- [ ] **4 вопроса заданы:** мир/сообщество/человек/личное
- [ ] **Ответы добавлены в черновик:** строки `[День]` обновлены
- [ ] **Метрики дня записаны:** `week-draft-append.sh` (WakaTime/коммиты/РП) + вручную (бюджет/прогресс месяца)
- [ ] **Черновик закоммичен:** `git -C ~/IWE/DS-Knowledge-Index-Tseren add docs/ && git commit -m "docs: week-draft W{NN} update"`

### Рефлексия дня — прямой опрос (WP-484, второй канал получения рядом с ботовым `/reflect`)

> **Источник:** пилот 28.07 уточнил, что закрытие дня должно само предлагать написать рефлексию, не только напоминать про `/reflect` в боте постфактум (см. п. «Задача 1» хендоффа РП149 28.07 вечер — 1.12 `reflection_status: absent` держит жёлтый вердикт чек-листа персонального руководства). Оба канала пишут в один и тот же файл (`history/{месяц}/{дата}-reflection.md` в персональном репозитории `personal-guide`), который читает ночной рендер (`get_pilot_reflections`, `DS-autonomous-agents/scripts/render-pilot-guides.py`) — выбор канала не важен, важно что файл за сегодня появился.

```bash
TODAY=$(date +%Y-%m-%d)
MONTH="${TODAY:0:7}"
REFLECTION_PATH="history/$MONTH/$TODAY-reflection.md"
if gh api "repos/TserenTserenov/personal-guide/contents/$REFLECTION_PATH" >/dev/null 2>&1; then
  echo "✅ Рефлексия за $TODAY уже есть ($REFLECTION_PATH) — не спрашивать повторно"
else
  echo "🟡 Рефлексии за $TODAY нет — спросить пилота прямо сейчас (см. пункт ниже)"
fi
```

- [ ] **Если 🟡 — спросить пилота:** «Что ты сегодня узнал (Q3)? Какое намерение на завтра (Q5)?» Допустимый ответ: пропустить (пилот явно говорит «не сегодня») или 1-2 предложения на каждый вопрос.
- [ ] **Если пилот ответил** — записать канонический формат и закоммитить в его личный репозиторий. Между проверкой выше и этим шагом файл мог появиться (бот `/reflect` в параллели, пока пилот отвечал в чате) — GitHub требует `sha` существующего файла для PUT, без него запрос падает с `422`, поэтому берём `sha` заново прямо перед записью, не полагаясь на результат проверки выше:
  ```bash
  cat > /tmp/reflection-$TODAY.md <<'EOF'
  ## 3. Что узнал

  <ответ пилота на Q3>

  ## 5. Что завтра

  <ответ пилота на Q5>
  EOF
  EXISTING_SHA=$(gh api "repos/TserenTserenov/personal-guide/contents/$REFLECTION_PATH" --jq '.sha' 2>/dev/null || true)
  SHA_ARGS=()
  [ -n "$EXISTING_SHA" ] && SHA_ARGS=(-f "sha=$EXISTING_SHA")
  if gh api --method PUT "repos/TserenTserenov/personal-guide/contents/$REFLECTION_PATH" \
    -f message="reflect: $TODAY (day-close)" \
    -f content="$(base64 < /tmp/reflection-$TODAY.md)" \
    -f branch="main" \
    "${SHA_ARGS[@]}" >/dev/null 2>&1; then
    echo "✅ Рефлексия за $TODAY записана"
  else
    echo "❌ Запись рефлексии не удалась — файл мог измениться между проверкой и записью, сообщить пилоту и повторить шаг вручную"
  fi
  rm /tmp/reflection-$TODAY.md
  ```
- [ ] **Если пилот пропустил** — не создавать файл (честный `reflection_status: absent` в чек-листе — не баг, реальный сигнал поведения, см. хендофф РП149 28.07).

### 🔴 Мультипликатор IWE — всегда Method B (по бюджету)

> **Источник:** 2 июня 2026 — метод A (по ходам/времени) дал 1.4x, метод B (по бюджету) — 2.4x. Разница ×1.7 из-за пропущенных сессий и незачтённого бюджета WP. Пилот подтвердил: Method B — единственный правильный.

**Формула Method B:**

```
Мультипликатор = Бюджет_закрыт / WakaTime

Бюджет_закрыт = сумма:
  • done РП → полный бюджет (из WP-REGISTRY колонка h)
  • partial РП → % выполнения × бюджет (оценивать честно по артефактам)
  • ad-hoc (без РП в DayPlan) → по числу ходов:
      0 ходов → 0.25h | 2-4 → 0.5h | 5-7 → 0.75h | 8+ → 1-1.5h
  • FMT / server / прочее без peer-сессий → фактическое время
```

**ОБЯЗАТЕЛЬНЫЕ шаги перед расчётом:**
1. Открыть `sessions/00-index.md` → отфильтровать ВСЕ строки за сегодня (включая те, что не вошли в индекс)
2. Найти папки сессий которых НЕТ в индексе: `ls sessions/$(date +%Y-%m)/$(date +%Y-%m-%d)-*/` vs `grep $(date +%Y-%m-%d) sessions/00-index.md`
3. Для каждой папки с `report.md` — взять `duration_min` из frontmatter
4. Проверить сессии с `turns_count: 0` но ненулевым числом файлов `NN-writer.md` — реальные ходы = (кол-во файлов ÷ 2)
5. Только после полного списка — считать Method B

**НЕ применять Method A (по времени сессий)** — он игнорирует бюджетный кредит выполненных РП и всегда занижает.

**Sanity check (остаётся):** <1.5x при ≥10 peer-сессиях → пересчитать Method B, не показывать три метода, просто пересчитать.
