#!/bin/bash
# test-a12-next-after-block.sh -- the style guard must not make the agent print the
# "Дальше:" line twice (РП-605 Ф6, 05.11.2026, peer-session 2026-11-05-04-wp605-next-dup).
#
# Cases: (1) block text for a blocked reply that HAD the line says "do not write it",
# never "give it again" / "до 12 слов" / "заменяет"; (2) block text for a reply that had
# NO line asks for exactly one; (3) a12-next-block.py after guard feedback: line shown
# before -> quiet, line never shown -> MISSING, a pilot message in between -> MISSING;
# (4) the hook logs had_next_line; (5) stop_hook_active=true never blocks.
#
# Run: bash .claude/hooks/tests/test-a12-next-after-block.sh

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

# make_transcript <out> <python rows expression>
make_transcript() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
def U(text):
    return {"type": "user", "message": {"content": [{"type": "text", "text": text}]}}
def FB(text="Stop hook feedback:\nСтиль нарушен (правила: A10 )."):
    return {"type": "user", "isMeta": True, "message": {"content": text}}
def A(text):
    return {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}
WITH_NEXT = "Итог проверки.\n\nPASS\n\nДальше: вы решаете, сливать ли запрос сегодня."
NO_NEXT = "Итог проверки.\n\nPASS"
REWRITE = "Итог проверки: всё сходится."
rows = eval(expr)
with open(path, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}

# Blocked reply carries an A10 violation ("PASS"), so the hook blocks in direct mode.
run_hook() { # $1 id, $2 rows expression, rest: extra env
  local id="$1" expr="$2"; shift 2
  mkdir -p "$TMP/$id/home" "$TMP/$id/proj"
  make_transcript "$TMP/$id/t.jsonl" "$expr"
  printf '{"transcript_path":"%s","session_id":"%s"}' "$TMP/$id/t.jsonl" "$id" \
    | env HOME="$TMP/$id/home" CLAUDE_PROJECT_DIR="$TMP/$id/proj" STYLE_ENFORCE_BLOCK=1 "$@" bash "$HOOK" 2>/dev/null
}

# (1) reply had the line
out=$(run_hook had-line '[U("Проверь."), A(WITH_NEXT)]')
reason=$(printf '%s' "$out" | jq -r '.reason // empty')
check "had-line blocks" "$([ "$(printf '%s' "$out" | jq -r '.decision // empty')" = block ] && echo yes || echo no)" "$out"
check "had-line reason says do not write the line" \
  "$([[ "$reason" == *"в этом ответе её не пиши"* ]] && echo yes || echo no)" "$reason"
check "had-line reason has no old wording" \
  "$([[ "$reason" != *"до 12 слов"* && "$reason" != *"заменяет"* && "$reason" != *"дай её заново"* ]] && echo yes || echo no)" "$reason"
check "had-line reason keeps the final-part limit" \
  "$([[ "$reason" == *"ТОЛЬКО её"* && "$reason" == *"остальной текст не повторяй"* ]] && echo yes || echo no)" "$reason"
check "had-line logged" \
  "$(grep -q 'A12_BLOCK_NEXT_NOTE | had_next_line=yes' "$TMP/had-line/home/.claude/logs/style-violations.log" 2>/dev/null && echo yes || echo no)" "no had_next_line=yes"

# (2) reply had no line
out=$(run_hook no-line '[U("Проверь."), A(NO_NEXT)]')
reason=$(printf '%s' "$out" | jq -r '.reason // empty')
check "no-line reason asks for exactly one line" \
  "$([[ "$reason" == *"строки «Дальше:» не было: ровно одна строка"* && "$reason" != *"в этом ответе её не пиши"* ]] && echo yes || echo no)" "$reason"
check "no-line logged" \
  "$(grep -q 'A12_BLOCK_NEXT_NOTE | had_next_line=no' "$TMP/no-line/home/.claude/logs/style-violations.log" 2>/dev/null && echo yes || echo no)" "no had_next_line=no"

# (3) detector after guard feedback
detect() { make_transcript "$TMP/$1.jsonl" "$2"; STYLE_CONTEXT=direct python3 "$DETECTOR" "$TMP/$1.jsonl" 2>"$TMP/err" | sed -n '1p'; }
got=$(detect shown-then-rewrite '[U("Проверь."), A(WITH_NEXT), FB(), A(REWRITE)]')
check "line shown before feedback -> quiet" "$([ -z "$got" ] && echo yes || echo no)" "[$got]"
got=$(detect never-shown '[U("Проверь."), A(NO_NEXT), FB(), A(REWRITE)]')
check "line never shown -> MISSING" "$([ "$got" = MISSING ] && echo yes || echo no)" "[$got]"
got=$(detect pilot-between '[U("Проверь."), A(WITH_NEXT), U("А теперь?"), A(REWRITE)]')
check "pilot message after the shown line -> MISSING" "$([ "$got" = MISSING ] && echo yes || echo no)" "[$got]"
got=$(detect line-in-rewrite '[U("Проверь."), A(NO_NEXT), FB(), A(WITH_NEXT)]')
check "line in the rewrite -> quiet" "$([ -z "$got" ] && echo yes || echo no)" "[$got]"
got=$(detect other-feedback '[U("Проверь."), A(WITH_NEXT), FB("# Autonomous loop check\nпроверь очередь"), A(REWRITE)]')
check "non-guard meta record -> MISSING" "$([ "$got" = MISSING ] && echo yes || echo no)" "[$got]"
check "detector writes nothing to stderr" "$([ ! -s "$TMP/err" ] && echo yes || echo no)" "$(cat "$TMP/err")"

# (4b) a crashed detector must not read as "line shown": use a copy of the hook dir
# whose a12-next-block.py exits 1, and expect the "exactly one line" wording.
mkdir -p "$TMP/broken/hooks"
cp -R "$HOOKS/." "$TMP/broken/hooks/"
printf 'import sys\nsys.exit(1)\n' > "$TMP/broken/hooks/a12-next-block.py"
mkdir -p "$TMP/broken/home" "$TMP/broken/proj"
make_transcript "$TMP/broken/t.jsonl" '[U("Проверь."), A(WITH_NEXT)]'
out=$(printf '{"transcript_path":"%s","session_id":"broken"}' "$TMP/broken/t.jsonl" \
  | env HOME="$TMP/broken/home" CLAUDE_PROJECT_DIR="$TMP/broken/proj" STYLE_ENFORCE_BLOCK=1 bash "$TMP/broken/hooks/response-clarity-hook.sh" 2>/dev/null)
reason=$(printf '%s' "$out" | jq -r '.reason // empty')
check "crashed detector -> asks for exactly one line" \
  "$([[ "$reason" == *"ровно одна строка"* && "$reason" != *"в этом ответе её не пиши"* ]] && echo yes || echo no)" "$reason"

# (5) the re-run after a block never blocks again
out=$(run_hook active '[U("Проверь."), A(WITH_NEXT), FB(), A(NO_NEXT)]' IWE_DUMMY=1)
mkdir -p "$TMP/active2/home" "$TMP/active2/proj"
out=$(printf '{"transcript_path":"%s","session_id":"active2","stop_hook_active":true}' "$TMP/active/t.jsonl" \
  | env HOME="$TMP/active2/home" CLAUDE_PROJECT_DIR="$TMP/active2/proj" STYLE_ENFORCE_BLOCK=1 bash "$HOOK" 2>/dev/null)
check "stop_hook_active=true does not block" "$([[ "$out" != *block* ]] && echo yes || echo no)" "$out"

echo "a12-next-after-block: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
