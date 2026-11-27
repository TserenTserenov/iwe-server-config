#!/bin/bash
# test-style-entries.sh — thin end-of-reply entries of Kimi and Codex (РП-388 Ф21).
# Both route a finished reply through the shared core behind style-check-text.sh.
# Kimi is log-only; Codex still returns the block decision. Run in an isolated
# HOME that links ~/IWE to this checkout, so the live hooks are not touched.
#
# Run: bash .claude/hooks/tests/test-style-entries.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.kimi/sessions/ws/sess" "$TMP/.claude"
CODE_SID="session_0f1e2d3c-aaaa-bbbb-cccc-000000000001"
mkdir -p "$TMP/.kimi-code/sessions/wd_iwe_ab12/$CODE_SID/agents/main"
ln -s "$ROOT" "$TMP/IWE"

PASS=0; FAIL=0
check() {  # check <name> <command...>: passes when the command succeeds
  local name="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   $name"; else FAIL=$((FAIL+1)); echo "FAIL $name"; fi
}

# A10 (bare English status marker) is a blockable rule; A13.1 became warn-only on 30.10.
BAD=$'Итог проверки.\n\nPASS\n\nДальше: жду ответа.'
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
kimi_code_journal() {  # kimi_code_journal <assistant text>: Kimi Code (VS Code) wire.jsonl
  TEXT="$1" python3 -I - "$TMP/.kimi-code/sessions/wd_iwe_ab12/$CODE_SID/agents/main/wire.jsonl" <<'PY'
import json, os, sys
def appended(role, content):
    return {"type": "agent.message.appended", "kind": "event",
            "message": {"message": {"role": role, "content": content}, "meta": {}}}
rows = [{"type": "metadata", "protocol_version": "1.5"},
        appended("user", [{"type": "text", "text": "q"}]),
        {"type": "context.append_loop_event", "event": {"type": "content.part",
         "part": {"type": "text", "text": "noise that is not a message"}}},
        appended("assistant", [{"type": "think", "think": "x"}, {"type": "text", "text": os.environ["TEXT"]}]),
        # a later tool-call-only message carries no text and must not hide the reply
        appended("assistant", [{"type": "think", "think": "y"}])]
open(sys.argv[1], "w").write("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
PY
}
kimi_code_hook() {  # kimi_code_hook <stop_hook_active>: payload as Kimi Code sends it (snake_case)
  printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"/w","stop_hook_active":%s,"client_type":"vscode"}' "$CODE_SID" "$1" \
    | HOME="$TMP" KIMI_CODE_HOME= python3 -I "$ROOT/.claude/hooks/kimi-style-stop.py" 2>"$TMP/stderr"
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
check "kimi: bad reply is logged without a rewrite" test "$rc" -eq 0
check "kimi: no rewrite reason is returned" test ! -s "$TMP/stderr"
kimi_hook true; rc=$?
check "kimi: loop guard (stop_hook_active) exits 0" test "$rc" -eq 0
kimi_journal "$GOOD"
kimi_hook false; rc=$?
check "kimi: clean reply exits 0" test "$rc" -eq 0
printf '{"hook_event_name":"Stop","session_id":"missing","stop_hook_active":false}' \
  | HOME="$TMP" python3 -I "$ROOT/.claude/hooks/kimi-style-stop.py"; rc=$?
check "kimi: unknown session fails open" test "$rc" -eq 0

kimi_code_journal "$BAD"
kimi_code_hook false; rc=$?
check "kimi code: bad reply is logged without a rewrite" test "$rc" -eq 0
check "kimi code: no rewrite reason is returned" test ! -s "$TMP/stderr"
kimi_code_hook true; rc=$?
check "kimi code: loop guard (stop_hook_active) exits 0" test "$rc" -eq 0
kimi_code_journal "$GOOD"
kimi_code_hook false; rc=$?
check "kimi code: clean reply exits 0" test "$rc" -eq 0
mkdir -p "$TMP/alt-code-home/sessions/wd_x_1/$CODE_SID/agents/main"
cp "$TMP/.kimi-code/sessions/wd_iwe_ab12/$CODE_SID/agents/main/wire.jsonl" "$TMP/alt-code-home/sessions/wd_x_1/$CODE_SID/agents/main/"
kimi_code_journal "$BAD"
printf '{"hook_event_name":"Stop","session_id":"%s","stop_hook_active":false}' "$CODE_SID" \
  | HOME="$TMP" KIMI_CODE_HOME="$TMP/alt-code-home" python3 -I "$ROOT/.claude/hooks/kimi-style-stop.py" 2>/dev/null; rc=$?
check "kimi code: KIMI_CODE_HOME wins over ~/.kimi-code (clean copy there)" test "$rc" -eq 0

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
# A14 blocking for Kimi and Codex is off since 24.11 (pilot decision, WP-388:
# STYLE_BLOCK_A14=0 until a re-measure shows precision >= 0.7): logged, not blocked.
kimi_journal "$A14_BAD"
kimi_hook false; rc=$?
check "kimi: A14 composition list does not block (A14 blocking off)" test "$rc" -eq 0
out=$(codex_hook "$A14_BAD" false)
check "codex: A14 composition list does not block (A14 blocking off)" test "$out" = "{}"

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
