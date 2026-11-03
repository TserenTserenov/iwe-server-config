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
  local id="$1" answer="$2" prompt="${3:-$LONG_PROMPT}"
  mkdir -p "$TMP/$id/home" "$TMP/$id/proj"
  ANSWER="$answer" PROMPT="$prompt" python3 - "$TMP/$id/t.jsonl" <<'PY'
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
run_hook_raw() {
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

# Same, with the every-turn A0 line (РП-388 Ф39) removed: the hint cases check the hints only.
A0_MARK='Главное правило стиля (A0'
run_hook() {
  run_hook_raw "$@" | grep -vF "$A0_MARK" | sed '/./,$!d'
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
  check "no hint for prompt «${prompt}»" "$([ -z "$out" ] && echo yes || echo no)" "$out"
done

# Current prompt not yet in the transcript: the last answer is still the one checked.
make_transcript noprompt "$WITH_SYMBOLS"
sed '$d' "$TMP/noprompt/t.jsonl" > "$TMP/noprompt/t.tmp" && mv "$TMP/noprompt/t.tmp" "$TMP/noprompt/t.jsonl"  # portable: BSD sed -i needs a suffix
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


# --- Place hint (РП-605 Ф6, 02.11): "Дальше:" names this very chat as the place ---
PLACE_BAD=$'Готово, запрос слит.\n\nДальше: вы, в этом чате: сказать «закрывай».'
PLACE_OTHER=$'Готово.\n\nДальше: вы, в новой беседе на РП-605: сказать «сверка».'
make_transcript place "$PLACE_BAD"
out=$(run_hook place "$LONG_PROMPT")
check "place hint after a line naming this chat" \
  "$(printf '%s' "$out" | grep -q 'для этого же чата' && echo yes || echo no)" "$out"
make_transcript placeshort "$PLACE_BAD" "да"
out=$(run_hook placeshort "да")
check "place hint is not skipped for a short prompt" \
  "$(printf '%s' "$out" | grep -q 'для этого же чата' && echo yes || echo no)" "$out"
check "place hint does not mention A13.1 names when there are none" \
  "$(printf '%s' "$out" | grep -q 'правило A13.1' && echo no || echo yes)" "$out"
make_transcript placeok "$PLACE_OTHER" "да"
out=$(run_hook placeok "да")
check "no place hint when another place is named" "$([ -z "$out" ] && echo yes || echo no)" "$out"
make_transcript placeoff "$PLACE_BAD" "да"
out=$(run_hook placeoff "да" "IWE_STYLE_NEXT_TURN_HINT=0")
check "off switch silences the place hint" "$([ -z "$out" ] && echo yes || echo no)" "$out"
PLACE_AND_SYM=$'Поправил `create_host_adapter()`.\n\nДальше: вы, здесь: проверить.'
make_transcript placesym "$PLACE_AND_SYM"
out=$(run_hook placesym "$LONG_PROMPT")
check "both hints go out together" \
  "$(printf '%s' "$out" | grep -q 'create_host_adapter()' && printf '%s' "$out" | grep -q 'для этого же чата' && echo yes || echo no)" "$out"

# --- A missing or broken a12 detector must not take the A13.1 hint down ---
# Run a copy of the hooks directory with a12-next-block.py removed / syntactically broken.
HOOK_ORIG="$HOOK"
for mode in missing broken; do
  cp -R "$HOOKS" "$TMP/hooks-$mode"
  if [ "$mode" = "missing" ]; then rm -f "$TMP/hooks-$mode/a12-next-block.py"; else echo 'def (' > "$TMP/hooks-$mode/a12-next-block.py"; fi
  HOOK="$TMP/hooks-$mode/inject-communication-style.sh"
  make_transcript "d$mode" "$PLACE_AND_SYM"
  out=$(run_hook "d$mode" "$LONG_PROMPT")
  check "A13.1 hint survives a $mode a12 detector" \
    "$(printf '%s' "$out" | grep -q 'create_host_adapter()' && echo yes || echo no)" "$out"
  check "no place hint when the a12 detector is $mode" \
    "$(printf '%s' "$out" | grep -q 'для этого же чата' && echo no || echo yes)" "$out"
done
HOOK="$HOOK_ORIG"


# --- Main rule A0 on every turn (РП-388 Ф39, 03.11) ---
make_transcript a0quiet "$CLEAN"
out=$(run_hook_raw a0quiet "да")
check "A0 line goes out on a turn without hints or reinjection" \
  "$(printf '%s' "$out" | grep -qF "$A0_MARK" && echo yes || echo no)" "$out"
make_transcript a0full "$CLEAN"
out=$(run_hook_raw a0full "$LONG_PROMPT" "" no)
check "A0 line goes out together with a reinjected style fragment" \
  "$(printf '%s' "$out" | grep -qF "$A0_MARK" && printf '%s' "$out" | grep -q 'Разговорный стиль IWE' && echo yes || echo no)" "$out"
make_transcript a0hintoff "$WITH_SYMBOLS"
out=$(run_hook_raw a0hintoff "$LONG_PROMPT" "IWE_STYLE_NEXT_TURN_HINT=0")
check "hint off switch keeps the A0 line" \
  "$(printf '%s' "$out" | grep -qF "$A0_MARK" && echo yes || echo no)" "$out"
make_transcript a0off "$CLEAN"
out=$(run_hook_raw a0off "да" "IWE_STYLE_A0_EVERY_TURN=0")
check "A0 off switch silences the A0 line" "$([ -z "$out" ] && echo yes || echo no)" "$out"
# No style source at all (empty project, hook copy without its snapshot): A0 still goes out.
cp -R "$HOOKS" "$TMP/hooks-nosrc"
mkdir -p "$TMP/styles-moved" && HOOK_SAVE="$HOOK" && HOOK="$TMP/hooks-nosrc/inject-communication-style.sh"
make_transcript a0nosrc "$CLEAN"
out=$(run_hook_raw a0nosrc "$LONG_PROMPT" "" no)
check "A0 line goes out when no style source is found" \
  "$(printf '%s' "$out" | grep -qF "$A0_MARK" && ! printf '%s' "$out" | grep -q 'Разговорный стиль IWE' && echo yes || echo no)" "$out"
HOOK="$HOOK_SAVE"

# --- Inner IWE words hint (РП-388 Ф39, pack rule 9) ---
JARGON=$'Исправление проверено в изолированной копии корня. В боевом IWE маршрутизатор пока не работает.\n\nДальше: вы: сказать «заливай».'
make_transcript jarg "$JARGON" "да"
out=$(run_hook jarg "да")
check "jargon hint names inner IWE words, even after a short prompt" \
  "$(printf '%s' "$out" | grep -q 'внутренней кухни IWE: корня, боевом, изолированной копии, маршрутизатор' && echo yes || echo no)" "$out"
check "jargon hint does not use the A13.1 wording" \
  "$(printf '%s' "$out" | grep -q 'правило A13.1' && echo no || echo yes)" "$out"
check "jargon hint is logged in its own file" \
  "$(grep -qE '\| jarg \| 4 \| ' "$TMP/jarg/home/.claude/logs/style-jargon-hints.log" 2>/dev/null && [ ! -s "$TMP/jarg/home/.claude/logs/style-next-turn-hints.log" ] && echo yes || echo no)" \
  "$(cat "$TMP/jarg/home/.claude/logs/"*.log 2>/dev/null)"
make_transcript jargown "$JARGON" "Почему в боевом IWE маршрутизатор до сих пор не работает, что с корнем?"
out=$(run_hook jargown "Почему в боевом IWE маршрутизатор до сих пор не работает, что с корнем?")
check "words the pilot used himself are not reported" \
  "$(printf '%s' "$out" | grep -q 'изолированной копии' && ! printf '%s' "$out" | grep -q 'боевом' && echo yes || echo no)" "$out"

echo "---"
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
