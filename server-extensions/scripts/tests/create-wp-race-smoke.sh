#!/bin/bash
# create-wp-race-smoke.sh -- WP-530 (2026-08-20, peer-session with Codex):
# concurrent create-wp.sh calls racing for the same WP number.
#
# Live reproduction found a two-layer bug, not one: create-wp.sh's WP_NUM is
# computed by scanning the REGISTRY without any lock, so two parallel callers
# can compute the same number and both proceed. wp-context-guarded-edit
# (--expected-absent for the card file, --expected-hash for the REGISTRY row)
# correctly rejects the losers -- but rollback_wp_creation() used to
# unconditionally `rm -rf "$WP_DIR"` and restore REGISTRY/WeekPlan from a
# snapshot taken at process start, with no check for whether a DIFFERENT
# (winning) session had already written its own result there in the
# meantime. Reproduced with 8 parallel callers on one host: 0 cards survived
# on disk instead of the expected 1, even though the winner's own log showed
# a clean success. This test locks in the fix: exactly one caller wins,
# exactly one row lands, nothing gets silently erased by a loser's rollback.
set -uo pipefail

CREATE_WP="${CREATE_WP_UNDER_TEST:-$HOME/IWE/scripts/create-wp.sh}"
SESSION_GUARD="${SESSION_GUARD_UNDER_TEST:-$HOME/IWE/iwe-local-config/scripts/session-guard.sh}"
[ -f "$CREATE_WP" ] || { echo "FAIL: $CREATE_WP not found"; exit 1; }
[ -f "$SESSION_GUARD" ] || { echo "FAIL: $SESSION_GUARD not found"; exit 1; }

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
mkdir -p "$GOV/inbox" "$GOV/current" "$GOV/docs" "$GOV/.claude/state"
cat > "$GOV/docs/WP-REGISTRY.md" <<'EOF'
| # | P | Название | Ст | Репо | Ставка | Бюджет | Комментарий |
|---|---|----------|----|----|--------|--------|-------------|
| 100 | P2 | Существующий РП | 🔄 | test | — | 1h | — |
EOF

echo "=== Живая гонка: 8 параллельных create-wp.sh на одном REGISTRY ==="
PIDS=()
for i in 1 2 3 4 5 6 7 8; do
  (
    IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO="DS-test-strategy" IWE_SCRIPTS="$(dirname "$SESSION_GUARD")" \
      bash "$CREATE_WP" --title "Карточка гонки $i" --budget 1h --priority P3 --no-consent-check \
      > "$TMP/race-$i.log" 2>&1
    echo $? > "$TMP/race-$i.exit"
  ) &
  PIDS+=($!)
done
for pid in "${PIDS[@]}"; do
  wait "$pid"
done

WINS=0
LOSSES=0
for i in 1 2 3 4 5 6 7 8; do
  code=$(cat "$TMP/race-$i.exit" 2>/dev/null || echo "?")
  if [ "$code" = "0" ]; then
    WINS=$((WINS + 1))
  else
    LOSSES=$((LOSSES + 1))
  fi
done
check "ровно 1 победитель из 8 параллельных create-wp.sh" "1" "$WINS"
check "ровно 7 отказов из 8 параллельных create-wp.sh" "7" "$LOSSES"

CARD_FILES=$(find "$GOV/inbox" -type f -name "WP-101.md" | wc -l | tr -d ' ')
check "ровно 1 файл карточки WP-101 на диске" "1" "$CARD_FILES"

REGISTRY_ROWS=$(grep -c "^| 101 " "$GOV/docs/WP-REGISTRY.md" 2>/dev/null || echo 0)
check "ровно 1 строка WP-101 в REGISTRY" "1" "$REGISTRY_ROWS"

ORIGINAL_ROW_INTACT=$(grep -c "^| 100 | P2 | Существующий РП" "$GOV/docs/WP-REGISTRY.md" 2>/dev/null || echo 0)
check "исходная строка WP-100 не тронута" "1" "$ORIGINAL_ROW_INTACT"

if [ -f "$GOV/inbox/WP-101/WP-101.md" ]; then
  CARD_TITLE=$(grep '^title:' "$GOV/inbox/WP-101/WP-101.md" | head -1)
  REGISTRY_TITLE_MATCH=$(grep -q "$(echo "$CARD_TITLE" | sed 's/title: "//;s/"$//')" "$GOV/docs/WP-REGISTRY.md" && echo yes || echo no)
  check "название в карточке совпадает с REGISTRY (не смешаны две сессии)" "yes" "$REGISTRY_TITLE_MATCH"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: гонка create-wp.sh разрешается корректно, ни один результат не потерян"
  exit 0
else
  echo "FAIL: $FAILURES проверок не прошли"
  exit 1
fi
