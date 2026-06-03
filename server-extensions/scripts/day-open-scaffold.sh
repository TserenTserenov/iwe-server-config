#!/usr/bin/env bash
# routing: helper  skill=day-open  called-by=haiku  deterministic=true
# see DP.SC.159, DP.ROLE.059
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
SERVER_MODE="${IWE_SERVER_MODE:-0}"  # WP-283: 1 = Linux server, Mac-only MCP недоступен

# --- Pre-flight healthcheck (WP-7 ФDay-Open-Hardening) ---
PREFLIGHT_JSON=$(bash "$IWE/scripts/day-open-preflight.sh" "$DATE" "$CONFIG" 2>/dev/null || echo '{"calendar":"unknown","scout":"unknown","triage":"unknown"}')
CALENDAR_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.calendar // "unknown"')
SCOUT_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.scout // "unknown"')
TRIAGE_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.triage // "unknown"')
MEMORY_PF=$(echo "$PREFLIGHT_JSON" | jq -r '.memory // "unknown"')

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
    if [ "${TRIAGE_PF:-unknown}" = "fail" ]; then
      echo "**Дельта:** ⚠️ Отчёт feedback-triage за $DATE отсутствует. Scheduler, вероятно, не запущен (простой ≥1 дня)."
    else
      echo "**Дельта:** нет данных (отчёт за $DATE отсутствует)"
    fi
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

  # Per-role launchd agents (старый com.exocortex.scheduler отключён с марта 2026)
  # Проверяем exit-status ключевых per-role агентов через launchctl list
  if command -v launchctl &>/dev/null; then
    local agents_bad=""
    for agent in com.strategist.morning com.strategist.notereview com.pulse.daily com.aisystant.profiler.recalculate; do
      local line status
      line=$(launchctl list 2>/dev/null | awk -v a="$agent" '$3==a{print}')
      [ -z "$line" ] && { agents_bad="$agents_bad $agent(missing)"; continue; }
      status=$(echo "$line" | awk '{print $2}')
      [ "$status" != "0" ] && [ "$status" != "-" ] && agents_bad="$agents_bad $agent(exit=$status)"
    done
    if [ -z "$agents_bad" ]; then
      echo "| LaunchAgents | 🟢 | per-role агенты OK |"
    else
      echo "| LaunchAgents | 🟡 |${agents_bad} |"
    fi
  else
    echo "| LaunchAgents | ⚪ | launchctl недоступен |"
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
  if [ "${SCOUT_PF:-unknown}" = "ok" ]; then
    local scout_dir="$IWE/DS-agent-workspace/scout/results/$YEAR/$MM/$DD"
    if [ -d "$scout_dir" ]; then
      local findings=0 captures=0
      [ -f "$scout_dir/report.md" ] && findings=$(grep -c '^### ' "$scout_dir/report.md" 2>/dev/null || echo 0)
      [ -f "$scout_dir/capture-candidates.md" ] && captures=$(grep -c '^### ' "$scout_dir/capture-candidates.md" 2>/dev/null || echo 0)
      echo "| Scout | 🟢 | $findings находок, $captures capture-кандидатов |"
    else
      echo "| Scout | 🟡 | нет отчёта на $DATE |"
    fi
  elif [ "${SCOUT_PF:-unknown}" = "fail" ]; then
    local last_log
    last_log=$(ls -t "$IWE/DS-autonomous-agents/logs/scout-"*.log 2>/dev/null | head -1 || echo "")
    if [ -n "$last_log" ]; then
      local last_date
      last_date=$(basename "$last_log" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
      echo "| Scout | 🔴 | нет отчёта на $DATE. Последний лог: $last_date (>20 дней простоя) — диагностика службы |"
    else
      echo "| Scout | 🔴 | нет отчёта на $DATE. Логи не найдены — служба не настроена |"
    fi
  else
    echo "| Scout | 🟡 | статус Scout не определён (preflight unavailable) |"
  fi

  # Scheduler / feedback-triage healthcheck с failure mode A/B/C
  # see: peer-сессия 2026-05-30-07-gap-list-day-open подэтап 4
  # Mode A — cron не запущен (нет юнита, нет логов 7+ дней)
  # Mode B — cron запустился, отчёт пустой (всё чисто, жалоб нет) = норм 🟢
  # Mode C — юнит загружен, но cron ещё не сработал (grace window до 06:30) = 🟡 pending
  local triage_file="$IWE/DS-agent-workspace/scheduler/feedback-triage/$DATE.md"
  local watchdog_log="$HOME/logs/synchronizer/feedback-watchdog-$DATE.log"
  local feedback_triage_log="$IWE/DS-my-strategy/logs/feedback-triage.log"
  local last_watchdog_log
  last_watchdog_log=$(ls -t "$HOME/logs/synchronizer/feedback-watchdog-"*.log 2>/dev/null | head -1 || echo "")
  local last_feedback_triage_log
  last_feedback_triage_log=$(ls -t "$IWE/DS-my-strategy/logs/feedback-triage"*.log 2>/dev/null | head -1 || echo "")
  local has_launchd_unit=false
  if launchctl list 2>/dev/null | grep -qE "iwe\.(scheduler|feedback-watchdog|synchronizer|feedback-triage)"; then
    has_launchd_unit=true
  fi

  # Grace window: feedback-triage запускается в 06:00, до 06:30 отсутствие отчёта — норма
  local current_hour current_min in_grace_window=false
  current_hour=$(date +%H)
  current_min=$(date +%M)
  if [ "$current_hour" -lt 6 ] || { [ "$current_hour" -eq 6 ] && [ "$current_min" -lt 30 ]; }; then
    in_grace_window=true
  fi

  if [ -f "$triage_file" ] || [ -f "$watchdog_log" ] || [ -f "$feedback_triage_log" ]; then
    # Mode B-1: отчёт/лог за сегодня есть → норм
    echo "| Scheduler/триаж | 🟢 | отчёт/лог за $DATE присутствует (Mode B норм) |"
  elif [ "$has_launchd_unit" = "true" ] && [ "$in_grace_window" = "true" ]; then
    # Mode C: юнит загружен, но cron ещё не сработал (до 06:30)
    echo "| Scheduler/триаж | 🟡 | Mode C: юнит загружен, ожидание cron (06:00) — grace window до 06:30 |"
  elif [ "$has_launchd_unit" = "true" ] && { [ -n "$last_watchdog_log" ] || [ -n "$last_feedback_triage_log" ]; }; then
    # Mode B-2: юнит зарегистрирован, есть свежий лог < 2 дней → норм (тишина = нет жалоб)
    local last_log_age_days=-1
    local last_log_file=""
    if [ -n "$last_feedback_triage_log" ]; then
      last_log_file="$last_feedback_triage_log"
    else
      last_log_file="$last_watchdog_log"
    fi
    if [ -n "$last_log_file" ]; then
      last_log_age_days=$(( ( $(date +%s) - $(stat -f %m "$last_log_file" 2>/dev/null || stat -c %Y "$last_log_file" 2>/dev/null || echo 0) ) / 86400 ))
    fi
    if [ "$last_log_age_days" -le 1 ] || [ "$last_log_age_days" -eq -1 ]; then
      echo "| Scheduler/триаж | 🟢 | Mode B: feedback-triage зарегистрирован, последний лог присутствует (нет жалоб = тишина) |"
    else
      echo "| Scheduler/триаж | 🟡 | Mode B: feedback-triage зарегистрирован, но лог не обновлялся ${last_log_age_days}д — возможно cron skipped |"
    fi
  else
    # Mode A: cron не запущен (нет юнита в launchctl) + нет свежих логов
    local last_log_age_days="∞"
    if [ -n "$last_feedback_triage_log" ]; then
      last_log_age_days=$(( ( $(date +%s) - $(stat -f %m "$last_feedback_triage_log" 2>/dev/null || stat -c %Y "$last_feedback_triage_log" 2>/dev/null || echo 0) ) / 86400 ))
    elif [ -n "$last_watchdog_log" ]; then
      last_log_age_days=$(( ( $(date +%s) - $(stat -f %m "$last_watchdog_log" 2>/dev/null || stat -c %Y "$last_watchdog_log" 2>/dev/null || echo 0) ) / 86400 ))
    fi
    echo "| Scheduler/триаж | 🔴 | **Mode A** (cron не отработал): юнит feedback-triage не зарегистрирован в launchctl, последний лог ${last_log_age_days}д назад |"

    # Auto-create incident-файл если ещё нет за сегодня
    local incident_file="$IWE/DS-my-strategy/inbox/INCIDENT-scheduler-cron-not-fired-$DATE.md"
    if [ ! -f "$incident_file" ]; then
      mkdir -p "$IWE/DS-my-strategy/inbox"
      cat > "$incident_file" <<INCEOF
---
type: incident
incident_id: INC-$DATE-scheduler-cron-not-fired
severity: critical
opened: $DATE
detected_by: day-open-scaffold.sh (auto Mode A)
mode: A (cron не запущен)
status: open
owner: pilot
related_wp: WP-7, WP-178, WP-356
auto_generated: true
---

# Инцидент: scheduler/feedback-watchdog не запущен ($DATE)

## Симптом (auto-detected)

- launchctl: юнит \`iwe.scheduler\` или \`iwe.feedback-watchdog\` отсутствует
- Последний лог \`~/logs/synchronizer/feedback-watchdog-*.log\` старше 24ч (или отсутствует)
- Mode A классификация (см. peer-сессия 2026-05-30-07 §Gap 3)

## Action items

1. Проверить \`~/Library/LaunchAgents/\` на наличие plist
2. \`bash $IWE/DS-my-strategy/scripts/install-launchd.sh\` для регистрации
3. Запустить руками: \`bash $IWE/DS-IT-systems/DS-ai-systems/synchronizer/scripts/scheduler.sh --dry-run\`

## Auto-generation note

Этот файл создан автоматически day-open-scaffold.sh при каждом обнаружении Mode A.
Если решено отложить fix — поставить \`status: deferred\` и убрать \`auto_generated\` поле, чтобы скаффолд не перезаписывал контекст.
INCEOF
    fi
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

  # active-wp freshness
  if [ "${MEMORY_PF:-unknown}" = "ok" ]; then
    echo "| active-wp | 🟢 | актуален (<7 дней) |"
  elif [ "${MEMORY_PF:-unknown}" = "stale" ]; then
    echo "| active-wp | 🟡 | устарел (>7 дней) — обновить через build-active-wp.py |"
  else
    echo "| active-wp | ⚪ | статус не определён |"
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

<details>
<summary><b>Активные РП (WP-283 Шаг E)</b></summary>

$(bash "$IWE/scripts/active-wp-sweep.sh" "$IWE/DS-my-strategy/inbox" "$IWE" 2>/dev/null || echo "<!-- active-wp-sweep: ошибка запуска -->")

</details>

<details open>
<summary><b>План на сегодня</b></summary>

<!-- PENDING: today_plan — синтез из WeekPlan W$WEEK_NUM (carry-over из Day Close + in_progress РП + budget_spread). Применить mandatory_daily_wps + daily_checkpoint_wps из day-rhythm-config.yaml. KE-строка: bash $IWE/DS-my-strategy/scripts/ke-queue-stats.sh --dayplan-row (реальный бюджет, не литерал «1h»). -->

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

$(if [[ "$SERVER_MODE" == "1" ]]; then
  bash "$IWE/scripts/server-calendar.sh" "$DATE" "$CONFIG" 2>/dev/null || echo "📅 **Календарь ($DAY_NUM $MONTH_RU):** ⚠️ PENDING — server-calendar.sh завершился с ошибкой"
else
  echo "<!-- PENDING: calendar — mcp__ext-google-calendar__list-events для calendar_ids из day-rhythm-config.yaml. Фильтр 09:00-19:00, private пропустить. -->"
  echo ""
  echo "| Время | Событие | Длит. | Связь с РП |"
  echo "|-------|---------|-------|------------|"
  echo "| HH:MM | <!-- PENDING --> | Xh | <!-- PENDING --> |"
  echo ""
  echo "⏱ Свободных блоков ≥1h: <!-- PENDING -->"
fi)

</details>

<details>
<summary><b>Здоровье платформы (QA)</b></summary>

$(render_bot_qa)

**IWE за ночь (светофор):**

$(render_iwe_status)

</details>

<details>
<summary><b>Наработки агентов</b></summary>

<details>
<summary><b>Наработки Scout (разбор)</b></summary>

$(render_scout)

</details>

<details>
<summary><b>📚 KE-кандидаты (Knowledge Extraction)</b></summary>

<!-- PENDING: ke_candidates — bash: grep -rl "status: pending-review" DS-my-strategy/inbox/extraction-reports/ | wc -l. Если 0 → удалить секцию. Если >0 → таблица файлов + SLA DP.SC.004 ≤24ч → запустить /apply-captures -->

</details>

</details>

<details>
<summary><b>Контент-план</b></summary>

**Стратегия:** <!-- PENDING: 1 строка из Strategy.md (пример: club → Telegram → Дзен/Habr, N постов/нед) -->
**TTL просрочены:** <!-- PENDING: D-NNN (истёк YYYY-MM-DD), ... или «нет просроченных» -->
**TTL скоро:** <!-- PENDING: D-NNN (истекает YYYY-MM-DD, через N дн), ... или «нет» -->

<!-- PENDING: content — таблица 1-3 тем из плана публикаций W{N}. Источник: WeekPlan или Strategy.md. -->

</details>

<details>
<summary><b>Разбор заметок</b></summary>

<!-- PENDING: notes_review — категоризация fleeting-notes.md (НЭП/Задача/Черновик/Знание/Шум) или carry-over из вчерашнего Note-Review коммита. Каждая заметка — markdown-ссылка с якорем на заголовок: [«текст заметки»](inbox/fleeting-notes.md#якорь-заголовка). Якорь = текст заголовка в нижнем регистре, пробелы → дефисы, без эмодзи. См. SKILL.md шаг 1c. -->

| Заметка | Тип | Предложение | ✅ |
|---------|-----|-------------|---|
| [<!-- PENDING -->](../inbox/fleeting-notes.md#якорь-заметки) | — | — | [ ] |

</details>

<details>
<summary><b>Мир</b></summary>

$(bash "$IWE/scripts/server-news.sh" "$CONFIG" 2>/dev/null || {
  echo "<!-- PENDING: world — RSS feeds недоступны (server-news.sh завершился с ошибкой). Каждый пункт = markdown URL. -->"
  echo ""
  echo "> ⚠️ Data-contract: каждый тезис в секции «Мир» обязан содержать markdown-ссылку на источник [заголовок](url)."
  echo "> Если источник недоступен — использовать placeholder [источник недоступен](n/a) и пометить 🔴 в «Требует внимания»."
  echo ""
  echo "**AI/LLM:** <!-- PENDING --> [заголовок](url) · [заголовок](url)"
  echo "**Инженерия:** <!-- PENDING --> [заголовок](url) · [заголовок](url)"
  echo "**Мировые события:** <!-- PENDING --> [заголовок](url) · [заголовок](url)"
})

**Вывод:** <!-- PENDING: news-lens — 2-4 предложения: какие из этих новостей релевантны активным РП (WP-350, WP-330, WP-351 и др.). Использовать контекст WeekPlan + WP-Registry. -->

</details>

<details>
<summary><b>Контекст недели (W$WEEK_NUM)</b></summary>

<!-- PENDING: bottleneck-week — запустить /bottleneck-pick --target weekplan --layer intra --horizon week --depth 1 и вставить 4-6 строк ПЕРВОЙ подсекцией: SC-failing, Bottleneck, Class (Policy/Resource/Cognitive), Этап 1, Сигнал. Source: extensions/day-open.after.md:158-191 -->

**Горлышко недели (SC-first, $DATE):** <!-- PENDING -->

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

<!-- PENDING: attention — собрать из: (1) carry-over WP, (2) IWE-светофор 🟡/🔴, (3) Scout не проверен, (4) обновления Base/IWE, (5) urgent feedback бота, (6) застрявшие заметки, (7) Мир без URL-ссылок, (8) Scheduler/триаж 🔴 (Mode A автоматически создаёт INCIDENT-файл), (9) KE-SLA 🔴 при oldest ≥3д, (10) Орг-сигналы R31 — прочитать DS-my-strategy/current/orgdev-signals.md и инжектить строки с ⚠ статусом (WP-377 Ф2.7). Если пусто — написать «—» или удалить секцию. -->
<!-- PENDING: self-check world — если секция «Мир» не содержит «](http» → добавить пункт: «🔴 Мир: данные без источников — требуется ручное заполнение URL» -->

</details>

*Создан: $DATE (Day Open / day-open-scaffold.sh WP-264 Ф2)*
EOF
