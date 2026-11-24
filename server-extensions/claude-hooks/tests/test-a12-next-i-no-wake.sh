#!/bin/bash
# test-a12-next-i-no-wake.sh -- A12_NEXT_I_NO_WAKE (РП-605 Ф7, 24.11.2026): a "Дальше: я ..." line
# with no unfinished background task and no wake-up alarm in the transcript is logged, never blocks.
#
# Cases: empty promise -> signal; pending task -> quiet; finished task -> signal; resumed task
# (started, finished, started again) -> quiet; alarm -> quiet; "вы:" line -> quiet; peer context ->
# quiet; the hook logs the signal and does not block even with STYLE_ENFORCE_BLOCK=1.
#
# Run: bash .claude/hooks/tests/test-a12-next-i-no-wake.sh

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$HOOKS/response-clarity-hook.sh"
DETECTOR="$HOOKS/a12-next-block.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
check() {
  local name="$1" ok="$2" detail="$3"
  if [ "$ok" = "yes" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL $name: $detail"; fi
}

make_transcript() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
def U(text):
    return {"type": "user", "message": {"content": [{"type": "text", "text": text}]}}
def A(text):
    return {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}
def RES(text):
    return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": text}]}}
def NOTE(task_id):
    return {"type": "user", "message": {"content": "<task-notification><task-id>%s</task-id><status>completed</status></task-notification>" % task_id}}
def WAKE():
    return {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t2", "name": "ScheduleWakeup", "input": {"delaySeconds": 600}}]}}
EMPTY = "Итог.\n\nДальше: я: прогнать независимую проверку и показать вам итог."
EVENT = "Итог.\n\nДальше: я, после уведомления помощника: свожу его выводы."
YOU = "Итог.\n\nДальше: вы: сказать «запускай проверку»."
rows = eval(expr)
with open(path, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}

signal() { # $1 id, $2 rows expression, rest: env; prints the 5th detector line
  local id="$1" expr="$2"; shift 2
  make_transcript "$TMP/$id.jsonl" "$expr"
  env STYLE_CONTEXT=direct "$@" python3 "$DETECTOR" "$TMP/$id.jsonl" 2>"$TMP/err" | sed -n '5p'
}
is_set() { [ -n "$1" ] && echo yes || echo no; }
is_empty() { [ -z "$1" ] && echo yes || echo no; }

got=$(signal empty '[U("Проверь."), A(EMPTY)]')
check "empty promise -> signal" "$(is_set "$got")" "[$got]"

got=$(signal pending '[U("Проверь."), RES("Async agent launched. agentId: aaa1111222233 (internal)"), A(EVENT)]')
check "pending task -> quiet" "$(is_empty "$got")" "[$got]"

got=$(signal finished '[U("Проверь."), RES("agentId: aaa1111222233"), NOTE("aaa1111222233"), A(EMPTY)]')
check "finished task -> signal" "$(is_set "$got")" "[$got]"

got=$(signal resumed '[U("Проверь."), RES("agentId: aaa1111222233"), NOTE("aaa1111222233"), U("Ещё раз."), RES("{\"resumedAgentId\":\"aaa1111222233\"}"), A(EVENT)]')
check "resumed task -> quiet" "$(is_empty "$got")" "[$got]"

got=$(signal alarm '[U("Проверь."), WAKE(), A(EMPTY)]')
check "alarm set -> quiet" "$(is_empty "$got")" "[$got]"

got=$(signal you '[U("Проверь."), A(YOU)]')
check "line for the pilot -> quiet" "$(is_empty "$got")" "[$got]"

got=$(signal peer '[U("Проверь."), A(EMPTY)]' STYLE_CONTEXT=peer)
check "peer context -> quiet" "$(is_empty "$got")" "[$got]"
check "detector writes nothing to stderr" "$([ ! -s "$TMP/err" ] && echo yes || echo no)" "$(cat "$TMP/err")"

# The hook logs the signal and does not block, even in blocking mode.
mkdir -p "$TMP/h/home" "$TMP/h/proj"
make_transcript "$TMP/h/t.jsonl" '[U("Проверь."), A(EMPTY)]'
out=$(printf '{"transcript_path":"%s","session_id":"h"}' "$TMP/h/t.jsonl" \
  | env HOME="$TMP/h/home" CLAUDE_PROJECT_DIR="$TMP/h/proj" STYLE_ENFORCE_BLOCK=1 bash "$HOOK" 2>/dev/null)
check "hook does not block" "$([[ "$out" != *block* ]] && echo yes || echo no)" "$out"
check "hook logs A12_NEXT_I_NO_WAKE" \
  "$(grep -q 'A12_NEXT_I_NO_WAKE' "$TMP/h/home/.claude/logs/style-violations.log" 2>/dev/null && echo yes || echo no)" "no log line"

echo "a12-next-i-no-wake: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
