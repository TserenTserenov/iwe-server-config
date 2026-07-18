#!/bin/bash
# month-close-scaffold.sh — deterministic fact-collector for Month Close (WP-484, Ф5).
#
# Peer-session 2026-07-18-13: month-close/SKILL.md step 1 (Сбор данных) is
# already almost entirely deterministic today — commits loop, iwe-drift.sh,
# memory-health.sh/memory-bleed.sh, static file reads — it just runs live
# inside the interactive session instead of being pre-collected. Same shape
# of fix WP-484 already applied to Day Open (day-open-scaffold.sh) and Week
# Open (week-open-day-section-patch.sh).
#
# Writes one facts file the interactive ritual reads instead of collecting
# live. A source that fails or is missing gets an explicit "нет данных"
# marker in its section — never a silent gap (WP-484's core invariant).
#
# Usage:
#   month-close-scaffold.sh --as-of YYYY-MM
#
# --as-of is required (no implicit "today") — this is deliberate, not an
# oversight: it lets the script run against a past month for fixture testing
# without faking the system clock, and it makes a real Month Close run's
# period explicit in its own invocation instead of implicit in "when this
# happened to execute".

set -euo pipefail
export TZ=UTC

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# iwe-env-bootstrap.sh sets its own SCRIPT_DIR when sourced, clobbering ours (issue #259,
# already documented in iwe-drift.sh) — save under a distinct name first.
MONTH_CLOSE_SCAFFOLD_SCRIPT_DIR="$SCRIPT_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
SCRIPT_DIR="$MONTH_CLOSE_SCAFFOLD_SCRIPT_DIR"
GOVERNANCE_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
REPO_DIR="$WORKSPACE_DIR/$GOVERNANCE_REPO"

usage() {
  echo "Использование: month-close-scaffold.sh --as-of YYYY-MM" >&2
  exit 1
}

AS_OF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --as-of) AS_OF="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$AS_OF" ] || usage
echo "$AS_OF" | grep -qE '^[0-9]{4}-(0[1-9]|1[0-2])$' || {
  echo "Неверный формат --as-of: ожидается YYYY-MM, получено '$AS_OF'" >&2
  exit 1
}

YEAR="${AS_OF%-*}"
MONTH="${AS_OF#*-}"
MONTH_START="${AS_OF}-01"

# Дни в месяце — без date -v/-d (BSD vs GNU уже один раз ломали этот РП, WP-484
# Ф2 инцидент 17.07, stat -f/-c). Чистая арифметика вместо флагов конкретной ОС.
case "$MONTH" in
  01|03|05|07|08|10|12) DAYS_IN_MONTH=31 ;;
  04|06|09|11) DAYS_IN_MONTH=30 ;;
  02)
    if [ $(( YEAR % 4 == 0 && (YEAR % 100 != 0 || YEAR % 400 == 0) )) -eq 1 ]; then
      DAYS_IN_MONTH=29
    else
      DAYS_IN_MONTH=28
    fi
    ;;
  *) echo "Некорректный месяц: $MONTH" >&2; exit 1 ;;
esac
MONTH_END="${AS_OF}-${DAYS_IN_MONTH}"

# Следующий месяц — верхняя (исключающая) граница для git log --until, чтобы не
# зависеть от времени суток последнего коммита 30/31 числа.
if [ "$MONTH" = "12" ]; then
  NEXT_MONTH_START="$((YEAR + 1))-01-01"
else
  NEXT_MONTH_NUM=$(( 10#$MONTH + 1 ))
  NEXT_MONTH_START="$(printf '%s-%02d-01' "$YEAR" "$NEXT_MONTH_NUM")"
fi

OUT_FILE="$REPO_DIR/archive/MonthClose-facts-${AS_OF}.md"
mkdir -p "$REPO_DIR/archive"

# iwe_repo_dirs — де-дуп по физическому пути (WP-484, находка 17.07: repo-symlink
# алиас типа DS-strategy → DS-my-strategy иначе считается вторым репозиторием,
# завышает счётчик коммитов вдвое). Тот же паттерн, что day-open-scaffold.sh.
iwe_repo_dirs() {
  local repo real seen=""
  for repo in "$@"; do
    [ -d "$repo/.git" ] || continue
    real=$(cd -P "$repo" 2>/dev/null && pwd) || continue
    case " $seen " in
      *" $real "*) continue ;;
    esac
    seen="$seen $real"
    echo "$repo"
  done
}

GENERATED_AT="$(date -u "+%Y-%m-%dT%H:%M:%SZ")"

{
  echo "---"
  echo "type: month-close-facts"
  echo "period: $AS_OF"
  echo "generated_at: $GENERATED_AT"
  echo "generated_by: month-close-scaffold.sh"
  echo "---"
  echo
  echo "# Факты для закрытия месяца $AS_OF"
  echo
  echo "> Сгенерировано детерминированно, без LLM (WP-484 Ф5). Интерактивный /month-close читает этот файл на шаге 1 вместо живого сбора. Отсутствующий источник помечен явно, не пропущен молча."
  echo "> **Проверка свежести перед использованием (обязательно, см. month-close/SKILL.md шаг 1):** \`generated_at\` должен быть НЕ раньше конца месяца \`$AS_OF\` (месяц завершился → факты полные). Прогон в середине месяца (например для ручного теста) даёт частичный, не финальный срез — такой файл не заменяет живой сбор для реального Month Close."
  echo

  # --- 1b. Коммиты за месяц ---
  echo "## 1b. Коммиты за месяц ($MONTH_START .. $MONTH_END)"
  echo
  any_commits=0
  while IFS= read -r repo; do
    name="$(basename "$repo")"
    count=$(git -C "$repo" log --since="$MONTH_START" --until="$NEXT_MONTH_START" --oneline --no-merges 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 0 ]; then
      echo "- $name: $count"
      any_commits=1
    fi
  done < <(iwe_repo_dirs "$WORKSPACE_DIR"/*/)
  [ "$any_commits" -eq 1 ] || echo "PENDING: нет данных (0 коммитов во всех репо за период — проверить корректность периода, если неожиданно)"
  echo

  # --- 1c. Week Report'ы месяца ---
  echo "## 1c. Week Report'ы месяца"
  echo
  # Найдено живьём 18.07: реальный путь archive/week-plans/, не archive/week-reports/
  # (последний существует, но содержит только старые майские отчёты — путь дрейфует,
  # см. WP-485). Ищем в обоих, чтобы не зависеть от того, куда переедет архивация.
  reports_found=0
  for dir in "$REPO_DIR/archive/week-plans" "$REPO_DIR/archive/week-reports" "$REPO_DIR/current"; do
    [ -d "$dir" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      fname="$(basename "$f")"
      # Дата в имени файла: "WeekReport WNN YYYY-MM-DD.md" — берём последнее поле как дату недели.
      fdate="$(echo "$fname" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')"
      [ -n "$fdate" ] || continue
      fmonth="${fdate%-*}"
      if [ "$fmonth" = "$AS_OF" ]; then
        echo "- $fname (${f#"$REPO_DIR"/})"
        reports_found=1
      fi
    done < <(find "$dir" -maxdepth 1 -iname "WeekReport*.md" 2>/dev/null | sort)
  done
  [ "$reports_found" -eq 1 ] || echo "PENDING: нет данных (ни один WeekReport с датой недели в $AS_OF не найден в archive/week-plans, archive/week-reports, current)"
  echo

  # --- 1d. Drift (месячный) ---
  echo "## 1d. Дрейф (снимок на момент запуска скрипта, НЕ исторический для --as-of в прошлом)"
  echo
  echo "> iwe-drift.sh не хранит историю — при --as-of прошлого месяца этот блок покажет СЕГОДНЯШНЕЕ состояние, не состояние того месяца. Годен как sanity-check формата, не как исторический факт задним числом."
  echo
  drift_output="$(bash "$SCRIPT_DIR/iwe-drift.sh" 2>&1 || true)"
  if [ -n "$drift_output" ]; then
    echo "$drift_output"
  else
    echo "PENDING: нет данных (iwe-drift.sh вернул пустой отчёт — либо нет дрейфа, либо манифест недоступен, скрипт не различает эти два случая на своём текущем выводе)"
  fi
  echo

  # --- 1e. Decision log ---
  echo "## 1e. Decision log месяца"
  echo
  DECISION_LOG="$REPO_DIR/decisions/decision-log-${AS_OF}.md"
  if [ -f "$DECISION_LOG" ]; then
    echo "Файл найден: decisions/decision-log-${AS_OF}.md ($(wc -l < "$DECISION_LOG" | tr -d ' ') строк)"
  else
    echo "PENDING: нет данных (decisions/decision-log-${AS_OF}.md не существует)"
  fi
  echo

  # --- 1f. Метрики памяти ---
  echo "## 1f. Метрики memory/"
  echo
  bash "$SCRIPT_DIR/memory-health.sh" 2>&1 || echo "PENDING: memory-health.sh завершился с ошибкой"
  echo
  bash "$SCRIPT_DIR/memory-bleed.sh" 2>&1 || echo "(memory-bleed.sh вернул ненулевой код — есть нарушения, см. вывод выше; это ожидаемый рабочий режим скрипта, не сбой сборщика)"
  echo

  # --- 1g. Стабильные входы ---
  echo "## 1g. Стабильные входы"
  echo
  for f in "docs/Dissatisfactions.md" "docs/Projects.md"; do
    full="$REPO_DIR/$f"
    if [ -f "$full" ]; then
      echo "- $f: найден ($(wc -l < "$full" | tr -d ' ') строк)"
    else
      echo "PENDING: $f не найден"
    fi
  done
} > "$OUT_FILE"

echo "Факты записаны: $OUT_FILE"
