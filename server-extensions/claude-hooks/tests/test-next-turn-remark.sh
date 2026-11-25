#!/bin/bash
# test-next-turn-remark.sh — remarks deferred from Stop hooks to the next turn (WP-605, 25.11.2026).
#
# Checks the observable effects, not just "it ran":
#   1. lib/next-turn-remark.sh stores a remark, the reader returns it once and deletes the file.
#   2. inject-communication-style.sh puts a stored remark into additionalContext of the next
#      UserPromptSubmit and removes it, so the third turn gets nothing.
#   3. response-clarity-hook.sh turns an unsolicited close/publish ask into a next-turn remark.
#   4. access-claim: exact "no access" phrase still blocks; a broad match is deferred; a phrase
#      inside typographic quotes or a "> " quote line is not a claim.
#
# Run: bash .claude/hooks/tests/test-next-turn-remark.sh

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECTORS="$(cd "$HOOKS/../detectors" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
check() {
  local name="$1" ok="$2" detail="$3"
  if [ "$ok" = "yes" ]; then PASS=$((PASS + 1)); echo "PASS $name"; else FAIL=$((FAIL + 1)); echo "FAIL $name: $detail"; fi
}

# $1 file, $2 pilot text, $3 assistant text: a two-row transcript.
write_transcript() {
  PILOT_TEXT="$2" REPLY_TEXT="$3" python3 - "$1" <<'PY'
import json, os, sys
rows = [
    {"type": "user", "message": {"content": [{"type": "text", "text": os.environ["PILOT_TEXT"]}]}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": os.environ["REPLY_TEXT"]}]}},
]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}

# --- 1. the library itself ---
# shellcheck source=../lib/next-turn-remark.sh
. "$HOOKS/lib/next-turn-remark.sh"
STATE="$TMP/lib/state"
next_turn_remark_add "$STATE" "s1" $'первое\nзамечание'
next_turn_remark_add "$STATE" "s1" "второе замечание"
got=$(next_turn_remark_take "$STATE" "s1")
check "reader returns both remarks, newlines folded" \
  "$([ "$got" = $'первое замечание\nвторое замечание' ] && echo yes || echo no)" "$got"
check "reader deletes the file" \
  "$([ ! -e "$STATE/next-turn-remarks-s1" ] && echo yes || echo no)" "$(ls "$STATE")"
check "unknown session id is not stored" \
  "$(next_turn_remark_add "$STATE" "unknown" "x" && echo no || echo yes)" "stored for unknown"
for i in 1 2 3 4 5 6 7; do next_turn_remark_add "$STATE" "cap" "замечание $i"; done
check "only the newest four remarks are kept" \
  "$([ "$(wc -l < "$STATE/next-turn-remarks-cap")" -eq 4 ] && head -1 "$STATE/next-turn-remarks-cap" | grep -q 'замечание 4' && echo yes || echo no)" \
  "$(cat "$STATE/next-turn-remarks-cap")"
next_turn_remark_add "$STATE" "long" "$(printf 'щ%.0s' $(seq 1 3200))"
check "a long remark is cut to 1000 characters, not bytes" \
  "$([ "$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read().rstrip("\n")))' "$STATE/next-turn-remarks-long")" -eq 1000 ] && echo yes || echo no)" \
  "$(wc -c < "$STATE/next-turn-remarks-long") bytes"
next_turn_remark_add "$STATE" "../evil" "x"
check "session id cannot leave the state dir" \
  "$([ -f "$STATE/next-turn-remarks-..evil" ] && [ ! -e "$TMP/lib/next-turn-remarks-evil" ] && echo yes || echo no)" "$(ls -a "$STATE")"

# --- 2. delivery by the UserPromptSubmit hook ---
PROJ="$TMP/inject/proj"
mkdir -p "$PROJ/.claude/state" "$TMP/inject/home"
next_turn_remark_add "$PROJ/.claude/state" "sess2" "СТИЛЬ-МЕТКА-42"
write_transcript "$TMP/inject/t.jsonl" "да" "Готово. Дальше: правка внесена."
run_inject() {
  printf '{"session_id":"sess2","transcript_path":"%s","prompt":"дальше"}' "$TMP/inject/t.jsonl" \
    | env HOME="$TMP/inject/home" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOKS/inject-communication-style.sh" 2>/dev/null
}
first=$(run_inject)
ctx=$(printf '%s' "$first" | jq -r '.hookSpecificOutput.additionalContext // empty')
check "next turn receives the remark" \
  "$([[ "$ctx" == *"СТИЛЬ-МЕТКА-42"* ]] && echo yes || echo no)" "${ctx:0:300}"
second=$(run_inject)
ctx2=$(printf '%s' "$second" | jq -r '.hookSpecificOutput.additionalContext // empty')
check "the remark is delivered only once" \
  "$([[ "$ctx2" != *"СТИЛЬ-МЕТКА-42"* ]] && echo yes || echo no)" "${ctx2:0:300}"
# Four long remarks (the most the file keeps) still reach the agent whole: they ride in
# the prefix, which the 7000-character cap never drops (Fable review 25.11).
for i in 1 2 3 4; do next_turn_remark_add "$PROJ/.claude/state" "sess2" "ДЛИННАЯ-$i $(printf 'ж%.0s' $(seq 1 980))"; done
full=$(run_inject)
ctx3=$(printf '%s' "$full" | jq -r '.hookSpecificOutput.additionalContext // empty')
check "four maximal remarks are all delivered" \
  "$([[ "$ctx3" == *"ДЛИННАЯ-1"* && "$ctx3" == *"ДЛИННАЯ-4"* ]] && echo yes || echo no)" "${#ctx3} chars"

# --- 3. unsolicited close / publish ask -> next-turn remark ---
run_clarity() {  # $1 id, $2 pilot text, $3 reply
  mkdir -p "$TMP/$1/home" "$TMP/$1/proj"
  write_transcript "$TMP/$1/t.jsonl" "$2" "$3"
  printf '{"transcript_path":"%s","session_id":"%s"}' "$TMP/$1/t.jsonl" "$1" \
    | env HOME="$TMP/$1/home" CLAUDE_PROJECT_DIR="$TMP/$1/proj" STYLE_AGENT=claude-code \
      bash "$HOOKS/response-clarity-hook.sh" >/dev/null 2>&1
}
run_clarity ask "Сделай правку правила." "Правка внесена. Дальше: вы: сказать «заливай», и я опубликую правку."
check "ask for «заливай» without the pilot's intent becomes a remark" \
  "$(grep -q 'правила 6.4-6.5' "$TMP/ask/proj/.claude/state/next-turn-remarks-ask" 2>/dev/null && echo yes || echo no)" \
  "$(cat "$TMP/ask/proj/.claude/state/next-turn-remarks-ask" 2>/dev/null)"
run_clarity told "Проверь и потом ПСЗ." "Проверка чиста. Дальше: вы: сказать «ПСЗ», если согласны."
check "no remark when the pilot asked to close himself" \
  "$([ ! -e "$TMP/told/proj/.claude/state/next-turn-remarks-told" ] && echo yes || echo no)" \
  "$(cat "$TMP/told/proj/.claude/state/next-turn-remarks-told" 2>/dev/null)"
run_clarity named "Что сделано?" "Правило о словах «заливай» внесено. Дальше: поручение «ПСЗ» выполнено и проверено Fable."
check "naming «заливай»/«ПСЗ» in a report is not an ask" \
  "$([ ! -e "$TMP/named/proj/.claude/state/next-turn-remarks-named" ] && echo yes || echo no)" \
  "$(cat "$TMP/named/proj/.claude/state/next-turn-remarks-named" 2>/dev/null)"
run_clarity report "Что сделано?" "Залил правку, коммит a1b2c3d. Дальше: правка опубликована."
check "a report about publishing is not an ask" \
  "$([ ! -e "$TMP/report/proj/.claude/state/next-turn-remarks-report" ] && echo yes || echo no)" \
  "$(cat "$TMP/report/proj/.claude/state/next-turn-remarks-report" 2>/dev/null)"

# --- 4. access-claim: block / defer / quote ---
run_access() {  # $1 id, $2 reply -> hook stdout
  mkdir -p "$TMP/$1/home" "$TMP/$1/proj"
  write_transcript "$TMP/$1/t.jsonl" "Посмотри счётчики." "$2"
  printf '{"hook_event_name":"Stop","transcript_path":"%s","session_id":"%s","stop_hook_active":false}' "$TMP/$1/t.jsonl" "$1" \
    | env HOME="$TMP/$1/home" IWE_ROOT="$TMP/root" CLAUDE_PROJECT_DIR="$TMP/$1/proj" \
      bash "$HOOKS/access-claim-stop-reminder.sh" 2>/dev/null
}
# The detector stays silent without a governance repo folder under IWE_ROOT.
mkdir -p "$TMP/root/.claude" "$TMP/root/DS-my-strategy"
ln -s "$DETECTORS" "$TMP/root/.claude/detectors"
out=$(run_access strict "У меня нет доступа к базе, сделайте запрос сами. Дальше: вы: выполнить запрос.")
check "exact «нет доступа» phrase still blocks" \
  "$([ "$(printf '%s' "$out" | jq -r '.decision // empty')" = block ] && echo yes || echo no)" "$out"
out=$(run_access broad "Токен для базы не нашёл в настройках. Дальше: вы: прислать токен.")
check "broad proximity match does not block" \
  "$([ "$(printf '%s' "$out" | jq -r '.decision // empty')" != block ] && echo yes || echo no)" "$out"
check "broad proximity match is deferred to the next turn" \
  "$([ -s "$TMP/broad/proj/.claude/state/next-turn-remarks-broad" ] && echo yes || echo no)" "$(ls -a "$TMP/broad/proj/.claude/state" 2>&1)"
out=$(run_access quoted $'В карточке записано:\n> у меня нет доступа к базе\nи ещё “нет доступа к Grafana”. Дальше: вопрос в карточке закрыт.')
check "quote line and typographic quotes are not a claim" \
  "$([ "$(printf '%s' "$out" | jq -r '.decision // empty')" != block ] && [ ! -e "$TMP/quoted/proj/.claude/state/next-turn-remarks-quoted" ] && echo yes || echo no)" "$out"

echo "---"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
