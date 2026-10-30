#!/bin/bash
# declare-intent-ritual-smoke.sh -- WP-484 Ф267 п.4: declare-intent.sh stores the
# pilot-agreed Ritual in the conversation record; a repeated declaration for the
# same WP keeps it, another WP or outside-wp starts without it.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/declare-intent.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export IWE_RUNTIME_DIR="$TMP/runtime" IWE_SCRIPTS="$TMP/no-scripts" CLAUDE_CODE_SESSION_ID="aaaa-bbbb" IWE_AGENT="claude-code"
REC="$IWE_RUNTIME_DIR/intent-declarations/$CLAUDE_CODE_SESSION_ID.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ritual_text() { jq -r '.ritual.text // "none"' "$REC"; }

bash "$SCRIPT" WP-484 >/dev/null || fail "plain declaration must work as before"
[ "$(ritual_text)" = none ] || fail "plain declaration must not invent a Ritual"

bash "$SCRIPT" WP-484 --ritual "Роль: писатель; РП-484; закрытый контур" >/dev/null || fail "--ritual declaration refused"
[ "$(ritual_text)" = "Роль: писатель; РП-484; закрытый контур" ] || fail "Ritual text not stored: $(ritual_text)"
jq -e '.ritual.agreed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$REC" >/dev/null || fail "agreed_at missing or malformed"
AGREED=$(jq -r '.ritual.agreed_at' "$REC")

bash "$SCRIPT" WP-484 >/dev/null || fail "repeated declaration refused"
[ "$(ritual_text)" = "Роль: писатель; РП-484; закрытый контур" ] || fail "repeated declaration for the same WP must keep the Ritual"
[ "$(jq -r '.ritual.agreed_at' "$REC")" = "$AGREED" ] || fail "kept Ritual must keep its original agreement time"

bash "$SCRIPT" WP-485 >/dev/null || fail "declaration for another WP refused"
[ "$(ritual_text)" = none ] || fail "another WP must not inherit the Ritual"

bash "$SCRIPT" WP-485 --ritual "a
b" >/dev/null || fail "multi-line Ritual refused"
[ "$(ritual_text)" = "a b" ] || fail "Ritual must be stored as one line"

bash "$SCRIPT" outside-wp >/dev/null || fail "outside-wp refused"
[ "$(ritual_text)" = none ] || fail "outside-wp must not keep a WP Ritual"

bash "$SCRIPT" outside-wp --ritual "x" >/dev/null 2>&1 && fail "--ritual with outside-wp must be refused"
bash "$SCRIPT" WP-484 --ritual "" >/dev/null 2>&1 && fail "empty --ritual must be refused"
bash "$SCRIPT" WP-484 --ritual "   " >/dev/null 2>&1 && fail "blank --ritual must be refused"
bash "$SCRIPT" WP-484 --ritual >/dev/null 2>&1 && fail "--ritual without a value must be refused"
bash "$SCRIPT" WP-484 --bogus >/dev/null 2>&1 && fail "unknown argument must be refused"

printf 'not json' > "$REC"
bash "$SCRIPT" WP-484 >/dev/null || fail "a corrupt previous record must not break the declaration"
[ "$(ritual_text)" = none ] || fail "a corrupt previous record must not invent a Ritual"
bash "$SCRIPT" WP-484 --ritual 'кавычки "x" и $y' >/dev/null || fail "quotes in Ritual refused"
[ "$(ritual_text)" = 'кавычки "x" и $y' ] || fail "quotes/dollar in Ritual not stored verbatim"

LONG=$(python3 -c 'print("я" * 2500)')
bash "$SCRIPT" WP-484 --ritual "$LONG" >/dev/null || fail "long Ritual refused"
[ "$(jq -r '.ritual.text | length' "$REC")" = 2000 ] || fail "Ritual must be cut to 2000 characters, not bytes"
jq -e '.ritual.text | test("\uFFFD") | not' "$REC" >/dev/null || fail "cut must not split a character"

echo "OK: declare-intent.sh stores, keeps and drops the agreed Ritual as specified"
