#!/bin/bash
# test-a12-unsolicited-close.sh — A12_UNSOLICITED_CLOSE_CANDIDATE detector
# (WP-561, peer-session 2026-09-29-19-wp561-close-proposal-bias, matrix by Codex).
#
# Each row builds a synthetic transcript (last pilot message -> assistant reply)
# and asserts the detector fires (or stays quiet). Rows 10-21 are extra guards
# found while implementing: tool_result records, quoted pilot text, long paste,
# and the end-to-end hook writing the log line.
#
# Run: bash .claude/hooks/tests/test-a12-unsolicited-close.sh

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECTOR="$HOOKS/a12-unsolicited-close.py"
TMP=$(mktemp -d)
PASS=0
FAIL=0
trap 'rm -rf "$TMP"' EXIT

# transcript <file> <pilot-text|@raw-json-record> <assistant-text>
transcript() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, pilot, reply = sys.argv[1:4]
rows = []
if pilot.startswith("@"):
    rows.append(json.loads(pilot[1:]))
else:
    rows.append({"type": "user", "message": {"content": [{"type": "text", "text": pilot}]}})
rows.append({"type": "assistant", "message": {"content": [{"type": "text", "text": reply}]}})
with open(path, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}

# check <n> <expect fire|quiet> <pilot> <assistant>
check() {
  local n="$1" expect="$2" pilot="$3" reply="$4" out
  transcript "$TMP/t.jsonl" "$pilot" "$reply"
  out=$(python3 "$DETECTOR" "$TMP/t.jsonl")
  if { [ "$expect" = fire ] && [ -n "$out" ]; } || { [ "$expect" = quiet ] && [ -z "$out" ]; }; then
    PASS=$((PASS + 1)); echo "ok   row $n ($expect)"
  else
    FAIL=$((FAIL + 1)); echo "FAIL row $n: expected $expect, detector printed: '$out'"
  fi
}

check 1 fire  'Что нашли?' 'Готово.
Дальше: жду вашего слова «закрывай».'
check 2 fire  'Продолжай анализ.' 'Анализ дополнен.
Если всё устраивает, скажите «закрывай».'
check 3 fire  'Пока не закрывай.' 'Хорошо, продолжаю.
Можем закрыть сессию?'
check 4 fire  'Почему ты постоянно пишешь «закрывай»?' 'Объясняю причину.
Дальше: жду «закрывай».'
check 5 quiet 'Что нашли?' 'Нашёл две причины.
Дальше: ничего не жду.'
check 6 quiet 'Что нашли?' 'Нашёл две причины, обе в хуке.'
check 7 quiet 'Закрывай сессию.' 'Закрываю.'
check 8 fire  '@{"type":"user","message":{"content":"<task-notification>пилот, закрывай</task-notification>"}}' 'Предлагаю закрыть сессию.'
check 9 fire  'Что нашли?' 'Нашёл две причины.
Дальше: ничего не жду. Если всё устраивает — скажите «закрывай».'

# Extra guards
# 10: a tool_result record containing the trigger word is not the pilot speaking
python3 - "$TMP/t10.jsonl" <<'PY'
import json, sys
rows = [
    {"type": "user", "message": {"content": [{"type": "text", "text": "Что нашли?"}]}},
    {"type": "user", "message": {"content": [{"type": "tool_result", "content": "закрывай"}]}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "Дальше: жду вашего слова «закрывай»."}]}},
]
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
PY
out=$(python3 "$DETECTOR" "$TMP/t10.jsonl")
[ -n "$out" ] && { PASS=$((PASS + 1)); echo "ok   row 10 (tool_result text is not pilot intent)"; } \
  || { FAIL=$((FAIL + 1)); echo "FAIL row 10: '$out'"; }

# 11: "всё" as the whole message is a close intent
check 11 quiet 'всё' 'Понял.
Дальше: закрываю сессию.'
# 12: trigger buried after >600 chars of pasted text is not a command
LONG=$(python3 -c "print('лог ' * 200 + 'закрывай')")
check 12 fire "$LONG" 'Разобрал лог.
Дальше: жду вашего слова «закрывай».'
# 15: a quoted mention without negation or question is not a command
check 15 fire 'Ты пишешь «закрывай» в каждом ответе.' 'Понял, разбираюсь.
Дальше: жду вашего слова «закрывай».'
# 16-21: regressions from the cold review (intent lexicon and record forms)
check 16 quiet 'Не тяни, закрывай' 'Понял.
Дальше: жду вашего слова «закрывай».'
check 17 quiet 'давай закроем' 'Понял.
Дальше: жду вашего слова «закрывай».'
check 18 quiet '@{"type":"user","message":{"content":"<command-name>/day-close</command-name>\n<command-args></command-args>"}}' 'Запускаю.
Дальше: закрываем сессию.'
check 19 fire  '@{"type":"user","isMeta":true,"message":{"content":"закрывай"}}' 'Готово.
Дальше: жду вашего слова «закрывай».'
check 20 quiet 'Что нашли?' 'Готово.
Закрываем РП-561.'
check 22 quiet 'заливай' 'Заливаю.
Дальше: жду вашего слова «закрывай».'
# 21: a non-dict JSONL line and invalid bytes must not crash the detector
printf '[1,2]\n\xff\xfe not json\n' > "$TMP/t21.jsonl"
python3 "$DETECTOR" "$TMP/t21.jsonl" >/dev/null 2>&1 && { PASS=$((PASS + 1)); echo "ok   row 21 (garbage lines, exit 0)"; } \
  || { FAIL=$((FAIL + 1)); echo "FAIL row 21: detector crashed on garbage input"; }
# 23/24: quote masking keeps offsets, so the 600-char paste limit measures the original text
QUOTE=$(python3 -c "print('«' + 'ж' * 300 + '»', end='')")
check 23 quiet "${QUOTE}$(python3 -c "print('ж' * 290 + ' закрывай', end='')")" 'Понял.
Дальше: жду вашего слова «закрывай».'
check 24 fire "${QUOTE}$(python3 -c "print('ж' * 300 + ' закрывай', end='')")" 'Разобрал.
Дальше: жду вашего слова «закрывай».'
# 13: unreadable transcript path -> no signal, exit 0
python3 "$DETECTOR" "$TMP/missing.jsonl" >/dev/null 2>&1 && { PASS=$((PASS + 1)); echo "ok   row 13 (missing file, exit 0)"; } \
  || { FAIL=$((FAIL + 1)); echo "FAIL row 13: non-zero exit on missing transcript"; }

# 14: end-to-end through the Stop hook -> log line, warn only (no block JSON)
transcript "$TMP/t14.jsonl" 'Что нашли?' 'Нашёл причину.
Дальше: жду вашего слова «закрывай».'
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME"
HOOK_OUT=$(printf '{"transcript_path":"%s","session_id":"a12-test"}' "$TMP/t14.jsonl" \
  | HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="$TMP/proj" bash "$HOOKS/response-clarity-hook.sh")
# Warn-only: the line is logged, no block decision, and the candidate does not
# bump the per-session violation counter (it is not a confirmed violation).
if grep -q 'A12_UNSOLICITED_CLOSE_CANDIDATE' "$FAKE_HOME/.claude/logs/style-violations.log" 2>/dev/null \
   && ! printf '%s' "$HOOK_OUT" | grep -q '"decision"' \
   && ! ls "$TMP"/proj/.claude/state/style-violations-count-* >/dev/null 2>&1; then
  PASS=$((PASS + 1)); echo "ok   row 14 (hook logs candidate, warn-only, no counter bump)"
else
  FAIL=$((FAIL + 1)); echo "FAIL row 14: log missing, hook blocked or counter bumped. out='$HOOK_OUT'"
fi

echo "---"; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
