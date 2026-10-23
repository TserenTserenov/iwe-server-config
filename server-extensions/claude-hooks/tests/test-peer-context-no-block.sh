#!/bin/bash
# test-peer-context-no-block.sh — the style guard must not ask a program-read reply
# to be rewritten (WP-388 Ф24). Peer mode is declared by the caller through
# IWE_STYLE_CONTEXT (or STYLE_CONTEXT); the same text must still block in direct mode.
#
# Run: bash .claude/hooks/tests/test-peer-context-no-block.sh

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HOOKS/response-clarity-hook.sh"
WRAPPER="$HOOKS/style-check-text.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
# A reply that trips A10 (a bare English status marker), a blockable rule.
REPLY=$'Итог проверки.\n\nPASS\n\nДальше: жду ответа.'
printf '%s' "$REPLY" > "$TMP/reply.txt"

check() {
  local name="$1" ok="$2" detail="$3"
  if [ "$ok" = "yes" ]; then PASS=$((PASS + 1)); echo "PASS $name"; else FAIL=$((FAIL + 1)); echo "FAIL $name: $detail"; fi
}

transcript="$TMP/t.jsonl"
REPLY_TEXT="$REPLY" python3 - "$transcript" <<'PY'
import json, os, sys
rows = [
    {"type": "user", "message": {"content": [{"type": "text", "text": "Проверь."}]}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": os.environ["REPLY_TEXT"]}]}},
]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY

run_core() { # $1 case id, rest: env assignments
  local id="$1"; shift
  mkdir -p "$TMP/$id/home" "$TMP/$id/proj"
  printf '{"transcript_path":"%s","session_id":"%s"}' "$transcript" "$id" \
    | env HOME="$TMP/$id/home" CLAUDE_PROJECT_DIR="$TMP/$id/proj" STYLE_ENFORCE_BLOCK=1 "$@" bash "$HOOK" 2>/dev/null
}

out=$(run_core direct)
check "core direct blocks" "$([ "$(printf '%s' "$out" | jq -r '.decision // empty')" = block ] && echo yes || echo no)" "$out"

reason=$(printf '%s' "$out" | jq -r '.reason // empty')
check "block reason asks for no visible correction line" \
  "$([[ "$reason" != *STYLE_FIX* && "$reason" == *"никаких пометок"* ]] && echo yes || echo no)" "$reason"
check "block reason still limits the repeat to the final part" \
  "$([[ "$reason" == *"ТОЛЬКО её"* && "$reason" == *"остальной текст не повторяй"* ]] && echo yes || echo no)" "$reason"

out=$(run_core peer-env IWE_STYLE_CONTEXT=peer)
check "core peer via IWE_STYLE_CONTEXT does not block" "$([[ "$out" != *block* ]] && echo yes || echo no)" "$out"

out=$(run_core peer-style STYLE_CONTEXT=peer)
check "core peer via STYLE_CONTEXT does not block" "$([[ "$out" != *block* ]] && echo yes || echo no)" "$out"

log="$TMP/peer-env/home/.claude/logs/style-violations.log"
check "core peer still logs the violation under a -peer agent" \
  "$([ -f "$log" ] && grep -qE '\| claude-code-peer \| A10 \|' "$log" && echo yes || echo no)" "$(cat "$log" 2>/dev/null)"

dlog="$TMP/direct/home/.claude/logs/style-violations.log"
check "core direct logs under the plain agent" \
  "$([ -f "$dlog" ] && grep -qE '\| claude-code \| A10 \|' "$dlog" && echo yes || echo no)" "$(cat "$dlog" 2>/dev/null)"

# Wrapper in return mode: the agent's own end-of-reply hook.
mkdir -p "$TMP/w-direct/home" "$TMP/w-peer/home"
out=$(HOME="$TMP/w-direct/home" STYLE_WRAPPER_EMIT=1 bash "$WRAPPER" kimi "$TMP/reply.txt" 2>/dev/null)
check "wrapper return mode blocks in direct mode" "$([ "$(printf '%s' "$out" | jq -r '.decision // empty')" = block ] && echo yes || echo no)" "$out"

out=$(HOME="$TMP/w-peer/home" STYLE_WRAPPER_EMIT=1 IWE_STYLE_CONTEXT=peer bash "$WRAPPER" kimi "$TMP/reply.txt" 2>/dev/null)
check "wrapper return mode is silent in peer mode" "$([ "$out" = "{}" ] && echo yes || echo no)" "$out"
check "wrapper return mode writes no log row in peer mode" \
  "$([ ! -s "$TMP/w-peer/home/.claude/logs/style-violations.log" ] && echo yes || echo no)" "$(cat "$TMP/w-peer/home/.claude/logs/style-violations.log" 2>/dev/null)"

# Adapter's own log-only call (no return mode) still records, under kimi-peer.
HOME="$TMP/w-peer/home" bash "$WRAPPER" kimi "$TMP/reply.txt" peer >/dev/null 2>&1
check "adapter log-only call records under kimi-peer" \
  "$(grep -qE '\| kimi-peer \| A10 \|' "$TMP/w-peer/home/.claude/logs/style-violations.log" 2>/dev/null && echo yes || echo no)" \
  "$(cat "$TMP/w-peer/home/.claude/logs/style-violations.log" 2>/dev/null)"

echo "---"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
