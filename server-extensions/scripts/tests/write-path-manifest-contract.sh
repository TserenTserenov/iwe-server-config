#!/usr/bin/env bash
# Contract-тест манифеста защищённых путей (Codex, пир-сессия 2026-08-30-01,
# раунд 3): плоский парсер хука fail-open на незнакомом представлении YAML --
# этот тест ловит дрейф формата раньше, чем манифест молча перестанет матчить.
set -uo pipefail

IWE_ROOT="${IWE_WORKSPACE:-$HOME/IWE}"
MANIFEST="$IWE_ROOT/.claude/hooks/write-path-manifest.yaml"
HOOK="$IWE_ROOT/.claude/hooks/write-path-lease-guard.sh"
FAIL=0

check() {  # $1=описание $2=результат(0/1)
  if [ "$2" -eq 0 ]; then echo "  ok: $1"; else echo "  FAIL: $1" >&2; FAIL=1; fi
}

echo "write-path-manifest contract:"

python3 - "$MANIFEST" <<'PYEOF'
import sys
manifest = sys.argv[1]
classes = []       # [(id, mode, [patterns])]
cur = None
for raw in open(manifest, encoding="utf-8"):
    line = raw.split("#", 1)[0].rstrip()
    s = line.strip()
    if s.startswith("- id:"):
        cur = {"id": s.split(":", 1)[1].strip(), "mode": None, "patterns": []}
        classes.append(cur)
    elif s.startswith("mode:") and cur is not None:
        cur["mode"] = s.split(":", 1)[1].strip()
    elif (s.startswith("- \"") or s.startswith("- '")) and cur is not None:
        cur["patterns"].append(s[2:].strip().strip("\"'"))

errors = []
if not classes:
    errors.append("парсер не нашёл ни одного класса")
ids = [c["id"] for c in classes]
if len(ids) != len(set(ids)):
    errors.append(f"id классов не уникальны: {ids}")
for c in classes:
    if c["mode"] not in ("enforce", "telemetry"):
        errors.append(f"класс {c['id']}: недопустимый mode {c['mode']!r}")
    if not c["patterns"]:
        errors.append(f"класс {c['id']}: ни одного распознанного pattern")
    for p in c["patterns"]:
        if "{{GOV_REPO}}" not in p and "/" not in p:
            errors.append(f"класс {c['id']}: подозрительный pattern {p!r}")
# Каждая непустая контентная строка манифеста должна быть распознана одной из
# трёх форм -- четвёртая форма означает дрейф формата, который парсер молча съест.
recognized_prefixes = ("classes:", "- id:", "mode:", "patterns:", "- \"", "- '")
for n, raw in enumerate(open(manifest, encoding="utf-8"), 1):
    s = raw.split("#", 1)[0].strip()
    if not s:
        continue
    if not s.startswith(recognized_prefixes):
        errors.append(f"строка {n}: нераспознанная форма {s!r} -- парсер хука её проигнорирует")
for e in errors:
    print(f"  FAIL: {e}", file=sys.stderr)
print(f"  классов: {len(classes)}, шаблонов: {sum(len(c['patterns']) for c in classes)}")
sys.exit(1 if errors else 0)
PYEOF
check "структура манифеста (id/mode/patterns, уникальность, формы строк)" $?

# Поведенческая проба: NotebookEdit с notebook_path под enforce-классом блокируется.
OUT=$(IWE_GOVERNANCE_REPO="${IWE_GOVERNANCE_REPO:-DS-my-strategy}" bash -c '
  echo "{\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"$HOME/IWE/${IWE_GOVERNANCE_REPO}/inbox/WP-1/WP-1.md\"}}" | bash "'"$HOOK"'"' 2>&1)
RC=$?
[ "$RC" -eq 2 ] || [ "$RC" -eq 0 ] # 2 = блок без аренды; 0 допустим, если аренда реально есть
check "NotebookEdit(notebook_path) доходит до проверки (rc=$RC, не молчаливый пропуск без матча)" $?
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q "."; then
  # rc=0 с пустым выводом легитимен ТОЛЬКО при живой аренде — проверим её
  python3 "$IWE_ROOT/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/scripts/lib/gateway-lock.py" check "$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-my-strategy}/inbox/WP-1/WP-1.md" >/dev/null 2>&1
  check "rc=0 объясняется живой арендой, не пропуском матча" $?
fi

if [ "$FAIL" -eq 0 ]; then echo "PASS: контракт манифеста соблюдён"; else echo "FAIL: см. выше" >&2; exit 1; fi
