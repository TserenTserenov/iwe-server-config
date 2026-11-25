#!/bin/bash
# create-wp-isolated-copy-smoke.sh -- WP-503 Ф111, inbox I-12 (found while creating WP-625 on 25.11):
# create-wp.sh run from an isolated copy of the governance repository
# (IWE_GOVERNANCE_REPO=.iwe-runtime/isolated-worktrees/<id>) must
#   1) write the main repository name, not the copy path, into the registry path cell;
#   2) add the WeekPlan row to the WP table, not to the scenario table placed above it.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)" || { echo "FAIL: cannot resolve scripts dir from $0"; exit 1; }
CREATE_WP="${CREATE_WP_UNDER_TEST:-$SCRIPTS_DIR/create-wp.sh}"
[ -f "$CREATE_WP" ] || { echo "FAIL: $CREATE_WP not found"; exit 1; }

FAILURES=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 -- ожидалось '$2', получено '$3'"
    FAILURES=$((FAILURES + 1))
  fi
}

GOV="$TMP/DS-test-strategy"
mkdir -p "$GOV/inbox" "$GOV/current" "$GOV/docs" "$TMP/.claude/state"
cat > "$GOV/docs/WP-REGISTRY.md" <<'REG'
| # | P | Название | Ст | Репо | Ставка | Бюджет | Комментарий |
|---|---|----------|----|----|--------|--------|-------------|
| 100 | P2 | Существующий РП | 🔄 | test | — | 1h | — |
REG
cat > "$GOV/current/WeekPlan W48 2026-11-23.md" <<'PLAN'
---
type: week-plan
---

## Сценарии недели

| № | Сценарий | Проверка | РП | Статус на утверждение | Свидетельство |
|---|---|---|---|---|---|
| SC-100-01 | Сценарий | Проверка | 100 | не начат | — |

## План

| 🚦 | # | РП | h | Источник | Статус | Результат |
|---|---|---|---|---|---|---|
| 🟠 | 100 | **Существующий РП** | 1 | — | in_progress | — |

**Бюджет:** 1h
PLAN

git -C "$GOV" init -q -b main
git -C "$GOV" -c user.email=t@t -c user.name=t add -A
git -C "$GOV" -c user.email=t@t -c user.name=t commit -q -m init
COPY_REL=".iwe-runtime/isolated-worktrees/test-copy"
git -C "$GOV" worktree add -q "$TMP/$COPY_REL" -b session-isolate/test 2>/dev/null \
  || { echo "FAIL: cannot create isolated worktree"; exit 1; }

IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO="$COPY_REL" IWE_SCRIPTS="$SCRIPTS_DIR" \
  bash "$CREATE_WP" --title "Карточка из отдельной копии" --budget 1h --priority P3 \
  --no-consent-check --no-artifactor-check > "$TMP/create.log" 2>&1
check "create-wp.sh завершился успешно" "0" "$?"

COPY="$TMP/$COPY_REL"
ROW=$(grep -E '^\| 101 \|' "$COPY/docs/WP-REGISTRY.md" || true)
[ -n "$ROW" ] || { echo "FAIL: строки РП-101 нет в реестре"; cat "$TMP/create.log"; exit 1; }
case "$ROW" in
  *"DS-test-strategy/inbox/WP-101/"*) check "путь в реестре — имя репозитория" "yes" "yes" ;;
  *) check "путь в реестре — имя репозитория" "DS-test-strategy/inbox/WP-101/" "$ROW" ;;
esac
case "$ROW" in
  *isolated-worktrees*) check "в реестре нет пути отдельной копии" "no" "yes" ;;
  *) check "в реестре нет пути отдельной копии" "no" "no" ;;
esac

PLAN_FILE="$COPY/current/WeekPlan W48 2026-11-23.md"
# The old writer put a row without the WP number into the scenario table: match the title.
SCEN_ROWS=$(awk '/^## Сценарии недели/{s=1;next} /^## /{s=0} s && /^\|/' "$PLAN_FILE" | grep -c 'Карточка из отдельной копии' || true)
PLAN_ROWS=$(awk '/^## План/{s=1;next} /^## /{s=0} s && /^\|/' "$PLAN_FILE" | grep -c '101' || true)
check "в таблице сценариев нет строки РП-101" "0" "$SCEN_ROWS"
check "в таблице РП есть строка РП-101" "1" "$PLAN_ROWS"

if [ "$FAILURES" -gt 0 ]; then
  echo "FAIL: $FAILURES проверок не прошло"
  echo "--- create.log ---"; cat "$TMP/create.log"
  exit 1
fi
echo "PASS: create-wp-isolated-copy-smoke"
