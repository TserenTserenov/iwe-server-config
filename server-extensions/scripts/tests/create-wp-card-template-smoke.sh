#!/bin/bash
# create-wp-card-template-smoke.sh -- WP-503 Ф111 (change code Ц38-20): create-wp.sh writes the card by the
# WP card template (docs/INBOX-CONVENTION.md, «Шаблон карточки РП») and creates the WP mailbox.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)" || { echo "FAIL: cannot resolve scripts dir from $0"; exit 1; }
CREATE_WP="${CREATE_WP_UNDER_TEST:-$SCRIPTS_DIR/create-wp.sh}"
WP_INBOX="$SCRIPTS_DIR/wp-inbox.sh"
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
mkdir -p "$GOV/inbox" "$GOV/current" "$GOV/docs" "$GOV/.claude/state"
cat > "$GOV/docs/WP-REGISTRY.md" <<'REG'
| # | P | Название | Ст | Репо | Ставка | Бюджет | Комментарий |
|---|---|----------|----|----|--------|--------|-------------|
| 100 | P2 | Существующий РП | 🔄 | test | — | 1h | — |
REG

IWE_ROOT="$TMP" IWE_GOVERNANCE_REPO="DS-test-strategy" IWE_SCRIPTS="$SCRIPTS_DIR" \
  bash "$CREATE_WP" --title "Карточка по шаблону" --budget 1h --priority P3 --no-consent-check --no-artifactor-check \
  > "$TMP/create.log" 2>&1
check "create-wp.sh завершился успешно" "0" "$?"

CARD="$GOV/inbox/WP-101/WP-101.md"
MAILBOX="$GOV/inbox/WP-101/INBOX.md"
[ -f "$CARD" ] || { echo "FAIL: нет карточки $CARD"; cat "$TMP/create.log"; exit 1; }

for field in 'budget_spent: 0h' 'audience: \[\]' 'artifact_kind: ""' 'artifact_home: ""' 'inbox: INBOX.md'; do
  check "в шапке есть «${field}»" "1" "$(grep -c -E "^${field}\$" "$CARD")"
done
check "раздел «Суть в трёх строках» идёт сразу за заголовком" "## Суть в трёх строках" \
  "$(awk '/^# WP-101:/{f=1;next} f&&NF{print;exit}' "$CARD")"
check "в теле есть раздел «Входящие»" "1" "$(grep -c '^## Входящие$' "$CARD")"
check "почтовый ящик создан" "yes" "$([ -f "$MAILBOX" ] && echo yes || echo no)"
check "заголовок ящика называет номер РП" "# Входящие РП-101" "$(head -1 "$MAILBOX")"

if [ -f "$WP_INBOX" ]; then
  bash "$WP_INBOX" add --repo "$GOV" --to WP-101 --from "smoke" --pointer "none" --summary "проверка записи в созданный ящик" > "$TMP/inbox-add.log" 2>&1
  check "wp-inbox.sh дописывает запись в созданный ящик" "1" "$(grep -c -E '^## И-1 · ' "$MAILBOX")"
else
  echo "  skip: wp-inbox.sh не найден рядом"
fi

if [ "$FAILURES" -eq 0 ]; then echo "ВСЕ ПРОВЕРКИ ПРОШЛИ"; else echo "ПРОВАЛОВ: $FAILURES"; exit 1; fi
