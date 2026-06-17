#!/bin/bash
# schema-registration-gate.sh — PreToolUse[Write] обёртка для AR.234 (Schema Registration Gate).
# ADR-IWE-020 (peer-сессия 2026-06-14-50, спин-офф WP-419).
#
# Узкое событие schema_registration_attempt — слушает ТОЛЬКО AR.234, не будит спящий
# шумный AR.009 (Routing Gate, FP 30-40% на каждый файл). Membership — schema-triggers.yaml.
#
# Контракт PreToolUse hook (Claude Code):
# - Stdin: JSON {"tool_name", "tool_input", "session_id", ...}
# - warn  → stdout {"additionalContext": "..."} + exit 0 (мягкий nudge, не блокирует)
# - ok    → silent exit 0
# Хук advisory: при любой неоднозначности fail-open (никогда не блокирует Write).

set -uo pipefail

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("tool_name",""))' 2>/dev/null)
# Новая схема = Write нового файла. Edit/MultiEdit — правка существующего, не сюда.
case "$TOOL_NAME" in
    Write) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); t=d.get("tool_input",{}); print(t.get("file_path", t.get("path","")))' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0
# Существующий файл = overwrite/edit, не новая схема
[ -f "$FILE_PATH" ] && exit 0

CFG="${SCHEMA_TRIGGERS_CONFIG:-$HOME/IWE/.claude/hooks/schema-triggers.yaml}"

# should_fire: грубый glob по basename из общего конфига (тонкий verdict — в check-функции)
SHOULD=$(_STG_CFG="$CFG" _STG_PATH="$FILE_PATH" python3 - <<'PYEOF' 2>/dev/null || echo "no"
import os, fnmatch
cfg = os.environ["_STG_CFG"]
base = os.path.basename(os.environ["_STG_PATH"])
try:
    import yaml
    with open(cfg) as f:
        c = yaml.safe_load(f) or {}
    globs = c.get("path_globs", [])
except Exception:
    print("no"); raise SystemExit
print("yes" if any(fnmatch.fnmatch(base, g) for g in globs) else "no")
PYEOF
)
[ "$SHOULD" = "yes" ] || exit 0

ENGINE="$HOME/IWE/.claude/hooks/rule-engine.sh"
[ ! -x "$ENGINE" ] && exit 0  # rule-engine отсутствует — fail-open

CTX=$(_FP="$FILE_PATH" python3 -c 'import os,json; print(json.dumps({"target_path":os.environ["_FP"],"is_new_file":True}))' 2>/dev/null || echo '{}')
RESULT=$(RULE_EVENT="schema_registration_attempt" RULE_CONTEXT="$CTX" "$ENGINE" dispatch 2>/dev/null)

# Безопасный разбор + JSON-вывод additionalContext (экранирование через json.dumps)
echo "$RESULT" | python3 -c '
import sys, json
try:
    r = json.loads(sys.stdin.read() or "{}")
except (json.JSONDecodeError, ValueError):
    raise SystemExit
if r.get("verdict") == "warn":
    msg = "⚠️ AR.234 (Schema Registration Gate): " + r.get("reason", "")
    print(json.dumps({"additionalContext": msg}, ensure_ascii=False))
' 2>/dev/null

exit 0
