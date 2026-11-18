#!/bin/bash
# test-protocol-artifact-validate-i18n-fail-closed.sh — WP-484 F313.
#
# Release 0.42 (#197) made protocol-artifact-validate.sh read the DayPlan
# section headings from the language catalogs (../lib/i18n.sh). Its stated
# contract: "A catalog failure is reported as an error, never as 'all
# present'". This test pins that contract for the root hook.
#
# It replaces test-protocol-artifact-validate-mandatory-fail-closed.sh, a
# template-only test that asserted a "mandatory" check the root hook removed
# on purpose in 28e7eff (WP-7 F107, 05.09). That stale test failed on every
# run and held the hook back from server delivery from 17.11.
#
# The hook is copied into an isolated fixture so its sibling ../lib/ can be
# genuinely absent (in the real repo it always exists, which would mask it).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$HOOK_DIR/../lib"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -f "$REAL_LIB/i18n.sh" ] || { echo "NOT VERIFIED: $REAL_LIB/i18n.sh missing"; exit 77; }

# --- Fixture: isolated workspace + governance repo with a staged DayPlan ---
WS="$TMP/ws"
GOV="$WS/DS-strategy"
mkdir -p "$GOV/current"
git -C "$GOV" init -q
git -C "$GOV" config user.email test@test
git -C "$GOV" config user.name test
cat > "$GOV/current/DayPlan 2026-09-10.md" <<'EOF'
# DayPlan 2026-09-10
## План на сегодня
| Время | РП |
|-------|----|
| 10:00 | WP-7 |
## Календарь
нет встреч
## IWE за ночь
нет находок
## Разбор заметок
нет заметок
## Итоги вчера
готово
EOF
git -C "$GOV" add "current/DayPlan 2026-09-10.md"

# The commit names its repository with git -C and cwd is that repository, so
# the hook's repo-scope resolves it regardless of how the command is spelled.
jq -n --arg cwd "$GOV" --arg cmd "git -C \"$GOV\" commit -m x" \
  '{session_id:"t", cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$cmd}}' \
  > "$TMP/envelope.json"

run_hook() { # <fixture-hooks-dir>
  env -u IWE_SCRIPTS IWE_WORKSPACE="$WS" IWE_ROOT="$WS" IWE_GOVERNANCE_REPO="DS-strategy" \
    bash "$1/protocol-artifact-validate.sh" < "$TMP/envelope.json" 2>/dev/null
}

# --- 1. Catalogs absent: a hook copy without the sibling ../lib/ ---
NO_LIB="$TMP/no-lib/.claude/hooks"
mkdir -p "$NO_LIB"
cp "$HOOK_DIR/protocol-artifact-validate.sh" "$NO_LIB/"
OUT=$(run_hook "$NO_LIB")
if printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "catalogs absent -> commit blocked (not silently passed)"
else
  bad "catalogs absent -> commit blocked (got: $OUT)"
fi
if printf '%s' "$OUT" | jq -e '.reason | test("i18n")' >/dev/null 2>&1; then
  ok "block reason names the catalog failure"
else
  bad "block reason names the catalog failure (got: $OUT)"
fi

# --- 2. Control: the same hook with the real ../lib/ next to it ---
WITH_LIB="$TMP/with-lib/.claude/hooks"
mkdir -p "$WITH_LIB"
cp "$HOOK_DIR/protocol-artifact-validate.sh" "$WITH_LIB/"
cp -R "$REAL_LIB" "$TMP/with-lib/.claude/lib"
OUT2=$(run_hook "$WITH_LIB")
if printf '%s' "$OUT2" | jq -e '(.reason // "") | test("i18n") | not' >/dev/null 2>&1; then
  ok "catalogs present -> no catalog error (other format findings may still block)"
else
  bad "catalogs present -> no catalog error (got: $OUT2)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
