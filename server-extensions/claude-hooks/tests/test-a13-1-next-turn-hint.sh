#!/bin/bash
# test-a13-1-next-turn-hint.sh — next-turn hint for A13.1 (РП-388 Ф36 step 5).
# inject-communication-style.sh must add one hidden line naming the unexplained
# code names of the previous answer, skip short/question/ack prompts, honour the
# off switch, and keep the hint when the style fragment is reinjected too.
#
# Run: bash .claude/hooks/tests/test-a13-1-next-turn-hint.sh

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HOOKS/inject-communication-style.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
check() {
  local name="$1" ok="$2" detail="$3"
  if [ "$ok" = "yes" ]; then PASS=$((PASS + 1)); echo "PASS $name"; else FAIL=$((FAIL + 1)); echo "FAIL $name: $detail"; fi
}

LONG_PROMPT="Хорошо, теперь проверь, как это работает на цехе, и расскажи итог."
WITH_SYMBOLS=$'Поправил разбор.\n\n- Страж падал в `create_host_adapter()` на `TypeError`.\n- Коммит a69734e.\n\nДальше: вы: проверить.'
CLEAN=$'Поправил разбор переписки: страж больше не падает на пустом ответе.\n\nДальше: вы: проверить.'

# $1 case id, $2 previous answer -> transcript at $TMP/$1/t.jsonl (prompt already appended,
# as Claude Code does before UserPromptSubmit).
make_transcript() {
  local id="$1" answer="$2"
  mkdir -p "$TMP/$id/home" "$TMP/$id/proj"
  ANSWER="$answer" PROMPT="$LONG_PROMPT" python3 - "$TMP/$id/t.jsonl" <<'PY'
import json, os, sys
rows = [
    {"type": "user", "message": {"content": [{"type": "text", "text": "Почини страж."}]}},
    {"type": "assistant", "message": {"model": "m", "content": [{"type": "text", "text": os.environ["ANSWER"]}]}},
    {"type": "user", "message": {"content": [{"type": "text", "text": os.environ["PROMPT"]}]}},
]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}

# $1 case id, $2 prompt, $3 extra env (VAR=value or empty) -> hook additionalContext on stdout.
# The style state file is pre-seeded so the fragment is not reinjected unless the case asks.
run_hook() {
  local id="$1" prompt="$2" extra="${3:-}" seed="${4:-yes}"
  if [ "$seed" = "yes" ]; then
    mkdir -p "$TMP/$id/proj/.claude/state"
    echo "1 1 999999999" > "$TMP/$id/proj/.claude/state/comm-style-injected-$id"
  fi
  jq -n --arg t "$TMP/$id/t.jsonl" --arg s "$id" --arg p "$prompt" \
    '{transcript_path: $t, session_id: $s, prompt: $p}' \
    | env HOME="$TMP/$id/home" CLAUDE_PROJECT_DIR="$TMP/$id/proj" $extra bash "$HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty'
}

make_transcript sym "$WITH_SYMBOLS"
out=$(run_hook sym "$LONG_PROMPT")
check "hint names the unexplained code names" \
  "$(printf '%s' "$out" | grep -q 'create_host_adapter()' && printf '%s' "$out" | grep -q 'TypeError' && echo yes || echo no)" "$out"
check "hint does not count the commit address" \
  "$(printf '%s' "$out" | grep -q 'a69734e' && echo no || echo yes)" "$out"
check "hint tells not to touch the previous answer" \
  "$(printf '%s' "$out" | grep -q 'Прошлый ответ не исправлять и не упоминать' && echo yes || echo no)" "$out"
log="$TMP/sym/home/.claude/logs/style-next-turn-hints.log"
check "hint is logged with session and count" \
  "$(grep -qE '\| sym \| 2 \| ' "$log" 2>/dev/null && echo yes || echo no)" "$(cat "$log" 2>/dev/null)"

make_transcript clean "$CLEAN"
out=$(run_hook clean "$LONG_PROMPT")
check "no hint after an answer without code names" "$([ -z "$out" ] && echo yes || echo no)" "$out"

make_transcript ack "$WITH_SYMBOLS"
for prompt in "да" "Заливай!" "А что с Маком, доехало ли туда обновление стража сегодня?" "Хорошо, проверь"; do
  out=$(run_hook ack "$prompt")
  check "no hint for prompt «$prompt»" "$([ -z "$out" ] && echo yes || echo no)" "$out"
done

# Current prompt not yet in the transcript: the last answer is still the one checked.
make_transcript noprompt "$WITH_SYMBOLS"
sed -i '$d' "$TMP/noprompt/t.jsonl"
out=$(run_hook noprompt "$LONG_PROMPT")
check "hint works before the prompt is written to the transcript" \
  "$(printf '%s' "$out" | grep -q 'TypeError' && echo yes || echo no)" "$out"

# Previous turn had no text (tool calls only): an older answer must not be used.
make_transcript toolonly "$WITH_SYMBOLS"
python3 - "$TMP/toolonly/t.jsonl" "$LONG_PROMPT" <<'PY2'
import json, sys
path, prompt = sys.argv[1], sys.argv[2]
rows = [
    {"type": "assistant", "message": {"model": "m", "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]}},
    {"type": "user", "message": {"content": [{"type": "text", "text": prompt}]}},
]
with open(path, "a", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY2
out=$(run_hook toolonly "$LONG_PROMPT")
check "no hint from an answer two turns back" "$([ -z "$out" ] && echo yes || echo no)" "$out"

make_transcript off "$WITH_SYMBOLS"
out=$(run_hook off "$LONG_PROMPT" "IWE_STYLE_NEXT_TURN_HINT=0")
check "off switch silences the hint" "$([ -z "$out" ] && echo yes || echo no)" "$out"

# First turn of a session: the style fragment (the hook's own s0-core.md snapshot) is
# injected; the hint must be appended to it.
make_transcript both "$WITH_SYMBOLS"
out=$(run_hook both "$LONG_PROMPT" "" no)
check "hint rides along with a reinjected style fragment" \
  "$(printf '%s' "$out" | grep -q 'Разговорный стиль IWE' && printf '%s' "$out" | grep -q 'create_host_adapter()' && echo yes || echo no)" "$out"

echo "---"
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
