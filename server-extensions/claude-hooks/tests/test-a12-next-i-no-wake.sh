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
_n = [0]
def CALL(tool, text, status=None, inp=None):
    """An assistant tool call plus the user record with its result (two rows)."""
    _n[0] += 1
    tid = "tu%d" % _n[0]
    use = {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": tid, "name": tool, "input": inp or {}}]}}
    res = {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": tid, "content": text}]}}
    if status:
        res["toolUseResult"] = {"status": status}
    return [use, res]
def NOTE(task_id, status="<status>completed</status>"):
    return {"type": "user", "message": {"content": "<task-notification><task-id>%s</task-id><output-file>/tmp/x</output-file>%s</task-notification>" % (task_id, status)}}
def TEXTROW(text):
    return {"type": "user", "message": {"content": text}}
def WAKE(tool="ScheduleWakeup", inp=None):
    return CALL(tool, "ok", inp=inp or {"delaySeconds": 600})
NUM2 = "Итог.\n\nДальше: 1) вы: посмотреть итог; 2) я: сверю журнал после ответа."
BOLD = "Итог.\n\nДальше: **я**: запущу проверку и покажу итог."
NUM = "Итог.\n\nДальше: 1) я: запускаю проверку; 2) вы: посмотреть итог."
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
  make_transcript "$TMP/$id.jsonl" "$expr" || { FAIL=$((FAIL + 1)); echo "FAIL $id: bad transcript expression" >&2; return 0; }
  env STYLE_CONTEXT=direct "$@" python3 "$DETECTOR" "$TMP/$id.jsonl" 2>"$TMP/err" | sed -n '5p'
}
is_set() { [ -n "$1" ] && echo yes || echo no; }
is_empty() { [ -z "$1" ] && echo yes || echo no; }

got=$(signal empty '[U("Проверь."), A(EMPTY)]')
check "empty promise -> signal" "$(is_set "$got")" "[$got]"

got=$(signal pending '[U("Проверь."), *CALL("Agent", "Async agent launched. agentId: aaa1111222233 (internal)", "async_launched"), A(EVENT)]')
check "pending task -> quiet" "$(is_empty "$got")" "[$got]"

got=$(signal finished '[U("Проверь."), *CALL("Agent", "agentId: aaa1111222233", "async_launched"), NOTE("aaa1111222233"), A(EMPTY)]')
check "finished task -> signal" "$(is_set "$got")" "[$got]"

got=$(signal resumed '[U("Проверь."), *CALL("Agent", "agentId: aaa1111222233", "async_launched"), NOTE("aaa1111222233"), U("Ещё раз."), *CALL("SendMessage", "resumedAgentId: aaa1111222233"), A(EVENT)]')
check "resumed task -> quiet" "$(is_empty "$got")" "[$got]"

got=$(signal alarm '[U("Проверь."), *WAKE(), A(EMPTY)]')
check "alarm set -> quiet" "$(is_empty "$got")" "[$got]"

got=$(signal you '[U("Проверь."), A(YOU)]')
check "line for the pilot -> quiet" "$(is_empty "$got")" "[$got]"

got=$(signal peer '[U("Проверь."), A(EMPTY)]' STYLE_CONTEXT=peer)
check "peer context -> quiet" "$(is_empty "$got")" "[$got]"
check "detector writes nothing to stderr" "$([ ! -s "$TMP/err" ] && echo yes || echo no)" "$(cat "$TMP/err")"

# Defects found by the independent review (24.11.2026).
got=$(signal monitor '[U("Проверь."), *CALL("Monitor", "Monitor started (task bbb1111222, timeout 300s)"), NOTE("bbb1111222", ""), A(EVENT)]')
check "monitor with an event (no final status) stays pending -> quiet" "$(is_empty "$got")" "[$got]"

got=$(signal monitor_end '[U("Проверь."), *CALL("Monitor", "Monitor started (task bbb1111222, timeout 300s)"), NOTE("bbb1111222", "<status>killed</status>"), A(EMPTY)]')
check "monitor that ended -> signal" "$(is_set "$got")" "[$got]"

got=$(signal cron_old '[U("Проверь."), *WAKE("CronCreate", {"cron": "*/5 * * * *", "prompt": "x"}), U("Ещё."), A("Итог.\n\nДальше: я: сверю журнал после следующего срабатывания.")]')
check "repeating cron from an earlier turn -> quiet" "$(is_empty "$got")" "[$got]"

got=$(signal cron_deleted '[U("Проверь."), *WAKE("CronCreate", {"cron": "*/5 * * * *", "prompt": "x"}), *CALL("CronDelete", "ok"), U("Ещё."), A(EMPTY)]')
check "deleted cron -> signal" "$(is_set "$got")" "[$got]"

got=$(signal foreground '[U("Проверь."), *CALL("Agent", "agentId: ccc1111222233 (use SendMessage to continue this agent)", "completed"), A(EMPTY)]')
check "helper finished in the foreground -> signal" "$(is_set "$got")" "[$got]"

got=$(signal phantom '[U("Проверь."), *CALL("Read", "assert agentId: ddd1111222233 in the test file"), A(EMPTY)]')
check "marker inside a file read -> signal" "$(is_set "$got")" "[$got]"

got=$(signal expired '[U("Проверь."), *CALL("Monitor", "Monitor started (task bbb1111222, timeout 300s)"), TEXTROW("<task-notification><task-id>bbb1111222</task-id><event>[Monitor expired after 30m with no events delivered]</event></task-notification>"), A(EMPTY)]')
check "expired monitor -> signal" "$(is_set "$got")" "[$got]"

got=$(signal multi '[U("Проверь."), *CALL("Bash", "Command running in background with ID: eee1111222"), *CALL("Bash", "Command running in background with ID: fff1111222"), TEXTROW("<task-notification><task-id>eee1111222</task-id> <task-id>fff1111222</task-id> <task-id>__orphan_summary__:shell</task-id> <status>stopped</status></task-notification>"), A(EMPTY)]')
check "one notification closes several tasks -> signal" "$(is_set "$got")" "[$got]"

got=$(signal taskstop '[U("Проверь."), *CALL("Bash", "Command running in background with ID: ggg1111222"), *CALL("TaskStop", "Successfully stopped task: ggg1111222 (sleep 900)"), A(EMPTY)]')
check "task stopped with TaskStop -> signal" "$(is_set "$got")" "[$got]"

got=$(signal bold '[U("Проверь."), A(BOLD)]')
check "bold line \"**я**:\" -> signal" "$(is_set "$got")" "[$got]"

got=$(signal num2 '[U("Проверь."), A(NUM2)]')
check "second numbered step \"2) я:\" -> signal" "$(is_set "$got")" "[$got]"

got=$(signal numbered '[U("Проверь."), A(NUM)]')
check "numbered line \"1) я:\" -> signal" "$(is_set "$got")" "[$got]"

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
