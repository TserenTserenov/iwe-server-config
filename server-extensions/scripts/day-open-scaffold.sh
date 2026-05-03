#!/usr/bin/env bash
# day-open-scaffold.sh — детерминированная генерация скелета DayPlan
# see WP-264 (~/IWE/DS-my-strategy/inbox/WP-264-day-open-enforcement.md), Ф2
#
# Принцип «Enforcement требует наблюдателя вне субъекта» (DP.ARCH.NNN, Ф5):
# секции, извлекаемые из конфига/файлов/git/scheduler reports — генерируются
# bash'ом без LLM. Секции, требующие синтеза или MCP, помечаются <!-- PENDING: X -->.
# Hook protocol-artifact-validate.sh уже проверяет 11 обязательных секций;
# Ф3 добавит проверку отсутствия PENDING перед commit.
#
# Использование:
#   bash day-open-scaffold.sh [YYYY-MM-DD] > "DS-my-strategy/current/DayPlan YYYY-MM-DD.md"
#   bash day-open-scaffold.sh                    # дата = сегодня
#   bash day-open-scaffold.sh 2026-04-26         # явная дата
#
# Все 10 обязательных секций (по hook protocol-artifact-validate.sh) присутствуют.

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"
DATE="${1:-$(date +%Y-%m-%d)}"
CONFIG="$IWE/DS-my-strategy/exocortex/day-rhythm-config.yaml"

# --- Date helpers (cross-platform: macOS BSD date / Linux GNU date) ---
if [[ "$(uname -s)" == "Darwin" ]]; then
  WEEK_NUM=$(date -j -f "%Y-%m-%d" "$DATE" "+%V" 2>/dev/null)
  DOW_NUM=$(date -j -f "%Y-%m-%d" "$DATE" "+%u" 2>/dev/null)
  DAY_NUM=$(date -j -f "%Y-%m-%d" "$DATE" "+%-d" 2>/dev/null)
  MONTH_NUM=$(date -j -f "%Y-%m-%d" "$DATE" "+%-m" 2>/dev/null)
  YEAR=$(date -j -f "%Y-%m-%d" "$DATE" "+%Y" 2>/dev/null)
  MM=$(date -j -f "%Y-%m-%d" "$DATE" "+%m" 2>/dev/null)
  DD=$(date -j -f "%Y-%m-%d" "$DATE" "+%d" 2>/dev/null)
  YDAY=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%Y-%m-%d" 2>/dev/null)
  YDAY_NUM=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%-d" 2>/dev/null)
  YDAY_MNUM=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%-m" 2>/dev/null)
else
  # GNU date (Linux / NixOS)
  WEEK_NUM=$(date -d "$DATE" "+%V" 2>/dev/null)
  DOW_NUM=$(date -d "$DATE" "+%u" 2>/dev/null)
  DAY_NUM=$(date -d "$DATE" "+%-d" 2>/dev/null)
  MONTH_NUM=$(date -d "$DATE" "+%-m" 2>/dev/null)
  YEAR=$(date -d "$DATE" "+%Y" 2>/dev/null)
  MM=$(date -d "$DATE" "+%m" 2>/dev/null)
  DD=$(date -d "$DATE" "+%d" 2>/dev/null)
  YDAY=$(date -d "$DATE - 1 day" "+%Y-%m-%d" 2>/dev/null)
  YDAY_NUM=$(date -d "$DATE - 1 day" "+%-d" 2>/dev/null)
  YDAY_MNUM=$(date -d "$DATE - 1 day" "+%-m" 2>/dev/null)
fi

DOW_NAMES=("" "Понедельник" "Вторник" "Среда" "Четверг" "Пятница" "Суббота" "Воскресенье")
MONTH_NAMES=("" "января" "февраля" "марта" "апреля" "мая" "июня" "июля" "августа" "сентября" "октября" "ноября" "декабря")
DOW_RU="${DOW_NAMES[$DOW_NUM]}"
MONTH_RU="${MONTH_NAMES[$MONTH_NUM]}"
YDAY_MONTH_RU="${MONTH_NAMES[$YDAY_MNUM]}"

# --- YAML reader (uses python3 + yaml; fallback to grep) ---
read_yaml() {
  local key="$1"
  python3 -c "
import yaml, sys
try:
    with open('$CONFIG') as f: d = yaml.safe_load(f)
    keys = '$key'.split('.')
    v = d
    for k in keys:
        v = v.get(k) if isinstance(v, dict) else None
        if v is None: break
    print(v if v is not None else '')
except Exception:
    pass
" 2>/dev/null
}

# --- Strategy_day guard (Ф6 WP-264) ---
# Если сегодня strategy_day → не генерировать DayPlan (SKILL.md шаг 4).
# Возвращает exit 2; extension обрабатывает этот код и выводит сообщение Claude.
STRATEGY_DAY_NAME=$(read_yaml "day_open.strategy_day" || true)
case "${STRATEGY_DAY_NAME:-monday}" in
  monday)    STRATEGY_DOW=1 ;;
  tuesday)   STRATEGY_DOW=2 ;;
  wednesday) STRATEGY_DOW=3 ;;
  thursday)  STRATEGY_DOW=4 ;;
  friday)    STRATEGY_DOW=5 ;;
  saturday)  STRATEGY_DOW=6 ;;
  sunday)    STRATEGY_DOW=7 ;;
  *)         STRATEGY_DOW=0 ;;
esac
if [ "${DOW_NUM:-0}" = "$STRATEGY_DOW" ]; then
  exit 2
fi

# --- Section: Pomodoro/ритм ---
render_pomodoro() {
  local work brk long n
  work=$(read_yaml "pomodoro.work_minutes")
  brk=$(read_yaml "pomodoro.break_minutes")
  long=$(read_yaml "pomodoro.long_break_minutes")
  n=$(read_yaml "pomodoro.sessions_before_long_break")
  echo "**Помидорки:** ${work:-?} мин работа / ${brk:-?} мин перерыв / ${long:-?} мин длинный после ${n:-?} сессий"
}

# --- Section: Видео (новые сегодня) ---
render_video() {
  local enabled
  enabled=$(read_yaml "video.enabled")
  if [ "$enabled" != "True" ]; then
    echo "*video.enabled = false → пропущено*"
    return
  fi
  local dirs=("$HOME/Documents/Zoom" "$HOME/Documents/Телемост" "$HOME/Видеозаписи Телемост")
  local count=0
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    local n
    n=$(find "$d" -mtime 0 \( -name "*.mp4" -o -name "*.mov" -o -name "*.webm" -o -name "*.m4a" -o -name "*.mp3" \) 2>/dev/null | wc -l | tr -d ' ')
    count=$((count + n))
  done
  if [ "$count" -eq 0 ]; then
    echo "**Видео:** 0 новых записей сегодня"
  else
    echo "**Видео:** $count новых записей сегодня (директории: Zoom / Телемост / Видеозаписи Телемост)"
  fi
}

# --- Section: Здоровье платформы (feedback-triage report) ---
render_bot_qa() {
  local file="$IWE/DS-agent-workspace/scheduler/feedback-triage/$DATE.md"
  if [ -f "$file" ]; then
    awk '/^\*\*Дельта/,/^### ✏️/' "$file" 2>/dev/null | head -40
    echo
    echo "*Полный отчёт: \`$file\`*"
  else
    echo "**Дельта:** нет данных (отчёт за $DATE отсутствует)"
    echo
    echo "| Метрика | Значение |"
    echo "|---------|----------|"
    echo "| Сегодня | нет данных |"
    echo "| Urgent | нет данных |"
  fi
  echo
  echo "<!-- PENDING: smoke-tests — N passed/failed (если запущены до commit) -->"
}

# --- Section: IWE за ночь (светофор) ---
render_iwe_status() {
  echo "| Подсистема | Статус | Детали |"
  echo "|------------|--------|--------|"

  # Scheduler report
  local sched_file
  sched_file="$IWE/DS-agent-workspace/scheduler/reports/SchedulerReport $DATE.md"
  if [ -f "$sched_file" ]; then
    echo "| Scheduler | 🟢 | отчёт за $DATE |"
  else
    echo "| Scheduler | 🟡 | нет отчёта на $DATE |"
  fi

  # template-sync (FMT last commit)
  if [ -d "$IWE/FMT-exocortex-template/.git" ]; then
    local fmt_last
    fmt_last=$(git -C "$IWE/FMT-exocortex-template" log -1 --format="%cr" 2>/dev/null || echo "?")
    echo "| template-sync | 🟢 | FMT last commit: $fmt_last |"
  else
    echo "| template-sync | 🔴 | FMT не найден |"
  fi

  # Scout findings
  local scout_dir="$IWE/DS-agent-workspace/scout/results/$YEAR/$MM/$DD"
  if [ -d "$scout_dir" ]; then
    local findings=0 captures=0
    [ -f "$scout_dir/report.md" ] && findings=$(grep -c '^### ' "$scout_dir/report.md" 2>/dev/null || echo 0)
    [ -f "$scout_dir/capture-candidates.md" ] && captures=$(grep -c '^### ' "$scout_dir/capture-candidates.md" 2>/dev/null || echo 0)
    echo "| Scout | 🟢 | $findings находок, $captures capture-кандидатов |"
  else
    echo "| Scout | 🟡 | нет отчёта на $DATE |"
  fi

  # gate_log активность (Ф1 проверка)
  local gate_log="$IWE/.claude/logs/gate_log.jsonl"
  if [ -f "$gate_log" ]; then
    local recent
    recent=$(awk -v d="$DATE" '$0 ~ d' "$gate_log" 2>/dev/null | wc -l | tr -d ' ')
    echo "| gate_log | 🟢 | $recent записей за $DATE (Ф1 WP-264) |"
  else
    echo "| gate_log | 🟡 | $gate_log не найден |"
  fi

  # update.sh check (FMT)
  if [ -d "$IWE/FMT-exocortex-template" ]; then
    local upd_status
    upd_status=$(cd "$IWE/FMT-exocortex-template" && bash update.sh --check 2>&1 | grep -oE '[0-9]+ обновлен|нет обновлен|актуал' | head -1)
    echo "| Update IWE | 🟢 | ${upd_status:-проверено} |"
  fi

  # Base repos (FPF/SPF/ZP) — fetch + behind count
  for repo in FPF SPF ZP; do
    local d="$IWE/$repo"
    if [ -d "$d/.git" ]; then
      git -C "$d" fetch --quiet 2>/dev/null
      local behind
      behind=$(git -C "$d" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
      if [ "$behind" -gt 0 ]; then
        echo "| $repo | 🟡 | $behind новых коммитов upstream |"
      else
        echo "| $repo | 🟢 | актуален |"
      fi
    fi
  done
}

# --- Section: Scout (ссылка на отчёт) ---
render_scout() {
  local scout_dir="$IWE/DS-agent-workspace/scout/results/$YEAR/$MM/$DD"
  if [ -d "$scout_dir" ]; then
    local findings=0 captures=0
    [ -f "$scout_dir/report.md" ] && findings=$(grep -c '^### ' "$scout_dir/report.md" 2>/dev/null || echo 0)
    [ -f "$scout_dir/capture-candidates.md" ] && captures=$(grep -c '^### ' "$scout_dir/capture-candidates.md" 2>/dev/null || echo 0)
    echo "> Отчёт за $DAY_NUM $MONTH_RU — $findings находок, $captures capture-кандидатов"
    echo "> **Статус ревью:** ⬜ не проверен"
    echo
    echo "Путь: \`$scout_dir/\`"
  else
    echo "> Нет отчёта на $DATE — Scout не запускался или ещё не закончил"
    echo "> **Статус ревью:** — (нет находок)"
  fi
}

# --- Section: Итоги вчера (commits stats) ---
render_yesterday() {
  local total=0 repos=0
  for repo in "$IWE"/*/; do
    [ -d "$repo/.git" ] || continue
    local n
    n=$(git -C "$repo" log --since="$YDAY 00:00" --until="$YDAY 23:59" --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -gt 0 ]; then
      total=$((total + n))
      repos=$((repos + 1))
    fi
  done
  echo "**Коммиты:** $total в $repos репо | **РП закрыто:** <!-- PENDING: count из git log + WeekPlan -->"
  echo
  echo "<!-- PENDING: ключевое — 1-3 значимых результата вчерашнего дня (требует синтеза из коммитов) -->"
}

# --- Output ---
cat <<EOF
---
type: daily-plan
date: $DATE
week: W$WEEK_NUM
status: active
agent: Стратег
generated_by: day-open-scaffold.sh (WP-264 Ф2)
---

# Day Plan: $DAY_NUM $MONTH_RU $YEAR ($DOW_RU)

<details open>
<summary><b>План на сегодня</b></summary>

<!-- PENDING: today_plan — синтез из WeekPlan W$WEEK_NUM (carry-over из Day Close + in_progress РП + budget_spread). Применить mandatory_daily_wps из day-rhythm-config.yaml. -->

| 🚦 | # | РП | h | Статус | Результат |
|----|---|-----|---|--------|-----------|
| ⚫ | N | **Саморазвитие** — [тема] | 1-2 | pending | — |
| 🔴 | NNN | **<!-- PENDING -->** | X | pending | — |

**Бюджет дня:** <!-- PENDING: budget — посчитать после плана, формат см. templates-dayplan.md (бюджет РП всего / физ / мультипликатор). -->

**Mandatory check:** WP-7 (техдолг бота, ≥30 мин) + ≥1 контентный РП — <!-- PENDING: проверить наличие в плане -->

**Carry-over из Day Close вчера:** <!-- PENDING: цитата секции «Завтра начать с» из вчерашнего DayPlan; если первый день — написать «нет (первый день)» -->

</details>

<details>
<summary><b>Саморазвитие (шаг 3)</b></summary>

<!-- PENDING: self_dev — прочитать drafts/draft-list.md и выбрать активный D-NNN. Обязательно:
  1. Номер черновика и тема: [D-NNN](drafts/D-NNN-тема.md)
  2. Где остановился: параграф / раздел / последний написанный тезис
  3. Сколько времени сегодня и на что именно
  4. TTL истекает? (из «Требует внимания» предыдущего DayPlan)
  Минимум: одна строка в таблице плана + эта секция с D-NNN. -->

**Активный черновик:** <!-- PENDING: [D-NNN](drafts/D-NNN-тема.md) -->
**Где остановился:** <!-- PENDING: раздел/параграф/последний тезис -->
**Сегодня:** <!-- PENDING: X мин/h — на что именно (ревью / дописать / структурировать) -->

</details>

<details>
<summary><b>Календарь ($DAY_NUM $MONTH_RU)</b></summary>

<!-- PENDING: calendar — mcp__ext-google-calendar__list-events для calendar_ids из day-rhythm-config.yaml. Фильтр 09:00-19:00, private пропустить. -->

| Время | Событие | Длит. | Связь с РП |
|-------|---------|-------|------------|
| HH:MM | <!-- PENDING --> | Xh | <!-- PENDING --> |

⏱ Свободных блоков ≥1h: <!-- PENDING -->

</details>

<details>
<summary><b>Здоровье платформы (QA)</b></summary>

$(render_bot_qa)

**IWE за ночь (светофор):**

$(render_iwe_status)

</details>

<details>
<summary><b>Наработки Scout (разбор)</b></summary>

$(render_scout)

</details>

<details>
<summary><b>Контент-план</b></summary>

<!-- PENDING: content — 1-3 темы из стратегии маркетинга + draft-list. Источник: DS-my-strategy/drafts/ или Strategy.md. -->

</details>

<details>
<summary><b>Разбор заметок</b></summary>

<!-- PENDING: notes_review — категоризация fleeting-notes.md (НЭП/Задача/Черновик/Знание/Шум) или carry-over из вчерашнего Note-Review коммита. Заметка = markdown-ссылка на источник (см. SKILL.md шаг 1c). -->

| Заметка | Тип | Предложение | ✅ |
|---------|-----|-------------|---|
| <!-- PENDING --> | — | — | [ ] |

</details>

<details>
<summary><b>Мир</b></summary>

<!-- PENDING: world — RSS feeds (curl) для news.topics из day-rhythm-config.yaml + WebSearch fallback. Каждый пункт = markdown URL (feedback_world_section_links.md). -->

- <!-- PENDING --> [заголовок](url) — источник
- <!-- PENDING --> [заголовок](url) — источник

</details>

<details>
<summary><b>Контекст недели (W$WEEK_NUM)</b></summary>

<!-- PENDING: week_context — фокус недели + текущий бюджет/мультипликатор + ТОС. Источник: DS-my-strategy/current/WeekPlan W$WEEK_NUM*.md. -->

</details>

<details>
<summary><b>Итоги вчера ($YDAY_NUM $YDAY_MONTH_RU)</b></summary>

$(render_yesterday)

</details>

<details>
<summary><b>Помидорки/ритм</b></summary>

$(render_pomodoro)

</details>

<details>
<summary><b>Видео</b></summary>

$(render_video)

</details>

<details>
<summary><b>Требует внимания</b></summary>

<!-- PENDING: attention — собрать из: (1) carry-over WP, (2) IWE-светофор 🟡/🔴, (3) Scout не проверен, (4) обновления Base/IWE, (5) urgent feedback бота, (6) застрявшие заметки. Если пусто — написать «—» или удалить секцию. -->

</details>

*Создан: $DATE (Day Open / day-open-scaffold.sh WP-264 Ф2)*
EOF
