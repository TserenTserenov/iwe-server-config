#!/bin/bash
# routing: executor=script  deterministic=true  optimization_priority=1
# reflection-gap-check.sh
# WP-484 — покрытие дневной рефлексии за окно (для недельного/месячного закрытия).
# Не создаёт файл за период — только показывает, какие дни внутри окна ещё
# не имеют history/{месяц}/{дата}-reflection.md, чтобы предложить пилоту закрыть
# часть пробелов при закрытии недели/месяца, вместо того чтобы копить их молча.
#
# Usage:
#   reflection-gap-check.sh <days>   # days = размер окна (7 для недели, 30 для месяца)
#
# Env:
#   REFLECTION_REPO   — owner/repo (default: TserenTserenov/DS-personal-guide)

set -euo pipefail

DAYS="${1:?usage: reflection-gap-check.sh <days>}"
REPO="${REFLECTION_REPO:-TserenTserenov/DS-personal-guide}"

MISSING=()
for ((i = 0; i < DAYS; i++)); do
  D=$(date -v-${i}d +%Y-%m-%d 2>/dev/null || date -d "-${i} day" +%Y-%m-%d)
  M="${D:0:7}"
  if ! gh api "repos/$REPO/contents/history/$M/$D-reflection.md" >/dev/null 2>&1; then
    MISSING+=("$D")
  fi
done

if [ ${#MISSING[@]} -eq 0 ]; then
  echo "✅ Рефлексия есть за все $DAYS дней окна"
else
  echo "🟡 ${#MISSING[@]} из $DAYS дней без рефлексии: ${MISSING[*]}"
fi
