#!/usr/bin/env bash
# check-script-collisions.sh — проверить коллизии скриптов между ~/IWE/scripts/ и FMT-exocortex-template/scripts/
#
# Назначение: S-21 (IWE-staging). Запускается ПЕРЕД промоцией скрипта L3→L1
# и периодически (Month Close), чтобы отследить drift.
#
# Типы скриптов: DP.KR.001 §5.6
# Тип 1 (universal): FMT/scripts/ → ~/IWE/scripts/ через update.sh
# Тип 2 (author): только в ~/IWE/scripts/ (не в FMT)
# Коллизия: имя есть в обоих местах → нужно решить (merge или rename).
#
# Использование:
#   check-script-collisions.sh              # показать коллизии
#   check-script-collisions.sh --verbose    # + diff для каждой коллизии
#   check-script-collisions.sh --quiet      # только код выхода (0=нет коллизий, 1=есть)

set -euo pipefail

IWE="${HOME}/IWE"
AUTHOR_SCRIPTS="${IWE}/scripts"
FMT_SCRIPTS="${IWE}/FMT-exocortex-template/scripts"

VERBOSE=0
QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$AUTHOR_SCRIPTS" ]]; then
  [[ $QUIET -eq 0 ]] && echo "ERR: не найдена $AUTHOR_SCRIPTS" >&2
  exit 2
fi
if [[ ! -d "$FMT_SCRIPTS" ]]; then
  [[ $QUIET -eq 0 ]] && echo "ERR: не найдена $FMT_SCRIPTS" >&2
  exit 2
fi

# Собираем имена файлов (только *.sh, *.py) на top-level
AUTHOR_FILES=$(cd "$AUTHOR_SCRIPTS" && find . -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" \) | sed 's|^\./||' | sort)
FMT_FILES=$(cd "$FMT_SCRIPTS" && find . -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" \) | sed 's|^\./||' | sort)

COLLISIONS=$(comm -12 <(echo "$AUTHOR_FILES") <(echo "$FMT_FILES"))

if [[ -z "$COLLISIONS" ]]; then
  [[ $QUIET -eq 0 ]] && echo "✓ коллизий нет ($(echo "$AUTHOR_FILES" | wc -l | tr -d ' ') в author, $(echo "$FMT_FILES" | wc -l | tr -d ' ') в FMT)"
  exit 0
fi

COUNT=$(echo "$COLLISIONS" | wc -l | tr -d ' ')

if [[ $QUIET -eq 1 ]]; then
  exit 1
fi

echo "⚠️  Коллизий: $COUNT"
echo ""
echo "Скрипты, существующие одновременно в ~/IWE/scripts/ и FMT/scripts/:"
echo ""

while IFS= read -r name; do
  AUTHOR_PATH="$AUTHOR_SCRIPTS/$name"
  FMT_PATH="$FMT_SCRIPTS/$name"
  AUTHOR_SIZE=$(wc -c < "$AUTHOR_PATH" | tr -d ' ')
  FMT_SIZE=$(wc -c < "$FMT_PATH" | tr -d ' ')

  if cmp -s "$AUTHOR_PATH" "$FMT_PATH"; then
    STATUS="идентичны"
  else
    STATUS="различаются"
  fi

  echo "  • $name — $STATUS (author: ${AUTHOR_SIZE}b, FMT: ${FMT_SIZE}b)"

  if [[ $VERBOSE -eq 1 && "$STATUS" == "различаются" ]]; then
    echo ""
    diff -u "$AUTHOR_PATH" "$FMT_PATH" | head -30 | sed 's/^/      /'
    echo ""
  fi
done <<< "$COLLISIONS"

echo ""
echo "Решение (по каждой коллизии):"
echo "  1. Merge: какая версия правильная → оставить одну, удалить другую"
echo "  2. Rename: переименовать author-версию (если нужны обе функции)"
echo ""
echo "Правило (DP.KR.001 §5.6):"
echo "  Тип 1 (universal) живёт только в FMT/scripts/ → ~/IWE/scripts/ через update.sh"
echo "  Тип 2 (author) живёт только в ~/IWE/scripts/"

exit 1
