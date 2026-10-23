#!/bin/bash
# test-style-entries.sh — thin end-of-reply entries of Kimi and Codex (РП-388 Ф21).
# Both route a finished reply through the shared core behind style-check-text.sh
# and hand the block decision back to the agent. Run in an isolated HOME that
# links ~/IWE to this checkout, so the live hooks are not touched.
#
# Run: bash .claude/hooks/tests/test-style-entries.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.kimi/sessions/ws/sess" "$TMP/.claude"
ln -s "$ROOT" "$TMP/IWE"

PASS=0; FAIL=0
check() {  # check <name> <command...>: passes when the command succeeds
  local name="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   $name"; else FAIL=$((FAIL+1)); echo "FAIL $name"; fi
}

BAD='Запусти `sync-agent-instructions.sh --force` и всё обновится.'
GOOD='Готово, всё работает.'

kimi_journal() {  # kimi_journal <assistant text>
  TEXT="$1" python3 -I - "$TMP/.kimi/sessions/ws/sess/context.jsonl" <<'PY'
import json, os, sys
rows = [{"role": "user", "content": "q"},
        {"role": "assistant", "content": [{"type": "think", "think": "x"},
                                          {"type": "text", "text": os.environ["TEXT"]}]}]
open(sys.argv[1], "w").write("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
PY
}
kimi_hook() {  # kimi_hook <stop_hook_active>
  printf '{"hook_event_name":"Stop","session_id":"sess","stop_hook_active":%s}' "$1" \
    | HOME="$TMP" python3 -I "$ROOT/.claude/hooks/kimi-style-stop.py" 2>"$TMP/stderr"
}
codex_hook() {  # codex_hook <reply> <stop_hook_active>
  REPLY_TEXT="$1" ACTIVE="$2" python3 -I -c '
import json, os
print(json.dumps({"last_assistant_message": os.environ["REPLY_TEXT"],
                  "stop_hook_active": os.environ["ACTIVE"] == "true"}, ensure_ascii=False))' \
    | HOME="$TMP" python3 -I "$ROOT/.codex/hooks/style_check_stop.py"
}

kimi_journal "$BAD"
kimi_hook false; rc=$?
check "kimi: bad reply exits 2" test "$rc" -eq 2
check "kimi: stderr carries the reason" grep -q "Стиль нарушен" "$TMP/stderr"
kimi_hook true; rc=$?
check "kimi: loop guard (stop_hook_active) exits 0" test "$rc" -eq 0
kimi_journal "$GOOD"
kimi_hook false; rc=$?
check "kimi: clean reply exits 0" test "$rc" -eq 0
printf '{"hook_event_name":"Stop","session_id":"missing","stop_hook_active":false}' \
  | HOME="$TMP" python3 -I "$ROOT/.claude/hooks/kimi-style-stop.py"; rc=$?
check "kimi: unknown session fails open" test "$rc" -eq 0

out=$(codex_hook "$BAD" false)
check "codex: bad reply returns block" grep -q '"decision": "block"' <<<"$out"
out=$(codex_hook "$BAD" true)
check "codex: loop guard returns empty object" test "$out" = "{}"
out=$(codex_hook "$GOOD" false)
check "codex: clean reply returns empty object" test "$out" = "{}"

A14_BAD='ИИ-агент — это система. В ней есть:

- **Модель** — понимает запрос.
- **Память** — хранит сведения.
- **Правила** — задают границы.'
kimi_journal "$A14_BAD"
kimi_hook false; rc=$?
check "kimi: A14 composition list exits 2" test "$rc" -eq 2
check "kimi: A14 named in the reason" grep -q "A14" "$TMP/stderr"
out=$(codex_hook "$A14_BAD" false)
check "codex: A14 composition list returns block" grep -q '"decision": "block"' <<<"$out"

# Claude path: no flag, so A14 stays warn-only (the core prints an empty object).
printf '{"transcript_path":"%s","session_id":"claude-a14"}' "$TMP/t.jsonl" >"$TMP/claude-in.json"
TEXT="$A14_BAD" python3 -I - "$TMP/t.jsonl" <<'PY'
import json, os, sys
rows = [{"type": "user", "message": {"content": [{"type": "text", "text": "q"}]}},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": os.environ["TEXT"]}]}}]
open(sys.argv[1], "w").write("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
PY
out=$(HOME="$TMP" STYLE_ENFORCE_BLOCK=1 bash "$ROOT/.claude/hooks/response-clarity-hook.sh" <"$TMP/claude-in.json" 2>/dev/null)
check "claude path: A14 without flag does not block" test "$out" = "{}"

echo "---"
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
