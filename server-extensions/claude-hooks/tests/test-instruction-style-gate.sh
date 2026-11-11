#!/bin/bash
# test-instruction-style-gate.sh — the first write of a text document that looks like a step-by-step
# instruction for a person is stopped with the rule from DP.SC.050; a repeated write of the same file
# passes; other files and texts pass; a missing rule source never blocks (pilot decision 11.11.2026,
# WP-529 Ф270).
#
# Run: bash .claude/hooks/tests/test-instruction-style-gate.sh
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/instruction-style-gate.sh"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
PASS=0
FAIL=0

OWNER="$TMP/style.md"
cat > "$OWNER" <<'EOF'
**Документы (посты, инструкции, гайды):**
- Первый абзац - суть.

**Пошаговая инструкция для человека** (решение пилота).
- **Где.** Каждое действие начинается с места.
- **Одна команда - один блок кода.** Своя рамка у каждой команды.

**Чат с пилотом (Claude Code, Kimi):**
- Режим «на пальцах».
EOF

FENCE='```'
INSTRUCTION="Нажми Cmd+Пробел и открой Терминал.

${FENCE}bash
brew install git
${FENCE}"

# run TOOL FILE TEXT [SESSION] -> prints "deny" or "pass", stderr to $TMP/err
run() {
  local field=content
  [ "$1" = Edit ] && field=new_string
  python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[4],"tool_name":sys.argv[1],"tool_input":{"file_path":sys.argv[2],sys.argv[5]:sys.argv[3]}}))' \
    "$1" "$2" "$3" "${4:-s1}" "$field" \
    | CLAUDE_PROJECT_DIR="$TMP/proj" IWE_INSTRUCTION_STYLE_SOURCE="${SOURCE:-$OWNER}" bash "$HOOK" 2>"$TMP/err" > "$TMP/out"
  if jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/out" >/dev/null 2>&1; then echo deny; else echo pass; fi
}
expect() {
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (ожидалось $3, получено $2)"; fi
}

expect "instruction .md, first write" "$(run Write /x/guide.md "$INSTRUCTION")" deny
grep -q 'Одна команда - один блок кода' "$TMP/out" && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "FAIL: rule text not in the reason"; }
grep -q 'Чат с пилотом' "$TMP/out" && { FAIL=$((FAIL + 1)); echo "FAIL: next section leaked into the reason"; } || PASS=$((PASS + 1))
expect "same file, second write" "$(run Write /x/guide.md "$INSTRUCTION")" pass
expect "same file, other session" "$(run Write /x/guide.md "$INSTRUCTION" s2)" deny
expect "other instruction file" "$(run Write /x/other.md "$INSTRUCTION")" deny
expect "Edit with powershell and вы-form" "$(run Edit /x/win.md "$(printf 'Откройте PowerShell.\n\n%spowershell\nwinget install jq\n%s' "$FENCE" "$FENCE")")" deny
expect "code file" "$(run Write /x/tool.sh "$INSTRUCTION")" pass
expect "doc without a command block" "$(run Write /x/note.md 'Нажми кнопку и открой файл.')" pass
expect "doc with code but no imperative" "$(run Write /x/tech.md "$(printf 'Формат:\n\n%sbash\nls\n%s' "$FENCE" "$FENCE")")" pass
expect "yaml block is not a command" "$(run Write /x/cfg.md "$(printf 'Открой файл.\n\n%syaml\na: 1\n%s' "$FENCE" "$FENCE")")" pass
SOURCE="$TMP/missing.md"
expect "rule source missing" "$(run Write /x/new.md "$INSTRUCTION")" pass
grep -q 'WARN' "$TMP/err" && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "FAIL: no warning when the rule source is missing"; }

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
