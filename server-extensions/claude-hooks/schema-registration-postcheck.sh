#!/bin/bash
# schema-registration-postcheck.sh — PostToolUse[Write] для AR.234 (ADR-IWE-020).
#
# E3-prompted-WITH-DETECTION: pre-write nudge только ПОКАЗЫВАЕТ §5-чеклист. Этот
# хук детектирует, ОТВЕТИЛ ли агент — заполнены ли обязательные §5-поля
# (owner/schema_version) в каноне только что записанной схемы. Не заполнены =
# агент проигнорил nudge → warn-маркер в session-warn-log → всплывёт в Close summary.
# Без этого «E3-prompted» был бы самообманом «E3-displayed» (различение ADR-IWE-020).
#
# Контракт PostToolUse: stdin JSON; вывод {"additionalContext": ...} опционален; exit 0.
# Хук advisory: никогда не падает на работу пользователя.

set -uo pipefail

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("tool_name",""))' 2>/dev/null)
case "$TOOL_NAME" in
    Write) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); t=d.get("tool_input",{}); print(t.get("file_path", t.get("path","")))' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0
[ ! -f "$FILE_PATH" ] && exit 0  # файл не записался — нечего проверять

SESSION_ID=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("session_id",""))' 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID="${CLAUDE_SESSION_ID:-default}"

CFG="${SCHEMA_TRIGGERS_CONFIG:-$HOME/IWE/.claude/hooks/schema-triggers.yaml}"
STATE_DIR="$HOME/.claude/state"
WARN_LOG="$STATE_DIR/session-${SESSION_ID}-warns.jsonl"

# Проверка: (1) путь в scope по globs; (2) если да — заполнены ли required_fields.
# Возвращает: "ok" (в scope, поля заполнены) | "missing:<list>" | "skip" (не схема).
RESULT=$(_STG_CFG="$CFG" _STG_PATH="$FILE_PATH" python3 - <<'PYEOF' 2>/dev/null || echo "skip"
import os, re, fnmatch
cfg = os.environ["_STG_CFG"]
path = os.environ["_STG_PATH"]
base = os.path.basename(path)
try:
    import yaml
    with open(cfg) as f:
        c = yaml.safe_load(f) or {}
except Exception:
    print("skip"); raise SystemExit
globs = c.get("path_globs", [])
if not any(fnmatch.fnmatch(base, g) for g in globs):
    print("skip"); raise SystemExit
required = c.get("required_fields", [])
try:
    with open(path) as f:
        text = f.read()
except Exception:
    print("skip"); raise SystemExit
missing = []
for field in required:
    # top-level YAML поле (^ с MULTILINE, без ведущих пробелов — избегает false-positive на вложенных)
    if not re.search(r'^' + re.escape(field) + r':\s*\S', text, re.MULTILINE):
        missing.append(field)
print("ok" if not missing else "missing:" + ",".join(missing))
PYEOF
)

case "$RESULT" in
    ok|skip) exit 0 ;;
    missing:*)
        MISSING="${RESULT#missing:}"
        mkdir -p "$STATE_DIR" 2>/dev/null || true
        # warn-маркер в формате rule-engine session-warn-log (подхватит session-summary при Close)
        # Два независимых вызова: write-to-log и stdout разделены.
        # Сбой записи в журнал не должен гасить additionalContext для агента.
        _WL="$WARN_LOG" _FP="$FILE_PATH" _MISS="$MISSING" python3 - <<'PYEOF' 2>/dev/null || true
import os, json, datetime
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
reason = ("Новая схема %s записана без §5-полей [%s] — агент не ответил на nudge AR.234. "
          "Заполни owner/schema_version в каноне схемы (ADR-IWE-020: prompt без ответа = E3-displayed)."
          % (os.environ["_FP"], os.environ["_MISS"]))
rec = {"ts": ts, "event": "schema_fields_postcheck", "rule": "AR.234", "verdict": "warn", "reason": reason}
with open(os.environ["_WL"], "a") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PYEOF
        _MISS="$MISSING" python3 -c '
import os, json
print(json.dumps({"additionalContext": "⚠️ AR.234: новая схема записана без полей [%s] — заполни owner/schema_version (иначе всплывёт в Close)." % os.environ["_MISS"]}, ensure_ascii=False))
' 2>/dev/null || true
        exit 0 ;;
    *) exit 0 ;;
esac
