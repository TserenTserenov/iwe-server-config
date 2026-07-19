#!/bin/bash
# week-close-scaffold.sh — deterministic fact-collector for Week Close (WP-484, Ф4a).
#
# Week Close 19.07 review: gathering these facts by hand (commits across ~28
# repos, calendar, pending-phases-sweep.sh, check-wp-transfer-completeness.sh,
# memory-bleed.sh, registry semantic-check, [no-registry-touch] tag count)
# took up most of the session. Same shape of fix WP-484 already applied to
# Month Close (month-close-scaffold.sh) and Day Open (day-open-scaffold.sh).
#
# Writes one facts file the interactive week-close/SKILL.md reads instead of
# collecting live. A source that fails or is missing gets an explicit "нет
# данных" marker in its section — never a silent gap (WP-484's core
# invariant). This script only collects facts — it makes no decisions
# (carry-over, retro quality score, hypothesis verdicts stay interactive).
#
# Usage:
#   week-close-scaffold.sh --as-of YYYY-MM-DD
#
# --as-of is the Monday the closing week started on (required, no implicit
# "today") — lets the script run against a past week for fixture testing
# without faking the system clock, and makes a real Week Close run's period
# explicit in its own invocation instead of implicit in "when this happened
# to execute".

set -euo pipefail
export TZ=UTC

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# iwe-env-bootstrap.sh sets its own SCRIPT_DIR when sourced, clobbering ours (issue #259,
# already documented in iwe-drift.sh) — save under a distinct name first.
WEEK_CLOSE_SCAFFOLD_SCRIPT_DIR="$SCRIPT_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
SCRIPT_DIR="$WEEK_CLOSE_SCAFFOLD_SCRIPT_DIR"
GOVERNANCE_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
REPO_DIR="$WORKSPACE_DIR/$GOVERNANCE_REPO"

usage() {
  echo "Использование: week-close-scaffold.sh --as-of YYYY-MM-DD" >&2
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
echo "$AS_OF" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || {
  echo "Неверный формат --as-of: ожидается YYYY-MM-DD, получено '$AS_OF'" >&2
  exit 1
}

# WEEK_START — понедельник недели, что закрывается; WEEK_END — воскресенье той же
# недели (исключающая верхняя граница для git log --until — следующий понедельник).
WEEK_START="$AS_OF"
if ! WEEK_END_TS=$(date -u -d "$WEEK_START +6 days" +%s 2>/dev/null); then
  # BSD date (macOS) fallback — тот же класс развилки, что уже ловил этот РП
  # (Ф2 инцидент 17.07, stat -f/-c).
  WEEK_END_TS=$(date -j -f "%Y-%m-%d" -v+6d "$WEEK_START" +%s)
fi
WEEK_END=$(date -u -d "@$WEEK_END_TS" +%Y-%m-%d 2>/dev/null || date -u -r "$WEEK_END_TS" +%Y-%m-%d)
if ! NEXT_MONDAY_TS=$(date -u -d "$WEEK_START +7 days" +%s 2>/dev/null); then
  NEXT_MONDAY_TS=$(date -j -f "%Y-%m-%d" -v+7d "$WEEK_START" +%s)
fi
NEXT_MONDAY=$(date -u -d "@$NEXT_MONDAY_TS" +%Y-%m-%d 2>/dev/null || date -u -r "$NEXT_MONDAY_TS" +%Y-%m-%d)

OUT_FILE="$REPO_DIR/archive/WeekClose-facts-${AS_OF}.md"
mkdir -p "$REPO_DIR/archive"

# iwe_repo_dirs — де-дуп по физическому пути (WP-484, находка 17.07: repo-symlink
# алиас типа DS-strategy → DS-my-strategy иначе считается вторым репозиторием,
# завышает счётчик коммитов вдвое). Тот же паттерн, что day-open-scaffold.sh и
# month-close-scaffold.sh.
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
  echo "type: week-close-facts"
  echo "period: $WEEK_START..$WEEK_END"
  echo "generated_at: $GENERATED_AT"
  echo "generated_by: week-close-scaffold.sh"
  echo "---"
  echo
  echo "# Факты для закрытия недели ($WEEK_START .. $WEEK_END)"
  echo
  echo "> Сгенерировано детерминированно, без LLM (WP-484 Ф4a). Интерактивный /week-close читает этот файл на шаге 1 вместо живого сбора. Отсутствующий источник помечен явно, не пропущен молча. Решения (ретро, carry-over, оценка качества недели, вердикты гипотез) остаются интерактивными — этот файл только раскладывает факты."
  echo "> **Проверка свежести перед использованием:** \`generated_at\` должен быть НЕ раньше конца недели \`$WEEK_END\` (неделя завершилась → факты полные). Прогон в середине недели (например для ручного теста) даёт частичный, не финальный срез."
  echo

  # --- 1. Коммиты за неделю (шаг 1 SKILL.md) ---
  echo "## 1. Коммиты за неделю ($WEEK_START .. $WEEK_END)"
  echo
  any_commits=0
  while IFS= read -r repo; do
    name="$(basename "$repo")"
    count=$(git -C "$repo" log --since="$WEEK_START 00:00" --until="$NEXT_MONDAY 00:00" --oneline --no-merges 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 0 ]; then
      echo "- $name: $count"
      any_commits=1
    fi
  done < <(iwe_repo_dirs "$WORKSPACE_DIR"/*/)
  [ "$any_commits" -eq 1 ] || echo "PENDING: нет данных (0 коммитов во всех репо за период — проверить корректность периода, если неожиданно)"
  echo

  # --- 2. Календарь недели (шаг 1 SKILL.md) ---
  echo "## 2. Календарь недели"
  echo
  if [ -x "$SCRIPT_DIR/server-calendar.sh" ]; then
    calendar_output="$(bash "$SCRIPT_DIR/server-calendar.sh" --week "$WEEK_START" 2>/dev/null || true)"
    if [ -n "$calendar_output" ]; then
      echo "$calendar_output"
    else
      echo "PENDING: нет данных (server-calendar.sh вернул пустой вывод)"
    fi
  else
    echo "PENDING: нет данных (server-calendar.sh не найден или не исполняем)"
  fi
  echo

  # --- 3. Pending фазы внутри активных РП (шаг 5b SKILL.md) ---
  echo "## 3. Pending фазы активных РП (§5b)"
  echo
  echo "> Известный чужой баг: pending-phases-sweep.sh режет описание фазы по байтам (substr), не по символам — на кириллице может оборвать multibyte-последовательность посреди символа. Строгий UTF-8 парсер этого блока (не bash/grep) может упасть на невалидной последовательности; сам факт-файл при этом читается нормально любым инструментом, работающим с байтами. Не чинится здесь — баг в pending-phases-sweep.sh, не в этом скрипте (WP-484 Ф4a находка, кандидат в РП485 техдолг)."
  echo
  if [ -f "$SCRIPT_DIR/pending-phases-sweep.sh" ]; then
    sweep_output="$(bash "$SCRIPT_DIR/pending-phases-sweep.sh" --repo "$REPO_DIR" 2>&1 || true)"
    if [ -n "$sweep_output" ]; then
      echo "$sweep_output"
    else
      echo "PENDING: нет данных (pending-phases-sweep.sh не нашёл pending-фаз — либо их правда нет, либо скрипт вернул пусто; не различает эти два случая)"
    fi
  else
    echo "PENDING: нет данных (pending-phases-sweep.sh не найден)"
  fi
  echo

  # --- 4. Проверка полноты переноса перед архивацией (шаг 6 SKILL.md) ---
  echo "## 4. Полнота переноса РП перед архивацией (§6)"
  echo
  if [ -f "$SCRIPT_DIR/check-wp-transfer-completeness.sh" ]; then
    transfer_output="$(bash "$SCRIPT_DIR/check-wp-transfer-completeness.sh" --all "$WORKSPACE_DIR" 2>&1 || true)"
    if [ -n "$transfer_output" ]; then
      echo "$transfer_output"
    else
      echo "PENDING: нет данных (check-wp-transfer-completeness.sh вернул пустой вывод)"
    fi
  else
    echo "PENDING: нет данных (check-wp-transfer-completeness.sh не найден)"
  fi
  echo

  # --- 5. Проверка здоровья бэкапов (шаг 7a SKILL.md) ---
  echo "## 5. Здоровье бэкапов (§7a)"
  echo
  if [ -f "$SCRIPT_DIR/iwe-backup-check.sh" ]; then
    backup_exit=0
    backup_output="$(bash "$SCRIPT_DIR/iwe-backup-check.sh" 2>&1)" || backup_exit=$?
    echo "$backup_output"
    case "$backup_exit" in
      0) echo "(verdict: ✅ норма)" ;;
      1) echo "(verdict: ⚠️ warnings — зафиксировать в WeekReport)" ;;
      2) echo "(verdict: ❌ критичные gaps — устранить ДО бэкапа)" ;;
      *) echo "PENDING: нет данных (iwe-backup-check.sh вернул неожиданный код $backup_exit)" ;;
    esac
  else
    echo "PENDING: нет данных (iwe-backup-check.sh не найден)"
  fi
  echo

  # --- 6. Memory Validate (шаг 7d SKILL.md) ---
  echo "## 6. Memory Validate (§7d)"
  echo
  if [ -f "$SCRIPT_DIR/memory-bleed.sh" ]; then
    bleed_output="$(bash "$SCRIPT_DIR/memory-bleed.sh" 2>&1 || true)"
    if [ -n "$bleed_output" ]; then
      echo "$bleed_output"
    else
      echo "PENDING: нет данных (memory-bleed.sh вернул пустой вывод)"
    fi
  else
    echo "PENDING: нет данных (memory-bleed.sh не найден)"
  fi
  echo

  # --- 7. Semantic-check реестра (drift-guard.md: Week Close --semantic-check) ---
  echo "## 7. Semantic-check реестра (WP-419 registry-catalog.py --report)"
  echo
  echo "> Снимок на момент запуска скрипта, НЕ исторический для --as-of в прошлом (тот же класс оговорки, что у §1d в month-close-scaffold.sh для iwe-drift.sh). Прогон за прошлую неделю покажет СЕГОДНЯШНЕЕ состояние реестра, не состояние той недели — годится как sanity-check формата, не как исторический факт задним числом."
  echo
  REGISTRY_CATALOG="$WORKSPACE_DIR/DS-ecosystem-development/0.OPS/scripts/registry-catalog.py"
  if [ -f "$REGISTRY_CATALOG" ]; then
    catalog_output="$(python3 "$REGISTRY_CATALOG" --report 2>&1 || true)"
    if [ -n "$catalog_output" ]; then
      echo "$catalog_output"
    else
      echo "PENDING: нет данных (registry-catalog.py --report вернул пустой вывод)"
    fi
  else
    echo "PENDING: нет данных (registry-catalog.py не найден по ожидаемому пути)"
  fi
  echo

  # --- 8. Счётчик [no-registry-touch] за неделю (drift-guard.md: аудит exemption-tag) ---
  echo "## 8. Использования [no-registry-touch] за неделю"
  echo
  if [ -d "$REPO_DIR/.git" ]; then
    touch_count=$(git -C "$REPO_DIR" log --since="$WEEK_START 00:00" --until="$NEXT_MONDAY 00:00" --oneline --grep='[no-registry-touch]' -F 2>/dev/null | wc -l | tr -d ' ')
    echo "- $touch_count коммитов с тегом за неделю"
    if [ "$touch_count" -gt 2 ]; then
      echo "- 🟡 флаг: >2/неделю — drift-guard.md рекомендует расследовать (incentive обхода registry-гейта)"
    fi
  else
    echo "PENDING: нет данных ($GOVERNANCE_REPO — не git-репозиторий по ожидаемому пути)"
  fi
  echo

  # --- 9. Данные для R-вопросника (memory/r-questionnaire.md, WP-484 Ф4c) ---
  echo "## 9. Данные для R-вопросника (behaviour-report + incident-journal)"
  echo
  echo "> Алгоритм r-questionnaire.md перед вопросом 1: (1) behaviour-report.sh, (2) incident-journal.md — оба детерминированные, собраны здесь заранее вместо поиска в момент вопроса."
  echo
  BEHAVIOUR_REPORT="$WORKSPACE_DIR/.claude/lib/behaviour-report.sh"
  if [ -f "$BEHAVIOUR_REPORT" ]; then
    behaviour_exit=0
    behaviour_output="$(bash "$BEHAVIOUR_REPORT" --period "${WEEK_START%-*}" 2>&1)" || behaviour_exit=$?
    if [ "$behaviour_exit" -ne 0 ]; then
      # behaviour-report.sh на "нет данных за период" отвечает содержательным текстом
      # и ненулевым exit-кодом (не пустым выводом) — нормализуем под тот же формат
      # PENDING, что и остальные 8 секций, вместо показа сырой строки скрипта как есть.
      echo "PENDING: нет данных (behaviour-report.sh: ${behaviour_output:-нет данных за период})"
    else
      echo "$behaviour_output"
    fi
  else
    echo "PENDING: нет данных (behaviour-report.sh не найден)"
  fi
  echo
  INCIDENT_JOURNAL="$WORKSPACE_DIR/PACK-agent-rules/incident-journal.md"
  if [ -f "$INCIDENT_JOURNAL" ]; then
    echo "Журнал инцидентов найден: PACK-agent-rules/incident-journal.md ($(wc -l < "$INCIDENT_JOURNAL" | tr -d ' ') строк) — прочитать перед вопросом 1 (агент предъявляет паттерны, пользователь подтверждает, не вспоминает сам)."
  else
    echo "PENDING: нет данных (PACK-agent-rules/incident-journal.md не найден)"
  fi
} > "$OUT_FILE"

echo "Факты записаны: $OUT_FILE"
