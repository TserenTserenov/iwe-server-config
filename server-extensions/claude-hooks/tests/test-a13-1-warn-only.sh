#!/bin/bash
# test-a13-1-warn-only.sh — A13.1 (bare backtick tech token) is logged but must not
# block a reply that the pilot has already seen (RP-605/RP-388, 30.10.2026): every such
# block produced a second visible message. Blockable rules (A10) keep blocking.
#
# Run: bash .claude/hooks/tests/test-a13-1-warn-only.sh

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HOOKS/response-clarity-hook.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
check() {
  local name="$1" ok="$2" detail="$3"
  if [ "$ok" = "yes" ]; then PASS=$((PASS + 1)); echo "PASS $name"; else FAIL=$((FAIL + 1)); echo "FAIL $name: $detail"; fi
}

# $1 case id, $2 reply text -> hook output on stdout; log lands in $TMP/$1/home.
run_reply() {
  local id="$1" reply="$2"
  mkdir -p "$TMP/$id/home" "$TMP/$id/proj"
  REPLY_TEXT="$reply" python3 - "$TMP/$id/t.jsonl" <<'PY'
import json, os, sys
rows = [
    {"type": "user", "message": {"content": [{"type": "text", "text": "Проверь."}]}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": os.environ["REPLY_TEXT"]}]}},
]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
  printf '{"transcript_path":"%s","session_id":"%s"}' "$TMP/$id/t.jsonl" "$id" \
    | env HOME="$TMP/$id/home" CLAUDE_PROJECT_DIR="$TMP/$id/proj" STYLE_ENFORCE_BLOCK=1 bash "$HOOK" 2>/dev/null
}

# Only A13.1: a file name in backticks with no Russian gloss on its left.
A13_ONLY=$'Статус записан.\n\n`meta.yaml`\n\nДальше: вы — скажите «закрывай», и я закрою сессию.'
out=$(run_reply a13 "$A13_ONLY")
log="$TMP/a13/home/.claude/logs/style-violations.log"
check "A13.1 is still written to the log" \
  "$([ -f "$log" ] && grep -qE '\| A13\.1 \|' "$log" && echo yes || echo no)" "$(cat "$log" 2>/dev/null)"
check "A13.1 alone does not block" \
  "$([ "$(printf '%s' "$out" | jq -r '.decision // empty')" != block ] && echo yes || echo no)" "$out"

# A10 together with A13.1: still blocks, and the reason no longer names A13.1.
A10_AND_A13=$'Итог.\n\nPASS\n\n`meta.yaml`\n\nДальше: жду ответа.'
out=$(run_reply a10 "$A10_AND_A13")
reason=$(printf '%s' "$out" | jq -r '.reason // empty')
check "A10 still blocks" \
  "$([ "$(printf '%s' "$out" | jq -r '.decision // empty')" = block ] && echo yes || echo no)" "$out"
check "block reason names A10 and not A13.1" \
  "$([[ "$reason" == *"правила: A10"* && "$reason" != *"правила: A10 A13.1"* && "$reason" != *"правила: A13.1"* ]] && echo yes || echo no)" "$reason"

echo "---"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
