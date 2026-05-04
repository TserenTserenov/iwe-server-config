#!/usr/bin/env bash
# active-wp-sweep.sh — heartbeat sweep активных РП
# see WP-283 Шаг E (DS-my-strategy/inbox/WP-283-server-day-open-crossplatform.md)
#
# Обходит DS-my-strategy/inbox/WP-*.md, находит файлы с status: in_progress | active,
# кросс-чекает с git activity, выводит markdown-таблицу кандидатов.
#
# Совместимость: bash 3.2+ (macOS), bash 4+ (Linux/NixOS)
#
# Использование:
#   bash active-wp-sweep.sh [INBOX_DIR] [IWE_ROOT]

set -uo pipefail

IWE="${2:-${IWE_ROOT:-$HOME/IWE}}"
INBOX="${1:-$IWE/DS-my-strategy/inbox}"
GIT_DAYS="${WP_SWEEP_GIT_DAYS:-7}"

# --- Найти python3 с yaml ---
_find_python3() {
  if python3 -c "import yaml" 2>/dev/null; then echo "python3"; return; fi
  local p
  for p in \
    /nix/store/aj1smkrsnv16lbz9g8qancb04b3kv0va-python3-3.12.8-env/bin/python3 \
    /usr/bin/python3 /usr/local/bin/python3; do
    [[ -x "$p" ]] && "$p" -c "import yaml" 2>/dev/null && { echo "$p"; return; }
  done
  echo ""
}

PYTHON=$(_find_python3)

if [[ -z "$PYTHON" ]]; then
  echo "<!-- active-wp-sweep: python3+yaml не найден, sweep пропущен -->"
  exit 0
fi

if [[ ! -d "$INBOX" ]]; then
  echo "<!-- active-wp-sweep: INBOX не найден: $INBOX -->"
  exit 0
fi

# --- Python-хелпер: извлекает wp + title из frontmatter ---
_extract_wp_meta() {
  local WP_FILE="$1"
  $PYTHON -c "
import sys, re
path = '$WP_FILE'
wp_num = ''
title = ''
try:
    with open(path, 'r', encoding='utf-8') as f:
        in_fm = False
        for line in f:
            line = line.rstrip()
            if line == '---':
                if not in_fm:
                    in_fm = True
                    continue
                else:
                    break
            if not in_fm:
                continue
            m = re.match(r'^wp:\s*(\S+)', line)
            if m:
                wp_num = m.group(1)
            m = re.match(r'^title:\s*[\"\']?(.+?)[\"\']?\s*$', line)
            if m:
                title = m.group(1).strip('\"\'')[:60]
except Exception:
    pass
print(wp_num + '|' + title)
" 2>/dev/null
}

# --- Собрать WP-файлы с in_progress или active ---
FOUND=0
OUTPUT_ROWS=""

for WP_FILE in "$INBOX"/WP-*.md; do
  [[ -f "$WP_FILE" ]] || continue

  # Быстрый grep: есть ли нужный статус?
  grep -qE "^status: (in_progress|active)" "$WP_FILE" 2>/dev/null || continue

  FOUND=$((FOUND + 1))
  FILENAME=$(basename "$WP_FILE" .md)

  # Извлечь номер и заголовок
  META=$(_extract_wp_meta "$WP_FILE")
  WP_NUM="${META%%|*}"
  WP_TITLE="${META##*|}"
  [[ -z "$WP_TITLE" ]] && WP_TITLE="$FILENAME"

  WP_LABEL="WP-${WP_NUM:-??}"

  # Git activity: ищем во всех git-репо под IWE
  GIT_INFO=""
  if [[ -n "$WP_NUM" ]]; then
    while IFS= read -r GIT_DIR; do
      REPO_DIR="$(dirname "$GIT_DIR")"
      HIT=$(git -C "$REPO_DIR" log \
        --since="${GIT_DAYS} days ago" \
        --oneline \
        --grep="WP-${WP_NUM}" \
        --all \
        2>/dev/null | head -1)
      if [[ -n "$HIT" ]]; then
        GIT_INFO="$HIT"
        break
      fi
    done < <(find "$IWE" -maxdepth 2 -name ".git" -type d 2>/dev/null)
  fi

  GIT_CELL="${GIT_INFO:0:55}"
  [[ -z "$GIT_CELL" ]] && GIT_CELL="нет (${GIT_DAYS}д)"

  OUTPUT_ROWS="${OUTPUT_ROWS}| **${WP_LABEL}** ${WP_TITLE} | ${GIT_CELL} |
"
done

# --- Вывод ---
if [[ $FOUND -eq 0 ]]; then
  echo "<!-- active-wp-sweep: активных РП не найдено -->"
  exit 0
fi

echo ""
echo "### 🔄 Активные РП (sweep по inbox/WP-*.md)"
echo ""
echo "| РП | Последний коммит (${GIT_DAYS}д) |"
echo "|----|---------------------------------|"
printf '%s' "$OUTPUT_ROWS"
echo ""
