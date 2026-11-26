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
INTERIM = ("<status>completed</status><note>This agent stopped with background work of its own still running. "
           "It may resume on its own when that work completes or reports, and the same task-id notifies again "
           "if it does; the result below may be interim.</note>")
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

# РП-605 Ф9 (26.11.2026): the live false hit of 25.11 22:04 -- a helper reported "completed"
# but marked the result interim (it waits for its own background work) and then reported again.
got=$(signal interim '[U("Проверь."), *CALL("Agent", "agentId: aaa1111222233", "async_launched"), NOTE("aaa1111222233", INTERIM), A(EVENT)]')
check "interim completed notification stays pending -> quiet" "$(is_empty "$got")" "[$got]"

got=$(signal interim_end '[U("Проверь."), *CALL("Agent", "agentId: aaa1111222233", "async_launched"), NOTE("aaa1111222233", INTERIM), NOTE("aaa1111222233"), A(EMPTY)]')
check "interim, then the final notification -> signal" "$(is_set "$got")" "[$got]"

kind() { # $1 id, $2 rows expression; prints the 6th detector line
  make_transcript "$TMP/$1.jsonl" "$2" || return 0
  env STYLE_CONTEXT=direct python3 "$DETECTOR" "$TMP/$1.jsonl" 2>/dev/null | sed -n '6p'
}
check "free empty promise -> FREE" "$([ "$(kind k1 '[U("Проверь."), A(EMPTY)]')" = FREE ] && echo yes || echo no)" "kind"
COND1='Итог.\n\nДальше: я: сделать П11, если вы скажете «делай П11».'
COND2='Итог.\n\nДальше: я, в следующей сессии по РП-625: увожу сбои в сводку.'
COND3='Итог.\n\nДальше: я: начну по вашему слову.'
for n in 1 2 3; do
  eval "c=\$COND$n"
  check "conditional or next-session promise $n -> COND" \
    "$([ "$(kind "c$n" "[U(\"Проверь.\"), A(\"$c\")]")" = COND ] && echo yes || echo no)" "kind"
done
check "no signal -> empty kind" "$([ -z "$(kind k0 '[U("Проверь."), A(YOU)]')" ] && echo yes || echo no)" "kind"

# РП-605 Ф9: the numbered formula "1) вы, здесь:" names this chat (live case 26.11, session already closed).
PLACE='Сессия закрыта.\n\nДальше: 1) вы, здесь: сказать «заливай ветку хуков», тогда я запушу её; 2) вы, в новой беседе на РП-484: сказать первой фразой «поправь поле».'
got=$(make_transcript "$TMP/pl.jsonl" "[U(\"Закрывай.\"), A(\"$PLACE\")]"; env STYLE_CONTEXT=direct python3 "$DETECTOR" "$TMP/pl.jsonl" 2>/dev/null | sed -n '4p')
check "numbered \"1) вы, здесь:\" -> this-chat signal" "$(is_set "$got")" "[$got]"
PLACE_OK='Готово.\n\nДальше: 1) вы, в новой беседе на РП-484: сказать первой фразой «поправь поле».'
got=$(make_transcript "$TMP/pl2.jsonl" "[U(\"Закрывай.\"), A(\"$PLACE_OK\")]"; env STYLE_CONTEXT=direct python3 "$DETECTOR" "$TMP/pl2.jsonl" 2>/dev/null | sed -n '4p')
check "numbered line naming another place -> quiet" "$(is_empty "$got")" "[$got]"

run_hook() { # $1 id, $2 rows expression, rest: env; prints the hook's stdout, sets HOME under $TMP/$1
  local id="$1" expr="$2"; shift 2
  mkdir -p "$TMP/$id/home" "$TMP/$id/proj"
  make_transcript "$TMP/$id/t.jsonl" "$expr"
  printf '{"transcript_path":"%s","session_id":"%s"}' "$TMP/$id/t.jsonl" "$id" \
    | env HOME="$TMP/$id/home" CLAUDE_PROJECT_DIR="$TMP/$id/proj" "$@" bash "$HOOK" 2>/dev/null
}
logline() { grep -c "$2" "$TMP/$1/home/.claude/logs/style-violations.log" 2>/dev/null || true; }
remarks() { cat "$TMP/$1/proj/.claude/state/next-turn-remarks-$1" 2>/dev/null || true; }

# A free empty "я": the turn is returned once, and the journal gets one line per return.
out=$(run_hook hf '[U("Проверь."), A(EMPTY)]')
check "free empty promise -> block" "$([[ "$out" == *'"decision": "block"'* ]] && echo yes || echo no)" "$out"
check "block text asks to do the step" "$([[ "$out" == *"Выполни обещанный шаг"* ]] && echo yes || echo no)" "$out"
check "hook logs A12_NEXT_I_NO_WAKE" "$([ "$(logline hf A12_NEXT_I_NO_WAKE)" -ge 1 ] && echo yes || echo no)" "no log line"
check "hook logs A12_NO_WAKE_RETURN" "$([ "$(logline hf A12_NO_WAKE_RETURN)" -ge 1 ] && echo yes || echo no)" "no log line"

# The return happens at most once per turn: the second stop of the same turn passes.
out=$(printf '{"transcript_path":"%s","session_id":"hf","stop_hook_active":true}' "$TMP/hf/t.jsonl" \
  | env HOME="$TMP/hf/home" CLAUDE_PROJECT_DIR="$TMP/hf/proj" bash "$HOOK" 2>/dev/null)
check "stop_hook_active -> no second return" "$([[ "$out" != *block* ]] && echo yes || echo no)" "$out"

# A conditional promise: no block, a remark for the next turn instead.
out=$(run_hook hc '[U("Проверь."), A("Итог.\n\nДальше: я: сделать П11, если вы скажете «делай П11».")]')
check "conditional promise -> no block" "$([[ "$out" != *block* ]] && echo yes || echo no)" "$out"
check "conditional promise -> remark stored" "$([[ "$(remarks hc)" == *"шаг ждёт слова пилота"* ]] && echo yes || echo no)" "$(remarks hc)"

# The numbered "здесь" line: a remark about the place, no block.
out=$(run_hook hp "[U(\"Закрывай.\"), A(\"$PLACE\")]")
check "this-chat place -> no block" "$([[ "$out" != *block* ]] && echo yes || echo no)" "$out"
check "this-chat place -> remark stored" "$([[ "$(remarks hp)" == *"из неё ничего не публикуется"* ]] && echo yes || echo no)" "$(remarks hp)"

# Off switches: the flag turns the return off, the signal is still logged; peer never returns.
out=$(run_hook hoff '[U("Проверь."), A(EMPTY)]' A12_NO_WAKE_BLOCK=0)
check "flag A12_NO_WAKE_BLOCK=0 -> no block" "$([[ "$out" != *block* ]] && echo yes || echo no)" "$out"
check "flag off still logs the signal" "$([ "$(logline hoff A12_NEXT_I_NO_WAKE)" -ge 1 ] && echo yes || echo no)" "no log line"
out=$(run_hook hpeer '[U("Проверь."), A(EMPTY)]' STYLE_CONTEXT=peer)
check "peer context -> no block" "$([[ "$out" != *block* ]] && echo yes || echo no)" "$out"
out=$(run_hook hother '[U("Проверь."), A(EMPTY)]' STYLE_AGENT=kimi)
check "other agent -> no block" "$([[ "$out" != *block* ]] && echo yes || echo no)" "$out"

# An honest "я" (pending helper) is never returned.
out=$(run_hook hok '[U("Проверь."), *CALL("Agent", "agentId: aaa1111222233", "async_launched"), A(EVENT)]')
check "honest \"я\" -> no block" "$([[ "$out" != *block* ]] && echo yes || echo no)" "$out"

# Peer review 26.11 (Kimi, Codex): the return of the turn does not depend on the remarks switch;
# the conditional-word list is narrower ("словарь" is not the pilot's word) and wider (more real waits).
out=$(run_hook hdefer '[U("Проверь."), A(EMPTY)]' IWE_STYLE_DEFER_REMARK=0)
check "remarks off, return still on -> block" "$([[ "$out" == *'"decision": "block"'* ]] && echo yes || echo no)" "$out"
out=$(run_hook hdefer2 '[U("Проверь."), A("Итог.\n\nДальше: я: сделать П11, если вы скажете «делай П11».")]' IWE_STYLE_DEFER_REMARK=0)
check "remarks off, conditional -> no block, no remark" "$([[ "$out" != *block* && -z "$(remarks hdefer2)" ]] && echo yes || echo no)" "$out"

CW1='Итог.\n\nДальше: я: обновлю ваш словарь терминов.'
check "«ваш словарь» is not the pilot's word -> FREE" "$([ "$(kind w1 "[U(\"Проверь.\"), A(\"$CW1\")]")" = FREE ] && echo yes || echo no)" "kind"
for n in 1 2 3 4 5; do
  case $n in
    1) t='Дальше: я: запущу сверку, когда вы скажете «готово».' ;;
    2) t='Дальше: я: опубликую по вашей команде.' ;;
    3) t='Дальше: я: начну при вашем одобрении.' ;;
    4) t='Дальше: я: сделаю, если дадите добро.' ;;
    5) t='Дальше: я: продолжу в новой сессии по РП-605.' ;;
  esac
  # "если дадите добро" has no "вы": the list needs the plain verb form too
  check "real wait form $n -> COND" \
    "$([ "$(kind "cw$n" "[U(\"Проверь.\"), A(\"Итог.\n\n$t\")]")" = COND ] && echo yes || echo no)" "kind"
done

INTERIM_UP="<status>completed</status><note>THE RESULT BELOW MAY BE INTERIM; this agent stopped with Background Work Of Its Own Still Running.</note>"
got=$(make_transcript "$TMP/iu.jsonl" "[U(\"Проверь.\"), *CALL(\"Agent\", \"agentId: aaa1111222233\", \"async_launched\"), NOTE(\"aaa1111222233\", \"$INTERIM_UP\"), A(EVENT)]"; env STYLE_CONTEXT=direct python3 "$DETECTOR" "$TMP/iu.jsonl" 2>/dev/null | sed -n '5p')
check "interim marker in other letter case -> quiet" "$(is_empty "$got")" "[$got]"

# Review of the merged change by Fable (26.11): common waits of the pilot are COND, a "вы" step before
# the "я" step makes the line COND, the live empty promises stay FREE.
i=0
for t in 'я: залью после вашего решения.' 'я: жду вашего решения.' 'я: продолжу после вашего «да».' \
         'я: сделаю по вашему сигналу.' 'я: продолжу, как скажете.' 'я: сделаю, если вы не против.' \
         'я: сделаю, если хотите.' 'я: продолжу, когда ответите.' 'я: жду ответа Гермеса.' \
         '1) вы: сказать «да»; 2) я: залью.'; do
  i=$((i + 1))
  check "wait form $i -> COND" \
    "$([ "$(kind "wf$i" "[U(\"Проверь.\"), A(\"Итог.\n\nДальше: $t\")]")" = COND ] && echo yes || echo no)" "$t"
done
FREE1='я: подготовлю заготовку малого РП для Ф8 и правки команды. Они касаются кода у РП-626, поэтому слить запрос сможете только вы.'
FREE2='я прошу отдельного проверяющего сверить правки, это шаг без вашего решения.'
FREE3='я: вернусь завтра утром.'
j=0
for t in "$FREE1" "$FREE2" "$FREE3"; do
  j=$((j + 1))
  check "live empty promise $j stays FREE" \
    "$([ "$(kind "fr$j" "[U(\"Проверь.\"), A(\"Итог.\n\nДальше: $t\")]")" = FREE ] && echo yes || echo no)" "$t"
done
check "\"вы, здесь:\" after a full stop is found" \
  "$(make_transcript "$TMP/ps.jsonl" '[U("Закрывай."), A("Итог.\n\nДальше: выполнено. 2) вы, здесь: сказать «заливай».")]'; [ -n "$(env STYLE_CONTEXT=direct python3 "$DETECTOR" "$TMP/ps.jsonl" 2>/dev/null | sed -n '4p')" ] && echo yes || echo no)" "after a dot"

# The return is sent at the end of the hook: the other checks still run (counter, journal) and the place
# remark of the same line is stored too.
out=$(run_hook hlate '[U("Проверь."), A("Тест PASS, exit 0.\n\nДальше: я, в этой сессии: закрыть журнал сессии.")]' STYLE_ENFORCE_BLOCK=1)
check "late return: block text asks to do the step" "$([[ "$out" == *"Выполни обещанный шаг"* ]] && echo yes || echo no)" "$out"
check "late return: the style findings are in the journal" "$([ "$(logline hlate 'A10')" -ge 1 ] && echo yes || echo no)" "no A10 line"
check "late return: the place remark is stored too" "$([[ "$(remarks hlate)" == *"из неё ничего не публикуется"* ]] && echo yes || echo no)" "$(remarks hlate)"

echo "a12-next-i-no-wake: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
