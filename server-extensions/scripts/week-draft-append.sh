#!/usr/bin/env bash
# week-draft-append.sh — обновить метрики текущего дня в черновике недельного поста.
#
# Собирает: WakaTime (--today), коммиты (all repos, since today 00:00), закрытые РП
# (из MEMORY.md текущей недели — помеченные ✅ сегодня), прогресс месяца (R done / R total).
#
# Использование:
#   week-draft-append.sh              # текущий день, текущая неделя
#   week-draft-append.sh --week 16    # явная неделя (если нужно)
#   week-draft-append.sh --dry-run    # показать, но не писать
#
# Не редактирует содержательные секции (мир/сообщество/человек/личное) —
# только строку таблицы «Метрики недели» для текущего дня.

set -euo pipefail

IWE="${HOME}/IWE"
KNOWLEDGE="${IWE}/DS-Knowledge-Index-Tseren"
WAKATIME_CLI="${HOME}/.wakatime/wakatime-cli"

DRY_RUN=0
WEEK_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --week) WEEK_ARG="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

TODAY_ISO=$(date +%Y-%m-%d)
DOW=$(date +%u)  # 1=Mon...7=Sun
DOM=$(date +%d)
MONTH_NUM=$(date +%m)
YEAR=$(date +%Y)

DOW_RU=("Пн" "Вт" "Ср" "Чт" "Пт" "Сб" "Вс")
DOW_LABEL="${DOW_RU[$((DOW-1))]} ${DOM#0}"

WEEK=${WEEK_ARG:-$(date +%V)}

# Reverse month numbering: Jan=12, Feb=11, Mar=10, Apr=09, May=08, Jun=07, Jul=06, Aug=05, Sep=04, Oct=03, Nov=02, Dec=01
MONTH_REVERSE=$((13 - 10#$MONTH_NUM))
MONTH_REVERSE_PADDED=$(printf "%02d" "$MONTH_REVERSE")
MONTH_NAME_RU=("январь" "февраль" "март" "апрель" "май" "июнь" "июль" "август" "сентябрь" "октябрь" "ноябрь" "декабрь")
MONTH_NAME="${MONTH_NAME_RU[$((10#$MONTH_NUM-1))]}"

DRAFT_DIR="${KNOWLEDGE}/docs/${YEAR}/${MONTH_REVERSE_PADDED}-${MONTH_NAME}"
DRAFT_FILE="${DRAFT_DIR}/week-draft-w${WEEK}.md"

if [[ ! -f "$DRAFT_FILE" ]]; then
  echo "ERR: черновик не найден: $DRAFT_FILE" >&2
  echo "Создай вручную или запусти week-draft-init.sh (W${WEEK})." >&2
  exit 1
fi

# 1. WakaTime
WAKA="—"
if [[ -x "$WAKATIME_CLI" ]]; then
  WAKA=$("$WAKATIME_CLI" --today 2>/dev/null | awk -F'[ ,]' '{
    total=0
    for(i=1;i<=NF;i++){
      if($i=="hrs"||$i=="hr") total += $(i-2)*60 + ($(i-1)=="and"?0:$(i-1))
      else if($i=="mins"||$i=="min") total += $(i-1)
    }
    if(total>=60) printf "%dh %02dmin", int(total/60), total%60
    else printf "%dmin", total
  }')
  [[ -z "$WAKA" ]] && WAKA="—"
fi

# 2. Commits across all repos since today 00:00
COMMITS=0
for repo in "$IWE"/*/; do
  if [[ -d "${repo}.git" ]]; then
    count=$(git -C "$repo" log --since="today 00:00" --oneline --no-merges 2>/dev/null | wc -l | tr -d ' ')
    COMMITS=$((COMMITS + count))
  fi
done

# 3. Closed WPs today (best effort — из MEMORY.md ищем done за сегодня тяжело; считаем через коммиты "close WP-" / "done WP-")
WPS_CLOSED=0
for repo in "$IWE"/*/; do
  if [[ -d "${repo}.git" ]]; then
    count=$(git -C "$repo" log --since="today 00:00" --pretty=%s 2>/dev/null | grep -ciE "(close|done|complete).*(wp-|WP-)[0-9]+" || true)
    WPS_CLOSED=$((WPS_CLOSED + count))
  fi
done

# 4. Progress month — parse from draft itself (user maintains R done count manually)
# Читаем строку «Закрыто на конец W» и используем если заполнена, иначе «—»
R_TOTAL=10  # апрель: R1-R10
R_DONE="?"
# Пробуем найти явно зафиксированное число в черновике; если не нашли — оставляем ?
if grep -qE "Закрыто на начало W${WEEK}.*R2.*R9.*1\.5" "$DRAFT_FILE" 2>/dev/null; then
  R_DONE_BASELINE="1.5"
fi
PROGRESS="—"
[[ "$R_DONE" != "?" ]] && PROGRESS=$(awk -v d="$R_DONE" -v t="$R_TOTAL" 'BEGIN{printf "%d%%", (d/t)*100}')

# Budget closed — пока оставляем для ручного заполнения (сложно посчитать автоматически)
BUDGET="—"

NEW_ROW="| ${DOW_LABEL} | ${WAKA} | ${COMMITS} | ${WPS_CLOSED} | ${BUDGET} | ${PROGRESS} |"

echo "== Черновик: $DRAFT_FILE"
echo "== Новая строка:"
echo "$NEW_ROW"
echo

if [[ $DRY_RUN -eq 1 ]]; then
  echo "(dry-run — изменения не записаны)"
  exit 0
fi

# Найти строку «| ${DOW_LABEL} |» в таблице и заменить
if grep -qE "^\| ${DOW_LABEL} \|" "$DRAFT_FILE"; then
  # macOS sed — нужен -i ''
  python3 - "$DRAFT_FILE" "$DOW_LABEL" "$NEW_ROW" <<'PYEOF'
import sys, re
path, label, new_row = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()
pattern = re.compile(r"^\| " + re.escape(label) + r" \|[^\n]*$", re.MULTILINE)
if pattern.search(content):
    content = pattern.sub(new_row, content, count=1)
    with open(path, "w") as f:
        f.write(content)
    print(f"OK: строка «{label}» обновлена")
else:
    print(f"ERR: не нашёл строку «{label}»", file=sys.stderr)
    sys.exit(1)
PYEOF
else
  echo "ERR: не нашёл строку для ${DOW_LABEL} в таблице черновика" >&2
  exit 1
fi
